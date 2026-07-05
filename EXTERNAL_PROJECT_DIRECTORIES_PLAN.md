# Project Path Roles and External Project Directories Plan

## Goal

Add first-class support for **Project Path Roles**, starting with **External Project Directories**, **Vendored Project Directories**, and **Excluded Project Paths**. External Project Directories are additional directories that belong to the active Workspace for browsing, fuzzy file search, grep, Project Symbol Search, Project Usage Search, autocomplete, and other project-wide tools, while remaining visually and semantically distinct from the Root Project.

The design should not hardcode this as a one-off external-folder feature. A directory inside the Root Project, such as `src/vendor/library1`, can also be given a role and an optional label so it displays as `library1/...` or `my_clearer_alias/...`.

## Glossary

The canonical user-facing terms are recorded in `CONTEXT.md`:

- **Root Project**: the first loaded Project and default relative-path base.
- **External Project Directory**: an additional directory made available to a Project for browsing and project-wide navigation while remaining distinct from the Root Project.
- **Vendored Project Directory**: a directory in or attached to a Project that contains third-party or dependency source code and is presented as a distinct named source area.
- **Excluded Project Path**: a Project path that remains visible as part of the Project context but is intentionally left out of project-wide search and navigation.
- **Project Path Role**: the user-facing classification assigned to a Project path.
- **Project Paths View**: a Project tool for reviewing and changing Project Path Roles, labels, locations, and storage scope.
- **Workspace**: per-project editor state; not the same thing as global App State.

Avoid user-facing language like “external folder”, “linked folder”, “ignored folder”, or “marker” once the feature is implemented.

## Existing code shape

Useful current behavior:

- `core.projects` already supports multiple `Project` objects.
- `data/plugins/workspace.lua` already saves extra project directories in its `directories` field, but this is local Workspace state and lacks role/alias semantics.
- `core.project.Project:files()` already scans one root using `config.ignore_files` rules.
- `core.current_project(filename)` already chooses among open projects when multiple `core.projects` are loaded.
- `data/core/treesitter/symbol_index.lua` has partial multi-project awareness in `start_project_indexing`, but `workspace_symbols()` and `workspace_usages()` default to a single root unless explicitly called per root.
- `data/plugins/findfile.lua` already has older multi-project behavior and can be used as reference for result prefixing, but it should not become the new source of truth.
- `data/plugins/fuzzy_searcher/init.lua` currently indexes only `core.root_project().path` through `project_dir()` and root-relative `fd` results.
- `data/plugins/filetree/init.lua` currently assumes a single `current_dir`, initialized to `core.root_project().path`, and clamps navigation back into the Root Project.
- `.anvil_project.lua` already exists as git-trackable project-level configuration.

This feature should build on those pieces instead of inventing a totally separate project concept.

## Design principle

Introduce one central model that all tools consult:

> A Workspace has a list of Project path entries. Each entry has a path, label, role, and capability flags.

Everything else should consume that model:

- file search asks which entries are searchable;
- grep asks which entries are searchable;
- tree-sitter asks which entries participate in symbols/usages;
- File Tree asks which entries are browsable and how to style them;
- UI renderers ask how an absolute path should be displayed;
- rankers ask whether a result should receive a penalty;
- commands ask whether a path is local, external, vendored, or excluded.

Avoid duplicating path classification logic inside each plugin.

## End-user UX model

The feature has two user-facing surfaces.

### File Tree quick actions

When the user is looking at a folder in the File Tree, they can select it and run a command such as:

```text
Project Paths: Mark Selected Folder…
```

The prompt flow is:

1. choose a role, for example `Vendored` or `Excluded`;
2. choose a label, defaulting to the folder basename; pressing Enter accepts the default;
3. choose storage: `Local only` or `Project config`.

Example: selecting `src/vendor/library1/`, choosing `Vendored`, and accepting label `library1` makes results display as:

```text
library1/foo/bar/Baz.java
```

