# Tree-sitter Integration Plan

## Purpose

Add Tree-sitter to Anvil as a first-party language intelligence layer that is fast, non-intrusive, and designed to coexist with later LSP support. The end goal is not just prettier colors; it is a foundation for syntax highlighting, structure-aware navigation, local symbol intelligence, and future semantic augmentation.

This plan intentionally does **not** propose a user-facing synchronous Tree-sitter MVP. A tiny synchronous native test harness may be a useful internal middle step, but the editor-facing architecture must be asynchronous from the start.

## Implementation readiness contract

This document is meant to be executable by an implementation agent, but only in phase order. "Implement the entire thing" means implement the Tree-sitter foundation through syntax highlighting and first structure/navigation features; it does **not** mean implement LSP in the same task. LSP remains a later integration that this architecture must not block.

Agent rules:

1. Do not skip phases. A later phase can start only after the previous phase builds and its tests pass.
2. Do not depend on ignored local subproject checkout state. Any Tree-sitter runtime/grammar input must be tracked as a wrap, tracked packagefile, or tracked Anvil source file.
3. Do not add an editor-facing synchronous parse path.
4. Do not let background threads touch Lua state or `Doc.lines`.
5. Do not remove or weaken the existing regex/native-tokenizer fallback.
6. Prefer a smaller correct phase over a broad partially-working phase. If a phase hits an API/version mismatch, stop and report rather than guessing.
7. For non-Lua changes, run the normal Meson build/test path and update the dev portable app when finished.

Readiness status:

- This plan is ready to drive implementation only as a gated milestone sequence, not as a single open-ended "implement everything" task.
- Phase 0 and Phase 1 are the first implementation assignment. Phase 0 must make every dependency input reproducible from tracked files before any editor-facing code is attempted.
- Phases 2-5 are specified as the first editor-facing landing, but each phase needs its own implementation/validation checkpoint before the next phase starts.
- Phase 6 is a feature family. Treat outline, syntax-node selection, symbol navigation, and local definition/reference fallback as separate sub-milestones.
- Phases 7-8 are architectural constraints and future integration direction, not immediate implementation tasks.

Milestone handoff rule:

- An implementation agent should receive exactly one milestone at a time. At the end of each milestone, the agent must report changed files, test commands/results, any version/API mismatches, and any plan ambiguities discovered. The reviewer then updates this plan or issues the next milestone instruction.

## References

### Zed reference

Fetched repo:

```text
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\zed-industries\zed
```

Key files:

```text
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\zed-industries\zed\crates\language\src\language.rs
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\zed-industries\zed\crates\language\src\syntax_map.rs
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\zed-industries\zed\crates\language_core\src\grammar.rs
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\zed-industries\zed\crates\grammars\src\grammars.rs
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\zed-industries\zed\docs\src\extensions\languages.md
```

Useful Zed ideas:

- A language is configuration + grammar + queries.
- Queries are separate files: `highlights.scm`, `injections.scm`, `indents.scm`, `outline.scm`, `brackets.scm`, `textobjects.scm`, etc.
- Syntax layers support injected languages.
- Tree-sitter and LSP semantic tokens coexist. Tree-sitter can be the base layer; LSP can overlay or replace semantic coloring.
- Language extension support is data-driven: grammar registration plus query/config files.

### Fred reference

Decompiled source dump:

```text
C:\Projects\my_decomps\fred_src_dump
```

Recovered project root:

```text
C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred
```

Key files:

```text
C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred\src\tree-sitter-bridge.cpp
C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred\src\ed.cpp
C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred\src\ed-buffer-manager.cpp
C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred\src\thread.cpp
C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred\src\util.cpp
C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred\external\tree-sitter
```

Useful Fred ideas:

- It uses the Tree-sitter C API directly, which is closer to Anvil than Zed's Rust abstractions.
- It vendors Tree-sitter runtime and generated grammar C sources.
- It keeps parser/tree/query cursor/language/state on the editor's registered text object.
- It parses asynchronously and keeps the old tree active while a new tree is parsing.
- It uses a `ParsingNeedsReparse` style state when edits arrive during a parse.
- It uses `ts_tree_edit`, `ts_tree_copy`, `ts_parser_set_cancellation_flag`, and query cursors over visible byte ranges.
- It appears focused on syntax highlighting, parse-tree output, and HTML/color-copy behavior. I did **not** find evidence that Fred implements Tree-sitter-powered go-to-usage or go-to-declaration.

## Current Anvil state

Relevant current Anvil files:

```text
C:\Projects\c_projects\anvil-editor\data\core\syntax.lua
C:\Projects\c_projects\anvil-editor\data\core\tokenizer.lua
C:\Projects\c_projects\anvil-editor\data\core\doc\highlighter.lua
C:\Projects\c_projects\anvil-editor\src\api\tokenizer.c
C:\Projects\c_projects\anvil-editor\data\plugins\language_*.lua
```

Anvil currently has a line-oriented regex/pattern tokenizer with a native C backend. There is no Tree-sitter integration yet. The existing highlighter is cooperative: it tokenizes batches and yields through Anvil's coroutine system. A blocking Tree-sitter parse on the UI thread would be a regression for large files.

Important current-model details for the integration:

- `Doc.lines` stores UTF-8 text as Lua strings, usually one trailing `\n` per line.
- CRLF files are normalized internally to `\n`; `doc.crlf` is output/save metadata, not part of the live line strings.
- Doc positions/columns are 1-based byte offsets into those Lua strings. Character movement is layered on top by skipping UTF-8 continuation bytes.
- Binary/invalid UTF-8 documents use cleaned display lines through `Doc:get_utf8_line`; Tree-sitter should be disabled for binary docs unless a later design explicitly parses raw bytes.

## Goals

1. Use Tree-sitter for rich syntax highlighting.
2. Use Tree-sitter for structure-aware editor features:
   - document outline
   - enclosing function/class navigation
   - structural selection expansion
   - matching tags/brackets where queries support them
   - local symbol / definition / reference approximations where reliable
3. Keep the editor responsive on large files.
4. Fall back quietly to Anvil's current tokenizer when Tree-sitter is unavailable, slow, missing a grammar, or disabled for a Document.
5. Make adding bundled languages mostly data-driven.
6. Build the architecture so LSP can later layer on top cleanly.

## Non-goals for the first Tree-sitter landing

