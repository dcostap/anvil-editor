# Git and Diff IntelliJ Audit and Execution Plan

## Status

This document records a code audit and an execution plan.

`GIT_DIFF_WORKFLOW_PLAN.md` remains the product authority. This report measures the current code against that plan and IntelliJ.

The audit used these revisions:

- Anvil: `0a7e55729ac76f7f21472e1ce46bf730249f5bc8`
- IntelliJ Community: `d9c9d42f2fd684b57b8ab29f7cd85a684541650c`
- Audit date: 2026-08-29

No Anvil behavior was changed during this audit.

## Executive result

The current implementation has a good visual base. The Diff View already feels more complete than its workflow model.

The current state is approximately:

| Area | Current completeness | Main reason |
|---|---:|---|
| Side-by-side Diff View presentation | 75% | Highlighting, alignment, folding, connectors, and overview markers exist. |
| Diff request lifecycle | 60% | Reload and disposal work, but source identity remains incomplete. |
| Git Log and Commit Diff View | 55% | Core browsing works, but metadata, refresh, and current Buffer use are weak. |
| File and selection history | 25% | The names exist, but the required history workflows do not. |
| General editor integration | 20% | Clipboard, swap, open-source, and context commands are absent. |
| Safety for large or binary input | 30% | Git caps output, but the text Diff View has unsafe paths. |

The user's 70% estimate is fair for visible presentation. It is too high for the complete Git and Diff workflow.

The shortest route to the 90% product is not a new VCS framework. It needs five focused changes:

1. Make every Diff Side use an explicit source identity.
2. Add the small general Diff commands that users invoke every day.
3. Make Git current-state sides use canonical Buffers.
4. Turn File History and Selection History into real Diff workflows.
5. Fix refresh, binary, large-input, and lifecycle faults.

Do not copy IntelliJ's framework size. Copy its user contracts and its source boundaries.

## Main recommendation

Keep one two-side Diff View. Keep the current request table and controller idea.

Reduce every text source to one Buffer plus small metadata. Do not retain separate file, text, and legacy compare paths.

Use four source kinds:

- canonical current Buffer;
- mapped current Buffer fragment;
- read-only historical snapshot;
- registered Untitled Buffer.

Use one non-text result for binary, submodule, directory, or oversized content.

Build Git views from those sources. Do not make Git Diff Views from detached strings.

This model supports almost every requested workflow without a general VCS abstraction.

## Current Anvil implementation map

### Diff engine and model

Relevant files:

- `src/api/diff.c`
- `src/diff_engine.cpp`
- `src/diff_engine.h`
- `data/plugins/diff/model.lua`

The native engine uses histogram anchors. It uses a shortest-edit fallback for repeated regions.

The Lua model adds:

- line states;
- line mapping;
- whole-token inline ranges;
- equal blocks;
- fold inputs;
- visual alignment inputs.

This is a good base. Keep the histogram engine.

### Diff View

Relevant file:

- `data/plugins/diffview.lua`

The Diff View has:

- side-by-side text surfaces;
- line and inline highlights;
- syntax support for file-backed Buffers;
- center line numbers;
- curved connectors;
- overview scrollbar markers;
- synchronized scroll and caret state;
- Diff Gap Rows;
- unchanged-region folds;
- Point of Interest navigation;
- asynchronous computation;
- stale-result rejection;
- view-scoped edit guards;
- dirty-close prompts;
- mutable request reloads;
- blank Diff View creation;
- file replacement for blank sides.

The request API is partly modern. Legacy compare helpers still create detached content.

### Git backend

Relevant file:

- `data/plugins/git/backend.lua`

The backend has:

- repository discovery;
- asynchronous Git jobs;
- output caps;
- generation values;
- process cancellation;
- status parsing;
- name-status parsing;
- numstat parsing;
- paged log parsing;
- commit and working-tree endpoints;
- file content loading;
- basic file history;
- basic `git log -L` selection history.

The backend already handles root commits, unborn repositories, renames, copies, deletions, and untracked records in part.

### Git model and views

Relevant files:

- `data/plugins/git_view.lua`
- `data/plugins/git/model.lua`
- `data/plugins/git/view.lua`
- `data/plugins/git/historical_buffer.lua`

The implementation has:

- one project Git state object;
- a Git Log;
- top-level Pane Views for model tabs;
- Commit Diff Views;
- working-tree diffs;
- File History rows;
- Selection History rows;
- changed-file Path Trees;
- changed-file stats;
- folder aggregation;
- lazy file loading;
- lazy log paging;
- lightweight Workspace state;
- stale file-load rejection.

The model still acts like an internal tab container. Each model tab also has a real top-level View.

### Other Git support

Relevant files:

- `data/plugins/gitdiff_highlight/init.lua`
- `data/plugins/gitdiff_highlight/ranges.lua`
- `data/plugins/filetree/git_status.lua`
- `data/plugins/path_tree.lua`

These parts provide:

- live Editor Git gutter markers;
- unsaved-change comparison against `HEAD`;
- Editor Git change navigation;
- File Tree Git status;
- File Tree line stats;
- shared Path Tree presentation.

The shared Path Tree is one of the strongest parts of the current design.

## What Anvil should retain

Keep these choices:

1. Keep all substantial surfaces as top-level Pane Views.
2. Keep one side-by-side viewer.
3. Keep Path Tree as the changed-file hierarchy.
4. Keep view-scoped read-only guards.
5. Keep stale-result rejection through generations.
6. Keep the loading delay before a loading overlay appears.
7. Keep unchanged-region folding.
8. Keep line and inline highlighting.
9. Keep center line numbers and connectors.
10. Keep direct editing instead of hunk-apply arrows.
11. Keep quiet diagnostics for jobs and state changes.
12. Keep activation-based Git refresh instead of continuous Git Log polling.

The report does not recommend a rewrite of the renderer or Diff View geometry.

## IntelliJ findings

### IntelliJ Diff request model

IntelliJ separates content, request, processor, and viewer concerns.

The useful lesson is the boundary, not the class count.

A `DiffContent` describes one source. A `DiffRequest` describes one comparison. A processor replaces requests and retains presentation state.

`MutableDiffRequestChain` keeps stable chain identity while its two sources change. Its swap action exchanges sources and titles.

Anvil already has the start of this model:

- content tables;
- a mutable chain;
- a request controller;
- assignment hooks.

Anvil should finish this model instead of adding another layer.

### IntelliJ Compare Clipboard with Selection

`CompareClipboardWithSelectionAction` has several important contracts:

1. It gets the active Editor or the selected project Editor.
2. It places Clipboard on the left.
3. It places current Editor content on the right.
4. It reuses the Editor's existing Document.
5. It wraps a selected range as a live Document fragment.
6. It uses the whole Document when no selection applies.
7. It retains the right-side file type for highlighting.
8. It titles both sides clearly.
9. It scrolls the right side to the current caret line.
10. It only forces the Editor side read-only when the source Editor is already a viewer.

The fragment uses a Range Marker and a synchronized temporary Document. Edits propagate in both directions.

Anvil's glossary makes one deliberate change. The Clipboard side is editable in an Anvil Clipboard Comparison.

This is a good change. Keep the IntelliJ orientation and source mapping.

### IntelliJ Blank Diff

`ShowBlankDiffWindowAction` provides more than two empty text areas.

It supports:

- two editable contents;
- initial content from an Editor selection;
- file replacement for the focused side;
- recent blank content;
- file drag and drop;
- side swapping;
- optional three-side mode;
- content persistence when the viewer closes.

