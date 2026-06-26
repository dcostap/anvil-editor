# Git View, history, and diff workflow plan

## Goal

Bring the IntelliJ-style Git inspection workflow into Anvil while keeping Anvil's vocabulary and interaction model:

- `git:open-view` opens one remembered **Git View** per Project.
- The Git View is a project-owned **Project Tool Window**, not a modal popup and not another arbitrary editor split.
- The Git feature set supports Git Log browsing, commit diffs, file/selection history, historical file opens, and arbitrary text comparison; arbitrary text comparison remains the existing Text Diff View workflow unless a later command deliberately embeds it in the Git View.
- Existing editor-facing Git affordances remain integrated: File Tree status colors, Git change gutters/overview markers, Point of Interest navigation, and Diff View reuse.

The screenshots being copied conceptually are IntelliJ's Action Search entries for `Show History` / `Show History for Selection...` and its Git window with a left commit history list plus a side-by-side diff viewer.

## Current Anvil starting points

- `data/plugins/diffview.lua` already provides a reusable side-by-side Diff View and commands for file/file and selected-text comparison.
- `data/plugins/gitdiff_highlight/` already computes working-tree hunk ranges for open Documents and renders gutter/overview markers.
- `data/plugins/filetree/init.lua` already shows Git file status and numstat in the File Tree.
- Anvil has low-level `RenWindow` support, but the Lua app model is still effectively one main `core.window` / `core.root_panel`. A robust Project Tool Window needs explicit event routing, drawing, focus, state, and close semantics.
- IntelliJ reference points worth copying conceptually:
  - Git file history follows renames instead of relying only on naive `git log --follow` behavior.
  - VCS log/file history diff viewers identify their use-place separately from generic diff usage.
  - Selection history actions are enabled only for one file and derive a line-range from the current selection; in Anvil this remains a File History View with a selection/range context.

## Non-goals for the first complete version

- Commit creation, staging UI, branch checkout/rebase/cherry-pick, conflict resolution, blame/annotate UI, or GitHub/Gerrit integrations.
- A full graph renderer identical to IntelliJ. A readable commit list with branch/ref text is enough initially; graph lanes can come later.
- Perfect rename/copy tracking in the first slice. The plan includes a path to rename-aware history, but the initial implementation may use Git's built-in path limiting if tests document the behavior.
- Exact shortcut tests. Tests must exercise commands and durable behavior, not key bindings.

## User-facing concepts

### Git View

A singleton Project Tool Window scoped to one Project. Opening it repeatedly raises/focuses the same window and restores its previous tab, selection, filters, diff mode, and window bounds.

Default contents:

```text
Git - <project name>

Tabs: [Log] [Diff <hash>] [History: file.ext] ...
Toolbar: branch/filter/refresh/diff viewer mode/ignore whitespace

Log tab:
+-------------------------+---------------------------------------------+
| commit list             | details + changed files + diff preview      |
| working tree row first  |                                             |
+-------------------------+---------------------------------------------+

Diff/history tabs:
+-------------------------+--------------------+--------------------+
| changed files / commits | left revision      | right revision     |
+-------------------------+--------------------+--------------------+
```

### Git Log

- Permanent non-closable tab.
- Top synthetic row represents Working Tree changes when the Project has uncommitted changes.
- Rows show author, date, short hash, subject, refs/branch names where available.
- Log loading is bounded and incremental: the first page uses a configured max count, the UI exposes a load-more path, and hitting an output cap degrades to a partial page/error row rather than freezing or failing the whole Git View.
- Selecting a commit updates details and changed files.
- Activating a commit opens/reuses a Commit Diff View tab.
- Activating a changed file from details opens the historical file or focuses the file in the diff depending command.

### Commit Diff View

- Closable Git View tab comparing one Git state against another.
- Normal commit default comparison: commit vs first parent.
- Root commit comparison: Git empty tree vs commit.
- Working Tree comparison: `HEAD` vs working tree; in an unborn repository, empty tree vs working tree. The right side is editable only for real working-tree files when this is safe.
- Left column lists changed files with statuses: added, modified, deleted, renamed, copied, untracked when applicable.
- Selecting a file updates a side-by-side Diff View.
- Diff viewer should expose changes as Points of Interest so existing `poi:previous` / `poi:next` navigation works.

### File History View

- Opened by `git:show-file-history` for the current file or a selected File Tree item.
- Shows commits affecting that file.
- Reuses the same commit-list + changed-file + Diff View browsing model.
- Historical path should be shown when Git reports rename/move information.
- Later version should follow renames robustly; initial behavior may use `git log --follow -- <path>` if the limitation is explicit and isolated.

### File History View for a selection