- No user-facing synchronous parse path.
- No immediate full Zed-equivalent language extension marketplace.
- No user-provided grammar/query extension system; this fork is bundled-first and single-user.
- No promise that Tree-sitter alone gives robust cross-file go-to-definition or go-to-usages.
- No replacement of the existing tokenizer fallback.
- No hard requirement that every existing language plugin be migrated immediately.

## Key design principle

Tree-sitter should be an **optional, asynchronous language layer** attached to a Document. It should enrich rendering and commands when ready, and disappear into the background when not ready.

The user's experience should be:

```text
Open/edit file -> Anvil stays responsive -> syntax/structure improves when parse is ready.
```

Not:

```text
Open/edit file -> UI blocks while parser catches up.
```

## Tree-sitter vs LSP responsibility split

Tree-sitter is syntactic. It can identify parse-tree structure and query captures. It is excellent for syntax coloring, outlines, structural navigation, local scopes in some languages, and text objects.

Tree-sitter is not enough for robust semantic code intelligence in languages like C/C++ where macros, includes, overloads, templates, types, build flags, and project configuration matter.

Expected split:

| Feature | Tree-sitter role | Later LSP role |
|---|---|---|
| Syntax highlighting | Base layer from `highlights.scm` | Optional semantic overlay or replacement |
| Outline | Query-based fallback / fast local structure | LSP document symbols can override or augment |
| Go to declaration/definition | Local/query fallback where reliable | Preferred source for semantic definition |
| Find usages/references | Local/query fallback, maybe current Document/project text index | Preferred source for semantic references |
| Diagnostics | None initially | LSP diagnostics |
| Completion | Possible syntax-aware context hints later | Preferred source for semantic completions |
| Rename | Not initially | LSP rename |
| Formatting | Not initially | LSP/formatter |

## Proposed architecture

### 1. Native Tree-sitter module

Add a native module separate from the existing tokenizer module:

```text
src/api/treesitter.c          -- Lua-facing userdata/API
src/treesitter/languages.c    -- explicit grammar registry
src/treesitter/languages.h
src/treesitter/service.c      -- native worker queue/lifecycle
src/treesitter/service.h
src/treesitter/snapshot.c     -- line table -> native UTF-8 snapshot + offset helpers
src/treesitter/snapshot.h
src/treesitter/query.c        -- query execution, predicate/directive handling, span conversion helpers
src/treesitter/query.h
```

The native module owns all Tree-sitter pointers and exposes safe Lua handles. Lua must never see raw `TSParser *`, `TSTree *`, `TSQuery *`, or `TSQueryCursor *`.

Core native objects:

```text
AnvilTSLanguage              -- static registry entry; not user-owned
AnvilTSSnapshot              -- native-owned LF-normalized document bytes + line starts
AnvilTSQuery                 -- compiled query + capture names + predicate/directive metadata
AnvilTSDocumentState         -- current tree, language, generations, active job pointer
AnvilTSParseJob              -- worker-owned parser/snapshot/old-tree/cancel flag/result
AnvilTSService               -- global worker queue, completed queue, mutexes/conds
```

Do not expose parser or query cursor userdata unless a later phase needs it. Keep parser/query-cursor allocation internal so ownership is obvious.

Concrete Lua-facing API for Phases 1-5:

```lua
local ts = require "treesitter"

-- runtime/registry
ts.runtime_version() -> string
ts.language_version(id) -> { abi = number, semantic = string? } | nil
ts.language_ids() -> { string, ... }
ts.has_language(id) -> boolean

-- compiled queries
-- Raises/returns nil+err on invalid query; native stores capture names and predicates.
local query, err = ts.compile_query(language_id, query_name, query_source)

-- document state
local state, err = ts.new_document_state(language_id, {
  parse_timeout_ms = 750,
  query_match_limit = 50000,
})
state:language_id() -> string
state:status() -> status, reason
state:generation() -> integer
state:cancel()
state:close()       -- idempotent; cancels active job and releases current tree

-- Scheduling copies doc lines into native memory on the main thread before queueing.
-- For a full parse, edit is nil.
-- For the first incremental path, edit is one normalized transaction edit in old-document coordinates.
-- If edit is provided and the current tree is safely renderable, native code must:
--   1. build TSInputEdit from the edit,
--   2. call ts_tree_edit on the main-thread current tree,
--   3. copy the edited tree with ts_tree_copy for the worker old_tree,
--   4. leave the main-thread edited tree renderable as safely-stale.
-- If any step fails, mark the current tree stale-unrenderable and queue a full parse instead.
state:schedule_parse(lines, generation, edit_or_nil) -> true | nil, err

-- Poll is main-thread-only. It swaps a completed current result into `state`.
-- It never blocks.
state:poll(current_generation) -> status, changed

-- Query ready current tree over a byte range. Returns captures/spans only from ready trees.
state:query_captures(query, byte_start, byte_end, opts) -> captures | nil, err
state:line_tokens(query, line_text, line_index, line_start_byte, line_end_byte, opts) -> token_table | nil, err
```

Allowed API adjustments during implementation:

- Method names can become table functions if that better matches existing C Lua module style.
- `line_tokens` may be implemented in Lua using `query_captures` first, then moved native if profiling demands it.
- The public boundary must remain: Lua schedules parses, polls status, and asks for visible-range captures/tokens. Worker threads never call Lua.

Native module registration:

- Add `int luaopen_treesitter(lua_State *L);` to `src/api/api.c`.
- Add `api/treesitter.c` and `src/treesitter/*.c` to `src/meson.build`.
- Keep the existing `tokenizer` module unchanged as fallback.

### 2. Language registry

Add a first-party Lua language registry that maps files to bundled Tree-sitter language definitions. This registry is separate from `core.syntax` but can use the same file/header matching style.

New Lua modules:

```text
data\core\treesitter\init.lua       -- high-level document integration helpers
data\core\treesitter\registry.lua   -- loads bundled configs, file/header matching, query loading
data\core\treesitter\highlight.lua  -- capture-to-token/span rules and cache helpers if not native
```

Bundled data layout:

```text
data\treesitter\languages\c\config.lua
data\treesitter\languages\c\highlights.scm
data\treesitter\languages\c\outline.scm          -- optional until Phase 6

data\treesitter\languages\cpp\config.lua
data\treesitter\languages\cpp\highlights.scm
data\treesitter\languages\cpp\outline.scm        -- optional until Phase 6
```