Anvil does not need all of this.

The 90% subset is:

- two registered Untitled Buffers;
- file replacement for either side;
- side swapping;
- Workspace restoration;
- untitled recovery;
- dirty-close protection.

Skip recent-content menus, drag and drop, and three-side mode for now.

### IntelliJ side-by-side Diff Viewer

`SimpleDiffViewer` and `TwosideTextDiffViewer` provide these high-value behaviors:

- clear side titles;
- change count status;
- next and previous change;
- next and previous file;
- focus opposite side;
- focus opposite side with mapped caret;
- open current side in the real Editor;
- synchronized scrolling through line mapping;
- fold unchanged regions;
- equality and error notifications;
- cancellable rediff work;
- slow-work feedback;
- settings for whitespace and highlight policy;
- line number, whitespace, indent guide, and soft-wrap settings;
- binary and too-large states.

IntelliJ also provides replace and append gutter actions. Anvil should not copy them now.

The Anvil plan already chooses direct editing instead of hunk application.

### IntelliJ Diff settings

IntelliJ exposes many settings. Most are not required for Anvil's first target.

The useful policies are:

- normal comparison;
- trim leading and trailing whitespace;
- ignore whitespace;
- line-only highlighting;
- word-level highlighting;
- unchanged-region context size;
- synchronized scrolling;
- soft wraps;
- line numbers.

The default IntelliJ word-level highlight is close to Anvil's current whole-token presentation.

For Anvil, add only three comparison policies first:

1. Exact.
2. Trim line-edge whitespace.
3. Ignore whitespace.

Keep word-level inline highlights as the only initial highlight mode.

Do not add a full Diff settings dialog before these policies prove useful.

### IntelliJ multi-file navigation

IntelliJ separates change navigation from file navigation.

Its processor keeps a prepared cross-file navigation state. It can show a boundary hint before moving files.

Anvil's product plan has a precise two-press boundary rule. Keep that rule.

Do not copy IntelliJ's setting matrix. Add one request callback for the adjacent changed file.

### IntelliJ Git Log

The IntelliJ Git Log has these useful presentation contracts:

- Subject, Author, Date, Hash, and Root data;
- graph and refs in the commit cell;
- text and hash search;
- branch, author, date, path, and repository filters;
- asynchronous commit detail loading;
- a changed-file tree;
- persisted splitter and column state;
- clear loading, empty, filtering, and error states;
- copy support for selected commit rows;
- navigation history;
- diff preview or standalone Diff View actions.

The Anvil 90% target does not need a graph or dynamic columns.

It does need the same information density.

A simple Anvil row can show:

```text
subject    refs    author    relative date    short hash
```

The details area should show:

- full hash;
- full message;
- author name and email;
- author date;
- committer name and date when different;
- parent hashes;
- refs;
- selected repository root;
- aggregate file and line counts.

Use exact time in details. A relative time is enough in the row.

### IntelliJ changed-file browser

IntelliJ delegates tree grouping and Diff request creation to shared components.

Anvil already does this well with `plugins.path_tree`.

Anvil still needs more row information:

- an explicit status marker;
- rename source and target;
- a binary marker;
- line stats;
- old and new paths for Path Targets;
- selected-file retention after refresh.

Color alone is not enough. A status letter improves accessibility and scan speed.

Recommended rows:

```text
M  src/app.lua                  +12 -3
R  src/new.lua  <- src/old.lua   +2 -2
D  src/old.lua                   -8
B  assets/logo.png             Binary
```

Keep hierarchy under the new path for renamed files.

### IntelliJ commit comparison

IntelliJ supports:

- one commit against its parent;
- two selected commits against each other;
- one commit against local content;
- merge changes grouped by parent;
- a standalone multi-file Diff View.

Anvil should keep first-parent commit diffs as the default.

Two selected commit comparison is useful but not part of the first recovery work. Add it after a two-row selection model exists.

Parent-specific merge comparison can wait.

### IntelliJ File History

IntelliJ File History uses a rename-aware path model. It does not trust plain `git log --follow` for every merge case.

Its Git loader works in history segments:

1. Load log data for the current path.
2. Detect a creation or rename boundary.
3. inspect parents and old paths at that boundary.
4. Queue parent and old-path history segments.
5. Deduplicate commits.
6. Refine paths through merge graph edges.

This is a useful lean model. Anvil can copy the segmented traversal without copying IntelliJ's graph framework.

IntelliJ File History supports:

- one revision against its parent;
- two selected revisions against each other;
- one revision against local content;
- selected revision details;
- an embedded Diff preview;
- rename-aware historical paths.

Modern IntelliJ exposes local comparison as an action. Anvil's product plan chooses a Local Changes row.

Keep the Anvil choice. It makes the common current-state comparison visible.

### IntelliJ Selection History

`VcsSelectionHistoryDialog` is the strongest direct reference for Anvil's missing workflow.

It does not use `git log -L` as the complete model.

Its algorithm is:

1. Read the current in-memory Document.
2. Add a synthetic Local Changes revision.
3. Represent the selected lines as a Block.
4. Load older full-file revisions.
5. Map the Block backward through each adjacent revision.
6. Display only the mapped fragments.
7. optionally hide revisions that did not change the Block.
8. map fragment-local lines back to full-file lines.

The `Block` implementation uses line comparison with ignored whitespace. It updates the selected range through each change.

This supports unsaved content. It does not create separate staged and unstaged rows.

That behavior matches Anvil's glossary and product plan.

### IntelliJ binary and large input behavior

IntelliJ selects a binary viewer when possible. It otherwise shows a clear unsupported or too-large state.

It never sends arbitrary binary bytes through a text diff renderer.

Anvil needs the same boundary. It does not need IntelliJ's binary viewer set.

The first Anvil state can show:

- file name;
- file type;
- byte size;
- old and new object IDs when available;
- `Binary files differ` or `Binary files are identical`;
- an Open File action for a current file.

Images can use the existing Image View later.

## Deliberate differences from IntelliJ

Do not copy these IntelliJ features in the first target:

- full commit graph rendering;
- dynamic Log columns;
- unified Diff View;
- three-way Diff View;
- merge conflict editor;
- hunk replace or append arrows;
- staging and committing UI;
- branch checkout UI;
- rebase, cherry-pick, and revert UI;
- Git hosting integration;
- external Diff tools;
- recent blank content menus;
- combined all-files single-scroll Diff View;
- signature validation;
- language-specific ignored changes.

These features add much more code than daily value.

## Gap matrix

