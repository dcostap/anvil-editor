# Git diff gutter and right-side overview improvement plan

## Objective

Improve Anvil's built-in `gitdiff_highlight` feature so it is robust, fast, and closer to IntelliJ's line status behavior:

- accurate gutter markers for added, modified, and deleted lines;
- fast updates for unsaved edits without running Git on every keystroke;
- reliable behavior for large files, spaces in paths, CRLF/LF, branch/index changes, and non-Git files;
- right-side whole-document diff markers drawn in the vertical scrollbar/error-stripe area, underneath the scrollbar thumb, so marker positions correspond to the global document position like IntelliJ and other IDEs.

## Golden-reference study: IntelliJ Community

Fetched repository:

```text
C:\Users\Dario Costa\AppData\Local\pi-web-smart-fetch\github-cache\JetBrains\intellij-community
```

Important IntelliJ files inspected:

- `platform/diff-impl/src/com/intellij/openapi/vcs/ex/LineStatusTrackerI.kt`
- `platform/diff-impl/src/com/intellij/openapi/vcs/ex/LineStatusTrackerBase.kt`
- `platform/diff-impl/src/com/intellij/openapi/vcs/ex/DocumentTracker.kt`
- `platform/diff-impl/src/com/intellij/openapi/vcs/ex/RangesBuilder.kt`
- `platform/diff-impl/src/com/intellij/openapi/vcs/ex/LineStatusMarkerRenderer.kt`
- `platform/diff-impl/src/com/intellij/openapi/vcs/ex/LineStatusMarkerRendererWithPopup.kt`
- `platform/diff-impl/src/com/intellij/openapi/vcs/ex/LineStatusGutterMarkerRenderer.kt`
- `platform/diff-impl/src/com/intellij/openapi/vcs/ex/VisibleRangeMerger.java`
- `platform/vcs-impl/src/com/intellij/openapi/vcs/ex/LineStatusTracker.kt`
- `platform/vcs-impl/src/com/intellij/openapi/vcs/impl/LineStatusTrackerManager.kt`
- `platform/platform-impl/src/com/intellij/openapi/editor/impl/EditorMarkupModelImpl.kt`
- `platform/platform-impl/src/com/intellij/openapi/editor/impl/ErrorStripeMarkersModel.java`

Key lessons to adapt:

1. **Separate model from rendering.** IntelliJ has a line status tracker that owns stable changed ranges, and renderers merely paint them.
2. **Compare current document against base revision content, not by parsing `git diff --word-diff`.** IntelliJ loads VCS/base content, keeps a second document, and diffs current vs base.
3. **Use ranges, not a per-line-only map.** Ranges represent current lines and base lines, so deletion anchors and navigation stay correct.
4. **Be explicit about update lifecycle.** IntelliJ's `DocumentTracker.kt` is incremental and has freeze/unfreeze semantics. Anvil's first version can full-recompute, but it must be bounded, debounced, and stale-result safe.
5. **Paint gutter and overview/error-stripe separately from the same range model.** IntelliJ creates one gutter highlighter plus separate thin error-stripe highlighters from the same ranges.
6. **Draw overview markers underneath/inside the scrollbar area.** IntelliJ's error stripe code draws thin marks in the scrollbar component and keeps the scrollbar interaction available.
7. **Use careful visual merging.** `EditorMarkupModelImpl.kt` merges overlapping error-stripe marks by layer/color and applies minimum marker height. Anvil should pre-merge pixel bands when many ranges map to the same pixels.
8. **Whitespace handling matters.** `RangesBuilder.kt` compares with `IGNORE_WHITESPACES` first, then only treats exact-equal lines as unchanged; this helps blank-line-heavy changes render as continuous blocks instead of dashed fragments.
9. **Trim equal prefix/suffix before expensive diff work.** IntelliJ narrows the changed area before comparing. Anvil should do the same so huge clean files and huge files with one tiny edit do not get disabled unnecessarily.

## Current Anvil state and limitations

Relevant Anvil files:

- `data/plugins/gitdiff_highlight/init.lua`
- `data/plugins/gitdiff_highlight/gitdiff.lua`
- `data/core/docview.lua`
- `data/core/scrollbar.lua`
- `data/plugins/diffview.lua` for an existing example of drawing change markers over scrollbar tracks.

Current limitations:

- `gitdiff_highlight` shells out to `git diff HEAD --word-diff --unified=1` and parses word-diff text. This is fragile and loses true base/current line-range structure.
- Git commands run synchronously inside a coroutine and can still be expensive for load/save.
- Unsaved edits are approximated in `Doc:on_text_change`, so insert/delete classification can be wrong.
- Diff state is effectively a sparse line map; deletion-only ranges and multi-line modified ranges are not represented explicitly.
- Right-side overview markers exist only in `diffview.lua`, not for normal document Git diffs.
- The current native `diff.diff_iter()` path is unsafe for large files: `src/api/diff.c` builds the LCS table before returning the Lua iterator, so a coroutine cannot yield during the expensive allocation/computation. Budgets must be checked before creating the iterator.
- Without prefix/suffix trimming, a very large clean file or a very large file with one small edit would exceed a naive `#base_lines * #doc.lines` budget even though the meaningful changed middle is tiny.
- A full per-line `line_index` table can become expensive for huge additions or whole-file changes.
- Git base bytes may need encoding conversion. If Anvil has loaded a non-UTF-8 file into UTF-8 `doc.lines`, raw `git show` output compared directly can create false diffs.
- Git process pipe handling must be robust. Waiting for process exit before reading large stdout/stderr can deadlock if pipe buffers fill.

## Proposed architecture

Keep this as a Lua plugin feature first. Only add core hooks if plugin-level overrides become too fragile.

### Data model

Use sorted half-open ranges internally, inspired by IntelliJ. Public drawing code can convert to 1-based visible line positions as needed.

```lua
---@class gitdiff.range
---@field type "addition"|"modification"|"deletion"
---@field current_start integer -- 1-based current-document line anchor, inclusive
---@field current_end integer   -- 1-based current-document line, exclusive
---@field base_start integer    -- 1-based base-revision line, inclusive
---@field base_end integer      -- 1-based base-revision line, exclusive
```

Meaning:

- addition: `base_start == base_end` and `current_start < current_end`;
- deletion: `current_start == current_end` and `base_start < base_end`;
- modification: both ranges are non-empty.

Tracker state:

```lua
---@class gitdiff.state
---@field is_in_repo boolean
---@field operational boolean
---@field loading boolean
---@field too_large boolean?
---@field generation integer
---@field base_generation integer
---@field local_generation integer
---@field repo_root string?
---@field rel_path string?
---@field base_text string?
---@field base_lines string[]?
---@field ranges gitdiff.range[]
---@field visible_cache table?       -- optional, derived only for current viewport
---@field overview_cache table?      -- optional, pre-merged pixel bands
---@field overview_cache_key table?  -- range generation + view/scale/style dimensions
---@field error string?
```

Principles:

- `ranges` is the source of truth.
- Do **not** rely on a full per-line map for large files. Prefer sorted ranges plus binary search for visible gutter rendering.
- A compact visible cache is allowed per frame/viewport.
- An overview pixel-band cache is allowed after range computation to avoid per-frame recomputation, but it must be invalidated by range generation, view/track size, line height, scale/DPI, style color/alpha, document line count, and scrollbar forced/expanded mode if marker width depends on it.
- deletion-only ranges are zero-current-width anchors rendered as horizontal marks at a defined current-document position.
- state has monotonic generations; async jobs must discard stale results.

### Deletion anchors

Define deletion anchors before implementation, because this is where inclusive line maps become fragile.

Use half-open `current_start == current_end` as the deletion anchor. Rendering rules:

- deletion at file start: anchor `current_start = 1`; draw at the top edge of line 1;
- deletion between two current lines: anchor is the following current line; draw at the top edge of that line;
- deletion at EOF: anchor `current_start = #doc.lines + 1`; because normal `draw_line_gutter(line, ...)` cannot draw line `#doc.lines + 1`, render it as an overlay at the bottom edge of the last visible/document line, or clamp to `#doc.lines` and draw at that line's bottom edge;
- whole-file delete / empty current document: clamp visual drawing to the available Anvil line representation and draw a deletion marker at the top and/or bottom edge as needed;
- account for Anvil's line representation. `Doc:load()` stores lines with trailing `"\n"`, empty files become a document-line representation rather than a truly zero-line buffer, and Anvil may not currently preserve "no final newline" as a distinct normal loaded-document state. Base splitting must mimic `Doc:load()` exactly, normalize CRLF to `"\n"` for comparison, and tests for no-final-newline should expect collapse to Anvil's representation unless core document semantics change.

## Git/base content loading

Use the user's installed Git executable. Do **not** bundle Git, libgit2, or a portable Git binary for this feature in the first implementation. This keeps Anvil smaller, avoids Git distribution/update/security complexity, and matches the expectation that Git-aware editor features depend on the user's Git installation.

Default command path:

```lua
config.plugins.gitdiff_highlight.git_path = "git"
```

If Git is not found or cannot be executed:

- disable Git diff markers for the affected session/document;
- show a clear app warning/notification once, not repeatedly on every file or keystroke;
- include enough information for the user to fix it, e.g. "Git executable not found. Install Git or configure `config.plugins.gitdiff_highlight.git_path`.";
- keep the editor fully usable with no markers.

Use Git only to discover/load base content, not to produce rendered line markers:

1. On document load or filename change:
   - run `git -C <file-dir> rev-parse --show-toplevel`;
   - compute/capture the canonical repo-relative path with forward slashes, preferably using `git -C <root> ls-files --full-name --error-unmatch -- <file>`;
   - use argument arrays for process calls so spaces in paths are safe;
   - handle nested Git repositories and worktrees by trusting Git's reported root/path, not by manual parent-directory guessing.
2. Decide and document base policy:
   - first implementation: compare current buffer to `HEAD`;
   - this intentionally means staged changes are still shown as changes against `HEAD`;
   - staged/index-aware support can be a later option, because Git staging complicates the meaning of "base";
   - v1 rename limitation: a renamed tracked file may appear as all-added if `HEAD:<new-path>` does not exist. Later, query rename info with `git status --porcelain=v2` or `git diff --name-status HEAD -- <path>` and load the old path as the base.
3. Load base revision:
   - normal tracked file: `git -C <root> show --textconv HEAD:<rel-path>` if available; fall back to `git show HEAD:<rel-path>`;
   - unborn `HEAD`: if the file is tracked in the index but there is no `HEAD`, treat base as empty;
   - file tracked in index but missing in `HEAD`: base is empty, so the document is all additions;
   - untracked/non-Git: mark `is_in_repo=false` and clear markers;
   - symlink/submodule paths should fail gracefully in v1 if content cannot be loaded as a normal text blob.
4. Run Git processes safely:
   - start with `stdout` and `stderr` redirected, or explicitly discard a stream only when safe;
   - read stdout incrementally while the process runs, with a hard cap of `max_file_size + 1`;
   - read enough stderr for diagnostics without allowing stderr to block the process;
   - kill/fail the job if stdout exceeds the cap;
   - handle `process.start()` failure/nil returns;
   - always clear `loading=true` on success, failure, timeout, or cancellation.
5. Validate and decode content:
   - check return codes and stderr before accepting stdout;
   - never treat truncated stdout as valid base text;
   - detect NUL bytes/binary content and mark non-operational;
   - convert Git blob bytes using `doc.encoding` when available so base text matches Anvil's decoded `doc.lines`;
   - if encoding conversion is unavailable or invalid, initially disable gitdiff for non-UTF-8/converted documents instead of producing false diffs;
   - preserve Anvil line format by splitting base text into the same representation as `doc.lines`.
6. Cache repo discovery by directory/root to avoid repeated `rev-parse`.
7. Refresh base content after save, explicit command, and later from `.git/HEAD`/`.git/index`/refs monitoring if needed.