`config.lua` format:

```lua
return {
  id = "cpp",
  name = "C++",
  grammar = "cpp",
  files = {
    "%.h$", "%.inl$", "%.cpp$", "%.cc$", "%.C$", "%.cxx$",
    "%.c++$", "%.hh$", "%.H$", "%.hxx$", "%.hpp$", "%.h++$",
    "%.cu$", "%.ino$",
  },
  headers = {},
  line_comments = { "//" },
  block_comment = { "/*", "*/" },
  queries = {
    highlights = "highlights.scm",
    outline = "outline.scm",
    -- injections/locals/brackets/indents/textobjects are later-phase files.
  },
}
```

Registry rules:

- Load only bundled `DATADIR/treesitter` data. User-provided Tree-sitter languages under `USERDIR` are out of scope.
- Use the same best-match behavior as `core.syntax`: filename match first, then header match.
- If a config references a missing grammar, quietly disable that Tree-sitter language and fall back to regex tokenization.
- If a config references a missing query file, disable only that query kind and quiet-log it.
- Do not mutate existing `syntax.items`; existing language plugins remain the regex fallback and source for comment/symbol metadata until explicitly replaced.

Install/dev-portable changes:

- Add `treesitter` to the installed data dirs in root `meson.build`.
- Update dev BAT junction workflow so `anvil-portable\data\treesitter -> anvil-editor\data\treesitter`, matching core/plugins/colors.
- Keep machine-local state out of `data\treesitter`.

### 3. Grammar packaging

Use statically compiled grammars. Do not start with dynamic grammar DLL loading; it adds Windows ABI, compiler, and security complexity.

Preferred packaging decision:

```text
subprojects/tree-sitter.wrap
subprojects/tree-sitter-c.wrap
subprojects/tree-sitter-cpp.wrap
subprojects/packagefiles/tree-sitter/meson.build       -- if upstream runtime has no usable Meson build
subprojects/packagefiles/tree-sitter-c/meson.build     -- if grammar has no usable Meson build
subprojects/packagefiles/tree-sitter-cpp/meson.build   -- if grammar has no usable Meson build
```

Phase 0 must pin exact wrap revisions. Selected Phase 0/1 pins:

```text
tree-sitter runtime: https://github.com/tree-sitter/tree-sitter.git, commit 519d511488497f6af43698d4c856f4b3f1f0b80c, version 0.27.0.
tree-sitter-c:       https://github.com/tree-sitter/tree-sitter-c.git, commit b780e47fc780ddc8da13afa35a3f4ed5c157823d, version 0.24.2.
tree-sitter-cpp:     deferred; do not let C++ packaging delay the C native proof.
```

Do not use floating branches such as `master` or `main`. A commit hash is acceptable when a tag is unavailable, but it must be documented in this file and in license/version notes.

Existing local directories such as `subprojects/tree-sitter` and `subprojects/tree-sitter-c` are ignored by `.gitignore`; they may be inspected as references but must not be the source of reproducible build inputs unless corresponding wraps/packagefiles are checked in.

If Meson wraps are awkward for a grammar, the acceptable fallback is to vendor generated grammar sources under an Anvil-owned tracked directory, for example:

```text
src/treesitter/vendor/tree-sitter-c/src/parser.c
src/treesitter/vendor/tree-sitter-cpp/src/parser.c
src/treesitter/vendor/tree-sitter-cpp/src/scanner.c or scanner.cc
```

Do **not** rely on current ignored local directories under `subprojects/tree-sitter*`. This repo currently ignores `subprojects/*/`, so checked-out subproject directories are not reproducible unless their wrap/packagefiles are tracked.

Version/API decision:

- Target Tree-sitter runtime API: pinned runtime `0.27.0` from commit `519d511488497f6af43698d4c856f4b3f1f0b80c`.
- Cancellation is done with `ts_parser_parse_with_options` and `TSParseOptions.progress_callback`, not `ts_parser_set_cancellation_flag`.
- Query timeout/cancellation should use `ts_query_cursor_exec_with_options` and `TSQueryCursorOptions.progress_callback` when available, plus `ts_query_cursor_set_match_limit`.
- The pinned header exposes `ts_language_abi_version` and `ts_language_metadata`; the Phase 1 registry/API/tests use those for grammar compatibility and semantic version checks.
- If a different runtime version is pinned later, update this section and native tests to match the actual header before implementation proceeds.

Initial grammar order:

1. `tree-sitter-c` for Phase 1 native proof.
2. `tree-sitter-cpp` for the first editor-facing C++ path.
3. `tree-sitter-lua` later, after C/C++ highlighting is stable.

Packaging requirements before Phase 1 is considered done:

- Runtime and grammars are reproducible from tracked wrap/packagefiles or tracked vendor sources.
- Grammar/runtime versions and licenses are noted in `licenses/licenses.md` or a new tracked `licenses/tree-sitter.md` referenced from it.
- Generated `parser.c` and any external `scanner.c` / `scanner.cc` sources required by each grammar are included in the build.
- Grammar registration is explicit: grammar id -> `tree_sitter_<lang>()` function in `src/treesitter/languages.c`.
- Native test target links against the same runtime/grammar objects that the app uses.

### 4. Document state

Attach Tree-sitter state to each Anvil Document, not to each Document View.

Lua-side conceptual state:

```lua
doc.treesitter = {
  language_id = "cpp",
  generation = 0,             -- increments on each text transaction or language reset
  parse_generation = 0,       -- generation currently queued/parsing/ready
  tree_generation = 0,        -- generation represented by the ready native tree
  status = "idle" | "snapshotting" | "queued" | "parsing" | "ready" | "stale" | "failed" | "disabled",
  reason = nil,
  native = userdata,          -- AnvilTSDocumentState
  queries = { highlights = query_userdata, outline = query_userdata },
  highlight_cache = {},       -- visible-range or per-line token cache
  debounce_deadline = nil,
}
```

Lifecycle hooks:

- `Doc:new` / `Doc:reset`: state starts nil. Do not require Tree-sitter during core doc construction.
- `Doc:load` / `Doc:set_filename` / `Doc:reset_syntax`: call a Lua helper like `core.treesitter.attach_or_update_doc(doc)` after syntax/path detection.
- `Doc:on_text_transaction`: increment Tree-sitter generation and notify the Tree-sitter helper with the transaction.
- `Doc:on_close`: call `doc.treesitter.native:close()` if present, clear caches, and release query references.