- Opened by `git:show-selection-history` when the active Editor has a tracked, file-backed Document and a selected line range.
- This is a File History View variant/context, not a separate user-facing view concept.
- Shows commits affecting the selected line range using `git log -L <start>,<end>:<path>` where supported.
- Initial plan: require a non-empty selection, a tracked file, no unsaved Document edits for that file, and no staged or unstaged Git changes for that file relative to `HEAD`. Dirty-file line mapping can be added later, but the first version should avoid showing history for the wrong committed lines.
- A selection-context history row can open a Commit Diff View restricted to the file/range context. Scoped Commit Diff View tabs must not collide with unscoped commit diff tabs; include file/range context in tab identity when the diff is restricted.

### Historical Document open

- Opening a historical version creates a read-only **Historical Document** in the Main Panel by default.
- The title should include file path and revision, e.g. `src/foo.lua @ a1b2c3d`.
- Historical Documents participate in normal text navigation/search/copy but are not saved as project files.
- Historical Documents need explicit read-only enforcement, including typed input, edit commands, save/save-as, and close prompts; a plain `Doc` flag is not enough unless core gains reusable read-only Document semantics.
- Historical Documents either do not persist in Workspace state or persist only lightweight repo/revision/path metadata and restore by reloading from Git. They must never persist full blob text as an untitled/new-file Document.
- Reopening the same revision/path should reuse an existing Historical Document where possible.

### Text Diff View

- Keep and polish existing arbitrary selected-text comparison.
- Reuse the existing `diff-view:select-text-for-compare`, `diff-view:compare-text-with-selected`, and `diff-view:start-strings-comparison` commands rather than re-registering duplicates.
- Prefer user-visible **Text Diff View** wording; avoid adding more "string comparison" labels even where old command names remain.
- Text Diff Views open in the Main Panel by default and coexist with the Git View; they are not Git-owned unless a future command explicitly requests a Git View-hosted text diff tab.

## Data and command layer

Introduce a Git backend module with no UI dependencies, probably `data/plugins/git/git.lua` or `data/core/git.lua` if it becomes first-party core infrastructure.

Responsibilities:

- Find repository root for a Project/file.
- Run Git through `core.process` asynchronously with output caps, cwd, cancellation, generation/request IDs, and quiet diagnostics. UI models must ignore stale results from older generations.
- Parse:
  - `git status --porcelain=v1 -z`
  - bounded/paged `git log` records with a NUL-safe custom format and continuation/load-more metadata
  - `git show --name-status -z` / `git diff --name-status -z` or equivalent NUL-delimited changed-file formats
  - file contents at revision: `git show <rev>:<path>`
  - patch/diff metadata for changed files
  - selection history via `git log -L`
- Normalize paths consistently with Anvil's Windows path handling.
- Expose structured errors: missing Git executable, not in repository, binary file, file too large, unsupported Git version, command timeout/cancelled.
- Use one first-party Git executable configuration path, and either migrate or bridge existing `gitdiff_highlight` / File Tree Git callers so Git View, gutters, and File Tree status agree on executable, cwd, path normalization, caps, and diagnostics.

Preferred initial API shape:

```lua
git.repo_for_path(path) -> repo | nil, err
git.status(repo, opts, callback) -> job
git.log_page(repo, opts, callback) -> job -- opts.limit/cursor; callback receives commits + next cursor/load-more state
git.changed_files(repo, left, right_or_worktree, opts, callback) -> job -- changed-file records carry status plus old_path/new_path when paths differ
git.file_at(repo, rev, relpath, opts, callback) -> job
git.diff_file(repo, left, right_or_worktree, changed_file_or_paths, opts, callback) -> job -- supports per-side paths for renames/copies
git.file_history(repo, relpath, opts, callback) -> job
git.selection_history(repo, relpath, start_line, end_line, opts, callback) -> job
job:cancel()
```

The UI should not shell out directly except through this module.

## Project Tool Window infrastructure

This is likely the riskiest prerequisite.

Required behavior:

- Create one project-owned window instance per tool kind, starting with `git`.
- Raise/focus existing tool window on repeat open.
- Hide/close semantics:
  - window close button and `Close View` hide the Git View window, not destroy state;
  - closable Git tabs can be closed individually;
  - Git Log tab cannot be closed;
  - tab-close commands should not have surprising window-close side effects unless explicitly named as "close tab or hide Git View".
- Persist window bounds and Git View UI state in Workspace/project state, not global App State except where existing window placement conventions require it.
- Route input/render/update to the correct window root:
  - event target window identity must be exposed to Lua or otherwise tracked;
  - mouse coordinates must be scaled for that window;
  - active view/focus must be per root/window or safely multiplexed.
- Keep main window responsive while Git commands run.

Implementation guidance:

- Prefer a small generic `core.tool_window` framework rather than a Git-only hack.
- Add tests for singleton/raise/state semantics against the Lua abstraction. Do not rely on actual OS window GUI smoke tests for most behavior, but Task 3 must include at least one targeted native/integration validation that event target identity, focus, resize, and mouse/key routing work for a real secondary window.
- If native multi-window support becomes too large, use an in-main-window fallback only as a temporary development scaffold, not the final user-facing implementation for this plan.

## Git View UI structure

Suggested modules:

- `data/plugins/git/init.lua` registers commands, defaults, and first-party plugin metadata.
- `data/plugins/git/backend.lua` owns Git process calls and parsers.
- `data/plugins/git/model.lua` owns Project-level Git View state and tab state.
- `data/plugins/git/view.lua` renders the Git View and delegates tab bodies.
- `data/plugins/git/log_view.lua` renders the Git Log tab.
- `data/plugins/git/diff_tab.lua` renders Commit Diff View tabs.
- `data/plugins/git/history_tab.lua` renders File History View tabs for whole-file and selection/range contexts.

Model objects should be separate from Views so tests can validate command behavior and state without screenshots.

Minimum tab state:

```lua
{
  repo_id = "<normalized repo root>",
  id = "log:<repo_id>" | "diff:<repo_id>:<left>:<right>" | "diff:<repo_id>:<left>:<right>:scope:<path>:<start>:<end>" | "history:file:<repo_id>:<path>" | "history:selection:<repo_id>:<path>:<start>:<end>",
  kind = "log" | "commit_diff" | "file_history",
  history_context = nil | { type = "file" | "selection", start_line = ..., end_line = ... },
  title = "Log" | "Diff abc123" | "History: foo.lua",
  closable = false | true,
  selected_commit = ...,
  selected_file = ...,
  scroll = ...,
  filters = ...,
  diff_options = { ignore_whitespace = false, highlight_words = true, viewer = "side_by_side" }
}
```

## Commands

Command names, not shortcuts, are the durable contract:

- `git:open-view`
- `git:refresh-view`
- `git:show-log`
- `git:open-selected-commit-diff`
- `git:open-working-tree-diff`
- `git:open-selected-historical-document`
- `git:show-file-history`
- `git:show-selection-history`
- `git:close-selected-tab`
- `git:hide-view`
- `git:reopen-closed-tab` if cheap enough; otherwise phase later.
- Existing diff commands remain under `diff-view:*`.

Default bindings can be added in `anvil_defaults.lua`, but tests must not assert exact keys.

## Persistence

Remember per Project/Workspace:

- whether Git View was open or hidden;
- Git tool window bounds/mode;
- selected tab and Git tab list;
- selected repo/commit/file per tab;
- diff options such as side-by-side/unified and whitespace handling;
- basic filters if implemented.

Do not persist:

- full commit contents or large diff text;
- transient loading/error state;
- process handles, generation IDs, cancellation tokens, or stale loading state.
- Historical Document full text; at most persist repo/revision/path metadata if Task 6 chooses restoreable Historical Documents.

On restore, rebuild lightweight model state, then lazily refresh from Git.

## Testing strategy

Use red-green cycles for each bug-prone slice.

Backend/runtime tests:

- Git command parsing from fixture strings: status, bounded log records/pages, NUL-delimited name-status including renames and copies, binary markers, NUL paths.
- Repo/path normalization on Windows-style and POSIX-style paths.
- File-at-revision/historical document identity using a tiny temporary Git repo if Meson test environment has Git; otherwise isolate parser tests and skip integration with a clear reason.
- Selection history command construction validates line ranges, clean/tracked-file predicates, dirty/untracked rejection, and path escaping without testing a keyboard shortcut.
- Root commit and unborn-HEAD diff planning tests cover empty-tree comparisons.

UI/model tests:

- `git:open-view` creates one Git View per Project and repeat open reuses/raises it.
- Git Log tab is permanent; `git:close-selected-tab` refuses/no-ops on Log, while `git:hide-view` hides the window.
- Opening a commit creates/reuses a Commit Diff View tab and persists selected commit/file state.
- Opening file history creates/reuses a File History View tab for the active repo/file.
- Historical document open creates a read-only Historical Document with expected title, content source metadata, and explicit Workspace persistence behavior.
- Diff tab file selection updates Diff View inputs.

Avoid tests for:

- exact pixel sizes of the Git window or columns;
- exact shortcut strings;
- theme colors;
- exact graph lane drawing.

Manual final smoke test after all tasks:

- Open Anvil on a real Git repository.
- `git:open-view`; verify separate OS window and repeat-open singleton.
- Browse log, open commit diff, switch changed files.
- Open historical file.
- Show file history and selection history.
- Compare arbitrary text selections.
- Verify a root commit and an unborn/new repository do not break Git Log or working-tree diff behavior.
- Close/reopen Anvil and confirm Git View state restores.

## Implementation tasks

### Task 1: Plan/review/finalize