| Feature | Anvil now | IntelliJ reference | Recommendation | Priority |
|---|---|---|---|---:|
| Side titles | Stored, not drawn | Always visible | Draw one compact title row | P1 |
| Change count/status | Missing | Visible status | Show equal, count, current index, loading, error | P1 |
| Compare selection with Clipboard | Missing | Live fragment on right | Add exact workflow | P1 |
| Compare file with Clipboard | Missing | Current Document on right | Add exact workflow | P1 |
| Swap sides | Missing | Mutable chain action | Swap source records and state | P1 |
| Focus other side | Missing | Mapped focus action | Add focus command | P1 |
| Open real file at caret | Missing | Navigatable content | Add mapped Path Target action | P1 |
| Non-wrapping navigation | Current navigation wraps | Local then cross-file | Remove wrap; add boundary state | P1 |
| Cross-file navigation | Missing | Request-chain navigation | Add Git-owned adjacent-file callback | P1 |
| Exact current Buffer use | Missing in file and Git diffs | Reuses Document | Resolve through `core.open_buffer` | P0 |
| Live selected fragment | Missing | Range Marker sync | Add one fragment Buffer helper | P1 |
| Blank Diff recovery | Missing | Recent/persisted contents | Use registered Untitled Buffers | P1 |
| Whitespace policy | Backend option exists but UI ignores it | Several policies | Add three policies | P2 |
| Binary state | Missing | Binary viewer/error state | Add non-text state | P0 |
| Too-large state | Missing in Diff View | Clear too-large state | Add byte, line, and inline budgets | P0 |
| Git Log metadata | Subject and hash only in rows | Subject, refs, author, date, hash, root | Add compact row and full details | P1 |
| Git Log body | Not loaded | Full message | Load lazily or with selected details | P1 |
| Git Log search | Missing | Text/hash field | Add one text/hash filter | P2 |
| Repository selector | Missing | Root filter | Add for known project repositories | P2 |
| Synthetic Working Tree row | Present | Local changes live elsewhere | Remove from Git Log | P1 |
| Working Diff current Buffer | Disk snapshot and read-only | Current Document | Use canonical editable Buffer | P0 |
| Commit Diff historical side | Detached text | Revision content with metadata | Use read-only snapshot source | P1 |
| Rename row text | New path only | Before and after paths | Show old path hint | P1 |
| File History preview | Missing | Embedded Diff preview | Implement | P1 |
| Local Changes revision | Missing | Selection History uses it | Add to File History per Anvil plan | P1 |
| Two-revision File History | Missing | Supported | Add two-row comparison | P1 |
| Dirty Selection History | Explicitly rejected | Supported | Replace command restriction | P1 |
| Block history | `git log -L` row list only | Backward Block mapping | Add line-range tracker | P1 |
| Directory History | Missing | Path-filtered history | Add after file history | P2 |
| Combined path history | Missing | Structure filters | Add only if Path Target selection is simple | P3 |
| Activation refresh | Missing | Data pack refresh | Add `on_resume` and app-focus refresh | P1 |
| Close Git Log semantics | Destroys sibling Git Views | Independent surfaces | Hide Log only | P1 |
| Git Workspace state | Duplicated per Git View | Shared UI state | Persist shared identities once | P2 |
| Current-file Git diff entry | Missing | Gutter and changes actions | Add preselected working Diff command | P1 |
| Copy commit hash | Only manual text selection | Standard row copy/data | Add direct command | P2 |
| Compare two Log commits | Missing | Supported | Add after two-row selection | P2 |
| Graph | Missing | Full graph | Do not add now | P3 |

## Confirmed defects and high-risk paths

### P0: quadratic unused inline diff work

Evidence:

- `data/plugins/diff/model.lua:inline_change`
- `src/api/diff.c:f_inline_diff`

`inline_change` calls `diff.inline_diff` for every paired modified line.

The model stores the returned `changes` table. No Diff View code reads that field.

`f_inline_diff` allocates a full `(left bytes + 1) * (right bytes + 1)` integer matrix.

The function has no cell budget. It does not check every row allocation.

One changed long line can consume extreme memory or crash the process.

Fix:

1. Remove the unused `diff.inline_diff` call from `DiffModel`.
2. Keep whole-token inline range generation.
3. Add a native cell budget to the public `diff.inline_diff` API.
4. Return a coarse delete/insert result above that budget.
5. Check every allocation before use.

This fix should happen before any new Diff feature.

### P0: binary and embedded NUL bytes enter text code

Evidence:

- `data/plugins/git/backend.lua:file_at`
- `data/plugins/git/model.lua:load_selected_diff_file`
- `data/plugins/git/view.lua:ensure_diff_view`
- `src/api/diff.c:similarity`
- `src/api/diff.c:push_edit`

Git file content is loaded as bytes. The model always turns it into text content.

The native similarity code uses `strcmp` and `strlen`. Edit records use `lua_pushstring` in several paths.

Embedded NUL data can truncate comparison values. Binary data can also reach text rendering and syntax code.

Fix:

1. Mark binary numstat records when Git emits `-` counts.
2. Detect NUL and invalid UTF-8 before creating a text source.
3. Reject text comparison when either source is non-text.
4. Render a non-text state.
5. make native string comparison length-aware for API safety.
6. Use `lua_pushlstring` for byte-preserving edit records.

### P0: editable file Diff Sides use detached Buffers

Evidence:

- `data/plugins/diffview.lua:buffer_for_content`
- `data/plugins/diffview.lua:content_editable`

A `file` content creates `Buffer(name, filename)` directly. It does not call `core.open_buffer`.

The content is editable by default. It is also marked as not owned.

This creates a second editable copy of a file. An Editor can hold a different canonical Buffer.

Edits can diverge. A save can overwrite disk while another Editor still shows stale text.

Fix:

- Remove file-to-Buffer construction from `DiffView`.
- Resolve current files through `core.open_buffer` before request creation.
- Retain the canonical Buffer while a Diff View uses it.
- Release it when the Diff Side is removed or closed.

### P0: Working Tree Diff ignores unsaved edits

Evidence:

- `data/plugins/git/backend.lua:file_at`
- `data/plugins/git/model.lua:load_selected_diff_file`
- `data/plugins/git/view.lua:ensure_diff_view`

`WORKING_TREE` reads the filesystem with `io.open`. Both rendered sides then use detached read-only text.

An unsaved Buffer does not appear. Editing the right side is impossible.

This conflicts with the declared current-state workflow.

Fix:

- Historical left: read-only snapshot source.
- Current right: canonical project Buffer source.
- Untracked current file: empty left plus canonical right.
- Deleted file: historical left plus empty right.

### P1: Selection History rejects the cases it must support

Evidence:

- `data/plugins/git_view.lua`, command `git:show_selection_history`

The command rejects a dirty Buffer. It also rejects any staged or unstaged path status.

It then calls `git log -L` and shows commit changed-file details.

This is the inverse of the required Selection History behavior.

Fix:

- Remove both rejection checks.
- Snapshot the selected current Buffer range.
- Add a Local Changes revision.
- Map the range backward across adjacent file revisions.
- Diff fragments, not whole commits.

### P1: File History is not a file Diff workflow

Evidence:

- `data/plugins/git/model.lua:load_file_history`
- `data/plugins/git/view.lua:update_pane_buffers`
- `data/plugins/git/view.lua:draw_history_tab`

Selecting a File History row loads all files changed by that commit. The right area shows commit details and a Path Tree.

Double-click opens a separate whole Commit Diff View.

The required embedded file Diff is absent.

Fix:

- Store historical path and parent path per row.
- Build one embedded Diff request from revision selection.
- Add Local Changes when current Buffer text differs from `HEAD`.
- Support one or two selected rows.

### P1: closing the Git Log destroys unrelated Git Views

Evidence:

- `data/plugins/git/view.lua:on_close`
- `tests/lua/ui/git_view.lua`

Closing the Log closes sibling Commit Diff and File History Views. It deletes the shared Git state.

The tests currently require this behavior.

The product plan requires the opposite behavior.

Fix:

- Closing Log removes only its Pane View.
- Keep the project Git service and sibling Views.
- `git:open_log` restores or creates the singleton Log.
- Update the old tests instead of preserving this behavior.

### P1: Git refresh does not follow activation

Evidence:

- `data/plugins/git/view.lua:set_refresh_pending`

