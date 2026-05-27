# Native fuzzy engine plan

## Context

Anvil currently has several fuzzy matching/filtering paths:

- `src/api/system.c`: `system.fuzzy_match()` provides an older/simple C matcher.
- `data/core/common.lua`: `common.fuzzy_match()` wraps `system.fuzzy_match()` for generic callers.
- `data/plugins/fuzzy_searcher/init.lua`: the richer picker-specific Lua matcher handles spans, scoring, top-N filtering, file search, commands, grep result filtering, etc.
- File search in `fuzzy_searcher` currently indexes files with bundled `fd.exe`, then filters/scans paths in Lua.
- `build_scope()` in `data/plugins/fuzzy_searcher/init.lua` still uses generic fuzzy filtering over files, so file-related fuzzy behavior is duplicated and uneven.

For large projects, e.g. ~150k files, per-keystroke Lua filtering can become expensive. The recent Lua optimization makes file search acceptable, but a reusable native fuzzy engine would be faster and would consolidate duplicated fuzzy logic.

## Goals

- Build a reusable native fuzzy filtering engine in C.
- Keep fuzzy-searcher UI/state in Lua.
- Support both one-shot filtering and reusable indexed filtering.
- Make project file search effectively instant on large projects.
- Reuse the same engine for commands, buffers, symbols, recent projects, and other fuzzy lists over time.
- Return match spans for UI highlighting, but generate them only for returned top results.
- Do top-N selection in C to avoid large Lua allocation/sort spikes.
- Preserve current behavior where practical, especially path/basename ranking.

## Non-goals

- Do not move fuzzy-searcher UI into C.
- Do not replace `fd.exe`/`rg.exe` process-based indexing/search initially.
- Do not require all fuzzy callers to migrate at once.
- Do not introduce Lua callbacks in the hot per-item matching loop for v1.
- Do not preserve duplicate fuzzy APIs as a final state. `system.fuzzy_match()` should be removed from the public API or replaced by the new engine once call sites are migrated.

## Current file search behavior

File indexing currently uses bundled `fd.exe` roughly as:

```text
fd --type f --hidden --exclude .git .
```

Important behavior:

- `fd` respects `.gitignore` by default because `--no-ignore` is not passed.
- Hidden files are included because `--hidden` is passed.
- `.git` is explicitly excluded.
- Paths are normalized to project-relative `/` separated strings in Lua.

## Proposed API

Use a small built-in `fuzzy` module for the new API. The end state should have one native fuzzy implementation. Do not add parallel `system.fuzzy_*` wrappers unless they are thin migration shims scheduled for removal.

### One-shot filtering

For small or medium lists, expose a simple one-shot API:

```lua
local results = fuzzy.filter(items, query, opts)
```

Example:

```lua
local results = fuzzy.filter(commands, "opf", {
  limit = 100,
  mode = "generic",
  spans = true,
})
```

Return shape:

```lua
{
  { index = 42, text = "core:open-file", score = 1234, spans = {{6, 8}, {11, 11}} },
  ...
}
```

Return the source item index rather than arbitrary Lua objects in v1. Lua can map `result.index` back to its original item. This avoids storing registry references to arbitrary Lua tables in C.
```

### Reusable indexed filtering

For huge lists, especially project files, expose a userdata-backed index:

```lua
local index = fuzzy.index(items, opts)
local results = index:search(query, opts)
index:set_items(new_items)
index:free()
```

Example:

```lua
files_index = fuzzy.index(files_cache, {
  mode = "path",
})

local results = files_index:search(query, {
  limit = 501,
  spans = true,
})
```

## C-side data model

Design the C index to be CPU-cache-friendly from the start. Avoid one allocation per path/entry and avoid pointer-heavy layouts in the hot scan loop.

Preferred initial string-array index entry:

```c
typedef struct {
  uint32_t text_offset;     // offset into text_arena
  uint32_t lower_offset;    // offset into lower_arena
  uint32_t len;
  uint32_t source_index;    // 1-based Lua source item index
  uint32_t basename_start;  // path mode: first char after final slash/backslash
  uint32_t extension_start; // optional/later; 0 or UINT32_MAX when absent
} FuzzyEntry;