instead of:

```text
src/vendor/library1/foo/bar/Baz.java
```

If the user types `my_clearer_alias`, results display as:

```text
my_clearer_alias/foo/bar/Baz.java
```

### Project Paths View

A command such as:

```text
Project Paths: Manage
```

opens a simple list view:

```text
Alias              Role        Path                         Storage
────────────────────────────────────────────────────────────────────────
my-app             Root        C:/code/my-app               automatic
jdk-src            External    D:/sources/jdk               local only
library1           Vendored    src/vendor/library1          project config
generated          Excluded    build/generated              project config
```

From a selected row, the user can edit the label, change the role, remove the rule, reveal/open the directory, or switch storage between local-only and project config when possible. Removing a rule never deletes files; it only stops applying the Project Path Role.

## Proposed module

Add a new core module, tentatively:

```text
data/core/project_paths.lua
```

Responsibilities:

- Store and normalize Project path entries.
- Merge project-config entries and local Workspace entries.
- Assign stable labels/aliases.
- Resolve an absolute path to its owning Project path entry.
- Convert absolute paths into display paths.
- Decide whether a path participates in file search, grep, symbols, usages, autocomplete, and File Tree.
- Apply Excluded Project Path rules.
- Expose change generation so indexers can invalidate caches.
- Make project-config reloads idempotent so removing an entry from `.anvil_project.lua` removes it from the effective Project path entries.

This module should be lightweight and not depend on UI plugins.

## Data model

A normalized Project path entry should look roughly like:

```lua
{
  id = "external:jdk-src",       -- stable generated id, not user-facing
  path = "D:/sources/jdk",       -- normalized absolute path
  label = "jdk-src",             -- optional user-facing display prefix; defaults to basename
  role = "external",             -- "root", "external", "vendored", "excluded", future roles
  source = "workspace",          -- "project" or "workspace"
  exists = true,
  browsable = true,
  searchable = true,
  grep = true,
  symbols = true,
  usages = true,
  autocomplete = true,
  rank_penalty = 150,
  filetree_style = "external",
}
```

Root Project entry:

```lua
{
  id = "root",
  path = core.root_project().path,
  label = common.basename(core.root_project().path),
  role = "root",
  source = "implicit",
  rank_penalty = 0,
}
```

Vendored subpath entry:

```lua
{
  path = "src/vendor/library1",
  label = "library1",
  role = "vendored",
  source = "project",
  browsable = true,
  searchable = true,
  grep = true,
  symbols = true,
  usages = true,
  autocomplete = true,
  rank_penalty = 75,
  filetree_style = "vendored",
}
```

Excluded subpath rule:

```lua
{
  path = "generated",
  role = "excluded",
  source = "project",
  searchable = false,
  grep = false,
  symbols = false,
  usages = false,
  autocomplete = false,
  browsable = true,
  filetree_style = "excluded",
}
```

Implementation note: keep the public API behavior-oriented. Callers should not hardcode `role == "external"` or `role == "vendored"` unless they are specifically rendering role styling.

## Public API sketch

Potential `core.project_paths` API:

```lua
local project_paths = require "core.project_paths"

project_paths.entries(opts)             -- ordered effective entries
project_paths.search_roots(kind)        -- roots enabled for "files", "grep", "symbols", "usages", etc.
project_paths.resolve(path)             -- entry, relpath, flags for an absolute path
project_paths.display_path(path, opts)  -- display string + prefix span/meta
project_paths.absolute_path(display)    -- reverse display path when possible
project_paths.is_excluded(path, kind)   -- kind-aware exclusion
project_paths.rank_penalty(path, kind)  -- numeric penalty
project_paths.configure_project(spec)    -- declarative project-config entries; replaces prior project-sourced entries
project_paths.add_external(entry, opts)  -- imperative helper, mainly for local/command flows
project_paths.remove_entry(id_or_path)
project_paths.set_label(id_or_path, label)
project_paths.add_excluded_path(entry)
project_paths.generation()
project_paths.invalidate(reason)
```