Important details:

- A Document may have several Document Views; they share one parse tree and one highlight cache.
- The old ready tree remains usable while a new parse is queued/parsing only when its edits have been applied safely with `ts_tree_edit`.
- If an edit cannot be applied safely to the old tree, mark Tree-sitter highlighting stale and use regex fallback until the replacement parse is ready.
- Results are swapped in only when the parse generation still matches the Document generation.
- If the language changes, old parse jobs are cancelled and discarded, old query caches are dropped, and a fresh full parse is scheduled.
- When a Document is closed or garbage-collected, outstanding jobs must be cancelled and native state must release without touching Lua from worker threads.
- Binary/invalid UTF-8 documents (`doc.binary`) are `disabled` with reason `binary` for Phases 1-6.

### 5. Snapshot model

Tree-sitter workers must not read Lua state from background threads. Lua strings and Document internals are main-thread-only.

Initial safe approach:

1. On the main thread, native `state:schedule_parse(lines, generation, edits)` receives `doc.lines` and copies them into an `AnvilTSSnapshot`.
2. The snapshot stores:
   - one contiguous UTF-8 byte buffer containing Anvil's internal LF-normalized text,
   - total byte length,
   - line count,
   - zero-based absolute byte start for each 1-based Anvil line,
   - optional per-line byte length for tests/debug.
3. Worker parses only native-owned snapshot memory.
4. When complete, worker returns a tree plus metadata tagged with the Document generation and snapshot id.

Do not include save-time CRLF translation in the snapshot. Tree-sitter points and byte offsets refer to the same internal text that `Doc.lines` and rendering use.

Offset/point conversion rules:

```text
Anvil position:  line is 1-based, col is 1-based byte offset in Doc.lines[line]
Tree-sitter:     row is 0-based, column is 0-based byte offset in the row
absolute byte:   line_starts[line] + (col - 1)
TSPoint:         { row = line - 1, column = col - 1 }
```

For inserted text, compute the new end point by scanning inserted bytes for `\n`:

- no newline: `new_end_point = { start.row, start.column + #text }`
- with newlines: `new_end_point = { start.row + newline_count, bytes_after_last_newline }`

Potential issue: copying a huge Document on the UI thread can itself stall. Initial guardrails:

- Quiet-log snapshot time and byte size.
- If snapshot copy exceeds a hard internal budget or allocation fails, mark the document `disabled` or `failed` for Tree-sitter and keep regex fallback.
- Use an internal emergency byte cap only for this naive full-copy implementation. This cap is not a product policy and should be removed/revisited after chunked snapshots exist.
- Do not promote the emergency cap to user config unless we actually tune it in practice.

Later optimization:

- Native rope/piece snapshot API.
- Chunked snapshots that yield between line batches.
- Reusing previous native snapshots.

### 6. Async parse state machine

Use Fred's state-machine idea, adapted to Anvil:

```text
idle
  attach/schedule -> snapshotting -> queued -> parsing
ready
  single safe edit -> ts_tree_edit current tree, mark stale, debounce parse, stale tree may render
  unsafe/batch edit -> mark stale-unrenderable, debounce full parse, regex fallback renders
stale
  debounce fires -> snapshotting -> queued -> parsing
parsing
  edit -> cancel active job, update/disable old tree as above, debounce replacement parse
parsing + completed result current -> ready
parsing + completed result stale -> discard, schedule replacement if still needed
failed -> regex fallback, retry on later explicit language reload/settings change
unsupported/missing query -> regex fallback for that feature only
disabled -> regex fallback
closed -> cancel jobs, free tree/query/state
```

Native parse service:

- Use SDL threading primitives already available in the app: `SDL_CreateThread`, `SDL_Mutex`, `SDL_Condition`, `SDL_AtomicInt` or C atomics where already accepted by the compiler.
- Start a small global worker pool lazily on first scheduled parse. Initial worker count: `max(1, min(2, cpu_count - 1))` unless implementation simplicity favors exactly one worker first.
- Maintain one current queued/parsing job per Document state. Scheduling a new job for the same state cancels the old job and lets the worker discard it.
- Completed jobs are pushed to a completed queue. Main thread polls with `state:poll(current_generation)` and/or a global `ts.poll_all()` from `core.run_step`/a background coroutine.
- When a worker completes a job, wake the app with a custom SDL event named `treesitter_complete` through the existing custom event system. This event must be registered with a native callback that returns a Lua event, e.g. `"treesitter_complete"`, so `core.on_event` can dispatch it. Registering a custom SDL event with no Lua-visible callback is not enough, because it may be consumed by the native event poller without notifying Lua.
- The Lua event handler should poll completed Tree-sitter jobs, invalidate affected render caches, and set `core.redraw = true`. Do not rely on a future user event to notice parse completion.
- On app shutdown/native module unload, cancel outstanding jobs, signal workers, join them, then release remaining snapshots/trees.

Cancellation with current Tree-sitter APIs:

```c
TSParseOptions opts = {
  .payload = job,
  .progress_callback = anvil_ts_parse_progress,
};
TSTree *tree = ts_parser_parse_with_options(parser, old_tree, input, opts);
```

`anvil_ts_parse_progress` returns `true` when the job cancel flag is set or a parse-time budget is exceeded. If a runtime with `ts_parser_set_cancellation_flag` is deliberately pinned instead, update the native code and tests to that API.

Rules:

- Do not block the UI thread waiting for parse completion.
- Do not render from a partially updated tree.
- If parsing fails and an old safely-edited tree exists, keep it only if its generation mapping is still valid; otherwise use regex fallback.
- If no old tree exists, use current Anvil tokenizer fallback.
- Quiet-log schedule, cancellation, completion, stale discard, parse duration, snapshot size, and failure reason.

### 7. Edit integration

On every text transaction, decide whether the current ready tree can be incrementally edited or whether Tree-sitter should fall back while a full parse is scheduled.

Single-edit Phase 3/4 behavior:

- If `#transaction.edits == 1` and a ready tree exists, compute one `TSInputEdit`, call `ts_tree_edit` on the current tree on the main thread/native owner path, mark tree status `stale` but renderable, and schedule an incremental parse using `ts_tree_copy` as `old_tree`.
- If no ready tree exists, schedule a full parse.

