# Tree-sitter Project Usage Index Plan

## Purpose

Make Tree-sitter-backed Project symbol/navigation features feel ready immediately after opening Anvil. The target user story is:

```text
Open a Project -> Anvil starts Tree-sitter indexing in the background -> Find usages of an outline symbol is instant or near-instant once the initial scan completes.
```

This is intentionally **syntactic usage search**, not semantic reference resolution. Tree-sitter will find parsed identifier occurrences with the same text as a symbol name. It will not prove imports, aliases, overloads, packages, inheritance, or type resolution. That is acceptable for this feature; semantic accuracy remains the LSP provider's job.

## Desired behavior

1. Tree-sitter Project indexing starts automatically at startup for the Root Project.
2. If workspace restoration adds extra Project directories, those Projects are indexed too.
3. Indexing runs in background coroutines and never blocks editing/rendering.
4. The existing Project Symbol Search still works from the same index.
5. `language:show-references` / `Alt+Shift+R` uses LSP first; when LSP is unavailable or empty, it uses the Tree-sitter Project usage index.
6. Tree-sitter usage fallback should show Project-wide syntactic usages, not just current-Document local references.
7. Edits and file changes reindex only affected files where practical.
8. Deleting/renaming files removes stale symbols/usages.
9. Logging should make index startup, completion, refreshes, skips, and failures diagnosable with `core.log_quiet(...)`.

## Current state

Relevant files:

```text
data/core/treesitter/symbol_index.lua
data/core/commands/language.lua
data/core/treesitter/locals.lua
data/core/treesitter/outline.lua
data/core/treesitter/init.lua
data/plugins/fuzzy_searcher/init.lua
data/plugins/workspace.lua
tests/lua/runtime/treesitter.lua
tests/lua/ui/language_navigation.lua
```

Current behavior:

- Project symbol indexing is lazy. It starts when `symbol_index.workspace_symbols(...)` is called.
- The symbol index scans supported files, parses each file, runs `outline.scm`, and stores outline symbols.
- A newer `workspace_references(...)` path performs a separate on-demand Project scan for one requested name using `locals.scm`.
- That separate scan can be slow because it reparses files that the symbol scan may already have parsed.
- `language:show-references` falls back to Tree-sitter workspace references, then to current-Document local references.

Main issue:

```text
The Tree-sitter Project scan already touches every relevant file, but it only stores outline symbols. Usages are gathered later by a second scan.
```

## Terminology

Use these names in code and UI-facing strings:

- **Project usage index**: Tree-sitter syntactic identifier occurrences across a Project, keyed by identifier text.
- **Usage**: A syntactic occurrence of an identifier-like node with the same text as a symbol.
- **Reference**: Reserved for LSP/semantic references or existing command naming where changing it would be broader than this refactor.
- **Project symbol index**: Existing Tree-sitter outline-symbol index.

Avoid promising “semantic references” for the Tree-sitter fallback.

## High-level design

Replace the separate per-name Tree-sitter reference scan with an integrated per-file scan:

```text
for each supported Project file:
  read file
  parse once
  run outline.scm -> symbols
  run usage query -> identifier occurrences
  store both in index.by_path[path]

aggregate:
  index.symbols
  index.usages_by_name[name]
```

Then usage lookup becomes cheap:

```lua
symbol_index.workspace_usages("TargetThing", { include_declaration = false })
-- or keep workspace_references(...) as the public compatibility wrapper
```

### Query source

Prefer a dedicated usage query kind instead of reusing full local-scope semantics:

```text
data/treesitter/languages/<language>/usages.scm
```

Language config gains:

```lua
queries = {
  highlights = "highlights.scm",
  outline = "outline.scm",
  locals = "locals.scm",
  usages = "usages.scm",
}
```

Initial Kotlin `usages.scm` should capture identifier-like syntax needed for class/function/property usages. Exact node names should match the Kotlin grammar already added.

Capture contract:

- Non-declaration occurrences should be captured as `@usage` or `@reference`.
- Declaration/name sites should either keep the existing `@definition.*` shape or be normalized to `is_declaration = true` during extraction.
- `include_declaration = false` must exclude declaration/name sites from `workspace_usages(...)` and the `language:show-references` Tree-sitter fallback.
- Deduplicate by name + file/range because some queries may capture the same node as both a definition and a usage.