After the first refresh, a call without a callback returns immediately.

`GitView` has no `on_resume` refresh. It also has no app-focus refresh.

A visible Git View can remain stale until explicit refresh.

Fix:

- Add a coalesced project Git refresh request.
- Request it from `GitView:on_resume`.
- Request it when Anvil receives `focusgained` and a Git View is current.
- Preserve commit hash, file path, caret, and scroll anchors.

### P1: Git changed-file child jobs are not fully cancellable

Evidence:

- `data/plugins/git/backend.lua:changed_files`

The method starts name-status. Its callback starts numstat.

The returned job only represents the first process. The second process is not part of a returned composite job.

Generation checks prevent most stale adoption. They do not stop the child process.

Fix:

- Return a small composite job.
- Add every child process to it.
- Cancel all children.
- Complete the callback once.

### P1: content titles and syntax hints are dead metadata

Evidence:

- `data/plugins/diffview.lua`

`content_titles` affect names but are not drawn above the Diff Sides.

`syntax_hint` is stored but never applied.

Git snapshot sources use anonymous text Buffers. They therefore lose file language highlighting.

`suppress_equal_contents_notification` is also stored without a visible notification system.

Fix:

- Draw content titles.
- Resolve snapshot syntax from source path or the paired current Buffer.
- Show equality, loading, error, binary, and too-large status in one shared status area.
- Remove unused request keys that remain unnecessary.

### P1: change navigation wraps inside one file

Evidence:

- `data/plugins/diffview.lua:navigate_diff_change`
- `tests/lua/ui/diffview_batch.lua`

At the last change, Next selects the first change. Previous behaves the same in reverse.

The test calls this cross-file behavior, but it only tests same-file wrapping.

Fix:

- Stop at file boundaries.
- Return a boundary result.
- Let a Git comparison arm its adjacent-file transition.
- Use Status Bar feedback.
- Replace the wrapping test.

### P1: Blank Diff contents cannot recover or restore

Evidence:

- `data/plugins/diffview.lua:buffer_for_content`
- `data/plugins/diffview.lua:open_blank_diff`
- `data/core/view.lua:View:get_state`

Blank sides are anonymous Buffers. The code then sets `new_file` to false.

`DiffView` does not implement Workspace state. The buffers do not enter normal untitled recovery.

Fix:

- Create both sides through `core.open_buffer()`.
- Retain stable side IDs.
- Implement `DiffView:get_state` and `DiffView.from_state` for Blank Diff only at first.
- Connect each side to untitled recovery.

### P2: synchronized scroll uses raw pixel positions

Evidence:

- `data/plugins/diffview.lua:sync_scroll_from`
- `data/plugins/diffview.lua:sync_caret_from`

The code copies vertical pixels to the other side. Caret sync uses the same visual-row number.

This can drift with different soft wraps. It also drifts around deliberately unpadded small changes.

Fix:

- Map the top visible source line through `DiffModel`.
- Convert that mapped line to the target visual position.
- Interpolate within changed blocks when possible.
- Keep current raw-pixel behavior only when the aligned geometry is equal.

### P2: File History rename logic stops at `--follow`

Evidence:

- `data/plugins/git/backend.lua:build_file_history_args`

Plain `--follow` loses some merge and rename histories.

Fix:

- Use segmented path traversal at rename boundaries.
- Queue parent and old-path pairs.
- Deduplicate commits.
- Store the path used in each commit.

### P2: Git Log paging uses offset skip

Evidence:

- `data/plugins/git/backend.lua:parse_log_page`
- `data/plugins/git/backend.lua:build_log_args`

The parser calculates a cursor hash. The next request uses `--skip` instead.

A changing repository can cause duplicate or missing rows during paging.

Fix later:

- Keep offset paging for one stable refresh generation.
- Restart paging after refresh.
- Use a revision cursor only if real duplicates appear.

Do not build a cursor protocol before it is needed.

### P2: Git gutter and Git View use different content rules

Evidence:

- `data/plugins/gitdiff_highlight/init.lua`
- `data/plugins/git/backend.lua`

The gutter has its own process runner, repository discovery, encoding rules, caps, and `--textconv` use.

The Git View uses the shared backend and does not use the same decoding rules.

A renamed working file can appear fully added in the gutter. The code notes this limitation.

Fix in stages:

1. Share decoding and text/binary classification first.
2. Share repository discovery and process execution later.
3. Add rename-aware gutter base lookup only after the main workflows work.

Do not block the main plan on a full gutter rewrite.

## Information and quality-of-life gaps

The following gaps do not require new architecture.

### Diff View information

Add:

- visible left and right titles;
- source revision labels;
- current change index and total;
- equal-content status;
- loading status after the existing delay;
- binary and too-large messages;
- read-only reason in Status Bar;
- comparison policy label when not Exact.

### Diff View actions

Add:

- Compare Selection with Clipboard;
- Compare File with Clipboard;
- Swap Sides;
- Focus Other Side;
- Open File at Caret;
- Previous Change;
- Next Change;
- Toggle Unchanged Folding;
- Replace Left with File;
- Replace Right with File.

Do not add hunk apply actions.

### Git Log information

Add:

- author;
- author date;
- relative date;
- refs in the row;
- author email in details;
- full commit message;
- parent hashes;
- committer when different;
- exact date and time;
- selected repository root;
- aggregate file, insertion, and deletion totals.

### Git Log actions

Add:

- copy selected commit hash;
- copy selected commit message;
- open selected commit Diff;
- open selected changed file Diff;
- refresh;
- focus Log list;
- focus details;
- show current-file history;
- show current selection history;
- open working Diff preselected to the current Path Target.

### Changed-file information

Add:

- `A`, `M`, `D`, `R`, `C`, `T`, `U`, and binary markers;
- old path for rename and copy records;
- line stats for files and folders;
- mode-only or type changes;
- submodule state;
- explicit empty-side labels.

## Target user workflows

### Workflow 1: Compare Selection with Clipboard

1. The user selects text in a current Buffer.
2. The user runs Compare Selection with Clipboard.
3. Anvil opens a new Text Diff View.
4. Clipboard appears on the left.
5. The selected live fragment appears on the right.
6. The right side uses the current Buffer's Language Mode.
7. Edits on the right update the source Buffer.
8. Edits in another Editor update the right side.
9. Open File at Caret maps to the full Buffer line.
10. Swap Sides keeps the mapping attached to the source.

If no selection exists, the command is unavailable.

### Workflow 2: Compare File with Clipboard

1. The command resolves the current Path Target.
2. The target must be a file.
3. Clipboard appears on the left.
4. The canonical current Buffer appears on the right.
5. Unsaved edits are visible.
6. The right caret starts near the source caret when available.
7. The current Buffer remains editable.

### Workflow 3: Blank Diff

1. The command creates two registered Untitled Buffers.
2. Both sides are editable.
3. Each side participates in dirty-close protection.
4. Each side participates in untitled recovery.
5. Workspace state restores the pair and side order.
6. The user can replace either side with a file.
7. The user can swap sides.

### Workflow 4: Git Log to Commit Diff

1. The user opens the singleton Git Log.
2. Anvil selects the repository for the current file or Root Project.
3. The list shows commits only.
4. Single selection updates full details and the changed-file Path Tree.
5. Activating a commit opens or reuses its Commit Diff View.
6. Activating a changed file preselects that file.
7. Historical sides are read-only snapshots.
8. Current sides use canonical Buffers.
9. Closing Git Log does not close the Commit Diff View.

