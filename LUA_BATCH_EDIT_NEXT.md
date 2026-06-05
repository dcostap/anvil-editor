# Lua Batch Edit Refactor — Next Work

## Current next target: `Doc:ime_text_editing`

`Doc:ime_text_editing` still uses per-selection legacy operations:

- `delete_to_cursor`
- `insert`
- `set_selections`

It should be migrated to the Lua batch edit transaction path.

### Why this is next

- It is conceptually close to text input.
- It still performs one or more edits per selection.
- It has special final selection behavior that should be characterized before refactoring:

```lua
self:set_selections(sidx, line1, col1 + #text, line1, col1)
```

That means the final selection/caret anchor direction matters.

### Suggested implementation steps

1. Add runtime characterization tests for `Doc:ime_text_editing`:
   - collapsed multi-caret input
   - selected range replacement
   - final selection anchor direction
2. Refactor `Doc:ime_text_editing` to:
   - build one edit list
   - compute explicit final selections
   - call `Doc:apply_edits(...)`
3. Run targeted tests.
4. Run full Lua runtime/UI tests.
5. Commit separately.

## Next cleanup target: paste helpers

Paste is now substantially batched, but helper structure can be cleaned up.

### Candidate cleanup

- `paste_matching_whole_lines(...)`
- `paste_all_whole_line_clipboards(...)`

These share similar selection/line-delta logic and could be consolidated.

### Goal

Reduce duplicate paste selection math while preserving characterized behavior.

## Later targets

### Search/replace paths

Inspect remaining search/replace command code and plugin paths for per-selection edit loops that still call:

- `insert`
- `remove`
- `replace_cursor`
- `set_selections` after each individual edit

Migrate safe paths to `apply_edits` after adding characterization tests.

### Documentation update

Update `LUA_BATCH_EDIT_PLAN.md` after the next implementation chunk to reflect completed paste batching and remaining work.