## Diff computation

Compute ranges in Anvil from `base_lines` and current in-memory `doc.lines`, but only when within a hard budget.

### Prefix/suffix trimming and budget

Before calling `diff.diff_iter(base_lines, doc.lines)`, first narrow the problem:

1. Fast path exact equality: if the loaded base text/lines equal current doc lines, publish `ranges = {}` without invoking the C diff.
2. Scan equal prefix lines.
3. Scan equal suffix lines without crossing the prefix.
4. Diff only the unmatched middle slices.
5. Apply `base_shift` / `current_shift` when converting middle-slice diff output back to document ranges.
6. Budget on the trimmed middle, not the whole file.

```lua
base_mid_count = base_mid_end - base_mid_start
current_mid_count = current_mid_end - current_mid_start
cells = base_mid_count * current_mid_count
if cells > config.plugins.gitdiff_highlight.max_diff_cells
   or base_mid_count > config.plugins.gitdiff_highlight.max_diff_lines
   or current_mid_count > config.plugins.gitdiff_highlight.max_diff_lines then
  state.too_large = true
  state.operational = false -- or degraded, depending on later policy
  state.ranges = {}
  return
end
```

This is critical for large files: a huge clean file or a huge file with one small edit should remain supported because the changed middle is small.

Suggested conservative initial defaults:

```lua
config.plugins.gitdiff_highlight.max_file_size = 2 * 1024 * 1024
config.plugins.gitdiff_highlight.max_diff_cells = 2 * 1000 * 1000
config.plugins.gitdiff_highlight.max_diff_lines = 50000
```

The actual `max_diff_lines` used for a DP middle slice may need to be lower after testing, because `src/api/diff.c` casts lengths to `int` and allocates a DP matrix.

Recommended initial behavior for oversized files:

- fail gracefully with `too_large=true` and no markers;
- log quietly only if debug logging is enabled;
- later alternatives:
  - external `git diff --numstat`/`--unified=0` coarse parser in a background process;
  - a better native diff algorithm with bounded memory;
  - an incremental tracker similar to IntelliJ `DocumentTracker.kt`.

Do not rely on yielding inside `diff.diff_iter()` for responsiveness. The budget must be checked before the iterator is created.

### Range building

For trimmed middle slices under budget:

- use `diff.diff_iter(base_mid_lines, current_mid_lines)`;
- convert output to half-open `gitdiff.range[]` with the prefix shifts applied;
- tag conversion:
  - `insert` in B/current => `addition`;
  - `delete` from A/base => `deletion`;
  - `modify` => `modification`;
  - adjacent delete+insert at the same anchor => one `modification` block;
- coalesce adjacent insert/delete pairs into modification blocks when they represent replacement;
- coalesce adjacent same-type ranges separated only by blank lines, preserving the IntelliJ-like continuous block behavior currently approximated by `effective_diff_for_line`;
- add optional whitespace policy later, inspired by IntelliJ `RangesBuilder.kt`: compare ignoring whitespace first, then only mark exact-equal lines as truly equal to avoid confusing blank-line splits.

## Update scheduling

Implement concrete per-document coalescing semantics:

- one pending local-diff worker per doc;
- one pending base-load worker per doc;
- debounce deadline stored in state;
- local diff generation separate from base generation;
- stale local diff results discarded if the doc changed again;
- stale base-load results discarded if filename/repo/path/generation changed;
- base reload completion immediately schedules local diff against the latest doc text;
- process failures always clear `loading=true` and set `error`/`operational=false` as appropriate.

Initial trigger matrix:

| Event | Action |
| --- | --- |
| `Doc:load` | discover repo + load base + schedule local diff |
| `Doc:on_text_change` | schedule debounced local diff only |
| `Doc:save` | reload base after save, then schedule local diff |
| `Doc:set_filename` / path change | rediscover repo/path and reload base |
| explicit `gitdiff:refresh` | force base reload |
| branch/index change later | force base reload |
| non-repo/binary/too-large | mark non-operational and clear markers |

When wrapping core methods, preserve arguments, returns, and errors:

- `Doc:on_text_change(change_type)` must call the original with the actual `change_type`, then schedule debounce. The current plugin has a suspicious wrapper path that passes the global `type` function instead of the change type; fix this during refactor.
- `Doc:save(...)` must schedule reload only after a successful save and must preserve all return values/errors from the original save.
- `Doc:load(...)` must preserve return values/errors and schedule work only after successful load.
- path changes/reloads must bump generations so pending workers cannot publish stale results to the wrong file.

## Rendering plan

### Left gutter markers

Keep the visual language from the current plugin:

- addition/modification: vertical stripe spanning the current line range;
- deletion: small horizontal marker anchored at the deletion position;
- same colors by default:
  - `style.gitdiff_addition`
  - `style.gitdiff_modification`
  - `style.gitdiff_deletion`

Changes:

- draw from sorted half-open `ranges`, not parsed Git output;
- binary-search the first range intersecting the visible line interval;
- use a visible-range cache if useful;
- keep the reserved marker lane to avoid layout jumps;
- implement a post-line overlay path or bottom-edge fallback for EOF deletions.

### Right-side global/overview markers

Add normal document overview markers to `gitdiff_highlight` by overriding `DocView:draw_scrollbar`, but with guardrails.

Desired draw order:

1. draw vertical scrollbar track or equivalent track basement;
2. draw Git overview markers inside the vertical scrollbar/error-stripe lane;
3. draw vertical scrollbar thumb on top;
4. draw horizontal scrollbar normally.

This makes markers appear below/beneath the scrollbar thumb while sharing the same right-side space.

Implementation options, in order of increasing robustness:

- short-term plugin-only: call the previous scrollbar draw, draw markers, then redraw `self.v_scrollbar:draw_thumb()` so markers are visually beneath the thumb;
- better plugin-only: manually call `self.v_scrollbar:draw_track()`, draw markers, `self.v_scrollbar:draw_thumb()`, then `self.h_scrollbar:draw()`;
- best long-term: add a small core hook for "draw vertical scrollbar track overlay" so plugins do not fight over `DocView:draw_scrollbar` overrides.

Exact IntelliJ behavior includes an error-stripe lane integrated with scrollbar thickness. For v1, sharing the existing vertical scrollbar track is acceptable; later we may add a separate thin lane next to the thumb if the shared track feels too cramped.

Important mapping correction: use full-document/source coordinates, not scroll range. This better matches IntelliJ's `EditorMarkupModelImpl.offsetsToYPositions()` behavior and avoids EOF markers being pushed by viewport size.

```lua
source_h = math.max(1, #doc.lines * line_height)
marker_y = track_y + (((range.current_start - 1) * line_height) / source_h) * track_h
marker_h = math.max(min_h, range_current_line_count * line_height / source_h * track_h)
```

Then clamp to the track.

Rules:

- deletion ranges have `range_current_line_count == 0`; draw with minimum height at the deletion anchor;
- short files and `scroll_past_end` on/off must be tested;
- pre-merge markers that land on the same pixel bands; if colors conflict, use modification color or a stable priority order;
- draw markers even when the scrollbar track would normally be visually subtle/hidden, then draw the thumb on top;
- use semi-transparent colors if full-opacity markers fight the scrollbar thumb.

Configuration:

```lua
config.plugins.gitdiff_highlight = config.plugins.gitdiff_highlight or {}
config.plugins.gitdiff_highlight.enabled = true
config.plugins.gitdiff_highlight.gutter = true
config.plugins.gitdiff_highlight.overview = true
config.plugins.gitdiff_highlight.show_untracked_as_added = false
config.plugins.gitdiff_highlight.local_diff_debounce_ms = 200
config.plugins.gitdiff_highlight.git_path = "git" -- user's Git executable
config.plugins.gitdiff_highlight.max_file_size = 2 * 1024 * 1024
config.plugins.gitdiff_highlight.max_diff_cells = 2 * 1000 * 1000
config.plugins.gitdiff_highlight.max_diff_lines = 50000
```

### Rendering override compatibility

