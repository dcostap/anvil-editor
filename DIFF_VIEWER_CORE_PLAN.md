# Diff View Core Integration Plan

## Current status

Diff View has been moved most of the way from a monkey-patched two-`DocView` plugin toward a first-class diff viewer built on core extension points.

This plan now tracks only what is done and what still needs implementation. Historical exploration details have been removed.

## Completed

### Core listener/provider groundwork

Completed:

- `Doc` has per-document text change listeners:
  - `add_text_change_listener(id, listener)`
  - `remove_text_change_listener(id)`
  - covers `apply_edits`, undo/redo transaction paths, and direct `raw_insert` / `raw_remove` mutations.
- `DocView` has extension/listener APIs:
  - decoration providers for line backgrounds, inline ranges, and provider text color.
  - POI providers.
  - selection listeners.
  - scroll listeners.
  - fold listeners.
  - visual-row providers for line-height row counts.
- Provider/listener registration is keyed by stable ids and supports deterministic priority ordering where ordering matters.

### Structural diff model

Completed:

- `data/plugins/diff/model.lua` contains reusable structural diff state:
  - per-side changes.
  - inline changed ranges.
  - equal blocks for fold candidates.
  - side-to-side line mapping.
  - hunk lookup/navigation helpers.
- Diff computation is no longer embedded directly in `DiffView:update_diff()`.
- `DiffView` still owns scheduling, generation IDs, stale-result rejection, listener/provider installation, layout, and disposal.

Design decision:

- `DiffModel` stays under `data/plugins/diff` for now. It can move to `data/core` later if another first-party feature needs it outside the diff plugin.

### DiffView no longer monkey-patches child instances

Completed:

- Removed `DiffView:patch_views()` method replacement behavior.
- Diff View no longer replaces child `DocView` or `Doc` methods for:
  - drawing.
  - scroll synchronization.
  - selection/caret synchronization.
  - text-change detection.
  - POI generation.
  - previous/next change navigation.
- Diff rendering uses `DocView` decoration providers.
- Diff POIs use `DocView` POI providers.
- Diff rediff uses document text-change listeners.
- Caret sync uses selection listeners.
- Scroll sync uses scroll listeners.
- Divider connectors and sync arrows remain owned by `DiffView`, because they are divider UI, not child gutter UI.

### Request/content normalization

Completed:

- Existing helper inputs are internally normalized into `DiffRequest` / `DiffContent` records.
- Added public-ish construction helpers:
  - `diffview.open(request, noshow)`
  - `diffview.content.text(text, opts)`
  - `diffview.content.file(path, opts)`
  - `diffview.content.document(doc, opts)`
  - `diffview.content.empty(opts)`
- Legacy helpers still route through the new request path:
  - `string_to_string`
  - `file_to_file`
  - `file_to_string`
  - `string_to_file`

Design decisions:

- Text and empty contents create owned untitled documents.
- Caller-provided document contents are caller-owned unless explicitly marked owned.
- File contents create file-backed documents and are not owned by the Diff View.

### Initial Git View migration

Completed:

- Git View creates commit diff panes through `diffview.open(request, true)` instead of `string_to_string(...)`.
- Git requests include metadata for:
  - selected changed file.
  - selected file path/index.
  - left/right revision endpoints.
  - read-only policy.

### Initial visual-row providers

Completed:

- Added `DocView:add_visual_row_provider(id, provider, opts)` and `remove_visual_row_provider(id)`.
- Diff gap/alignment rows use the provider API instead of direct `set_visual_row_extension` calls.

Current limitation:

- Providers currently expose line-height row counts only. They do not yet expose row objects, drawing callbacks, or hit-testing.

### Initial paired fold listeners

Completed:

- Added `DocView:add_fold_listener(id, fn)` and `remove_fold_listener(id)`.
- Fold listeners fire for fold add/remove/expand/collapse/change/invalidate events.
- Diff paired fold expansion now reacts through fold listeners instead of intercepting fold-widget clicks before `DocView` handles them.

Current limitation:

- Fold state is still preserved by equal-block index, not by stable content identity.

## Remaining work