Fallback rule:

- If `usages.scm` exists, use it.
- Otherwise, optionally fall back to `locals.scm` captures for languages already configured that way, but normalize captures into the same usage/declaration contract.
- Do not require every Tree-sitter language to have Project usages before indexing symbols.

## Data model

Extend each file entry:

```lua
index.by_path[path] = {
  fingerprint = fingerprint,
  symbols = { ... },
  usages_by_name = {
    ["TargetThing"] = {
      {
        name = "TargetThing",
        kind = "usage" | "definition" | ...,
        capture = "usage",
        is_declaration = false,
        path = path,
        file = relpath,
        relpath = relpath,
        language_id = language.id,
        text = "TargetThing",
        line_text = "...",
        start_line = 4,
        start_col = 13,
        end_line = 4,
        end_col = 24,
        start_byte = ...,
        end_byte = ...,
        range = { start = ..., ["end"] = ... },
        workspace_tree_sitter_fallback = true,
      },
    },
  },
}
```

Extend the root index:

```lua
index.symbols = { ... }
index.usages_by_name = {
  ["TargetThing"] = { ...merged file usages... },
}
index.usage_count = 0
index.symbol_status = "idle" | "indexing" | "ready"
index.usage_status = "idle" | "indexing" | "ready"
```

Keep usage records intentionally similar to existing reference records so `data/core/commands/language.lua` can reuse picker conversion code.

Readiness rule:

- `workspace_symbols(...)` must be able to return fresh/stale symbol results as soon as outline extraction is complete enough for its status, even if usage extraction is still running.
- `workspace_usages(...)` reports usage readiness independently.
- A parse-once implementation is still preferred, but the public symbol-search path must not wait behind heavier usage aggregation.

## Fingerprints and invalidation

The file fingerprint must include all query inputs that affect the file entry:

- file size
- modified time
- language id
- grammar id
- effective parse timeout
- outline query source and effective outline query limits
- usage query source, or fallback locals query source, plus effective usage query limits (`match_limit`, `max_captures`, `timeout_ms`)

If any outline/usage query input or effective limit changes, that file must reindex. If implementation chooses not to include a tunable in the fingerprint, changing that tunable must explicitly invalidate the index.

## Startup indexing

Add an explicit startup trigger, probably in `core.treesitter` or `symbol_index`:

```lua
symbol_index.start_project_indexing({ reason = "startup" })
```

Expected behavior:

1. After the Root Project exists and Tree-sitter is loaded, schedule indexing for `core.root_project().path`.
2. After workspace restoration adds extra Projects, schedule indexing for each `core.projects[i].path`.
3. Hook Project lifecycle points:
   - wrap `core.add_project(project)` so extra Projects added after startup, including workspace-restored Projects, schedule indexing idempotently;
   - wrap or integrate with `core.set_project(project)` so Project switches invalidate old assumptions and schedule the new Root Project;
   - use a startup/deferred call as a safety net, not as the only mechanism.
4. Avoid duplicate work: if a Project is already indexing or ready and fresh, do not restart it.

Implementation preference:

- Put the public scheduling API in `data/core/treesitter/symbol_index.lua`.
- Make the `core.add_project` hook mandatory and idempotent. A one-shot deferred startup scan can race with workspace restoration and miss extra Projects.
- Keep plugin-specific hooks minimal; install Project hooks once from Tree-sitter core code after `core.projects` exists.

## Background execution and responsiveness

Initial implementation can keep using Anvil coroutines:

```lua
core.add_thread(function()
  scan_index(index, generation)
end)
```

Performance rules:

- Parse each file once per scan.
- Run outline and usage queries against the same parse state before closing it.
- Yield every small batch of files, as the current scan does.
- Preserve `MAX_FILE_BYTES` skip behavior.
- Keep query timeouts and capture limits per file.
- Use `core.redraw = true` on progress updates.

Future optional optimization:

- If Project indexing still causes frame hitches, add a native/background worker queue for file snapshots and query results. Do not start there unless profiling proves coroutine scanning is not enough.

## Incremental updates

### Open Document edits

When an open Document changes and Tree-sitter parse becomes ready, do **not** overwrite the disk-backed `index.by_path[path]` entry with unsaved buffer state. The disk-backed entry uses file size/mtime fingerprints; mixing unsaved content into it can leave stale usages after close/revert because the disk fingerprint still appears fresh.