typedef struct {
  FuzzyEntry *entries;      // contiguous fixed-size entry array
  char *text_arena;         // packed original strings
  char *lower_arena;        // packed lowercase strings
  uint32_t count;
  uint32_t text_arena_len;
  uint32_t lower_arena_len;
  int mode;
  uint64_t generation;
} FuzzyIndex;
```

Search should linearly scan `entries[]`, read string bytes from contiguous arenas, keep a fixed-size top-N buffer, and avoid heap allocation per candidate.

Potential later precomputations:

- Separator positions.
- Word/camel boundary bitset or byte flags.
- Extension offset.
- Directory depth.
- Short-name/base-name ranking hints.

Keep hot fields compact and sequential. Use offsets (`uint32_t`) instead of pointers where practical to reduce memory footprint and improve cache behavior.

## Matching modes

The engine should support scorer profiles rather than one hardcoded scoring policy, but v1 should stay small: implement only `generic` and `path`. Add `command`, `symbol`, and `line` later if real call sites need distinct behavior.

### `generic`

Useful for commands, buffers, generic lists.

Prefer:

- exact substring matches
- prefix matches
- word boundary matches
- shorter text when quality is similar

### `path`

Useful for project files.

Prefer:

- basename matches
- exact substring in basename
- prefix of basename
- boundary matches after `/`, `\\`, `_`, `-`, `.`, and spaces
- shorter path when quality is similar
- reasonable handling of extension/name matches

### Later modes

Potential later modes if `generic` is not good enough for a given call site:

- `command`: command palette; prefer boundaries after `:`, `-`, `_`, command segment prefixes, and exact substrings.
- `symbol`: symbol/document outline; prefer prefixes, camelCase boundaries, `_` boundaries, and concise names.
- `line`: filtering line/grep results; prefer exact substrings and word boundaries, likely with spans disabled by default.

## Top-N selection

Top-N must happen in C.

Avoid this pattern:

```lua
-- Bad for large projects:
-- return all matches to Lua, allocate result tables, sort in Lua, then truncate.
```

Prefer:

```c
// C maintains a fixed-size sorted array or min-heap of the best N results.
// Lua receives only the requested limit.
```

For small `limit` values, a sorted fixed-size array is likely simple and fast enough. A min-heap can be considered if limits become large.

## Span generation

The C matcher should optionally return spans:

```lua
index:search(query, { limit = 100, spans = true })
```

Important: score all candidates cheaply, keep only the top-N candidates, then compute highlight spans only for those returned candidates. Do not allocate span data for every matching candidate.

When `spans = false`, skip span computation/table allocation entirely for speed.

Returned spans use Lua's existing 1-based inclusive positions:

```lua
spans = {{start_col, end_col}, ...}
```

## Lua item support

Version 1 should support arrays of strings only. This avoids Lua callbacks inside the hot loop.

Later support arrays of tables with a known key:

```lua
local idx = fuzzy.index(items, {
  key = "text",
  mode = "generic",
})
```

Avoid this in hot paths:

```lua
key = function(item) return item.text end
```

Calling Lua from C per item would erase much of the performance benefit.

## Integration plan

### Phase 1: Native engine foundation

- Add a new C fuzzy engine implementation, likely under `src/api/` or `src/fuzzy.*`.
- Prefer exposing it as a built-in `fuzzy` module:
  - `fuzzy.filter(items, query, opts)`
  - `fuzzy.index(items, opts)`
  - index methods: `search`, `set_items`, `free`, `__gc`
- Return low-level results with `index`, `text`, `score`, and optional `spans`.
- Implement only `generic` and `path` modes initially.
- Implement top-N selection in C.
- Generate optional spans only for returned top results.
- Migrate existing `common.fuzzy_match()`/`system.fuzzy_match()` users to the new API.
- Remove `system.fuzzy_match()` from the public API, or turn it into a private/internal helper, after migration.

### Phase 2: File search migration

- Keep file discovery via `fd.exe` in `data/plugins/fuzzy_searcher/init.lua`.
- Build the first C file index after `fd` finishes, not every partial batch. Avoid rebuilding a 150k-item index every 250 streamed files.
- Later, consider `index:add(batch)` if live partial-index search is needed during indexing.
- Replace Lua file filtering loop in `FSView:start_file_search()` with indexed C search.
- Keep the current Lua matcher as fallback if the native index is unavailable.
- Preserve recent file handling. Options:
  - append recents into the C index, or
  - search recents separately and merge results in Lua.

### Phase 3: Other fuzzy-searcher pickers and file scopes

After file search feels good, migrate additional fuzzy paths deliberately:

- `build_scope()` file filtering.
- Commands.
- Open buffers.
- Recent projects.
- Symbols or document items if applicable.
- Grep result file filtering where appropriate.

### Phase 4: Tune ranking and profiling

- Add lightweight profiling counters/timings behind a debug flag.
- Compare ranking against the current Lua matcher with real projects.
- Tune scoring constants for `path` and `generic` modes.
- Add regression tests for expected ordering on representative query/path sets.

## File search-specific design

The C-side path index should store:

- original project-relative path
- lowercase path
- length
- basename offset
- optional extension offset
- optional directory depth

Search behavior:

1. Trim/split query into words.
2. For each candidate, match all words.
3. Score exact substring matches highly.
4. Boost basename matches.
5. Boost basename prefix matches even more.
6. Boost boundary and consecutive matches.
7. Penalize long paths mildly.
8. Keep only top `limit + 1` results to determine `has_more`.
9. Compute spans only for the retained top results if requested.

## Memory and cache considerations

For ~150k files:

- Average path length might be ~80-120 bytes.
- Storing original + lowercase paths could be roughly 30-40 MB plus entry overhead.
- This is acceptable for large-project performance, but should be released on project switch.

Implementation preferences:

- Use contiguous arenas for original and lowercase strings.
- Use a contiguous `FuzzyEntry[]` with offsets into those arenas.
- Avoid one `malloc` per path.
- Avoid per-candidate temporary allocations during search.
- Keep the search loop mostly linear and branch-light.
- Keep Lua allocation limited to final returned results.

Potential memory reductions later:

- Store original strings only once and lowercase lazily/in-place in a second buffer block.
- Store boundary flags compactly only when a mode benefits enough to justify memory.
- Use narrower integer fields if practical after measuring max path/index sizes.

## Error/lifetime handling

- Index userdata must free all allocations in `__gc`.
- `set_items()` should replace the full index safely.
- Project switches should invalidate old indexes.
- If allocation fails, return Lua error or nil+message consistently.
- Lua code should handle native-index creation failure and fall back to Lua filtering.

## Minimal automated testing during implementation

The repository does not currently have a first-party C unit test framework for app code. Meson test support exists, but current discovered tests are from subprojects. There is also a Lua test framework (`data/core/test.lua`) for runtime-level tests.

For this work, add minimal first-party tests without pulling in a large framework:

- Keep the fuzzy core mostly pure C, e.g. `src/fuzzy.c` / `src/fuzzy.h`.
- Keep Lua binding code thin and separate, e.g. `src/api/fuzzy.c` or similar.
- Add a tiny C test executable, e.g. `tests/fuzzy_test.c`.
- Use plain `assert` or a small local `CHECK()` macro; no external test dependency.
- Add a Meson `test('fuzzy', fuzzy_test)` target so implementation can be validated with:

```sh
meson test -C build-windows-x86_64 fuzzy
```

Test only stable/easily testable behavior:

- exact substring matches are found
- non-matches are excluded
- case-insensitive matching works
- path basename match ranks above a weaker directory/path-only match
- top-N limit works
- returned `source_index` maps back correctly
- empty query behavior is deterministic
- spans for simple exact/subsequence matches are correct
- repeated create/search/free does not crash

Avoid brittle tests that assert exact numeric scores. Prefer ordering/invariant tests.

Optional later Lua smoke test, only if easy to wire through the existing runtime test path:

```lua
local fuzzy = require "fuzzy"
local idx = fuzzy.index({"src/main.c", "README.md"}, { mode = "path" })
local r = idx:search("main", { limit = 10, spans = true })
assert(r[1].text == "src/main.c")
```

Performance tests should be manual/optional at first: generate a large synthetic path list, print index/search timings, and use it for local regression checks rather than strict CI-style pass/fail.

## Expected payoff

For large file search:

- Index creation: one-time native preprocessing cost after `fd` indexing completes initially.
- Each keystroke: C scans preprocessed entries and returns only top results.
- Avoids per-keystroke Lua lowercasing, allocation, normalization, table construction, and sorting.
- Should remain smooth at 150k+ files and scale better to even larger projects.

## End state recommendation

Build the reusable C fuzzy index rather than a one-off file-search helper. Keep implementation v1 intentionally narrow: string arrays, `generic` and `path` modes, index-based results, top-N in C, and spans only for returned results. But the architectural end state should be bold: one native fuzzy engine, no duplicated Lua fuzzy engine, and no public legacy `system.fuzzy_match()` path.

After migration:

- `fuzzy` is the public fuzzy API.
- `system.fuzzy_match()` is removed or made non-public/internal.
- `common.fuzzy_match()` is either removed or kept only as a tiny convenience wrapper over `fuzzy.filter`/`fuzzy.score`, not as a separate implementation.
- `data/plugins/fuzzy_searcher/init.lua` no longer owns an independent fuzzy algorithm.

Best abstraction boundary:

```text
C fuzzy engine:
  - reusable index userdata
  - scorer modes
  - top-N result selection
  - optional spans

Lua fuzzy_searcher:
  - UI/state/key handling
  - fd/rg process orchestration
  - preview/open behavior
  - calls native fuzzy engine for filtering
```

This gives speed without baking fuzzy-searcher UI assumptions into C.