### 1. Rich visual-row provider objects

Current state:

- Visual-row providers support only count-style line-height rows before/after document lines.
- Current count semantics are cumulative for `before[line]`: a diff gap provider can say "there are N total extra rows before this document line" and `DocView` computes the per-line delta.

Finish by adding provider-owned row objects while preserving existing count providers.

Provider API:

```lua
provider:visual_rows(view, line, placement, previous_line_total) -> {
  {
    id = "stable-row-id",
    kind = "diff-gap" | "action" | string,
    height_rows = 1,
    draw = function(view, row, x, y, w, h) end,
    hit_test = function(view, row, x, y) end,
    on_click = function(view, row, button, x, y, clicks) end,
    metadata = {},
  }
}
```

Core composition contract:

- Rows are still one `DocView:get_line_height()` tall. Arbitrary pixel-height rows are not part of this phase.
- Count providers stay supported:
  - `before[line]` keeps its existing cumulative meaning.
  - `rows_before(view, line)` may return either a cumulative count or row objects; object-returning providers should be per-anchor objects.
  - legacy anonymous count rows are synthesized as internal row entries with generated ids.
- Object rows are anchored to a document line plus placement:
  - `placement = "before"` rows appear before that line's fold/line rows.
  - `placement = "after"` rows appear after that line's fold/line rows. Intermediate `after` rows must be included, not only trailing EOF rows.
- Row ordering is deterministic:
  - provider priority.
  - provider id.
  - row order returned by that provider.
- `DocView:get_visual_row_entry(row)` must return provider row entries like:

```lua
{
  type = "provider",
  provider_id = id,
  line = line,
  placement = "before" | "after",
  row = absolute_row,
  row_in_provider = n,
  provider_row = row_object,
}
```

- Drawing should dispatch provider row `draw(...)` for visible provider rows before ordinary line text drawing.
- Mouse resolution should preserve provider row identity. A click on a provider row should call `row.hit_test` / `row.on_click` before falling back to ordinary document-line selection.
- Diff gap rows can remain anonymous blank rows until a visible action row is needed.

Tests to add/update:

- provider row draw callback runs for visible extra rows.
- click hit-testing resolves to the provider row and does not start normal text selection.
- wrapped document lines plus before/after provider rows compose correctly.
- count-style diff gap providers remain compatible.
- provider removal restores ordinary `DocView` row counts and hit-testing.

### 2. Stable diff fold identity

Current state:

- Diff fold expansion state is keyed by equal-block index.
- Edits can shift/reorder equal blocks, so expansion state can be lost or applied to the wrong block.

Finish by replacing index-only fold preservation with stable identity matching.

Identity model:

- Primary identity must be content/neighbor based, not position based.
- Primary identity fields:
  - previous hunk signature, if present.
  - next hunk signature, if present.
  - normalized first visible unchanged line in the candidate.
  - normalized last visible unchanged line in the candidate.
  - hidden-line count bucket/exact count, used only when it improves uniqueness.
- Position fields such as side starts/counts are **tie-breakers only**. They must not be part of the strict identity key, because insertion before a fold shifts positions.
- Hunk signatures should be small and stable:
  - hunk tag.
  - first changed line text hash/summary on both sides when available.
  - last changed line text hash/summary on both sides when available.
  - hunk changed-line counts.
- Ambiguity handling:
  - Build candidate identities for old expanded folds and new fold candidates.
  - If exactly one new candidate matches an old identity, preserve expansion.
  - If zero candidates match, reset to default fold behavior.
  - If multiple candidates match, use position as a tie-breaker only if it chooses one clearly nearest candidate; otherwise reset to default fold behavior.
- Keep numeric `index` only for diagnostics/display. Do not use it as persisted expansion state.

Tests to add:

- expanding a long unchanged region survives insertion before the region.
- expanding a region does not expand a different equal block after repeated-content edits.
- deleting/touching the folded unchanged block safely resets fold state.
- identical repeated equal blocks become ambiguous and reset instead of preserving incorrectly.

### 3. Public DiffRequest / DiffContent API hardening

Current state:

- Request/content helpers exist and legacy helpers route through them.
- API is usable but not documented as stable.

Finish by making the contract explicit and validating requests before opening a view.

Request schema:

```lua
{
  title = string?,
  kind = "text" | "git" | "blank" | "file" | string,
  contents = { left = content, right = content },
  content_titles = { left = string?, right = string? }?,
  editable_policy = "read-only" | "content" | "editable"?,
  preferred_focus_side = "left" | "right"?,
  metadata = table?,
}
```

`DiffContent` is a discriminated union. Common optional fields:

```lua
{
  kind = string,
  name = string?,
  editable = boolean?,
  owns_doc = boolean?,
  read_only_reason = string?,
  syntax_hint = string?,
}
```

Kind-specific fields:

```lua
-- text: DiffView creates an owned untitled Doc from text.
{ kind = "text", text = string, ... }

-- empty: DiffView creates an owned empty untitled Doc.
{ kind = "empty", ... }

-- file: DiffView creates/opens a normal file-backed Doc.
{ kind = "file", filename = string, ... }

-- document: caller provides an existing Doc.
{ kind = "document", doc = Doc, ... }
```

Validation/defaulting rules:

- `request.contents.left` and `request.contents.right` are required for two-way side-by-side Diff View.
- Unknown content kinds are invalid unless a future content resolver is explicitly registered.
- `content_titles.side` overrides `content.name` for UI side labels when present.
- `content.name` is used as the created document name when no side title is given.
- Missing `editable_policy` defaults to `"content"`.
- Invalid requests should return a clear error object/string; they should not fail later with a nil-field crash.

Ownership decisions:

- `DiffView` owns docs only when `content.owns_doc == true` or when it creates a text/empty transient doc.
- Caller-owned document content is never closed/disposed by closing one Diff View.
- File-backed docs are ordinary documents with ordinary dirty/save behavior.
- Git historical contents are text contents with read-only policy, not file-backed editable documents.

Tests to add:

- request helpers create equivalent views to legacy helpers.
- invalid requests produce deterministic validation errors.
- title precedence: `content_titles.side` over `content.name` over filename basename.
- caller-owned document content is not closed/disposed by closing a Diff View.
- owned transient text/empty docs are cleaned up when the Diff View is disposed.

### 4. Editable policy and file-backed diff sides

Current state:

- Text Diff View and Git Diff View content can be represented by requests.
- Detailed editability enforcement is not complete.

Finish by enforcing editability consistently at a central mutation boundary and in DiffView-originated actions.

Effective editability:

- false when request `editable_policy == "read-only"`.
- true when request `editable_policy == "editable"`, unless content explicitly sets `editable = false`.
- content-owned when request `editable_policy == "content"`:
  - `content.editable == false` means read-only.
  - `content.editable == true` means editable.
  - missing `content.editable` defaults to editable for ordinary text/empty/file/document contents, except Git requests which set read-only explicitly.

Enforcement boundary:

- Add a side-aware edit guard owned by `DiffView` and installed on side docs/views.
- The guard must cover all document mutation routes, not just keyboard input:
  - typing.
  - paste.
  - delete/backspace/newline commands.
  - `Doc:apply_edits` and helpers that call it.
  - undo/redo if they would mutate read-only content.
  - DiffView's own sync/apply actions (`DiffView:sync`, divider clicks, `diff-view:sync-change`).
- Preferred implementation is a document-level mutation gate, e.g. extending `Doc:can_apply_edits(...)` or adding a per-doc edit-guard listener that `apply_edits`, `raw_insert`, and `raw_remove` consult before mutation.
- DiffView-originated sync/apply actions must check target-side editability before calling `replace`/`apply_edits`, and should not show sync arrows/actions for read-only targets unless they are disabled with a clear reason.
- Read-only rejection should surface `read_only_reason`:
  - visible warning for direct user edit attempts.
  - quiet log for background/programmatic attempts unless user initiated.

File-backed side decisions:

- Editable file-backed sides use normal document dirty/save behavior.
- File-backed read-only sides reject edits but can still be viewed, folded, searched, and navigated.
- Git commit/historical sides remain read-only.
- Working-tree Git editing remains disabled until explicitly implemented and tested.