Because `gitdiff_highlight` globally overrides `DocView` methods:

- preserve and call previous overrides where possible;
- avoid drawing Git overview markers in `diffview` internal docviews unless explicitly intended: check `self.diff_view_parent`;
- compose safely with other plugins that also override scrollbars/minimap;
- preserve current minimap support at first, but avoid using minimap as the primary overview implementation;
- verify forced-expanded, forced-contracted, hover-expanded, hidden scrollbar modes, resize, font change, and DPI/scale changes;
- invalidate overview pixel-band caches when range generation, view height, scrollbar track rect, line height, scale/DPI, style colors/alpha, document line count, or relevant scrollbar mode changes.

## Navigation and interaction

Short-term:

- make `gitdiff:next-change` and `gitdiff:previous-change` navigate by sorted ranges;
- add `gitdiff:refresh`;
- clicking the overview track should keep normal scrollbar behavior initially.

Later:

- click gutter marker to open a small popup showing base/current hunk, mirroring IntelliJ `LineStatusMarkerRendererWithPopup.kt`;
- actions: previous, next, copy base hunk, revert hunk, open full diff;
- optional right-side marker hover tooltip/preview.

## Implementation phases

### Phase 0 - Constraints and test fixtures

Before UI changes:

- define the half-open range model;
- define base/current line splitting so it exactly matches Anvil `doc.lines`;
- define deletion anchors for start, middle, EOF, whole-file delete, and empty files;
- define `max_file_size`, `max_diff_cells`, and `max_diff_lines` budgets;
- document that Anvil may collapse no-final-newline distinctions unless core document semantics change;
- add pure Lua table-driven range-builder tests independent of UI;
- add a dev command to print/validate ranges for the active document;
- add temporary Git repo integration tests/dev scripts for path spaces, unborn `HEAD`, CRLF, added file, renamed file, nested repo/worktree if practical;
- include blank-line coalescing and CRLF/no-final-newline fixtures;
- validate changed Lua files with `luajit check-lua-syntax.lua`.

### Phase 1 - Range builder

- Add `data/plugins/gitdiff_highlight/ranges.lua`.
- Implement exact-clean fast path and prefix/suffix trimming.
- Budget the trimmed middle before creating `diff.diff_iter`.
- Implement conversion from `diff.diff_iter(base_mid_lines, current_mid_lines)` to sorted half-open `gitdiff.range[]`, with prefix shifts applied, under budget only.
- Add tests/fixtures for:
  - one-line modification;
  - multi-line addition;
  - deletion at start/middle/EOF;
  - whole-file delete;
  - empty file vs non-empty file;
  - blank-line-heavy modifications;
  - file with no trailing newline if Anvil can represent it distinctly.

### Phase 2 - Async tracker and Git loader

- Refactor `init.lua` into tracker functions:
  - `ensure_state(doc)`;
  - `schedule_base_reload(doc, reason)`;
  - `schedule_local_diff(doc, reason)`;
  - `publish_state(doc, generation, state)`.
- Replace `git diff --word-diff` with base content loading.
- Implement safe Git process draining with stdout/stderr caps and timeout/failure cleanup.
- Implement encoding handling: convert base bytes using document encoding when possible, otherwise disable for non-UTF-8/invalid converted documents.
- Implement one pending base-load worker and one pending local-diff worker per doc.
- Keep stale-result protection.
- Add debug logging only behind a config flag.

### Phase 3 - Gutter renderer migration

- Update `DocView:draw_line_gutter` override to use sorted ranges.
- Preserve gutter width reservation.
- Fix deletion anchors at file start/end and after removed final lines.
- Migrate navigation to ranges.

### Phase 4 - Right-side overview markers

- Override `DocView:draw_scrollbar` in `gitdiff_highlight` with compatibility guards.
- Map overview markers using full document/source height.
- Pre-merge markers that land on the same pixels.
- Draw vertical track, Git overview markers, then thumb; if using short-term compatibility path, redraw the vertical thumb after markers.
- Keep horizontal scrollbar behavior unchanged and draw it after markers so markers do not cover it.
- Clamp EOF deletion markers carefully.
- Use scaled minimum marker height once; avoid double-applying `SCALE`.
- Pre-merge pixel bands by priority, e.g. deletion > modification > addition, or use modification as conflict color.
- Avoid drawing inside `diffview` child docviews unless explicitly desired.