Batch-edit initial behavior:

- If `#transaction.edits > 1`, do **not** attempt to apply multiple `ts_tree_edit` calls initially.
- Mark the old Tree-sitter tree `stale_unrenderable`, cancel any active parse, schedule a full parse after debounce, and render regex fallback until the new tree is ready.
- Later optimization may implement sequential multi-edit mapping, but it must include tests for simultaneous original-coordinate edits.

`TSInputEdit` fields for one normalized edit:

```c
TSInputEdit {
  start_byte     = edit.start_offset,
  old_end_byte   = edit.end_offset,
  new_end_byte   = edit.start_offset + strlen(edit.text),
  start_point    = { edit.line1 - 1, edit.col1 - 1 },
  old_end_point  = { edit.line2 - 1, edit.col2 - 1 },
  new_end_point  = point_after_insert(edit.line1, edit.col1, edit.text),
}
```

Required inputs from `Doc:apply_edits` / transaction:

- `transaction.edits[*].line1/col1/line2/col2`
- `transaction.edits[*].text`
- `transaction.edits[*].start_offset/end_offset`
- document generation after the transaction

The Tree-sitter layer should hook into `Doc:on_text_transaction(transaction)`, not legacy `raw_insert` / `raw_remove`. Existing plugins that wrap `raw_insert`/`raw_remove` should continue to work through the fallback highlighter path.

Important:

- Tree-sitter byte offsets and point columns are bytes, not UTF-8 character indices.
- Anvil Doc columns are also byte offsets today, but many user-facing movements operate by UTF-8 characters. Keep conversion helpers explicit and tested so structural commands do not land inside continuation bytes.
- For CRLF files, use internal LF offsets only. `doc.crlf` is save metadata.

### 8. Highlighting path

Use the existing highlighter/render boundary instead of scattering Tree-sitter calls through every view.

Phase 4 boundary decision:

- Keep `Highlighter:get_line()` as the legacy regex-tokenizer API because other code uses its tokenizer `state` for subsyntax/symbol behavior.
- Add render-facing methods to `data/core/doc/highlighter.lua`:

```lua
Highlighter:get_render_line(idx) -> { text = string, tokens = token_table, source = "treesitter" | "tokenizer" }
Highlighter:each_render_token(idx, scol) -> iterator
Highlighter:invalidate_render_cache(first_line, last_line)
```

- Update `DocView` text drawing and pixel/column measuring to use `each_render_token` / `get_render_line`.
- Leave command logic that needs tokenizer state on `get_line()` until a later language-intelligence abstraction replaces it.
- Other visual consumers can migrate to render tokens opportunistically, but the first highlighting landing must at least update `DocView:draw_line_text`, `DocView:get_col_x_offset`, and `DocView:get_x_offset_col` so displayed colors and hit-testing use the same token stream.
- Phase 4 must audit in-repo visual plugins that wrap drawing or measure text, especially `drawwhitespace`, `diffview`, and `bracketmatch`. They may continue using legacy `get_line()` where appropriate, but they must not create a mismatch where Tree-sitter-colored text is measured with a different token stream than the one drawn.

When a render line is requested:

1. Ask `doc.treesitter` whether a ready or safely-stale tree and `highlights` query exist.
2. Convert the requested line or visible line range to byte range using snapshot line starts.
3. Use `ts_query_cursor_set_byte_range`; also set `ts_query_cursor_set_match_limit`.
4. Execute `highlights.scm` against the root node initially. Only switch to `ts_node_descendant_for_byte_range` if tests prove captures that cross the visible range still work correctly.
5. Evaluate query predicates/directives for each match before accepting captures.
6. Convert accepted captures into non-overlapping line token spans.
7. Map capture names to `style.syntax[...]` keys.
8. Return a normal Anvil token table `{ type, text, type, text, ... }` so existing drawing code stays simple.

Query predicates/directives required for real bundled queries:

- Support at least `#eq?`, `#not-eq?`, `#match?`, `#not-match?`, `#any-of?`, `#not-any-of?` for filtering matches.
- Support `#set! priority <number>` or equivalent metadata for highlight priority if bundled queries use it.
- Predicate evaluation must be implemented against native snapshot text, not Lua strings. Capture text extraction must use capture byte ranges from the current snapshot.
- `#match?` / `#not-match?` should use Anvil's existing native regex infrastructure if practical; otherwise document the chosen C regex engine before implementing it.
- Unsupported predicates/directives must quiet-log once per query and either conservatively reject that pattern or disable the query; do not silently mis-highlight.
- Phase 4 must include a small fixture query that exercises every supported predicate/directive before C/C++ bundled queries are trusted.

Cache query results by document generation/tree generation, query id, and visible line/byte range. Do not run an unbounded Tree-sitter query inside every per-line draw call. A simple first cache can be per-line render tokens keyed by `{tree_generation, line_index, line_text}` and invalidated on text transactions/theme/query changes.

Fallback behavior:

- If no ready/safely-stale tree: current `doc.highlighter` regex tokens.
- If query fails or language missing: current tokenizer.
- Tree-sitter and the regex tokenizer must never both render overlapping highlights for the same line. Pick one source per rendered line, with regex as fallback only.
- If query time exceeds budget repeatedly or match limit is exceeded repeatedly: temporarily disable Tree-sitter highlighting for that Document and quiet-log the reason.

Capture mapping:

- Fully support richer Tree-sitter capture names directly, e.g. `function`, `function.method`, `type.builtin`, `punctuation.bracket`.
- Existing `core.init` already has dotted-scope fallback behavior for many syntax keys; extend `data/colors/default.lua` and `map_new_syntax_colors` only for capture names actually emitted by bundled query files.
- Themes should override keys; default.lua remains the complete first-party schema.

### 9. Query priority and overlap rules

Tree-sitter queries can produce overlapping captures. Rendering must be deterministic and capped.

Span resolution algorithm for a line:

1. Collect accepted captures intersecting the requested line.
2. Clamp capture byte ranges to the line's byte range for token generation, but preserve original range length for priority comparisons.
3. Drop zero-length captures for highlighting.
4. Enforce `max_query_captures`/match-limit before span splitting.
5. Build sorted boundary bytes from line start/end plus capture starts/ends.
6. For each adjacent boundary segment, choose the winning active capture by this order:
   - higher explicit query priority (`#set! priority`) wins;
   - more specific capture name wins, measured by dotted component count (`function.method.call` > `function`);
   - smaller original capture byte length wins, so child captures override broad parent captures;
   - later query pattern/capture order wins as final tie-breaker.
7. Emit adjacent segments with the same style as one token.
8. Fill uncovered segments with `normal`.

This rule intentionally prefers smaller/more-specific captures over broad captures. Query authors can override with explicit priority metadata.

Need tests for:

- Nested captures.
- Adjacent captures.
- Overlap between keyword/function/string captures.
- Explicit priority overriding specificity.
- Multi-byte UTF-8 text.
- CRLF documents using LF-normalized internal offsets.
- Capture sets that hit match/capture limits.

### 10. Structural navigation

Tree-sitter can power useful navigation before LSP exists:

- Go to enclosing function/class/module.
- Select enclosing function/class/comment/string.
- Expand selection by syntax node.
- Go to next/previous function/class.
- Outline / symbol list for current Document.
- Matching tag/bracket where query support exists.

Suggested query files:

```text
outline.scm
textobjects.scm
locals.scm
brackets.scm
```

Tree-sitter-only go-to-declaration/usages should be treated as a fallback, not the final answer.

Possible Tree-sitter fallback levels:

1. Current Document local definitions/references from `locals.scm`.
2. Project text/symbol index by identifier name.
3. If LSP is available later, prefer LSP for definition/references.

For C/C++, Tree-sitter alone cannot reliably resolve declarations/usages across translation units, macros, includes, overloads, or templates. LSP should eventually own that.

### 11. LSP coexistence plan

Tree-sitter should be designed as the base language layer that LSP can augment.

Settings model inspired by Zed:

```lua
config.semantic_tokens = "off"       -- Tree-sitter only
config.semantic_tokens = "combined"  -- Tree-sitter base + LSP overlay
config.semantic_tokens = "full"      -- LSP semantic tokens replace Tree-sitter highlighting where available
```

Navigation precedence:

```text
Go to definition:
  LSP result if ready and confident
  else Tree-sitter local/query fallback
  else text search fallback

Find usages:
  LSP references if available
  else Tree-sitter local refs + project text search
```

Outline precedence:

```text
LSP document symbols if enabled/available
else Tree-sitter outline.scm
else no outline / text fallback
```

Highlight precedence:

```text
Tree-sitter syntax captures
+ optional LSP semantic token overlay
+ existing selections/search/find/git diff overlays unchanged
```

### 12. Performance guardrails

Required from the first editor-facing integration:

- Parse cancellation.
- Debounced reparsing after edits.
- One current parse job per Document.
- Global worker queue/backpressure so many open files cannot spawn unbounded jobs.
- Generation checks before result swap.
- Visible-range query only for rendering.
- Query timeout or capture-count/match-limit guard.
- Quiet logs for parse duration, query duration, snapshot size, cancellation, fallback, and disable reasons.
- Automatic fallback to current tokenizer on repeated failures.

Do not add arbitrary normal-use file-size limits just because a file is large. Fred appears to rely on async parsing, cancellation, piece-tree snapshots, and visible-range queries rather than a simple user-facing size cap. Anvil should aim for the same end state.

One exception: if the first implementation uses a naïve full-document copy on the UI thread, keep an internal emergency snapshot memory/time guard so a pathological file cannot freeze or exhaust the editor. Treat that as a temporary safety rail, not a product policy; quiet-log it and fall back to the regex tokenizer.

Example internal defaults to consider only if needed:

```lua
config.treesitter = {
  enabled = true,
  parse_timeout_ms = 750,
  edit_debounce_ms = 120,
  max_query_captures = 50000,
  max_visible_query_ms = 8,
}
```

Per project policy says not every constant needs config immediately. Promote only values we genuinely expect to tune.

### 13. Threading model

Do not use Lua coroutines for actual parsing. They are cooperative and still run on the UI thread. Also avoid the Lua `thread` module for parsing: it creates separate Lua states and adds serialization/lifetime complexity that is unnecessary for C-only Tree-sitter work.

Use a native C service built on SDL primitives already linked into Anvil.

Ownership rules:

- Main thread owns `AnvilTSDocumentState`, current ready `TSTree`, compiled query userdata, and all Lua references.
- Worker owns its `TSParser`, parse job snapshot, old-tree copy, and result until it pushes completion.
- Worker never touches Lua state.
- Main thread polls completed jobs and swaps a result into `AnvilTSDocumentState` only after generation checks.
- A `TSTree` used as `old_tree` by a worker must be produced by `ts_tree_copy` so the main thread can keep rendering/owning its current tree independently.

Job structure should include at minimum:

```c
typedef struct AnvilTSParseJob {
  uint64_t job_id;
  uint64_t state_id;
  uint64_t generation;
  const AnvilTSLanguage *language;
  AnvilTSSnapshot *snapshot;
  TSTree *old_tree_copy;
  SDL_AtomicInt cancel;
  uint32_t parse_timeout_ms;
  double queued_time;
  double started_time;
  TSTree *result_tree;
  char *error;
} AnvilTSParseJob;
```

Parser rules:

- One parser per worker thread is preferred after Phase 2; one parser per job is acceptable for the first working implementation if simpler.
- A parser is never shared concurrently across threads.
- If a parse is cancelled by progress callback, call `ts_parser_reset(parser)` before reusing that parser.
- Deletion may happen on the owner thread chosen by the wrapper. Be consistent and document it in `service.c` comments.

Wake/poll integration:

- Register a custom event such as `treesitter_complete` during native module init, or expose a lightweight `ts.poll_completed()` called from a background coroutine that yields frequently.
- Preferred is a custom SDL event, because Anvil may sleep when there are no events/redraws.
- The Lua handler for the custom event should poll completed jobs, update document states, clear affected render caches, and set `core.redraw = true`.

Shutdown rules:

- `doc:on_close` cancels that state's queued/parsing job and marks the state closed.
- Native service shutdown cancels all jobs, wakes all workers, joins them, drains completed jobs, and frees snapshots/trees.
- A completed job for a closed or generation-mismatched state is discarded quietly.

### 14. Adding language support later

Adding a bundled language should require:

1. Add generated grammar source to build.
2. Register grammar id -> `tree_sitter_lang()` function.
3. Add `data\treesitter\languages\<id>\config.lua`.
4. Add query files.
5. Add style defaults only for new first-party capture keys.
6. Add a small parse/highlight test fixture.

User languages under `USERDIR` and dynamic grammars are intentionally out of scope for this fork. New language support should be added as bundled first-party code.

### 15. Testing plan

Add tests at each phase. Do not defer all tests until highlighting is visible.

Native tests:

- New Meson target, e.g. `tests/native/treesitter_test.c`, registered as `anvil:treesitter`.
- Load each registered grammar and verify `ts_parser_set_language` succeeds.
- Compile bundled/simple queries and report useful query errors.
- Parse simple C source and assert root node type/ranges.
- Convert Anvil positions to Tree-sitter points/bytes:
  - ASCII single-line,
  - multi-line,
  - UTF-8 multi-byte text,
  - trailing newline,
  - CRLF input after LF normalization.
- Apply one `TSInputEdit` and incremental reparse; verify changed ranges/root remains valid.
- Query visible byte range and containing byte range.
- Evaluate supported predicates/directives.
- Cancel parse through the actual runtime API (`TSParseOptions.progress_callback` for runtime 0.27-style API).
- Cancel query through `TSQueryCursorOptions.progress_callback` where available.
- Repeated create/parse/cancel/delete loop to catch leaks/crashes.

Lua runtime tests:

- Registry loads bundled language configs.
- File detection attaches Tree-sitter state for C/C++ and leaves unsupported files alone.
- Missing grammar falls back to current tokenizer.
- Missing/invalid query disables only that query kind.
- Parse completion changes status to ready.
- Stale parse result is discarded after edits/generation mismatch.
- Single edit keeps safely-stale tree renderable while replacement parse is pending.
- Batch edit marks Tree-sitter stale-unrenderable and uses regex fallback until ready.
- Highlight captures map to expected syntax style keys.
- `doc:on_close` cancels jobs and late completions are ignored.

UI tests:

- Document View draws with Tree-sitter render tokens when ready.
- Document View falls back while parsing/unready/stale-unrenderable.
- `get_col_x_offset` and `get_x_offset_col` use the same render token stream as drawing.
- Switching themes preserves required style keys.
- Structural commands operate on syntax tree when ready and fail gracefully when not.

Stress/manual diagnostic tests:

- Large C++ file.
- Long minified line.
- Rapid typing while parse is active.
- Multi-cursor/batch edits.
- CRLF file, verifying internal LF-normalized offsets.
- UTF-8 identifiers/strings, verifying commands never select inside continuation bytes.
- Repeated open/close to catch leaks and stale worker completions.

Default commands:

```sh
meson test -C build-windows-x86_64 anvil:treesitter --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/treesitter.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/treesitter_highlight.lua --print-errorlogs
meson test -C build-windows-x86_64 --suite anvil --print-errorlogs
```

### 16. Implementation phases

#### Phase 0: Plan and packaging decision

Deliverables:

- This expanded plan is checked in.
- Add or update tracked Meson wraps/packagefiles for the Tree-sitter runtime and the Phase 1 grammar.
- Confirm exact runtime/grammar versions and record them in this plan and license/version notes.
- Confirm the runtime header contains the cancellation/query APIs the implementation will use. If the pinned runtime differs from this plan's API assumptions, update this plan before writing Phase 1 native code.
- Remove or ignore any temptation to use untracked local `subprojects/tree-sitter*` state.
- Decide whether C++ grammar is included now or deferred to Phase 5; do not let C++ packaging delay the C native proof.

Suggested Phase 0 file outputs:

```text
subprojects/tree-sitter.wrap
subprojects/tree-sitter-c.wrap
subprojects/packagefiles/tree-sitter/meson.build       -- if needed
subprojects/packagefiles/tree-sitter-c/meson.build     -- if needed
licenses/tree-sitter.md                                -- or equivalent section referenced from licenses/licenses.md
```

Exit criteria:

- `git status --short` shows every new dependency input represented by tracked files.
- `meson setup --reconfigure build-windows-x86_64` or the equivalent Meson configure step can resolve the pinned runtime and grammar from tracked wraps/packagefiles.
- No editor-facing code has been added yet.

#### Phase 1: Native Tree-sitter build + tests only

Deliverables:

- Tree-sitter runtime and `tree-sitter-c` build through Meson.
- Optional `tree-sitter-cpp` can be added here if packaging is easy; otherwise Phase 5.
- `src/treesitter/languages.c` explicit registry with `c` and any other Phase 1 grammar.
- `src/api/treesitter.c` exposes minimal runtime/grammar/query test functions.
- License/version notes added.
- Native `anvil:treesitter` test target proves parse/query/edit/cancel/offset conversion.

Allowed synchronous code:

- Synchronous parsing is allowed only in native tests/tools in this phase.
- No editor-facing parse scheduling yet.

Exit criteria:

- `meson test -C build-windows-x86_64 anvil:treesitter --print-errorlogs` passes.
- Full `meson test -C build-windows-x86_64 --suite anvil --print-errorlogs` passes or failures are unrelated and reported.

#### Phase 2: Async native parse service

Deliverables:

- Global native worker service with queue, completed queue, cancellation, shutdown, and quiet diagnostics.
- `AnvilTSSnapshot` copies `doc.lines`-style Lua tables on the main thread.
- `AnvilTSDocumentState` supports `schedule_parse`, `cancel`, `poll`, `close`, status/reason.
- Completion wakeup mechanism implemented, preferably custom SDL event `treesitter_complete`.
- Native tests cover queued parse, cancellation, stale result discard at the native-state level, and close/shutdown.

Exit criteria:

- No Lua document/render integration yet.
- A Lua/native smoke test can schedule a parse without blocking and poll it to ready.

#### Phase 3: Document integration without rendering takeover

Deliverables:

- `data/core/treesitter/registry.lua` and `data/core/treesitter/init.lua`.
- `data/treesitter/languages/c/config.lua` and/or `cpp/config.lua`.
- `Doc` lifecycle hooks attach/update/close Tree-sitter state.
- Parses scheduled on open, filename/syntax change, and text transaction.
- Single-edit incremental path; multi-edit full-parse/fallback path.
- Regex tokenizer remains the only rendering source.
- Debug command/status helper such as `tree-sitter:log-document-status` or equivalent quiet diagnostics.