Important display behavior:

- Root Project file: `src/Main.java`
- External Project Directory file: `jdk-src/java/lang/String.java`
- Vendored Project Directory file: `library1/foo/bar/Baz.java`, even if the actual path is `src/vendor/library1/foo/bar/Baz.java`
- Absolute non-project file: unchanged absolute path or home-encoded absolute path
- Missing external root: still render the entry in management UI/File Tree as missing, but do not search it

`display_path()` should return structured metadata, not only a string:

```lua
{
  text = "jdk-src/java/lang/String.java",
  root_label = "jdk-src",
  root_role = "external",
  prefix_span = { 1, 7 },
  relpath = "java/lang/String.java",
  abs_path = "D:/sources/jdk/java/lang/String.java",
}
```

This lets widgets color the `jdk-src` prefix without reparsing strings.

## Storage strategy

Use two storage layers.

### Shared project configuration

For entries intended to travel with the repo, use `.anvil_project.lua`.

Preferred declarative example:

```lua
local project_paths = require "core.project_paths"

project_paths.configure_project {
  external = {
    { path = "../jdk-src", label = "jdk-src" },
  },
  vendored = {
    { path = "src/vendor/library1", label = "library1" },
  },
  excluded = {
    { path = "generated" },
  },
}
```

Relative paths in `.anvil_project.lua` should resolve against the Root Project.

Prefer a declarative `configure_project` API over append-style project config calls. `.anvil_project.lua` can be reloaded in-place; append-style calls make stale entries easy when the user deletes a line and reloads. If imperative helpers are allowed inside project config, the loader must wrap the Project Module load in a transaction that clears/replaces project-sourced entries for that Root Project.

Pros:

- Already supported by Anvil.
- Git-trackable.
- No new `.anvil/` format required initially.
- Can use Lua for conditional per-machine logic when needed.

### Local Workspace state

For machine-specific absolute paths and quick drag/drop additions, store local entries in Workspace state.

Extend `data/plugins/workspace.lua` from:

```lua
directories = save_directories()
```

toward something like:

```lua
project_paths = project_paths.save_workspace_state()
```

Keep compatibility for existing `directories` by importing them as External Project Directories with generated labels.

Local entries should not be written into `.anvil_project.lua` automatically. The add/edit prompts should make storage explicit: `Local only` for machine-specific paths, or `Project config` for shared repo-relative rules. Provide an explicit “Save to Project Config” action for existing local entries.

## Ordering and conflict rules

Effective order should be stable:

1. Root Project
2. Project-config External Project Directories and Vendored Project Directories
3. Local Workspace External Project Directories and local role entries
4. Excluded Project Path rules, applied as overlays

Conflict handling:

- Duplicate paths collapse to one entry.
- Project-config entries win over local Workspace entries for the same path.
- Labels must be unique in display contexts; duplicate labels should receive suffixes, e.g. `src`, `src-2`.
- If a marked directory is inside the Root Project, treat it as a role overlay, not a second independent root.
- If roots/role entries overlap, choose the longest matching root for `resolve(path)`.

## Excluded Project Path semantics

An Excluded Project Path is not simply hidden.

Default behavior:

- visible in File Tree;
- visually subdued/red-tinted;
- excluded from fuzzy file search;
- excluded from grep;
- excluded from Project Symbol Search;
- excluded from Project Usage Search;
- excluded from project-wide autocomplete;
- openable/editable if explicitly selected.

This avoids the ambiguity of “ignored” meaning hidden, git-ignored, or excluded from indexing.

## Vendored Project Directory semantics

A Vendored Project Directory is visible and searchable by default, but visually and semantically distinguished from ordinary Root Project code.

Default behavior:

- visible in File Tree;
- displayed under its label in fuzzy/search/reference results;
- searchable by fuzzy file search and grep;
- included in Project Symbol Search and Project Usage Search;
- included in project-wide autocomplete;
- slightly downranked against otherwise equivalent Root Project files/symbols;
- styled with a role color distinct from both Root Project and External Project Directory results.

A Vendored Project Directory can be inside the Root Project (`src/vendor/library1`) or can point to an attached/external dependency source tree. The user-facing label is optional and defaults to the folder basename.

## Fuzzy file search integration

Primary file: `data/plugins/fuzzy_searcher/init.lua`

Current limitations:

- `project_dir()` returns only Root Project.
- `ensure_file_index()` runs `fd` once under the Root Project.
- `files_cache` stores plain root-relative strings.
- `fullpath(path)` assumes a string relative to Root Project unless it is absolute.

Plan:

1. Replace single-root file cache with generation-aware multi-root cache.
2. Store file items as tables internally:

```lua
{
  text = "jdk-src/java/lang/String.java",
  relpath = "java/lang/String.java",
  abs_path = "D:/sources/jdk/java/lang/String.java",
  root_id = "external:jdk-src",
  root_label = "jdk-src",
  root_role = "external", -- or "vendored"
  rank_penalty = 150,
}
```

3. Keep display string compatibility at boundaries where needed.
4. Run `fd` for each `project_paths.search_roots("files")` entry.
5. Convert each result to a display path through `project_paths.display_path()`.
6. Apply `rank_penalty` to fuzzy scores.
7. Update `draw_file_result_row()` to accept optional root-prefix metadata and draw the prefix with role colors, including external, vendored, and excluded.
8. Update `fullpath()` and `file_result_key()` to handle structured file items.
9. Ensure recent files use the same display/resolve path logic.

Short-term compatibility option:

- Store display strings in `files_cache`, plus a map from display string to metadata.
- This minimizes disruption to native fuzzy indexing, which currently indexes strings.
- Longer term, promote structured items throughout the picker.

## Grep/search-in-files integration

Primary file: `data/plugins/fuzzy_searcher/init.lua`

Current limitations:

- `start_grep()` runs one `rg` process with `cwd = project_dir()`.
- Scope files are root-relative strings.
- Parsed vimgrep results are relative to the current working root.

Plan:

1. For whole-Workspace grep, start one `rg` job per searchable root.
2. Parse each result relative to that job's root.
3. Attach root metadata and display path.
4. Merge streams into one result list.
5. Apply consistent sorting/grouping across roots.
6. For scoped grep (`file query # text`), build scope items from all roots and group them by root before invoking `rg`.
7. Ensure result activation opens `abs_path`, not display path.

Important: preserve cancellation behavior. Increment one grep generation and kill all per-root processes on new search.

## Tree-sitter Project Symbol Search and Project Usage Search

Primary file: `data/core/treesitter/symbol_index.lua`

Current limitations:

- `ensure_scan(root)` indexes one root.
- `workspace_symbols(query, opts)` defaults to one root.
- `workspace_usages(name, opts)` defaults to one root.
- Result `file`/`relpath` are relative to the indexed root only.

Plan:

1. Keep single-root indexes internally. They are a good unit for file watching and cache invalidation.
2. Add multi-root query helpers, or make default `workspace_symbols()`/`workspace_usages()` query all `project_paths.search_roots("symbols"/"usages")` when no explicit root is passed.
3. Preserve explicit-root behavior for callers that pass `opts.root`.
4. Merge per-root results and status:
   - `fresh` only when all enabled roots are fresh;
   - `stale` when at least one root returns stale usable results;
   - `pending` when no usable result exists yet;
   - include per-root status metadata for UI messages.
5. Attach display metadata to each symbol/usage:

```lua
symbol.display_file = "jdk-src/java/lang/String.java"
symbol.root_label = "jdk-src"
symbol.root_role = "external"
symbol.rank_penalty = 150
```