Tests to add:

- read-only diff side rejects typing, paste, delete/backspace, and direct `apply_edits`.
- read-only target rejects `diff-view:sync-change` and divider sync click.
- editable text side accepts edits and rediffs exactly once per user edit.
- editable file-backed side becomes dirty and saves through normal document save.
- Git commit diff sides are read-only and expose a useful read-only reason.

### 5. Mutable blank diff workflow

Current state:

- `DiffContent.empty` exists, but there is no standalone blank diff command/host workflow.

Finish by adding a mutable request host for blank/source-swapping workflows.

Commands:

- `diff-view:open-blank-diff`
- `diff-view:replace-left-with-file`
- `diff-view:replace-right-with-file`

Host API:

```lua
local host = MutableDiffRequestHost(request, opts)
host:get_view()
host:replace_content(side, content, opts)
host:reload(opts)
host:try_close(callback)
host:dispose()
```

Host responsibilities:

- Own the active mutable request.
- Own the current `DiffView` instance.
- Preserve surrounding tab/node/tool placement when reloading or replacing content.
- Dispose the old `DiffView` integrations before installing a replacement view.
- Increment generation IDs so stale diff computations cannot apply after replacement.
- Preserve focus side, scroll/caret state, and folding state where it is safe and side contents are semantically the same.
- Keep commands from mutating `DiffView` internals directly.

Dirty-content protection:

- Blank diff starts with two normal owned untitled documents.
- Owned editable docs must be protected on close and side replacement.
- Closing the host should prompt or otherwise reuse the normal `DocView:try_close()` dirty-document confirmation behavior for each dirty owned side doc.
- Replacing a dirty owned side must confirm before discarding it.
- If the user cancels the dirty prompt, replacement/close is cancelled and the existing view remains active.
- Non-owned caller docs are not closed by the host; their normal owners remain responsible for dirty state.

Replacement decisions:

- Replacement from file should use a normal file-backed `Doc` when the user intends to edit/save that file.
- Replacement from snapshot/recent text should use owned text content.
- Reload/replacement should keep the same outer tab placement; recreating the internal `DiffView` is acceptable.

Tests to add:

- blank diff opens with editable left/right documents.
- editing either side schedules one rediff.
- replacing left or right with a file keeps the same outer tab placement.
- replacing a dirty blank side prompts and cancels correctly.
- closing a dirty blank diff prompts and can cancel close.
- closing a clean blank diff disposes owned untitled docs.

### 6. Git View polish after request migration

Current state:

- Git View builds a `kind = "git"` request and passes useful metadata.

Finish by using that metadata for richer Git diff behavior.

Design decisions:

- Commit diff requests are read-only by default.
- Divider/apply/revert labels should be sourced from Git request metadata, not hardcoded in generic Diff View.
- Reloading a selected changed file should reuse the same surrounding Git tab/session placement.
- If working-tree editing is added later, it should be opt-in and only for the working-tree side.

Tests to add:

- Commit Diff View opens through `DiffRequest` with expected metadata.
- selecting another changed file reloads the viewer without losing Git pane focus state.
- Git request metadata is available to divider/action code.

### 7. Unified and three-way modes

Current state:

- Structural pieces should support future viewers, but only side-by-side two-way diff is implemented.

Design decisions:

- Do not build unified or three-way UI until the two-way request/content/model contracts are stable.
- Unified and three-way should be separate viewer implementations selected from request shape/kind.
- `DiffModel.compute(...)` remains a pure worker body. Viewer/session code owns async lifecycle.

Future tests:

- viewer selection chooses side-by-side for two contents.
- future unified viewer can consume the same `DiffModel` without depending on `DocView` side-by-side geometry.

## Validation checklist for future phases

Run targeted tests while developing:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/diff_model.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/doc_text_change_listener.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/docview_decorations.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/diffview_batch.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/git_view.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/linewrap.lua --print-errorlogs
```

Use the full Anvil suite when unrelated known failures are cleared:

```sh
meson test -C build-windows-x86_64 --suite anvil --print-errorlogs
```
