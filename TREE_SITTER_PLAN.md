# Tree-sitter Integration Plan

## Purpose

Add Tree-sitter to Anvil as a first-party language intelligence layer that is fast, non-intrusive, and designed to coexist with later LSP support. The end goal is not just prettier colors; it is a foundation for syntax highlighting, structure-aware navigation, local symbol intelligence, and future semantic augmentation.

This plan intentionally does **not** propose a user-facing synchronous Tree-sitter MVP. A tiny synchronous native test harness may be a useful internal middle step, but the editor-facing architecture must be asynchronous from the start.

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

Add a native module, probably separate from the existing tokenizer module:

```text
src/api/treesitter.c
src/treesitter/...
```

The native module owns all Tree-sitter pointers and exposes safe Lua handles. Lua should never see raw `TSParser *`, `TSTree *`, `TSQuery *`, or `TSQueryCursor *`.

Core native objects:

```text
AnvilTSLanguage
AnvilTSParser
AnvilTSTree
AnvilTSQuery
AnvilTSQueryCursor
AnvilTSParseJob
AnvilTSDocumentState
```

Likely Lua-facing API shape:

```lua
local ts = require "treesitter"

-- registry/config
local ok = ts.has_language("cpp")
local lang = ts.language("cpp")
local query = ts.query(lang, "highlights", query_source)

-- document state
local state = ts.new_document_state(lang)
ts.schedule_parse(state, snapshot, edit_info_or_nil)
ts.cancel_parse(state)
ts.poll(state) -- swaps ready result into state, returns status

-- query
local captures = ts.query_captures(state, "highlights", byte_start, byte_end)
```

The exact API can change, but the boundary should stay stable: Lua schedules parse jobs, polls status, and asks for visible-range captures.

### 2. Language registry

Add a first-party language registry that maps file patterns to Tree-sitter language definitions.

Suggested data layout:

```text
data\treesitter\languages\cpp\config.lua
data\treesitter\languages\cpp\highlights.scm
data\treesitter\languages\cpp\injections.scm
data\treesitter\languages\cpp\locals.scm
data\treesitter\languages\cpp\outline.scm
data\treesitter\languages\cpp\brackets.scm
data\treesitter\languages\cpp\indents.scm
```

`config.lua` can be simple and native to Anvil:

```lua
return {
  name = "C++",
  grammar = "cpp",
  files = { "%.cpp$", "%.hpp$", "%.h$", "%.cxx$" },
  line_comments = { "//" },
  block_comment = { "/*", "*/" },
  queries = {
    highlights = "highlights.scm",
    injections = "injections.scm",
    locals = "locals.scm",
    outline = "outline.scm",
    brackets = "brackets.scm",
    indents = "indents.scm",
  },
}
```

Why Lua config instead of TOML initially:

- Anvil already has Lua as the configuration/runtime language.
- Avoids adding a TOML parser just for Tree-sitter language metadata.
- Keeps first-party defaults consistent with the rest of the fork.

User-provided languages under `USERDIR` are intentionally out of scope. This fork should treat Tree-sitter languages as bundled first-party editor features.

### 3. Grammar packaging

Start with statically compiled grammars, like Fred. This is easiest and most reliable on Windows.

Initial grammar order:

1. `tree-sitter-c`
2. `tree-sitter-cpp`
3. `tree-sitter-lua` later, after the C/C++ path proves the integration

Possible Meson shape:

```text
subprojects/tree-sitter.wrap
subprojects/tree-sitter-c.wrap
subprojects/tree-sitter-cpp.wrap
subprojects/tree-sitter-lua.wrap
```

Or vendor generated parser sources under an Anvil-owned source directory if Meson wraps are awkward.

Do not start with dynamic grammar DLL loading. It can come later, but it adds Windows ABI, compiler, and security complexity.

Packaging notes that should be settled before Phase 1 lands:

- Track grammar/runtime versions and licenses in-repo.
- Include generated `parser.c` plus any external `scanner.c` / `scanner.cc` sources required by a grammar.
- Keep grammar registration explicit: grammar id -> `tree_sitter_<lang>()` function.
- Prefer reproducible Meson wraps or checked-in Anvil-owned package files over untracked local subproject edits.

### 4. Document state

Attach Tree-sitter state to each Anvil Document, not to each Document View.

Conceptual state:

```lua
doc.treesitter = {
  language_id = "cpp",
  generation = 0,
  edit_generation = 0,
  parse_generation = 0,
  status = "idle" | "snapshotting" | "queued" | "parsing" | "ready" | "stale" | "failed" | "disabled",
  reason = nil,
  native = userdata,
}
```