Use a live-document overlay instead:

```lua
index.open_docs[path] = {
  doc = doc,
  change_id = doc:get_change_id(),
  symbols = { ... },
  usages_by_name = { ... },
}
```

Query-time merging should prefer the open-doc overlay for that path and suppress the disk-backed entry for the same path, similar to the existing `combined_symbols(...)` behavior.

Lifecycle rules:

1. If the Document belongs to one or more indexed Projects and has a supported language, update the overlay for every indexed Project whose root contains the file.
2. Clear the overlay on Document close, revert, filename change away from that path, or Tree-sitter detach.
3. On save, either clear the overlay and mark the disk entry dirty, or update the disk-backed entry with a new disk fingerprint after the save completes.
4. Rebuild only aggregates affected by that file where possible; at minimum, rebuild merged symbols/usages for affected indexes.

This gives immediate correctness for edited files without poisoning the disk-backed Project index.

Potential API:

```lua
symbol_index.update_open_document(doc, reason)
symbol_index.clear_open_document(doc, reason)
```

Call update from Tree-sitter document parse completion path after `treesitter.poll_doc(doc)` reports a ready/changed tree. Call clear from close/detach/revert/rename paths.

### Saved/current file changes

For files changed externally or saved without a live ready parse:

- Mark the file dirty when possible.
- Schedule a debounced per-file reindex.
- If no file-watcher integration is available, rely on periodic/freshness refresh as the fallback.

Potential API:

```lua
symbol_index.mark_file_dirty(path, reason)
symbol_index.reindex_file(path, opts)
```

### Deleted/renamed files

During full refresh scans, prune paths no longer found under the Project. For targeted delete/rename integration, remove the old path immediately when a file-tree operation or dirwatch event makes it available.

Minimum acceptable first implementation:

- Full Project refresh prunes deleted files.
- Open Document edits update live overlays for all matching Project indexes.
- On-demand queries can request refresh after `DEFAULT_REFRESH_AFTER_SECONDS` as they do today.

## Public API changes

Add or adjust these APIs in `symbol_index.lua`:

```lua
symbol_index.start_project_indexing(opts)          -- schedules all current Projects
symbol_index.ensure_scan(root, opts)               -- still valid, now indexes symbols + usages
symbol_index.workspace_symbols(query, opts)        -- unchanged behavior
symbol_index.workspace_usages(name, opts)          -- preferred Tree-sitter syntactic usage API
symbol_index.workspace_references(name, opts)      -- wrapper/deprecated internal alias to usages, for existing command code
symbol_index.update_open_document(doc, reason)     -- targeted live-doc overlay update for every matching Project
symbol_index.clear_open_document(doc, reason)      -- remove live-doc overlay on close/revert/detach/rename
symbol_index.mark_file_dirty(path, reason)         -- optional/debounced external update hook for every matching Project
symbol_index.status(root)                          -- include separate symbol/usage counts and progress
```

`workspace_references(...)` can remain for compatibility with `language:show-references`, but internally it should no longer perform a separate per-name scan.

## `language:show-references` flow

Desired flow:

```text
symbol at caret
  -> LSP references, if available
  -> Tree-sitter Project usages from integrated usage index
  -> current-Document local references only as last fallback
```

When Tree-sitter Project index is still building:

- Keep the picker open with status like:

```text
Tree-sitter: indexing Project usages… 120/290 files scanned
```

- If stale usage results exist, display them with `(indexing)` suffix.
- Do not replace the picker with local references just because Project indexing is still pending.
- Do not use a user-facing wait timeout for Tree-sitter Project usages. Keep waiting/updating until results are ready, the picker is closed, the request is superseded, or indexing reports a real unavailable/error state.

## Outline-symbol filtering

The user goal is usages of outline symbols, not every local variable.

Important distinction:

- Internally, the usage index may contain many identifier names.
- The command should prefer using it for names that correspond to an outline symbol or a selected identifier in a source file.

Recommended behavior:

1. If exact outline symbols with that name exist in the Project, show usages normally.
2. If no outline symbol exists, either:
   - still show syntactic usages, because the user explicitly invoked the command on an identifier, or
   - show current-Document local fallback.

