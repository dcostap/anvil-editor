# Git and Diff Workflow Plan

## Status and authority

This is the authoritative product and implementation plan for Anvil's Git and Diff workflows.

It replaces the obsolete `GIT_VIEW_PLAN.md` and `DIFF_VIEWER_CORE_PLAN.md`. Those plans were useful during the first implementation, but they describe a superseded secondary-window/nested-tab design and an already-committed Diff View refactor as unfinished work.

The product decisions in this plan come from the July 2026 workflow interview. When this plan conflicts with an older implementation or test, this plan is the intended behavior.

## Product goal

Copy the high-value parts of IntelliJ's Git history and text-diff workflow without reproducing IntelliJ's full VCS architecture.

The result should feel like one coherent Anvil feature:

- every substantial Git or Diff surface is a top-level Pane Tab;
- there are no nested Git tabs;
- file-backed Diff Sides are real views of the same Document used by Editors;
- history selection updates its Diff View immediately;
- Git changed-file trees use the same visual hierarchy rules as the File Tree;
- activation, focus, navigation, persistence, and feedback follow the same conventions as the rest of Anvil;
- features that are not part of the desired workflow are removed rather than kept as compatibility clutter.

## Explicit non-goals

These are not part of this plan unless requested later:

- staging, committing, branch checkout, merge/rebase, cherry-pick, or conflict-resolution UI;
- Git hosting integrations;
- a full IntelliJ-style commit graph engine;
- unified or three-way Diff Views;
- hunk copy/apply arrows or commands;
- an embedded diff preview inside the Git Log;
- background polling while Git tabs remain continuously focused;
- preserving deprecated command aliases solely for compatibility.

## Product decisions

### Top-level Left Pane tabs

The visible Git surfaces are sibling Left Pane tabs, not children of a Git container:

- Git Log
- Commit Diff View
- File History View
- Directory History View
- combined multi-path history when implemented

Text Diff Views, including Blank Diff Views and Clipboard Comparisons, are also top-level Left Pane tabs.

### Tab identity and reuse

- There is one singleton Git Log per Project.
- Closing the Git Log removes its visible Pane Tab but retains its state. `git:show-log` restores and focuses it.
- A Commit Diff View is reused by normalized repository and comparison endpoints. A request that specifies a changed file focuses that file in the reused tab.
- File History is reused by normalized repository and path.
- Selection history is reused only for the same repository, file, and selected line range. A different range opens another tab.
- Directory History is reused by normalized repository and directory.
- Combined path history is reused by the normalized, sorted set of selected paths.
- Blank Diff Views and Clipboard Comparisons are independent scratch workflows and open new tabs.

There are no nested tab strips inside any of these surfaces.

## Entry-point workflows

### Show Git Log

Canonical command: `git:show-log`.

Behavior:

1. Resolve the Project.
2. Resolve the Selected Git Repository:
   - prefer the repository containing the focused project file;
   - otherwise use the Root Project repository;
   - when a Project contains several repositories, expose a repository selector and remember independent UI state for each repository.
3. Restore/focus the singleton Git Log Pane Tab.
4. Refresh on activation, preserving valid state.

The Git Log lists committed revisions only. Remove Anvil's synthetic Working Tree row from this surface. Local changes remain available through history views, Git gutters/File Tree status, and `git:open-working-tree-diff`.

Initial row information:

- subject
- refs
- short hash
- author
- date/time

A graph renderer and advanced filtering may come later. A basic text filter and repository selector are worthwhile after the core workflows are correct.

Layout:

```text
+--------------------------------+----------------------------------+
| commit list                    | commit details                   |
|                                | changed-file tree                |
+--------------------------------+----------------------------------+
```

Interaction:

- Single-clicking a commit selects it and refreshes details/changed files.
- Double-clicking a commit or pressing `Alt+R` opens/reuses its Commit Diff View.
- Single-clicking a changed file selects it but does not open another tab.
- Double-clicking a changed file or pressing `Alt+R` opens/reuses the Commit Diff View with that file preselected.
- The Git Log has no embedded Diff View for now.

### Show History

Canonical command: `git:show-history`.

The command is context-sensitive and works for:

- the active Editor's file;
- a selected File Tree file;
- a selected File Tree directory;
- a file-backed Diff Side connected to a current project Document;
- several selected File Tree paths, when combined history is available.

A single file opens/reuses a File History View. A directory opens/reuses a Directory History View. Several paths open/reuse combined path history.

File History layout:

```text
+--------------------------------+----------------------------------+
| file revisions                 | embedded Diff View               |
|                                |                                  |
+--------------------------------+----------------------------------+
```

File History behavior:

- Follow renames and moves robustly, including merge-history cases where plain `git log --follow` loses revisions.
- Include a Local Changes Revision whenever the current Document differs from the latest committed file revision.
- Local Changes is one combined current-Document state. Do not create separate staged, unstaged, index, or unsaved rows.
- Selecting one committed revision compares its previous file revision on the left with the selected revision on the right.
- Selecting Local Changes compares the latest committed file revision on the left with the current editable Document on the right.
- Selecting two revisions compares the older revision on the left with the newer revision on the right.
- Selection immediately updates the embedded Diff View.
- Double-click and `Alt+R` do nothing beyond the already-visible embedded preview.

The current-state side is a real file-backed Diff Side sharing the project's Document. Historical sides are read-only snapshots.

### Show History for Selection

Canonical command: `git:show-selection-history`.

The command is available for a non-empty selection in:

- an Editor for a tracked project file;
- a file-backed Diff Side connected to the current project Document.

It is initially unavailable for selections in historical/read-only snapshots.

Behavior mirrors IntelliJ's block history rather than the current restrictive Anvil command:

- It works with staged, unstaged, and unsaved changes.
- The current selected block appears as the Local Changes Revision.
- It traces the evolving block backward through file revisions.
- It shows only revisions that meaningfully affected the block by default.
- The embedded Diff View displays the evolving block fragments, not the whole file.
- Fragment line mappings retain their full-file locations.
- The current fragment remains connected to the real Document and is editable.
- Historical fragments are read-only.
- `Ctrl+Enter` from the current fragment opens the real file at the corresponding full-file line.

Do not implement this by merely calling `git log -L` and then opening unscoped whole-commit diffs. The model needs an IntelliJ-style block tracker that starts from the current Document and maps the block through adjacent file revisions.

### Directory and combined path history

Directory History shows commits affecting paths beneath the selected directory.

Combined history, if implementation cost remains reasonable after single-path history is complete, shows the union of commits affecting any selected file or directory. It is explicitly lower priority than correct file and selection history.

These views should use a path-filtered commit list and affected-file tree. Selecting a file updates an embedded Diff View for that file and selected revision. Their exact polish must follow the same selection, activation, tree ordering, and persistence conventions as the core views.

## Commit Diff View

A Commit Diff View focuses on one commit or working-tree comparison across all affected files.

Layout:

```text
+-------------------------------+-----------------------------------+
| changed-file tree             | side-by-side Diff View            |
|                               |                                   |
+-------------------------------+-----------------------------------+
```

Behavior:

- Normal commit: first parent versus commit.
- Root commit: empty tree versus commit.
- Working Tree: `HEAD` versus current project Documents/files; unborn repository uses the empty tree.
- A changed file can be preselected by the opening action.
- Selecting a file updates the embedded Diff View in place.
- Historical commit contents are read-only.
- Any side representing the current real file uses the canonical shared Document and is editable.
- Untracked files use an empty historical side and the real current Document side.
- Deleted or binary files remain represented in the tree and show an appropriate non-text state.

### Changed-file tree

Do not duplicate File Tree hierarchy logic inside the Git view.

Extract/reuse a shared project-relative path-tree projection that owns:

- path splitting and hierarchy creation;
- folder-before-file ordering;
- stable filename ordering;
- folder aggregation;
- flattened leaf order;
- expansion state where applicable;
- path-to-row and row-to-path mapping.

Reuse `plugins.filetree.render` for visual status colors, folder rows, and addition/deletion hints. File Tree editing behavior remains owned by File Tree; Git views reuse hierarchy and rendering, not filesystem mutation behavior.

The flattened leaf order is the authoritative cross-file navigation order.

### Cross-file change navigation

Next/previous change navigation is non-wrapping and uses an armed boundary transition:

1. Within a file, move normally between changes.
2. At the final change in a file, the first further `next` command stays in place and shows Navigation Boundary Feedback: repeating the command will continue to the next changed file.
3. Repeating the same command while still at that boundary selects the next file and lands on its first change.
4. Previous-change navigation behaves symmetrically.
5. At the first/last file of the whole comparison, remain in place and show final boundary feedback.

The armed state has no timeout. It resets when navigation state changes, including:

- caret/selection movement;
- selecting another file;
- changing focus or Pane Tab;
- editing either side;
- refreshing/reloading the comparison;
- swapping sides;
- invoking the opposite direction.

Use the Status Bar through the existing navigation-feedback seam rather than inventing a new balloon system.

## Shared Diff View behavior

### Source identity

Every Diff Side must have an explicit source identity and lifecycle:

1. **Current Document** — shares the canonical Anvil Document used by Editors.
2. **Current Document fragment** — maps a selected range onto the canonical Document and propagates edits to that range.
3. **Historical snapshot** — immutable revision text with repository/revision/path metadata.
4. **Transient untitled Document** — editable scratch text owned by a Text Diff View.

A file path must never silently produce a detached duplicate Document when the canonical project Document already exists. Resolve file content through Anvil's normal Document-opening/reuse seam.

### Request/controller lifecycle

Carry forward the useful hardening work from the former Diff core plan:

- a plain reload with unchanged source identities preserves compatible fold state;
- replacing either source with unrelated content clears pair-dependent fold state and resets stale geometry;
- swapping the same two sources preserves source-specific state where safe;
- cancelling a dirty-side replacement leaves content, focus, caret, scroll, folds, and assignment hooks untouched;
- old listeners/providers and owned Documents are disposed exactly once during reload or close;
- direct external edits to caller-owned Documents are observed and trigger rediff rather than being blocked globally;
- read-only enforcement remains view-scoped for caller-owned Documents and covers every first-party mutation command routed through that Diff Side.

Treat ambiguous fold-state matches as reset-to-default rather than applying state to the wrong unchanged block.

### Live updates

- Editing a file-backed Diff Side updates every Editor and Diff Side showing that Document.
- Editing the file in another Editor updates all open Diff Views live.
- Editing a selection-backed fragment updates the corresponding range in the full Document.
- Diff computation reruns asynchronously with stale-result rejection.
- A File History Local Changes Revision and its preview update when the shared Document changes.

### Open real file at line

`Ctrl+Enter` invokes the canonical command `diff-view:open-file-at-caret`.

- From a current file-backed side, open/focus the real file in an Editor at the corresponding line.
- From a current fragment, map to the full-file line before opening.
- Preserve the Diff View tab; do not close or replace it.
- From a transient or historical side without a valid current-file mapping, do not guess; show concise Status Bar feedback.

Remove the existing `Ctrl+Enter` hunk-sync behavior.

### Remove hunk application

Remove:

- divider copy/apply arrows;
- click handling for applying a hunk;
- `diff-view:sync-change`;
- related tests and state.

Users edit editable Diff Sides directly.

### Swap Diff Sides

Add `diff-view:swap-sides` for every two-way Diff View.

Swapping is presentation-only:

- preserve each source identity and editability;
- preserve the focused source and caret, moving that source to the other visual side;
- preserve source-specific scroll/caret state where safe;
- recompute line alignment;
- keep `Ctrl+Enter` mapping attached to the source, not the visual left/right slot;
- reset armed cross-file boundary navigation.

### Viewer scope

Keep side-by-side two-way Diff View as the sole viewer in this plan. Preserve:

- line and inline change highlighting;
- syntax highlighting;
- synchronized scrolling/caret behavior;
- aligned gap rows and connectors;
- collapsed unchanged regions;
- Points of Interest/change navigation;
- overview markers;
- live rediff.

Ignore-whitespace policies, unified mode, three-way mode, breadcrumbs, and a full settings toolbar are later enhancements, not prerequisites for the workflows above.

## Text Diff workflows

### Blank Diff View

Canonical command: `diff-view:open-blank`.

- Open a new top-level Pane Tab.
- Create two ordinary editable untitled Documents.
- Recompute differences live.
- Include both Documents in normal untitled recovery.
- Persist/restore the tab association and both contents through Workspace restoration.
- Use normal dirty-close protection.
- Allow side swapping.

### Clipboard Comparison

Canonical commands:

- `diff-view:compare-selection-with-clipboard`
- `diff-view:compare-file-with-clipboard`

Mirror IntelliJ:

- clipboard text is the editable transient left side;
- current selection or current file is the right side;
- a full-file right side shares the canonical Document;
- a selected fragment remains mapped to and editable in the canonical Document;
- opening a comparison creates a new top-level Pane Tab;
- swapping sides remains available.

The general command search may expose both explicit commands. Context menus are not required by this plan.

Existing file/file and selected-text comparisons should be migrated onto the same source-identity rules instead of maintaining separate legacy construction paths.

## Refresh and persistence

### Activation-based refresh

Git data refreshes when:

- a Git-related Pane Tab becomes active after focus was elsewhere;
- Anvil regains application focus while a Git-related tab is active;
- the user invokes the explicit refresh command.

Do not continuously poll while a tab remains focused. Coalesce rapid focus changes and cancel/ignore stale requests.

### Workspace state

Restore:

- whether the Git Log is visible or hidden;
- Selected Git Repository;
- Git Log selection, scroll, filters, and selected changed file;
- open Commit Diff, File History, Directory History, and combined-history tabs;
- selected revisions/files and scroll positions;
- Diff View fold and source-order state;
- Blank Diff View tab/document association and recoverable contents.

On restore, persist identities and lightweight UI state, then reload Git data. Never persist large commit blobs or diff output in Workspace state.

A visible Git Log at shutdown returns visibly. A hidden Git Log remains hidden until `git:show-log`. Other Git-related tabs restore independently.

## Backend and model requirements

The Git backend remains UI-independent and owns all Git process construction.

Required characteristics:

- async jobs with output caps, cancellation, generation IDs, and quiet diagnostics;
- composite jobs that cancel every child process;
- NUL-safe status, log, numstat, and name-status parsing;
- robust root, unborn repository, rename/copy, deletion, untracked, binary, and large-file behavior;
- rename-aware file-history traversal rather than permanent reliance on `--follow`;
- path filtering for files, directories, and normalized multi-path sets;
- one Git executable/config/path-normalization contract shared by Git views, File Tree status, and Git gutters;
- model code does not construct raw Git command lines.

A Project-level Git state service should own the singleton Git Log state and shared repository discovery. It must not masquerade as a secondary OS Tool Window.

## Architecture cleanup

The current Git implementation still carries both secondary-window and Pane Tab concepts. Clean this up rather than adding adapters:

- remove Git's dependency on `core.tool_window`;
- move Git persistence into Pane Tab/Workspace state directly;
- remove obsolete pseudo-tool-window branches;
- remove obsolete internal tab-strip drawing helpers;
- rename view/session fields so they describe Main Surfaces rather than windows;
- if no other feature uses `core.tool_window` after migration, remove the framework, native routing hooks, performance counters, Workspace fields, tests, and obsolete Project Tool Window glossary entry in the same cleanup;
- split the oversized Git command/model/view modules when doing so clarifies stable seams, not merely to satisfy a file-count target.

The existing Diff request/content/controller APIs should be retained conceptually, but finish their source-identity lifecycle and remove legacy helper paths once all in-repo callers migrate.

## Canonical command contract

Git:

- `git:show-log`
- `git:refresh-view`
- `git:show-history`
- `git:show-selection-history`
- `git:open-selected-commit-diff`
- `git:open-working-tree-diff`
- `git:open-selected-historical-document`
- `git:select-next-row`
- `git:select-previous-row`
- `git:activate-selected-row`
- `git:focus-next-pane`
- `git:focus-list-pane`
- `git:focus-diff-pane`

Diff:

- `diff-view:open-blank`
- `diff-view:compare-selection-with-clipboard`
- `diff-view:compare-file-with-clipboard`
- `diff-view:swap-sides`
- `diff-view:open-file-at-caret`
- `diff-view:previous-change`
- `diff-view:next-change`
- `diff-view:toggle-folding`

Remove/rename superseded in-repo commands and update all callers/keymaps/tests together. Do not preserve aliases unless an external boundary is identified.

Tests exercise commands and behavior, never exact shortcuts.

## Implementation sequence

Use targeted red-green vertical slices. Do not build a broad speculative test suite before each behavior exists.

### Slice 1: source identity and shared Documents

Seam: public Diff request/content API plus observable Document text.

Tests first:

- opening a file-backed Diff Side reuses the canonical project Document;
- edits from a Diff Side appear in an existing Editor and vice versa;
- a fragment side edits the mapped source range;
- historical snapshots remain read-only;
- stale rediff work cannot overwrite newer content.

Implementation:

- add explicit source identity records;
- resolve files through normal Document reuse;
- add mapped fragment content;
- finish controller disposal/reload ordering and side-identity compatibility;
- verify plain reload preservation, semantic replacement reset, cancelled replacement stability, and exactly-once disposal.

### Slice 2: Diff interaction contract

Seam: public commands and Diff Side focus/caret state.

Tests first:

- `diff-view:open-file-at-caret` opens the canonical Editor at the mapped line without closing the Diff View;
- swapping sides preserves focused source identity and editability;
- no hunk application action remains;
- next/previous changes remain correct after swapping.

Implementation:

- remove apply arrows and `sync-change`;
- add open-file and swap commands;
- migrate command names and keymaps.

### Slice 3: Blank and Clipboard Diff workflows

Seam: commands, Left Pane tabs, Workspace/untitled recovery, and shared Document edits.

Tests first:

- each Blank Diff command opens a new Pane Tab with two editable untitled Documents;
- dirty close/recovery/Workspace restore preserves both sides;
- clipboard comparison uses clipboard-left/current-right orientation;
- whole-file and selected-fragment comparisons edit the real Document.