### Workflow 5: Working Diff from an Editor or File Tree

1. The user invokes Open Current File Diff.
2. Anvil resolves the current Path Target.
3. Anvil opens or reuses the repository Working Diff.
4. The target file is selected.
5. The left side shows `HEAD` or empty.
6. The right side shows the canonical current Buffer.
7. Unsaved edits appear immediately.
8. Untracked files use an empty left side.
9. Deleted files use an empty right side.

### Workflow 6: File History

1. The user invokes Show History from an Editor, File Tree, or current Diff Side.
2. Anvil opens or reuses history for repository and path.
3. A Local Changes row appears only when needed.
4. Selecting Local Changes shows `HEAD` against the current Buffer.
5. Selecting one commit shows its parent against that revision.
6. Selecting two commits shows older against newer.
7. Rename-aware paths select the correct blobs.
8. The preview updates without opening another View.

### Workflow 7: Selection History

1. The user selects a range in a tracked current Buffer.
2. Unsaved, staged, or unstaged changes do not disable the command.
3. The current selected text becomes Local Changes.
4. Anvil maps the selected block backward through file revisions.
5. The list can hide revisions that did not change the block.
6. The Diff View shows fragments only.
7. Fragment lines retain full-file mappings.
8. The current fragment stays editable and live.
9. Open File at Caret returns to the full Buffer.

### Workflow 8: Binary or oversized content

1. The changed file remains visible in the Path Tree.
2. Selecting it does not run a text diff.
3. The content area shows a clear non-text state.
4. Current files can open in their normal View.
5. Historical object details remain available.
6. Navigation can continue to the next changed file.

## Minimal target design

### One normalized Diff Source record

Replace legacy content variants with one normalized source record.

Suggested shape:

```lua
{
  kind = "current" | "fragment" | "snapshot" | "untitled" | "empty" | "non_text",
  buffer = buffer_or_nil,
  identity = stable_identity,
  owns_buffer = false,
  editable = false,
  title = "HEAD: src/app.lua",
  source_path = absolute_path_or_nil,
  revision = revision_or_nil,
  line_mapper = mapper_or_nil,
  lifecycle = lifecycle_or_nil,
  state = non_text_state_or_nil,
}
```

Every text source has a Buffer.

`source_path` does not assign file identity to historical snapshots. It only supports title, Language Mode, and navigation.

`identity` decides whether reload can retain side state.

Examples:

- Current Buffer identity: Buffer object.
- Fragment identity: source Buffer plus Range Marker.
- Snapshot identity: repository, revision, and historical path.
- Untitled identity: recovery ID.
- Empty identity: endpoint and path.

Do not add subclasses. Plain records and small lifecycle functions are enough.

### One two-source request

Suggested shape:

```lua
{
  title = "Diff src/app.lua",
  sources = { left_source, right_source },
  comparison_policy = "exact",
  preferred_focus = right_source.identity,
  boundary_handler = optional_function,
  state = {
    source_order = { left_source.identity, right_source.identity },
    folds = {},
  },
}
```

Remove `compare_type`. Derive presentation from source records.

Remove file and string legacy construction after callers migrate.

### One fragment helper

Add one focused module, for example:

- `data/plugins/diff/fragment_buffer.lua`

It should:

1. Create a Range Marker on the source Buffer.
2. Create one owned temporary Buffer for the range text.
3. apply source edits to the fragment.
4. apply fragment edits back to the marked source range.
5. guard recursive updates.
6. copy the source Language Mode.
7. map local lines and columns to source positions.
8. expose assignment and disposal hooks.
9. show an invalid-range state if the marker becomes invalid.

Use `data/core/range_marker.lua`. Do not create a second range tracking system.

### One project Git service

The service should own:

- known repositories;
- Selected Git Repository;
- singleton Git Log state;
- refresh generation;
- active jobs;
- open Git View identities;
- lightweight Workspace state.

The service should not own rendering. Each top-level View owns its own surface state.

The current `session` table can become this service. Remove window fields and internal-tab drawing helpers.

### One Git comparison endpoint model

A Commit Diff View needs:

```lua
{
  repo = repo,
  left = { revision = parent_or_empty },
  right = { revision = commit_or_working },
  scope = optional_path_set,
}
```

For each selected file, resolve both Diff Sources.

Do not store `left_text` and `right_text` as the durable model.

This removes detached-current-content bugs and makes source ownership explicit.

## Command contract recommendation

Current Anvil Command Identifiers use an owner prefix and a snake-case action.

`GIT_DIFF_WORKFLOW_PLAN.md` currently lists hyphenated `diff-view:*` names. That conflicts with the current command format and plugin prefix.

Recommended final commands:

### Diff

- `diff:open`
- `diff:compare_selection_with_clipboard`
- `diff:compare_file_with_clipboard`
- `diff:swap_sides`
- `diff:focus_other_side`
- `diff:open_file_at_caret`
- `diff:previous_change`
- `diff:next_change`
- `diff:toggle_folding`
- `diff:replace_left_with_file`
- `diff:replace_right_with_file`

### Git

- `git:open_log`
- `git:refresh`
- `git:show_history`
- `git:show_selection_history`
- `git:open_selected_commit_diff`
- `git:open_working_tree_diff`
- `git:open_current_file_diff`
- `git:open_selected_historical_buffer`
- `git:copy_selected_commit_hash`
- `git:copy_selected_commit_message`
- `git:select_next_row`
- `git:select_previous_row`
- `git:activate_selected_row`
- `git:focus_list_pane`
- `git:focus_diff_pane`

Choose one command set before implementation. Update every caller and test together.

Do not keep aliases without an external need.

## Implementation sequence

Use red-green vertical slices. Run only the targeted tests for each slice.

### Slice 0: Diff safety

Goal:

Prevent large-line and binary failures before feature work.

Tests first:

- embedded NUL values do not truncate native diff records;
- a large one-line modification uses bounded inline work;
- a binary Git record becomes non-text content;
- oversized text produces a stable too-large state;
- a stale large computation cannot replace a newer result.

Implementation:

- remove the unused byte-level inline matrix from `DiffModel`;
- cap the public native inline API;
- make native string operations length-aware;
- add source byte and line budgets;
- add non-text request state;
- parse binary numstat records.

Files:

- `src/api/diff.c`
- `data/plugins/diff/model.lua`
- `data/plugins/diffview.lua`
- `data/plugins/git/backend.lua`
- `tests/lua/runtime/diff.lua`
- `tests/lua/runtime/diff_model.lua`
- `tests/lua/ui/diffview_batch.lua`

### Slice 1: canonical current sources

Goal:

Use the same Buffer in Editors and Diff Sides.

Tests first:

- file Diff creation reuses `core.open_buffer`;
- Diff edits appear in an existing Editor;
- Editor edits appear in an open Diff View;
- closing a Diff View does not close a caller-owned Buffer;
- the Buffer remains retained when its Editor closes;
- historical snapshots remain independent and read-only.

Implementation:

- normalize source records;
- remove direct file Buffer construction;
- retain and release canonical Buffers;
- move historical text into snapshot sources;
- apply Language Mode from source metadata.

Files:

- `data/plugins/diffview.lua`
- optional `data/plugins/diff/source.lua`
- `tests/lua/ui/diffview_sources.lua`

Keep a separate source module only if it makes lifecycle code smaller.

### Slice 2: Diff information and navigation

Goal:

Make the existing viewer self-explanatory and predictable.