For this fork, prefer option 1 plus still allow option 2 if results are available. Do not add strict blocking that makes obvious class usages disappear because the declaration file has not indexed yet.

## Memory and limits

Usage indexing stores more data than outline indexing. Keep the first implementation simple but bounded:

- Keep existing `MAX_FILE_BYTES`.
- Keep per-file `match_limit`, `max_captures`, and `timeout_ms`.
- Add a Project-level usage cap/status so a pathological Project cannot store millions of records silently.
- Deduplicate by file/range/name because a node may be captured as both a definition and a usage.
- Sort merged usages by relpath, line, col.
- Track `index.usage_count` and any cap/truncation reason for diagnostics.
- Prefer compact storage for the first eager-index implementation: store file/path identifiers and ranges, and hydrate `line_text` only for displayed picker rows if that is straightforward.

If memory still becomes a problem later:

- Store only names that also appear in outline symbols.
- Store file-local maps and build per-name aggregate lazily.
- Persist compact indexes outside Lua memory if needed.

Measure on the Kotlin Project before further optimization, but do not ship eager all-identifier indexing with no Project-level bound.

## Implementation phases

### Phase 1: Rename/design cleanup without behavior regression

- Decide final API names: `workspace_usages` preferred, `workspace_references` wrapper.
- Add separate symbol and usage status/progress fields to the existing index object.
- Define usage capture normalization, including `is_declaration` and `include_declaration` filtering.
- Keep tests passing with current behavior before deeper refactor.

Validation:

```sh
./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua data/core/treesitter/symbol_index.lua data/core/commands/language.lua
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/treesitter.lua --print-errorlogs
```

### Phase 2: Integrated parse-once file indexing

- Refactor `parse_file_symbols(...)` into a file indexer that returns symbols and usages.
- Keep one native document state per file.
- Run `outline.scm` and usage query before closing the state.
- Store disk-backed `symbols` and `usages_by_name` in `index.by_path[path]`.
- Build root `index.symbols` and `index.usages_by_name` aggregates, or a lazy per-name aggregate with the same public behavior.
- Preserve independent symbol/usage readiness so Project Symbol Search is not delayed by usage aggregation.
- Remove or bypass the separate `reference_indexes` per-name scan.
- Add Project-level usage cap/truncation diagnostics before enabling eager indexing by default.

Regression test:

- Existing workspace references test should still pass.
- Add assertion that `workspace_usages(..., { include_declaration = false })` excludes declarations.
- Add assertion that calling `workspace_symbols(...)` first makes later `workspace_usages(...)` fresh without launching a separate per-name scan.
- Add assertion that `workspace_symbols(...)` can return while usage indexing is pending/truncated, if the implementation exposes separate readiness.

### Phase 3: Kotlin usages query

- Add `data/treesitter/languages/kotlin/usages.scm`.
- Update Kotlin config to include it.
- Capture class/type identifiers, function call names, property names where useful, and simple identifiers.
- Preserve the usage/declaration capture contract (`@usage`/`@reference` versus `@definition.*`, or equivalent normalization).
- Avoid comments/strings by relying on Tree-sitter node types rather than text search.

Regression test:

- Kotlin class declared in one file and used in another returns Project-wide usages.
- A `.txt` file containing the same text does not count.
- String/comment occurrences in Kotlin do not count if the query can avoid them cleanly.
- Declaration filtering works: references-only mode excludes the class/function/property declaration site.

### Phase 4: Startup eager indexing

- Add `symbol_index.start_project_indexing(...)`.
- Schedule indexing for all currently loaded Projects at startup.
- Install a mandatory idempotent `core.add_project` hook so delayed workspace-restored Projects are indexed.
- Hook Project switches so indexing starts for newly loaded Root Projects and old indexes are invalidated or left isolated by root.
- Ensure startup indexing does not block window creation or restored editors.

Regression/UI test ideas:

- Set `core.projects` to a temp Project, call startup hook, wait until status is ready, assert symbols/usages exist without calling `workspace_symbols(...)` first.
- Add second Project via `core.add_project` after a delay, assert it schedules indexing; this covers workspace restoration races.

### Phase 5: Live Document updates