- Write this plan.
- Launch review subagents.
- Revise until no major issues remain.
- Commit the plan before implementation.

### Task 2: Git backend foundation

Deliverables:

- Backend module for repo discovery, process execution, path normalization, parser utilities, first-party Git executable config, request generation IDs, cancellation, and bounded/paged log APIs.
- Runtime parser tests.
- Integration decision recorded and started for File Tree/gitdiff_highlight reuse or bridging of shared backend/config.
- No Git View UI yet.

Validation:

- Targeted parser/runtime tests red then green.
- Lua syntax check for touched Lua files.

### Task 3: Project Tool Window framework

Deliverables:

- Generic first-party Project Tool Window abstraction.
- Native multi-window event/draw/update routing as needed.
- Persistent singleton state skeleton.
- Tests for singleton and hide/restore semantics.
- Targeted native/integration validation for secondary-window event routing and focus.

Validation:

- Targeted UI/model tests red then green.
- Meson Anvil suite as appropriate.
- Non-Lua changes require build/update workflow after the task is accepted.

### Task 4: Git View shell and permanent Log tab

Deliverables:

- `git:open-view` command.
- Git View window with permanent Log tab and refresh state.
- First page of commits loaded from backend, with Working Tree row when applicable and load-more/partial-error state for large repositories.
- Basic details/changed-files pane.

Validation:

- UI/model tests for singleton Git View, non-closable Log tab, selected commit/details behavior.

### Task 5: Commit Diff View tabs

Deliverables:

- Activating commit/working tree opens/reuses a Commit Diff View tab.
- Changed-file list + side-by-side Diff View backed by real Git content.
- Diff options for at least side-by-side and ignore whitespace if cheap.
- POI navigation through diff changes where feasible.

Validation:

- Backend tests for diff inputs, per-side rename/copy paths, and UI/model tests for tab reuse/file selection. Scoped diff tab identity must be tested separately from ordinary unscoped commit diff tab reuse.

### Task 6: Historical Document opens

Deliverables:

- Open selected historical file from Git View into Main Panel as read-only Historical Document.
- Reuse by repo/revision/path identity.
- Clear title and read-only behavior.
- Explicit Historical Document Workspace behavior: either non-persistent or metadata-only restore.
- Reusable read-only Document/View semantics or Historical Document-specific guards for typing, edit commands, save/save-as, and close prompts.

Validation:

- UI/runtime tests for read-only Document creation, mutation/save prevention, Workspace behavior, and reuse.

### Task 7: File History View

Deliverables:

- `git:show-file-history` command from active file-backed Editor and File Tree context where practical.
- File History View tab with commit list and reused diff browsing model.
- Rename-aware structure, even if the first implementation's Git command is a documented simpler path.

Validation:

- Tests for command availability, tab identity/reuse, and backend path history parsing.

### Task 8: File History View for selections

Deliverables:

- `git:show-selection-history` command for non-empty selection in a clean, tracked, file-backed Editor; clean means no unsaved Document edits and no staged/unstaged Git changes for that file relative to `HEAD` in the initial implementation.
- Uses selected line range.
- File History View tab with selection/range context and reused diff browsing model.
- Clear disabled/error behavior for unsaved files, Git-dirty files, untracked files, and unsupported Git versions.

Validation:

- Tests for command availability on selected vs unselected/non-file documents, unsaved/Git-dirty/untracked rejection, line-range extraction, and tab identity.

### Task 9: Text Diff polish and integration

Deliverables:

- Keep arbitrary text comparison command workflow reliable.
- Improve names/titles for Text Diff View.
- Ensure it coexists with Git View and does not depend on Git.

Validation:

- Existing or new focused tests for selected-text compare behavior only where it guards durable behavior.

### Task 10: Persistence, restore, and cleanup

Deliverables:

- Workspace persistence for Git View state.
- Restore hidden/open state and selected tabs lazily.
- Clean diagnostics through `core.log_quiet` for Git/proc/window state transitions.
- Finish migration/bridging so Git View, File Tree status, and Git change gutters share Git executable/config/path conventions.
- Remove temporary scaffolding and compatibility slop introduced during earlier tasks.

Validation:

- Tests for serialized/restored lightweight state.
- Relevant Meson suite.
- Final two-subagent pending-change review loop before each task commit, as requested.

## Review checklist for implementation reviews

Before committing each task:

- Has the task been tested red-green where practical?
- Are command names and context terms consistent with `CONTEXT.md`?
- Did we avoid asserting shortcuts/pixels/theme colors?
- Are Git process calls cancellable/capped and logged quietly?
- Is UI state separated from backend parsing/process logic?
- Does repeated opening reuse singleton state instead of creating duplicates?
- Are historical Documents read-only and clearly identified?
- Are non-Lua changes finalized with the repo's build/update workflow?