Tests first:

- side titles follow source order;
- equal content reports equality;
- change status reports total and current change;
- Next and Previous do not wrap;
- Focus Other Side preserves mapped source position;
- Open File at Caret uses source line mapping;
- Swap Sides preserves focused source identity and editability;
- swap resets armed cross-file navigation.

Implementation:

- add a compact title/status header;
- add commands;
- make local navigation non-wrapping;
- add request boundary handling;
- transfer source-specific caret and scroll state during swap.

Files:

- `data/plugins/diffview.lua`
- `data/plugins/diff/model.lua`
- `tests/lua/ui/diffview_navigation.lua`

Do not test pixel widths or exact shortcuts.

### Slice 3: Clipboard Comparison

Goal:

Implement the two requested Clipboard commands.

Tests first:

- Clipboard is left and current content is right;
- selection command requires a non-empty selection;
- file command uses a canonical Buffer;
- fragment edits update the source Buffer;
- source edits update the fragment;
- mapped Open File returns to the correct full-file line;
- each invocation creates an independent Text Diff View.

Implementation:

- add `fragment_buffer.lua`;
- use `system.get_clipboard()`;
- resolve context through `core.file_context`;
- copy Language Mode from the current source;
- focus and scroll the right side near the source caret.

Files:

- `data/plugins/diff/fragment_buffer.lua`
- `data/plugins/diffview.lua`
- `tests/lua/ui/diffview_clipboard.lua`

### Slice 4: Blank Diff persistence

Goal:

Make Blank Diff safe across close, restart, and recovery.

Tests first:

- both sides are registered Untitled Buffers;
- each side keeps independent text and undo state;
- dirty close prompts once;
- Workspace restore keeps both side IDs and source order;
- untitled recovery retains both contents after an unclean exit;
- file replacement only replaces the selected side.

Implementation:

- create sides through `core.open_buffer()`;
- add stable recovery IDs;
- add focused Blank Diff Workspace state;
- reuse the current request controller.

Files:

- `data/plugins/diffview.lua`
- `data/plugins/untitled_recovery.lua` only if its public seam is insufficient;
- `data/plugins/workspace.lua` only if generic View state is insufficient;
- `tests/lua/ui/diffview_blank.lua`

Prefer existing recovery seams. Do not add a second recovery store.

### Slice 5: Git lifecycle and Log information

Goal:

Make the Git Log accurate, current, and useful before changing history.

Tests first:

- Git Log contains committed revisions only;
- opening Log reuses one project Log;
- closing Log leaves sibling Git Views open;
- reopening Log restores selection and scroll;
- `on_resume` requests one coalesced refresh;
- app focus regain refreshes the current Git View;
- refresh preserves a valid commit hash anchor;
- row metadata includes author, date, refs, and hash;
- details include full message, email, parents, and exact date.

Implementation:

- remove the synthetic Working Tree row;
- include full selected-commit metadata;
- add compact row rendering;
- simplify the session into a project Git service;
- remove obsolete internal tab drawing helpers;
- add activation and focus refresh.

Files:

- `data/plugins/git/backend.lua`
- `data/plugins/git/model.lua`
- `data/plugins/git/view.lua`
- `data/plugins/git_view.lua`
- `tests/lua/runtime/git_backend.lua`
- `tests/lua/runtime/git_view_model.lua`
- `tests/lua/ui/git_view.lua`

Update tests that currently require the synthetic row and destructive Log close.

### Slice 6: correct Commit and Working Diff sources

Goal:

Use source records for all Git file comparisons.

Tests first:

- normal commit uses first parent and commit;
- root commit uses empty and commit;
- unborn Working Diff uses empty and current Buffer;
- untracked file uses empty and current Buffer;
- deleted file uses snapshot and empty;
- renamed file uses old and new paths;
- unsaved current edits appear in Working Diff;
- current-side edits update every Editor;
- binary and submodule records show non-text states;
- rapid file selection cannot show stale content.

Implementation:

- make the model store endpoints instead of side text;
- resolve current files through `core.open_buffer`;
- resolve historical files through snapshot loading;
- add old/new path titles;
- return a composite changed-file job;
- add current Path Target preselection.

Files:

- `data/plugins/git/backend.lua`
- `data/plugins/git/model.lua`
- `data/plugins/git/view.lua`
- `data/plugins/git_view.lua`
- `tests/lua/runtime/git_view_model.lua`
- `tests/lua/ui/git_view.lua`

### Slice 7: cross-file change navigation

Goal:

Implement the planned two-press boundary behavior.

Tests first:

- navigation moves inside one file without wrapping;
- first boundary press stays and reports the next file;
- repeated press selects the adjacent file and first change;
- Previous is symmetric;
- final project boundary stays in place;
- caret movement disarms;
- file selection disarms;
- edit disarms;
- opposite direction disarms;
- refresh and side swap disarm.

Implementation:

- Diff View reports local boundaries;
- Git View owns adjacent file selection;
- Path Tree flattened leaf order remains authoritative;
- Status Bar displays boundary feedback.

Files:

- `data/plugins/diffview.lua`
- `data/plugins/git/view.lua`
- `tests/lua/ui/diffview_navigation.lua`
- `tests/lua/ui/git_view.lua`

### Slice 8: File History

Goal:

Replace commit-details history with the required file preview.

Tests first:

- Editor, File Tree, and current Diff Side resolve the same history identity;
- Local Changes appears only when needed;
- Local Changes uses unsaved Buffer text;
- one revision compares parent to revision;
- two revisions compare older to newer;
- rename fixture resolves historical paths;
- merge-rename fixture does not lose the old path;
- selection updates the embedded preview;
- activation does not open a Commit Diff View;
- refresh preserves valid row and scroll anchors.

Implementation:

- add segmented rename-aware traversal;
- store historical path per revision;
- add a two-row revision selection model;
- embed a Diff View;
- listen to current Buffer changes for Local Changes.

Files:

- `data/plugins/git/backend.lua`
- optional `data/plugins/git/file_history.lua`
- `data/plugins/git/model.lua`
- `data/plugins/git/view.lua`
- `data/plugins/git_view.lua`
- Git fixture tests under `tests/lua/runtime`;
- UI behavior under `tests/lua/ui`.

Create `file_history.lua` only if the traversal and selection model make `model.lua` harder to read.

### Slice 9: Selection History

Goal:

Implement real block history from current content.

Tests first:

- command works with unsaved edits;
- command works with staged edits;
- command works with unstaged edits;
- Local Changes exactly matches the selected current text;
- an insertion before the block moves its full-file line mapping;
- a replacement inside the block changes the mapped fragment;
- a deleted block becomes empty without corrupting older rows;
- unchanged revisions can be hidden;
- current fragment edits update the real Buffer;
- Open File maps to the correct full-file line;
- same repository, file, and range reuses the View;
- a different range opens a different View.

Implementation:

- add a line-range tracker based on adjacent full-file diffs;
- use ignored whitespace for range tracking only;
- use exact current content for displayed Diff Sources;
- reuse the fragment helper;
- load history in cancellable batches;
- keep generation checks for row selection and source loads.

Files:

- `data/plugins/git/block_history.lua`
- `data/plugins/git/backend.lua`
- `data/plugins/git/model.lua`
- `data/plugins/git/view.lua`
- `data/plugins/git_view.lua`
- `tests/lua/runtime/git_block_history.lua`
- `tests/lua/ui/git_selection_history.lua`