6. Ensure dirty open document overlays work for documents under External Project Directories.
7. Exclude files whose path is disabled for `symbols` or `usages`.
8. Update filesystem watcher startup to watch all roots that are indexed.

Ranking:

- Root Project symbols retain current behavior.
- External Project Directory and Vendored Project Directory symbols receive a small penalty in fuzzy symbol search/autocomplete.
- Exact matches should still be visible; penalty should only break ties or near-ties.

## LSP integration

Primary files:

- `data/core/lsp/manager.lua`
- `data/core/lsp/config.lua`
- `data/core/lsp/client.lua`
- `data/core/lsp/provider.lua`

Do not make LSP support a blocker for the initial feature.

Initial behavior:

- Opening a document from an External Project Directory should let existing LSP root selection choose a root as it does today.
- Project Usage Search can still use tree-sitter fallback to include external source directories when LSP does not.

Future behavior:

- Advertise LSP workspace folders when Anvil has a clear mapping from Project path entries to LSP clients.
- Implement `workspace/workspaceFolders` and `workspace/didChangeWorkspaceFolders` if useful.
- For Java specifically, investigate whether the Java LSP can use additional source roots/library source attachments through server-specific config.

Caution: Some language servers treat each root as an independent project. Do not blindly add every External Project Directory to every LSP client without language-specific validation.

## Autocomplete integration

Primary file: `data/plugins/autocomplete.lua`

Current behavior:

- Autocomplete already pulls project symbols through `symbol_index.workspace_symbols()`.

Plan:

1. Once tree-sitter multi-root query is centralized, autocomplete should inherit external results automatically.
2. Apply rank penalty for external Project path entries.
3. Preserve source metadata so preview/go-to-declaration opens the absolute source file.
4. Display source hints with external label where useful, e.g. `jdk-src/java/lang/String.java`.
5. Keep Root Project-local symbols preferred over external symbols for equally good matches.

## File Tree integration

Primary file: `data/plugins/filetree/init.lua`

Current limitations:

- `FileTreeView.current_dir` is a single directory.
- Navigation is clamped to `core.root_project().path`.
- Rendering assumes every row belongs to `current_dir`.

Target UX:

```text
src/
tests/
README.md

──────────────── Vendored Project Directories
library1/  → src/vendor/library1

──────────────── External Project Directories
jdk-src/
guava-src/
```

When expanded:

```text
src/
tests/
README.md

──────────────── Vendored Project Directories
library1/
  foo/
    bar/
      Baz.java

──────────────── External Project Directories
jdk-src/
  java/
    lang/
      String.java
guava-src/
  com/
```

Plan:

1. Add File Tree row metadata for:
   - normal entries;
   - section separators;
   - External Project Directory root rows;
   - Vendored Project Directory root rows;
   - missing external roots;
   - Excluded Project Path rows.
2. Keep Root Project as the primary editable tree.
3. Render role sections at the bottom when entries exist, starting with Vendored Project Directories and External Project Directories.
4. Use role-specific styles:
   - external label/root rows: accent or cool/dim color;
   - vendored label/root rows: distinct dependency/library color;
   - excluded rows: subdued with slight red tint;
   - missing roots: warning color.
5. Initial external/vendored rows should support selection, activation, reveal, expand, and collapse through `line_meta.abs`.
6. Defer rename/create/delete/move for External Project Directory rows unless an entry explicitly opts into `writable = true` and the File Tree edit/apply pipeline has been refactored around absolute row metadata.
7. The separator/header rows should not be editable filesystem rows.
8. Existing text-edit workflow should remain valid for Root Project filesystem rows.
9. Filesystem watchers should include External Project Directories if they are visible.
10. Git status should probably remain Root Project-oriented initially. External roots can be styled without git status until per-root git status is designed.

Open question: whether File Tree should allow changing `current_dir` into an External Project Directory as a focused view mode. The initial implementation can avoid this by showing external entries as a bottom section under the Root Project tree.

## Drag/drop and commands

Current drag/drop support:

- `View:on_file_dropped(filename, x, y)` exists.
- `core.root_panel:on_file_dropped(...)` routes file-drop events.

Commands to add:

- `project-paths:manage`
- `project-paths:mark-selected-folder`
- `project-paths:add-external-directory`
- `project-paths:add-external-directory-local`
- `project-paths:add-external-directory-to-project-config`
- `project-paths:remove-entry`
- `project-paths:rename-label`
- `project-paths:change-role`
- `project-paths:change-storage`
- `project-paths:add-excluded-project-path`
- `project-paths:remove-excluded-project-path`

File Tree mark behavior:

1. Selecting a directory in the File Tree and running `project-paths:mark-selected-folder` opens a role prompt.
2. For a Root Project subdirectory, offer at least `Vendored` and `Excluded`.
3. Prompt for an optional label, defaulting to `common.basename(path)`. Pressing Enter accepts the default.
4. Prompt for storage: `Local only` or `Project config`.
5. Apply immediately and refresh File Tree/fuzzy/tree-sitter indexes.
6. If the path already has a Project Path Role, offer edit/remove actions instead of creating a duplicate.

Drag/drop behavior:

1. Dropping a directory onto the File Tree or project surface prompts to add it as an External Project Directory.
2. Default storage should be local Workspace state, but the prompt should allow `Project config` when the path can be represented portably.
3. Prompt for an optional label, defaulting to `common.basename(path)`.
4. If path is already present, reveal it or open it in Project Paths View instead of adding a duplicate.

Project Paths View behavior:

- Show rows for Root Project, External Project Directories, Vendored Project Directories, Excluded Project Paths, missing entries, and other future roles.
- Columns: label, role, path, storage.
- Row actions: rename label, change role, remove rule, reveal/open folder, change storage.
- Removing a row removes only the role/config entry, never files on disk.

## Rendering and style defaults

Style defaults belong in `data/colors/default.lua`, not plugin fallback constants.

Potential style keys:

```lua
style.project_path_external = ...
style.project_path_external_dim = ...
style.project_path_vendored = ...
style.project_path_vendored_dim = ...
style.project_path_excluded = ...
style.project_path_missing = ...
style.project_path_separator = ...
```

Fuzzy Searcher and File Tree should use the same role colors where practical.

Avoid adding too many style knobs initially. Add only keys needed to make the roles legible.

## Ranking policy

Default rank behavior:

- Root Project: no penalty.
- External Project Directory: slight penalty.
- Vendored Project Directory: slight penalty, likely smaller than arbitrary External Project Directories because vendored code often lives inside the Root Project and may be more relevant.
- Excluded Project Path: not included in ranked searches by default.

Suggested starting values:

- file fuzzy score penalty: 100-200 points;
- symbol/autocomplete penalty: smaller, maybe 20-80 points, because symbol quality is often more important than source location;
- recent external files may receive less penalty.

Do not test exact penalty values. Test only that Root Project results are preferred over otherwise equivalent External Project Directory results.

## Path display and activation rules

Every result row should separate display from activation:

- display path: `jdk-src/java/lang/String.java`
- activation path: `D:/sources/jdk/java/lang/String.java`

For a Vendored Project Directory:

- display path: `library1/foo/bar/Baz.java`
- activation path: `C:/code/my-app/src/vendor/library1/foo/bar/Baz.java`

Never feed display paths directly to `core.project_absolute_path()` unless `project_paths.absolute_path()` has resolved them.

Update places that currently assume Root Project-relative paths:

- `fuzzy_searcher.fullpath()`
- file search result activation
- grep result activation
- symbol result activation
- recent-file rendering
- copy-relative-filepath command behavior, if the active file is external
- command output path resolution if desired later

Potential command behavior:

- Copy absolute filepath: unchanged.
- Copy relative filepath:
  - Root Project file: root-relative path.
  - External Project Directory file: display path with external label, or maybe “not inside Root Project”. Decide explicitly before implementation.
  - Vendored Project Directory file: likely display path with vendored label, because the user explicitly chose that label as the practical project-context path.