### Slice 4: Pane Tab Git ownership

Seam: Git commands, Pane Tab list, and Workspace state.

Tests first:

- `git:show-log` creates/reuses one Project Git Log;
- closing it hides state without closing sibling Git tabs;
- reopening restores/focuses it;
- Git tabs are top-level siblings with no nested tabs;
- visible/hidden restart behavior matches this plan.

Implementation:

- replace pseudo-tool-window state with a Project Git state service;
- remove secondary-window branches and obsolete infrastructure when unused.

### Slice 5: shared changed-file hierarchy

Seam: path-tree projection consumed by File Tree and Git surfaces.

Tests first:

- stable folder/file ordering and flattened leaf order;
- rename/copy per-side paths;
- folder status/stat aggregation;
- row/path mapping independent of rendering details.

Implementation:

- extract hierarchy projection;
- migrate File Tree and Git changed-file trees;
- keep rendering through shared File Tree rendering helpers.

### Slice 6: Git Log workflow

Seam: `git:show-log`, row selection, and activation handlers.

Tests first:

- committed revisions only; no synthetic Working Tree row;
- selecting a commit updates details and changed-file tree;
- changed-file single-click selects;
- commit or file activation opens/reuses Commit Diff with expected preselection;
- selected repository defaults from focused file and is remembered.

### Slice 7: Commit Diff and cross-file navigation

Seam: Commit Diff commands, file selection, POI navigation, Status Bar feedback.

Tests first:

- root, normal, unborn, working-tree, untracked, deleted, renamed, and binary cases;
- current side is a shared editable Document;
- historical sides are read-only;
- next/previous follows flattened changed-file order;
- first boundary press shows feedback; repeated press crosses;
- no timeout; every specified state change disarms;
- global ends do not wrap.

### Slice 8: whole-file history

Seam: `git:show-history`, revision selection, and embedded Diff View inputs.

Tests first:

- Editor, File Tree, and file-backed Diff Side contexts resolve the same tab identity;
- same file reuses; different file opens separately;
- Local Changes appears only when needed and uses current Document text;
- one/two/local revision selection follows the agreed comparison model;
- selection updates embedded diff; activation does not open another view;
- rename/merge fixture preserves historical paths and commits.

### Slice 9: selection history

Seam: `git:show-selection-history` and observable fragment revisions.

Tests first:

- works with unsaved, staged, and unstaged changes;
- same file/range reuses while a different range does not;
- Local Changes matches the current selected block;
- backward block mapping returns independent worked-example expectations;
- previews contain fragments rather than whole files;
- mapped current fragment edits the real Document;
- `Ctrl+Enter` opens the correct full-file line.

Do not duplicate the block-tracking algorithm in test expectations. Use fixture revisions with manually worked expected fragments/ranges.

### Slice 10: directory and combined history

Implement directory history after file history is stable. Add combined path history only if the shared path-filter model keeps it modest.

Tests cover normalized tab identity, union filtering, affected-file ordering, and embedded selected-file diff behavior.

### Slice 11: activation refresh and polish

Tests first:

- tab activation and app refocus trigger coalesced refresh;
- continuous focus does not poll;
- valid selection/scroll survives refresh;
- disappeared commits/files fall back predictably;
- user-facing errors and navigation boundaries reach the Status Bar.

Then add row metadata, repository selector polish, basic text filtering, diagnostics, and performance caps.

## Validation

For every Lua slice:

```sh
./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua <changed Lua files>
```

Run the smallest red-green target first, then relevant broader suites:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/git_backend.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/git_view_model.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/git_view.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/diffview_batch.lua --print-errorlogs
meson test -C build-windows-x86_64 --suite anvil --print-errorlogs
```

Add focused files/targets as modules are split. Tests assert public behavior, not helper call counts, exact shortcuts, visual pixel constants, or private state when a public seam exists.

## Completion criteria

The workflow is complete when a user can:

1. Show/reopen the singleton Git Log and browse commit changed-file trees.
2. Activate a commit or changed file into a top-level Commit Diff View.
3. Navigate changes across all commit files with the two-press boundary behavior.
4. Show file history with a live Local Changes Revision and selection-driven embedded diff.
5. Show selection history from a dirty Document and inspect only the evolving block.
6. Edit every current-file Diff Side as the same real Document used by Editors.
7. press `Ctrl+Enter` to return to the real Editor location without losing the Diff View.
8. Open recoverable Blank Diff Views and IntelliJ-oriented Clipboard Comparisons.
9. Swap Diff Sides without losing source identity.
10. Close, restart, restore, refocus, and refresh these tabs without surprising state loss.