### Phase 5 - Robustness polish

- Handle CRLF/LF consistently by splitting base text with Anvil's line semantics.
- Handle paths with spaces and Windows separators via process argument arrays and forward-slash repo-relative paths.
- Document v1 rename behavior and optionally add old-path lookup for renames.
- Handle nested Git repos/worktrees gracefully through Git-reported roots.
- Mark binary/invalid-encoding/too-large files non-operational without errors.
- Add refresh after save and explicit `gitdiff:refresh`.
- Add repo/root cache invalidation.
- Test plugin coexistence with `diffview`, minimap, and forced scrollbar modes.

### Phase 6 - Optional IntelliJ-like popups and hunk actions

- Use range model to extract base/current hunk text.
- Show a lightweight popup near the gutter marker.
- Add actions for copy/revert/open full diff.
- Implement revert by replacing the current document range with base range text.

### Phase 7 - Future large-file/incremental diff work

If full recompute is still too limited:

- add a better native diff algorithm with bounded memory;
- or add a simplified incremental tracker inspired by IntelliJ `DocumentTracker.kt`;
- or use external Git diff output only as a coarse fallback for huge files, explicitly separate from the normal precise path.

## Validation checklist

Manual cases:

- non-Git file: no markers, no errors;
- tracked clean file: no markers;
- unsaved one-line edit: modification marker appears after debounce;
- unsaved inserted lines: addition markers appear without saving;
- unsaved deleted lines: deletion marker appears at correct anchor;
- deletion at file start;
- deletion at EOF;
- whole-file delete;
- empty file vs non-empty file;
- file with no trailing newline, with expected behavior matching current Anvil line semantics;
- changed block containing blank lines: continuous marker, not dashed;
- Git executable missing: one clear warning/notification, no repeated spam, no markers;
- custom `git_path` points to a valid Git executable;
- file with spaces in path;
- CRLF file;
- new tracked file not in `HEAD`: all additions;
- unborn `HEAD` repository;
- staged-but-unsaved file: changes are shown against `HEAD` in v1;
- renamed tracked file: v1 limitation is documented or old-path lookup works;
- branch switch while base load is still running;
- file rename/path change while a diff job is pending;
- non-UTF-8 text file;
- symlink or submodule path;
- file in nested Git repo;
- file in Git worktree;
- Git command writes stderr but valid stdout;
- Git process starts but exceeds stdout cap;
- binary file tracked by Git;
- very large clean file;
- very large file with one small edit;
- save after edits: markers recompute and remain correct;
- explicit `gitdiff:refresh` after branch/reset updates base;
- resize/font-scale changes while overview markers are visible;
- scrollbar hidden/contracted/expanded/hover states;
- multiple views of the same document;
- plugin coexistence with `diffview`, minimap, and forced scrollbar modes.

Performance checks:

- no Git process on every keystroke;
- exact-clean and prefix/suffix-trimmed files avoid unnecessary full diff work;
- no call to `diff.diff_iter` beyond `max_diff_cells` / `max_diff_lines` for the trimmed middle;
- stdout/stderr are drained safely and capped; large Git blobs cannot deadlock the editor;
- no full-range or full-line-index scan in every draw for huge documents;
- stale async jobs do not overwrite newer state;
- process failures do not leave `loading=true`.

## Acceptance criteria

- Gutter markers stay accurate for additions, modifications, and deletions while editing unsaved buffers.
- Right-side overview markers are visible in normal document views, underneath the scrollbar thumb, and align with full-document positions.
- Navigation jumps by hunk/range, not individual noisy lines.
- Large or unsupported files fail gracefully without UI stalls.
- The implementation remains mostly isolated to `data/plugins/gitdiff_highlight` unless core scrollbar hooks become clearly necessary.