Exit criteria:

- Lua runtime tests verify attach, ready status, stale discard, fallback, close cancellation.
- Opening/editing C/C++ files does not change visible highlighting yet and does not block the UI.

#### Phase 4: Tree-sitter highlighting path

Deliverables:

- Bundled `highlights.scm` for the first language being tested.
- Query compile/cache and predicate/directive support needed by the bundled query.
- Visible-range or per-line query API.
- Capture-to-token span resolver with deterministic overlap rules.
- `Highlighter:get_render_line` / `each_render_token` added.
- `DocView` draw and pixel/column measuring migrated to render tokens.
- Fallback to regex tokenizer when Tree-sitter is unavailable/unready/disabled.
- Performance guardrails for query match limit, capture count, and repeated slow query disable.

Exit criteria:

- UI test proves Tree-sitter tokens draw when ready and regex tokens draw while unready/fallback.
- No overlapping double-highlighting.
- Existing tokenizer tests still pass.

Phase 4 implementation note:

- Completed for bundled C highlighting only. C++ grammar/config/highlighting, structure/navigation, and LSP layering remain deferred to later phases.

#### Phase 5: First bundled C/C++ language support

Deliverables:

- Add `tree-sitter-cpp` grammar if not already added.
- C and C++ configs/query files installed under `data/treesitter/languages`.
- Capture names emitted by bundled queries have defaults/fallbacks in `data/colors/default.lua` and `core.init` mapping as needed.
- Small parse/highlight fixtures for C and C++.
- Existing `language_c.lua` and `language_cpp.lua` remain regex fallback.

Exit criteria:

- C and C++ files highlight through Tree-sitter when ready.
- Missing grammar/query can be simulated and falls back quietly.
- Dev portable install includes `data/treesitter` junction/data.

#### Phase 6: Structure/navigation

Deliverables, preferably split into sub-phases:

1. Outline:
   - `outline.scm` support.
   - Current-document outline API returns sorted symbols with ranges/kinds/names.
   - Fallback gracefully when no ready tree/query.
2. Syntax-node selection expansion:
   - Commands expand/shrink selection by syntax node boundaries.
   - Never land inside UTF-8 continuation bytes.
3. Enclosing/next/previous symbol navigation:
   - Commands for enclosing function/class/module and next/previous function/class.
4. Optional local definition/reference fallback:
   - Only where query data is reliable.
   - Clearly label as local syntactic fallback, not semantic truth.

Exit criteria:

- UI/runtime tests for each command behavior.
- No tests for exact keybindings.

#### Phase 7: LSP-ready abstraction

Deliverables:

- A Lua-facing language intelligence interface that Tree-sitter implements:
  - syntax highlighting provider,
  - outline provider,
  - structural selection/navigation provider,
  - optional local symbol provider.
- Precedence rules documented in code comments/config docs.

Exit criteria:

- No LSP implementation required.
- Tree-sitter code is not hardwired in places that would prevent LSP overlay/replacement later.

#### Phase 8: LSP integration later

Deliverables:

- LSP semantic tokens, definitions, references, document symbols, diagnostics.
- Overlay or replace Tree-sitter features according to settings and availability.

Exit criteria:

- Out of scope for the initial Tree-sitter implementation.

## Confirmed implementation decisions

These decisions were confirmed during planning and should be treated as part of the implementation spec.

1. **Dependency packaging:** Use tracked Meson wraps for `tree-sitter`, `tree-sitter-c`, and `tree-sitter-cpp`, with packagefiles for missing Meson build definitions. Vendored generated sources are allowed only if a grammar wrap is awkward.
2. **Runtime API/version:** Pin a current Tree-sitter runtime and use progress-callback cancellation (`ts_parser_parse_with_options`) instead of the older `ts_parser_set_cancellation_flag`.
3. **First proof grammar:** Phase 1 native proof uses C only, then C++ is added in Phase 5 unless C++ packaging is trivial and can be added in Phase 1 without delaying the native proof.
4. **Completion wakeup:** Use a custom SDL event (`treesitter_complete`) to wake the main loop when parse jobs finish.
5. **Initial batch edit behavior:** For multi-edit transactions, temporarily fall back to regex until a full replacement parse is ready instead of attempting complex sequential `ts_tree_edit` mapping immediately.
6. **Emergency snapshot guard:** Allow an internal, quiet-logged emergency guard for naive full-document snapshot allocation/time. Keep it internal only; do not expose it as a user-facing file-size policy yet.
7. **Highlight boundary:** Keep `Highlighter:get_line()` legacy and add `get_render_line`/`each_render_token` for Tree-sitter-aware drawing.
8. **Structure fallback ambition:** Defer Tree-sitter go-to-definition/usages until outline/selection/navigation are working; keep them explicitly local/syntactic.

## User decisions

1. First language path: C/C++ first, Lua later.
2. Parse/status visibility: quiet by default. Use quiet logs and debug/status commands; show statusbar feedback only for important errors that need user attention.
3. Fallback policy: keep the old regex tokenizer permanently as fallback. It must not conflict with or overlap Tree-sitter highlighting.
4. Capture vocabulary: fully support richer Tree-sitter capture names, with aliases/fallbacks where useful.
5. Performance policy: avoid arbitrary normal-use file-size caps. Prefer async parsing, cancellation, visible-range queries, and backpressure; only use temporary emergency guards for naïve snapshot stalls/OOM risks.
6. Structure/navigation priority: all listed Tree-sitter structure features are desired after highlighting.
7. Stale highlighting: keep the old ready Tree-sitter tree while a new parse is pending when safe; fall back only on failure or excessive staleness.
8. Language extensibility: bundled first-party languages only; no user language extension system.
9. LSP precedence: combined mode by default, with Tree-sitter as base and LSP semantic tokens/features overlaying or replacing where appropriate.

## Summary

Fred shows the practical C/C++ path: native Tree-sitter runtime, hardcoded grammar registration, async parse jobs, edited old trees, visible-range query captures, and fallback behavior. Zed shows the larger language architecture: query-file conventions, language registries, injections, and LSP coexistence.

Anvil should combine those lessons: implement Fred-like async C integration first, but shape the language/query/config layer so it can grow toward Zed-style language intelligence and LSP coexistence.