- Add `symbol_index.update_open_document(doc, reason)` and `symbol_index.clear_open_document(doc, reason)`.
- Use the already-ready Document Tree-sitter state to extract outline and usages for the changed file.
- Store results in live-document overlays, not disk-backed `index.by_path` entries.
- Update overlays for every indexed Project whose root contains the file.
- Rebuild merged aggregates or incrementally update aggregate maps.
- Call update from Tree-sitter parse completion polling for changed Documents; call clear from close/revert/detach/rename paths.

Regression test:

- Index Project with `OldName` usage.
- Open/edit Document to replace with `NewName`.
- Simulate/await Tree-sitter ready.
- Assert `workspace_usages("OldName")` no longer returns that edited occurrence and `workspace_usages("NewName")` does while the dirty Document is open.
- Close or revert the dirty Document without saving, then assert the disk-backed `OldName` usage returns and the unsaved `NewName` usage is gone.
- In overlapping Project roots, assert all matching indexes see the live overlay update.

### Phase 6: Dirty/external file refresh

- Add file dirty marking/debounce if there is an existing dirwatch or save hook suitable for this.
- Reindex dirty files individually for every indexed Project whose root contains the path.
- Keep full refresh as fallback for delete/prune correctness.

Regression test:

- After changing a file on disk and marking it dirty, only that file reindexes and usage results update.

### Phase 7: Command/UI polish

- Update `language:show-references` status text to say Tree-sitter Project usages when using syntactic fallback.
- Keep local references only as final fallback.
- Remove generic “Loading references…” wait timeouts from the Tree-sitter Project usage fallback; pending indexing should keep updating progress until ready/cancelled/error.

Validation:

- UI test for pending -> final picker update if feasible.
- Manual Kotlin Project check on `ConfiguradorDataClasses.kt` symbol that previously returned only local references.

## Testing commands

Lua syntax after Lua edits:

```sh
./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua \
  data/core/treesitter/symbol_index.lua \
  data/core/treesitter/init.lua \
  data/core/commands/language.lua \
  data/treesitter/languages/kotlin/config.lua
```

Targeted tests:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/treesitter.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/language_navigation.lua --print-errorlogs
```

Broader suite when implementation is complete:

```sh
meson test -C build-windows-x86_64 --suite anvil --print-errorlogs
```

## Success criteria

On the Kotlin Project that motivated this plan:

1. Startup logs show Tree-sitter Project indexing begins without opening fuzzy symbol search first.
2. Initial indexing scans each supported file once for both symbols and usages.
3. After initial indexing, `Alt+Shift+R` on a Kotlin outline symbol shows Project-wide Tree-sitter usages quickly.
4. The status does not fall back to “local references” merely because Project indexing is pending.
5. Editing a Kotlin file updates usages for that file without requiring a full Project rescan.
6. Deleted files are eventually pruned from symbols/usages.

## Non-goals

- No semantic correctness guarantee beyond exact syntactic identifier usage.
- No Kotlin compiler/indexer integration.
- No import/package resolution.
- No cross-language semantic resolution.
- No blocking startup scan.
- No large compatibility layer for old per-name reference scan behavior.

## Implementation status

Status as of the current uncommitted implementation pass:

Implemented:

- Eager Tree-sitter Project indexing hooks for Project add/set flow.
- Integrated Project scan that extracts outline symbols and usage captures from the same parsed file.
- Kotlin `usages.scm` and Kotlin config registration.
- `symbol_index.workspace_usages(...)`, with `workspace_references(...)` kept as a compatibility wrapper.
- `language:show-references` Tree-sitter fallback now uses Project usages and no longer has a user-facing wait timeout.
- Live open-Document overlay support so dirty buffers can override disk-backed entries without poisoning the disk index.
- Usage cap/truncation metadata and UI status handling for truncated usage indexes.
- Regression tests for Project-wide Kotlin usages, declaration filtering, eager indexing, live overlays, and cap-skipped files.

Not fully done / follow-up items:

- Project Symbol Search readiness is not fully decoupled from usage indexing. Partial/stale symbol results are improved during scans, but `symbol_status = "ready"` is still reached at the end of the combined symbols+usages scan.
- There is no complete targeted disk-backed `reindex_file(path)` implementation yet. Save-time behavior relies on live overlays plus normal Project refresh rather than a precise one-file disk reindex.
- External file dirty/dirwatch integration remains minimal. Full Project refresh still handles eventual pruning/refresh for external edits/deletes.
