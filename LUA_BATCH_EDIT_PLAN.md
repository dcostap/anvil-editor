# Lua Batch Edit Plan

## Goal

Make multi-caret editing fast and consistent by replacing per-caret mutation loops with one shared Lua batch edit transaction primitive.

The target user-facing behavior is that typing, deleting, pasting, and common transforms stay responsive with hundreds or thousands of carets.

## Problem

Many current commands iterate selections and call single-edit APIs such as `Doc:insert`, `Doc:remove`, `Doc:delete_to_cursor`, or `Doc:replace_cursor` once per caret.

Each single edit can rescan, adjust, sanitize, and notify the full selection state. With `N` carets, this creates `O(N^2)` behavior and can hang with thousands of carets.

## Core Primitive

Introduce one shared document mutation primitive, conceptually:

```lua
doc:apply_edits(edits, opts)
```

Each edit is a range replacement:

```lua
{
  line1 = line1,
  col1 = col1,
  line2 = line2,
  col2 = col2,
  text = replacement_text,
  selection = final_selection_after_edit,
}
```

All multi-caret text operations should eventually express their intent as a list of these edits and call this primitive once.

## Responsibilities

`Doc:apply_edits` should:

1. Snapshot original selections once.
2. Sanitize and validate edit ranges once.
3. Reject or deterministically resolve overlapping edits.
4. Sort edits bottom-to-top so earlier document positions remain stable while applying lower edits.
5. Apply all text changes in one transaction.
6. Compute final selections directly and install `doc.selections` once.
7. Sanitize and merge selections once at the end.
8. Push one undo transaction using table snapshots, not huge vararg lists.
9. Notify highlighter/cache/docviews/plugins once or with coalesced changed ranges.
10. Call `on_text_change` once.

## Commands To Migrate

Use the primitive for:

- typing / text input
- replacing selected text while typing
- backspace
- delete
- `doc:delete-to-*`
- paste
- newline / newline above / newline below
- indent / unindent
- duplicate lines
- delete lines
- move lines up/down
- upper/lower case transforms
- comment toggles
- any command matching the pattern: loop selections, then call `insert`, `remove`, `delete_to_cursor`, or `replace_cursor`

## Lua Performance Notes

Avoid LuaJIT pitfalls in hot batch paths:

- Do not use `table.unpack` on large selection arrays.
- Prefer flat arrays over many tiny temporary tables in tight loops.
- Avoid repeated `common.splice` where a coalesced line-table rewrite is simpler.
- Cache line lengths or sanitized positions when reused.
- Defer selection normalization until the end of the transaction.

## Compatibility Strategy

Keep public APIs such as `Doc:insert`, `Doc:remove`, `Doc:text_input`, and command names stable.

Refactor their implementations to call `Doc:apply_edits` internally. This preserves plugin-facing behavior while removing the slow per-caret mutation pattern.

## Testing Strategy

Add regression tests for:

- typing at many collapsed carets
- typing over many selected ranges
- backspace/delete at many carets
- paste with one clipboard payload and per-caret payloads
- undo/redo of large multi-caret batches
- overlapping edit rejection or merge semantics
- line-ending and multiline replacements
- mirrored/registered DocView selection state behavior

Prefer behavior tests over exact shortcut tests.