Use manually worked fixture expectations. Do not duplicate the tracker in tests.

### Slice 10: context entry points and small polish

Goal:

Complete daily entry points without widening the product.

Add:

- generic `git:show_history` through Path Target;
- `git:open_current_file_diff`;
- copy commit hash and message;
- compact Git text/hash filter;
- repository selector for known project roots;
- explicit changed-file status markers;
- rename hints;
- three Diff whitespace policies.

Directory History can follow after this slice.

Combined Path History remains optional.

## Backend plan

### Log format

Use a NUL-safe fixed-field record format.

Commit messages cannot contain NUL. Use NUL between fields and records.

Load these fields:

- hash;
- parents;
- author name;
- author email;
- author time;
- committer name;
- committer email;
- commit time;
- refs;
- subject;
- body.

The row can use the first page's metadata. The details area can load the body lazily if output size becomes a problem.

### Changed files

Keep name-status and numstat as two commands for clarity.

Return one composite job. Merge results by new display path.

Preserve:

- raw status;
- old path;
- new path;
- rename score;
- additions;
- deletions;
- binary flag.

Add raw mode data only when a real mode or submodule bug requires it.

### Current content

The backend should never read a current project file for presentation when a canonical Buffer is available.

The backend owns Git snapshots. The Diff source resolver owns current Buffers.

This boundary is simple and important.

### Rename-aware history

Implement a segmented traversal:

```text
queue = [{ revision = HEAD, path = selected_path }]
while queue is not empty:
  load log segment for revision and path
  append unseen commits with path metadata
  at creation/rename boundary:
    inspect parent-to-commit name-status
    queue each valid parent and old path
sort and deduplicate by commit identity
```

Use first-parent display comparisons by default. Preserve all parents for traversal.

Do not build a permanent commit graph.

### Error model

Use stable error kinds:

- `disabled`;
- `not_in_repository`;
- `unborn_repository`;
- `cancelled`;
- `start_failed`;
- `exit`;
- `output_too_large`;
- `binary`;
- `invalid_encoding`;
- `missing_path`;
- `missing_object`;
- `unsupported_type`.

Views should map these kinds to short user messages.

Logs should retain command, repository, generation, exit code, and bounded stderr.

## Performance and cancellation plan

### Diff computation

- Debounce live rediff by a short fixed delay.
- Cancel the previous coroutine before new work starts.
- Reject stale generations.
- Cap text bytes and lines.
- Cap inline work per changed line.
- Keep the previous valid Diff visible during recompute.
- Show loading only after the current delay.

Do not add a worker process until measurements show a UI problem.

### Git jobs

- Return composite jobs for multi-command operations.
- Cancel every child.
- Complete callbacks once.
- Keep output caps.
- Reject stale generations at model adoption.
- Coalesce activation refresh.
- Do not poll the Git Log while it remains focused.

### Content cache

Do not add a broad cache first.

If file switching is slow after source fixes, add one bounded per-Commit-Diff cache:

- key: repository, revision, historical path;
- count: eight entries;
- total byte cap: existing Git output cap;
- never cache current Buffer text;
- clear on View close.

Measure before adding it.

## Detailed test plan

### Native and runtime tests

Use:

- `tests/lua/runtime/diff.lua`
- `tests/lua/runtime/diff_model.lua`
- `tests/lua/runtime/git_backend.lua`
- `tests/lua/runtime/git_view_model.lua`
- new focused history algorithm tests.

Test:

- NUL preservation;
- long-line budgets;
- line mapping;
- whitespace policy;
- binary numstat;
- NUL-safe log fields;
- composite cancellation;
- root and unborn endpoints;
- rename and copy paths;
- segmented file history;
- block history worked examples.

### In-process UI tests

Use:

- `tests/lua/ui/diffview_batch.lua`
- `tests/lua/ui/git_view.lua`
- new focused files for source, Clipboard, navigation, and history behavior.

Test through:

- commands;
- Pane placement;
- public View methods;
- Text View event handlers;
- Buffer text;
- Selection State;
- Path Targets;
- Workspace state.

Do not test:

- exact shortcuts;
- exact pixel sizes;
- exact colors;
- private helper call counts;
- arbitrary timing thresholds.

### Existing tests that encode superseded behavior

Update or remove these tests during the matching slice:

- `refreshes log with working tree row and commits`;
- `opens working tree diff from the synthetic row`;
- `shows working tree row when log fails because repo has no commits`;
- `closing the Git Log Pane Tab removes the owning Git session`;
- `closing the Git Log Pane Tab removes sibling Git tabs and repairs focus`;
- `wraps diff change navigation across file boundaries`.

These tests protect current implementation details. They do not match the product plan.

### Fixture scenarios

Create small Git repositories for:

1. normal linear edits;
2. root commit;
3. unborn repository;
4. untracked file;
5. staged added file;
6. staged and unstaged edits together;
7. deleted file;
8. simple rename;
9. rename plus later edit;
10. rename through a merge;
11. copied file;
12. binary file;
13. submodule or gitlink change;
14. CRLF text;
15. non-UTF-8 text;
16. path with spaces and Unicode;
17. selected block moved by insertion;
18. selected block replaced;
19. selected block deleted;
20. 500 or more paged commits.

Keep each fixture focused.

### Manual verification

After each visual slice, verify:

- narrow and wide Pane sizes;
- soft-wrapped and unwrapped sides;
- folded and expanded unchanged regions;
- title clipping;
- long file names;
- renamed paths;
- no-change status;
- rapid file selection;
- active Editor plus several Diff Views of one Buffer;
- app focus loss and regain;
- binary and too-large states;
- dark and light-enough theme contrast where available.

## Scope control

### Required for the 90% target

- safe text diff limits;
- binary state;
- canonical Buffer sources;
- mapped fragments;
- Clipboard commands;
- side titles and status;
- swap, focus, and open-source actions;
- non-wrapping and cross-file navigation;
- correct Git Log lifecycle;
- useful commit metadata;
- current Buffer Working Diff;
- File History preview and Local Changes;
- dirty Selection History;
- activation refresh;
- Blank Diff recovery.

### Useful after the target

- text/hash Git Log filter;
- repository selector;
- compare two Log commits;
- copy commit hash and message;
- three whitespace policies;
- Directory History;
- image-specific binary comparison;
- selected commit against local content.

### Not now

- graph renderer;
- unified viewer;
- three-way viewer;
- merge editor;
- staging UI;
- commit UI;
- branch management;
- hunk apply actions;
- blame UI;
- patch creation UI;
- hosting integration;
- combined all-file scrolling;
- arbitrary extension framework for VCS providers.

## Completion criteria

The 90% target is complete when all statements below are true.

1. A Diff Side never creates a detached editable copy of a current file.
2. Binary or oversized input never enters the text diff engine.
3. Long changed lines cannot allocate an unbounded matrix.
4. Side titles identify both sources.
5. The viewer reports equality and change count.
6. Change navigation does not wrap unexpectedly.
7. Cross-file navigation follows the Path Tree leaf order.
8. Compare Selection with Clipboard uses a live mapped fragment.
9. Compare File with Clipboard uses the canonical Buffer.
10. Blank Diff survives normal Workspace restore and untitled recovery.
11. Swap Sides preserves source identity and editability.
12. Open File at Caret maps to the real current Buffer.
13. Git Log rows show subject, refs, author, date, and hash.
14. Git details show full message and core metadata.
15. Git Log does not include a synthetic Working Tree row.
16. Closing Git Log leaves other Git Views open.
17. Git Views refresh on activation and app focus regain.
18. Working Diff includes unsaved current Buffer edits.
19. Commit Diff handles root, rename, delete, untracked, binary, and stale-load cases.
20. File History previews one or two revisions and Local Changes.
21. Selection History works with unsaved, staged, and unstaged changes.
22. Selection History displays mapped fragments with full-file line mappings.
23. Git jobs cancel every child process.
24. Workspace state stores identities and small UI state, not file blobs.
25. The implementation does not add a general VCS framework.