Important details:

- A Document may have several Document Views; they should share one parse tree.
- The old ready tree remains usable while a new parse is queued/parsing.
- Results are swapped in only when the parse generation still matches the Document generation.
- If the language changes, old parse jobs are cancelled and discarded.
- When a Document is closed or garbage-collected, outstanding jobs must be cancelled and native state must release without touching Lua from worker threads.

### 5. Snapshot model

Tree-sitter workers must not read Lua state from background threads. Lua strings and Document internals must be treated as main-thread-only.

Initial safe approach:

1. On the main thread, build an immutable native-owned UTF-8 snapshot of the Document's internal LF-normalized text.
2. Pass that snapshot to the native worker.
3. Worker parses only native-owned memory.
4. When complete, worker returns a tree plus metadata tagged with the Document generation.

Do not include save-time CRLF translation in the snapshot. Tree-sitter points and byte offsets should refer to the same internal text that `Doc.lines` and rendering use.

Potential issue: copying a huge Document on the UI thread can itself stall. Guardrails:

- Snapshot creation should be budgeted/yielding where possible.
- Large files can be disabled or delayed.
- Quiet-log snapshot time and byte size.
- Keep a hard max file size for Tree-sitter until snapshotting is optimized.

Later optimization:

- Native rope/piece snapshot API.
- Chunked snapshots.
- Reusing previous native snapshots.

### 6. Async parse state machine

Use Fred's state-machine idea, adapted to Anvil:

```text
ready
  edit -> apply ts_tree_edit to current tree, mark stale, debounce parse
stale
  debounce fires -> snapshotting/queued/parsing
parsing
  edit -> apply edit to visible old tree if possible, set needs_reparse, cancel current job
parsing + completed result current -> ready
parsing + completed result stale -> discard, schedule replacement if needed
failed -> fallback tokenizer, retry on later explicit language reload or settings change
disabled -> fallback tokenizer
```

Native parse jobs should support cancellation using:

```c
ts_parser_set_cancellation_flag(parser, &atomic_flag)
```

Rules:

- Do not block waiting for parse completion.
- Do not render from a partially updated tree.
- If parsing fails, keep the old tree if one exists.
- If no old tree exists, use current Anvil tokenizer fallback.

### 7. Edit integration

On every Document edit, compute a Tree-sitter edit:

```c
TSInputEdit {
  start_byte,
  old_end_byte,
  new_end_byte,
  start_point,
  old_end_point,
  new_end_point,
}
```

Required mappings:

- Anvil's 1-based `(line, col)` byte positions -> Tree-sitter's 0-based `TSPoint { row, column }` byte positions.
- Absolute byte offsets in the LF-normalized document snapshot.
- Edited range old/new points and byte lengths.

Anvil already tracks Document lines and changed ranges in transaction paths. The Tree-sitter layer should hook into `Doc:apply_edits` / `Doc:on_text_transaction` style mutation points where batch edits are available, rather than relying only on legacy `raw_insert` / `raw_remove` paths.

Important:

- Tree-sitter byte offsets and point columns are bytes, not UTF-8 character indices.
- Anvil Doc columns are also byte offsets today, but many user-facing movements operate by UTF-8 characters. Keep conversion helpers explicit and tested so structural commands do not land inside continuation bytes.

### 8. Highlighting path

When a Document View draws visible lines:

1. Ask Tree-sitter state whether a ready tree and highlight query exist.
2. Convert visible line range to byte range.
3. Use `ts_query_cursor_set_byte_range`.
4. Execute `highlights.scm` against the smallest relevant node:
   - root node initially
   - `ts_node_descendant_for_byte_range` later if it proves correct and faster
5. Convert captures into non-overlapping line spans.
6. Map capture names to `style.syntax[...]` keys.
7. Draw using existing Document View text rendering machinery.

Initial integration should prefer adapting the existing highlighter/token iteration boundary, or a parallel per-line span cache with the same semantics, so callers such as `DocView:draw_line_text`, minimap/search previews, and command UI do not each grow their own Tree-sitter path.

Cache query results by document generation, tree generation, query id, and visible line/byte range. Do not run an unbounded Tree-sitter query inside every per-line draw call.

Fallback behavior:

- If no ready tree: current `doc.highlighter` tokens.
- If query fails or language missing: current tokenizer.
- Tree-sitter and the regex tokenizer should never both render overlapping highlights for the same range. Pick one source per rendered span/line/range, with regex as fallback only.
- If query time exceeds budget repeatedly: temporarily disable Tree-sitter highlighting for that Document.

Capture mapping:

- Fully support the richer Tree-sitter capture vocabulary directly, e.g. `function`, `function.method`, `type.builtin`, `punctuation.bracket`.
- Add aliases/fallbacks where helpful for compatibility with existing Anvil style keys.
- Ensure `data\colors\default.lua` has complete first-party defaults for new style keys used by bundled query files.
- Preserve Anvil's existing `style.syntax` fallback behavior for unknown dotted scopes.

### 9. Query priority and overlap rules

Tree-sitter queries can produce overlapping captures. We need deterministic rules.

Initial rule proposal:

- Sort captures by start byte, then longer range first, then capture order.
- More specific dotted captures can override broader captures.
- Later captures may override earlier captures only when query metadata or a config flag says so.
- Do not allow rendering loops to repeatedly split pathological capture sets without a cap.

Need tests for:

- Nested captures.
- Adjacent captures.
- Overlap between keyword/function/string captures.
- Multi-byte UTF-8 text.
- CRLF documents.

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

Use a native worker:

- Worker receives native-owned snapshot, parser language, old tree copy if available, and cancellation flag.
- Worker runs `ts_parser_parse` / `ts_parser_parse_string` / input callback parse.
- Worker never touches Lua state.
- Main thread polls for completed jobs during normal update.
- Main thread owns swapping `doc.treesitter.native` state.

Tree-sitter parser objects are not shared across threads unless explicitly designed. Simpler rule:

- One parser per parse job, or one parser per worker thread with strict ownership.
- Trees may be copied with `ts_tree_copy` when needed.
- Delete Tree-sitter objects on the thread that owns the wrapper, unless Tree-sitter docs confirm cross-thread deletion is safe for that object.

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

Native tests:

- Load grammar.
- Compile queries.
- Parse simple source.
- Convert between Anvil byte positions and Tree-sitter byte offsets/points.
- Apply `TSInputEdit` and incremental reparse.
- Query visible byte range.
- Cancel parse.
- Delete/cleanup under repeated operations.

Lua runtime tests:

- Document language detection attaches Tree-sitter state.
- Missing grammar falls back to current tokenizer.
- Parse completion changes status to ready.
- Stale parse result is discarded after edits.
- Highlight captures map to expected syntax styles.

UI tests:

- Document View draws with Tree-sitter spans when ready.
- Falls back while parsing.
- Switching themes preserves required style keys.
- Structural commands operate on syntax tree when ready and fail gracefully when not.

Stress tests:

- Large C++ file.
- Long minified line.
- Rapid typing while parse is active.
- CRLF file, verifying internal LF-normalized offsets.
- UTF-8 identifiers/strings, verifying commands never select inside continuation bytes.
- Repeated open/close to catch leaks and stale worker completions.

### 16. Implementation phases

#### Phase 0: Design skeleton

- Add this plan.
- Decide initial grammar set.
- Decide build packaging approach.

#### Phase 1: Native Tree-sitter build + tests only

- Add Tree-sitter runtime and one grammar to Meson.
- Add explicit grammar registration and license/version notes.
- Add native test program or Meson test target proving parse/query/edit/cancel and byte/point conversion.
- This may include synchronous calls, but only in tests/tools. It is not the editor-facing MVP.

#### Phase 2: Async native parse service

- Add worker queue.
- Add parse job/result lifecycle.
- Add cancellation and generation ids.
- Add quiet diagnostics.

#### Phase 3: Document integration without rendering takeover

- Attach Tree-sitter state to Documents.
- Detect language.
- Schedule parses on open/edit/language change.
- Keep current tokenizer rendering.
- Expose status through quiet logs/debug command.
- Use statusbar/user-visible feedback only for important errors that need attention.

#### Phase 4: Tree-sitter highlighting path

- Add visible-range query API.
- Convert captures to spans.
- Integrate with Document View draw path.
- Fallback to current highlighter when unavailable.

#### Phase 5: First bundled languages

- Start with C/C++.
- Add query files and tests.
- Tune style defaults for the richer Tree-sitter capture vocabulary.

#### Phase 6: Structure/navigation

- Add outline query support.
- Add syntax-node selection expansion.
- Add enclosing/next/previous symbol navigation.
- Add local fallback for go-to-definition/usages only where query data is reliable.

#### Phase 7: LSP-ready abstraction

- Create a unified language intelligence interface.
- Define precedence between Tree-sitter and future LSP providers.
- Keep Tree-sitter as base/fallback.

#### Phase 8: LSP integration later

- Add LSP semantic tokens, definitions, references, document symbols, diagnostics.
- Overlay or replace Tree-sitter features according to settings and availability.

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