## Compatibility and migration

Existing Workspace `directories` field:

- Treat as legacy External Project Directories.
- Load into the new Workspace project-path state.
- Save in the new shape going forward.
- Do not keep a long-lived compatibility abstraction if the migration can be clean and in-repo tests are updated.

Existing `core.projects`:

- Short term: continue adding External Project Directories to `core.projects` where existing APIs expect multi-project membership.
- Treat `core.projects` as a compatibility bridge during migration, not the authoritative feature model.
- Long term: `core.projects` may become less important for path scopes, with `project_paths` becoming the authoritative source.

Because this is a personal fork, prefer clean refactors over carrying old aliases indefinitely.

## Risks and guardrails

- **Display path vs activation path**: `jdk-src/java/lang/String.java` and `library1/foo/bar/Baz.java` are UI text, not necessarily filesystem paths. Store and open absolute paths everywhere.
- **Project config reload staleness**: deleting an entry from `.anvil_project.lua` must remove it after reload. Prefer declarative replacement semantics and test this explicitly.
- **File Tree mutation risk**: the editable DocView tree currently assumes one root. External sections should be browse/open first; writable operations require a deliberate absolute-path refactor.
- **Huge External Project Directories**: library source trees can be large. Keep per-kind capability flags, quiet logs, status text, and future caps/disable switches.
- **Overlapping roots and exclusions**: use normalized path keys and longest-prefix matching. Warn quietly on surprising overlaps.
- **Git status**: Root Project git status should not be accidentally applied to unrelated external directories.
- **LSP workspace folders**: language servers have different root semantics. Do not blindly add every External Project Directory to every LSP client.
- **Windows path identity**: consistently use existing normalization helpers such as `common.normalize_path`, `common.normalize_volume`, and path compare keys.

## Tests

Use Lua tests through Meson.

Recommended focused tests:

### Runtime tests for `core.project_paths`

Create something like:

```text
tests/lua/runtime/project_paths.lua
```

Test:

- Root Project entry is implicit.
- External Project Directory and Vendored Project Directory entries normalize paths.
- Relative project-config paths resolve against Root Project.
- Duplicate labels are disambiguated.
- Longest root match wins.
- Excluded Project Path rules suppress search/symbol capabilities.
- Display path metadata includes root label and prefix span.
- Display path reverse resolution opens the correct absolute path.
- Reloading project-config entries removes stale project-sourced External Project Directories and Excluded Project Paths.

### Fuzzy Searcher tests

Add/extend tests under:

```text
tests/lua/ui/fuzzy_searcher_*.lua
```

Test:

- file rows include Root Project, External Project Directory, and Vendored Project Directory files;
- external/vendored result display path is prefixed by label;
- activation opens the correct absolute file;
- Root Project result outranks equivalent external/vendored result;
- excluded paths are not returned;
- recent external/vendored files render with the role label.

Avoid testing exact keybindings or exact penalty numbers.

### Tree-sitter index tests

Add/extend runtime tests around `data/core/treesitter/symbol_index.lua`.

Test:

- Project Symbol Search returns symbols from Root Project, External Project Directories, and Vendored Project Directories;
- Project Usage Search returns usages from all enabled roles;
- excluded paths are skipped;
- dirty open docs under External Project Directories or Vendored Project Directories overlay disk index results;
- explicit `opts.root` still restricts to one root.

### File Tree UI tests

Add/extend tests under:

```text
tests/lua/ui/filetree_*.lua
```

Test:

- External Project Directory and Vendored Project Directory sections appear after Root Project entries;
- separator/header rows are non-filesystem rows;
- expanding an external/vendored root shows its files;
- selecting/activating external/vendored file opens the absolute path;
- external/vendored separator/root rows are not treated as editable filesystem rows;
- excluded path rows are visible and flagged with excluded role metadata;
- missing external root is represented without crashing.