## IntelliJ source inventory

The audit inspected these IntelliJ Community sources at the revision listed above.

### General Diff actions and content

- `platform/diff-impl/src/com/intellij/diff/actions/CompareClipboardWithSelectionAction.java`
- `platform/diff-impl/src/com/intellij/diff/actions/ShowBlankDiffWindowAction.kt`
- `platform/diff-impl/src/com/intellij/diff/actions/DocumentFragmentContent.java`
- `platform/diff-impl/src/com/intellij/diff/actions/CompareFilesAction.java`
- `platform/diff-impl/src/com/intellij/diff/actions/impl/MutableDiffRequestChain.kt`
- `platform/diff-impl/src/com/intellij/diff/DiffContentFactoryImpl.java`
- `platform/diff-impl/src/com/intellij/diff/DiffRequestFactoryImpl.java`

### Diff viewers and lifecycle

- `platform/diff-impl/src/com/intellij/diff/tools/simple/SimpleDiffViewer.java`
- `platform/diff-impl/src/com/intellij/diff/tools/simple/SimpleDiffChangeUi.java`
- `platform/diff-impl/src/com/intellij/diff/tools/simple/AlignedDiffModel.kt`
- `platform/diff-impl/src/com/intellij/diff/tools/util/side/TwosideTextDiffViewer.java`
- `platform/diff-impl/src/com/intellij/diff/tools/util/base/DiffViewerBase.java`
- `platform/diff-impl/src/com/intellij/diff/tools/util/base/TextDiffViewerUtil.java`
- `platform/diff-impl/src/com/intellij/diff/tools/util/base/IgnorePolicy.java`
- `platform/diff-impl/src/com/intellij/diff/tools/util/base/HighlightPolicy.java`
- `platform/diff-impl/src/com/intellij/diff/tools/util/base/TextDiffSettingsHolder.kt`
- `platform/diff-impl/src/com/intellij/diff/impl/DiffRequestProcessor.java`
- `platform/diff-impl/src/com/intellij/diff/impl/CacheDiffRequestProcessor.java`
- `platform/diff-impl/src/com/intellij/diff/DiffManagerImpl.kt`

### Diff navigation and actions

- `platform/diff-impl/src/com/intellij/diff/actions/impl/DiffDifferenceNavigationAction.kt`
- `platform/diff-impl/src/com/intellij/diff/tools/util/CrossFilePrevNextDifferenceIterableSupport.kt`
- `platform/diff-impl/src/com/intellij/diff/actions/impl/OpenInEditorAction.kt`
- `platform/diff-impl/src/com/intellij/diff/actions/impl/FocusOppositePaneAction.java`
- `platform/diff-impl/src/com/intellij/diff/actions/impl/SetEditorSettingsActionGroup.kt`
- `platform/diff-impl/src/com/intellij/diff/actions/impl/ToggleDiffAligningModeAction.kt`

### Binary Diff

- `platform/diff-impl/src/com/intellij/diff/tools/binary/TwosideBinaryDiffViewer.java`
- `platform/diff-impl/src/com/intellij/diff/requests/UnknownFileTypeDiffRequest.java`

### Git and VCS Log

- `platform/vcs-log/impl/src/com/intellij/vcs/log/ui/frame/MainFrame.java`
- `platform/vcs-log/impl/src/com/intellij/vcs/log/ui/frame/VcsLogChangesBrowser.kt`
- `platform/vcs-log/impl/src/com/intellij/vcs/log/ui/frame/VcsLogMainGraphTable.java`
- `platform/vcs-log/impl/src/com/intellij/vcs/log/ui/table/VcsLogGraphTable.java`
- `platform/vcs-log/impl/src/com/intellij/vcs/log/ui/table/column/VcsLogDefaultColumn.kt`
- `platform/vcs-log/impl/src/com/intellij/vcs/log/ui/filter/VcsLogClassicFilterUi.kt`
- `platform/vcs-log/impl/src/com/intellij/vcs/log/ui/details/commit/CommitDetailsPanel.kt`
- `plugins/git4idea/backend/src/log/GitLogProvider.kt`
- `plugins/git4idea/backend/src/GitCommit.java`

### VCS changed-file Diff chains

- `platform/vcs-impl/src/com/intellij/openapi/vcs/changes/actions/diff/ChangeDiffRequestProducer.java`
- `platform/vcs-impl/src/com/intellij/openapi/vcs/changes/ui/ChangeDiffRequestChain.java`
- `platform/vcs-impl/src/com/intellij/openapi/vcs/changes/DiffRequestProcessorWithProducers.java`

### File History

- `platform/vcs-log/impl/src/com/intellij/vcs/log/history/FileHistoryUi.java`
- `platform/vcs-log/impl/src/com/intellij/vcs/log/history/FileHistoryPanel.java`
- `platform/vcs-log/impl/src/com/intellij/vcs/log/history/FileHistoryModel.java`
- `platform/vcs-log/impl/src/com/intellij/vcs/log/history/FileHistoryDiffPreview.kt`
- `platform/vcs-log/impl/src/com/intellij/vcs/log/history/FileHistoryPaths.kt`
- `platform/vcs-log/impl/src/com/intellij/vcs/log/history/FileHistoryRefiner.kt`
- `plugins/git4idea/backend/src/history/GitFileHistory.kt`
- `platform/vcs-log/impl/src/com/intellij/vcs/log/ui/actions/history/ShowDiffAfterWithLocalFromFileHistoryActionProvider.java`
- `platform/vcs-log/impl/src/com/intellij/vcs/log/ui/actions/history/CompareRevisionsFromFileHistoryActionProvider.java`

### Selection History

- `platform/vcs-impl/src/com/intellij/openapi/vcs/actions/SelectedBlockHistoryAction.java`
- `platform/vcs-impl/src/com/intellij/openapi/vcs/history/impl/VcsSelectionHistoryDialog.java`
- `platform/vcs-impl/src/com/intellij/diff/Block.java`

### Log comparison actions

- `platform/vcs-log/impl/src/com/intellij/vcs/log/ui/actions/CompareRevisionsFromLogAction.kt`
- `platform/vcs-log/impl/src/com/intellij/vcs/log/ui/actions/ShowChangesFromParentsAction.java`
- `platform/vcs-log/impl/src/com/intellij/vcs/log/ui/actions/ShowStandaloneDiffFromLogActionProvider.kt`
- `platform/vcs-log/impl/src/com/intellij/vcs/log/ui/actions/ShowDiffAfterWithLocalFromLogActionProvider.java`

## Final assessment

Anvil does not need a larger architecture. It needs the current architecture to honor source identity.

The strongest implementation order is:

1. safety;
2. canonical sources;
3. daily Diff commands;
4. Git lifecycle and metadata;
5. correct current-state Git diffs;
6. File History;
7. Selection History;
8. small filters and context polish.

After these changes, the remaining IntelliJ gaps will be optional breadth. They will not block the daily Git workflow.