Do not test exact colors/pixel placement. Test durable metadata/section behavior.

### Project Paths View tests

Add UI tests for the management surface.

Test:

- rows list label, role, path, and storage for root, external, vendored, and excluded entries;
- renaming a label updates display paths without touching files;
- changing role updates behavior flags and style metadata;
- removing a row removes only the Project Path Role entry and leaves files on disk;
- changing storage moves an entry between local Workspace state and project config state when possible.

## Implementation phases

### Phase 1: Core model

- Add `data/core/project_paths.lua`.
- Add tests for normalization, display, resolution, roles, and exclusions.
- Add minimal style defaults for role rendering.
- Wire declarative project config from `.anvil_project.lua` into the module with stale-entry replacement semantics.
- Extend Workspace save/load with new project path state and legacy `directories` import.

Deliverable: no major UI changes yet, but `project_paths.entries()` returns correct effective state.

### Phase 2: Fuzzy file search

- Convert file indexing to multi-root.
- Add display metadata and rank penalty.
- Update activation to use absolute paths.
- Add tests for display/activation/downranking/exclusion.

Deliverable: fuzzy file search can find and open external/vendored files with clear role labels.

### Phase 3: Grep/search-in-files

- Run `rg` per searchable root.
- Merge result streams.
- Display external label prefixes.
- Ensure scoped grep works across roots.
- Add tests where practical.

Deliverable: search-in-files includes External Project Directories and Vendored Project Directories while excluding Excluded Project Paths.

### Phase 4: Tree-sitter symbols/usages and autocomplete

- Make tree-sitter workspace queries multi-root by default.
- Attach root display metadata.
- Apply exclusion rules and rank penalties.
- Let autocomplete inherit Project Symbol Search improvements.
- Add runtime tests.

Deliverable: Project Symbol Search, Project Usage Search, and project-symbol autocomplete include external and vendored source directories.

### Phase 5: File Tree UX

- Add External Project Directory and Vendored Project Directory sections.
- Add role metadata and rendering.
- Support reveal/activation/expand/collapse for external/vendored entries.
- Keep external/vendored role sections browse/open-only at first unless a deliberate writable path is implemented.
- Show Excluded Project Paths visibly but subdued.
- Add UI tests.

Deliverable: File Tree provides the main discoverable UI for External Project Directories and Vendored Project Directories without making cross-root filesystem edits risky.

### Phase 6: Commands and drag/drop

- Add command palette commands.
- Add File Tree `Mark Selected Folder…` flow.
- Add prompt flows for adding/removing/renaming entries, changing role, and changing storage.
- Add directory drag/drop flow.
- Add the Project Paths View as the management surface.

Deliverable: feature is usable without manually editing `.anvil_project.lua`.

### Phase 7: LSP follow-up

- Investigate LSP workspace folder support per server.
- Add workspace folder notifications only if they improve real behavior.
- Keep tree-sitter support as the reliable baseline for project-wide external source browsing.

## Open questions

1. Should “Copy Relative Filepath” for external files copy `jdk-src/java/lang/String.java` or report that the file is outside the Root Project?
2. Should External Project Directories be allowed to have per-root git status in File Tree immediately, or should that be deferred?
3. Should Excluded Project Paths apply to open-document autocomplete, or only project-wide indexes/searches?
4. Should external and vendored results receive the same penalty in file search, symbol search, usage search, and autocomplete, or should each role/kind have its own default?
5. Should any External Project Directory be writable from the File Tree initially, or should all external mutation wait for the absolute-path edit/apply refactor?

## First code target

Start with `data/core/project_paths.lua` plus runtime tests. That gives the rest of the feature one stable source of truth and prevents fuzzy search, File Tree, and tree-sitter from drifting into incompatible definitions of what External Project Directories, Vendored Project Directories, and Excluded Project Paths mean.
