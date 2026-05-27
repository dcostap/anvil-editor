# Document Split View Independent Selection Plan

## Goal

Support a real, robust document split view mode where the same document can be open in multiple editor views, including the right-side side panel, while each view has its own independent cursor, selection, and scroll position.

The intended model is:

- `Doc` remains the shared text/document model.
- Each `DocView` owns its own cursor and selection state.
- Side-panel editor views behave like real editor tabs constrained to the side node.
- Existing document lifecycle behavior continues to work: autosave, autoreload, dirty state, conflict detection, save/close handling, etc.

## Current Limitation

Today cursor/selection state is stored on `Doc`:

- `data/core/doc/init.lua`
  - `self.selections`
  - `self.last_selection`
  - `Doc:get_selection()`
  - `Doc:set_selection()`
  - `Doc:get_selections()`
  - `Doc:text_input()`
  - `Doc:move_to()` / `Doc:select_to()` / `Doc:delete_to()`

`DocView` owns scroll and view geometry, but all views sharing the same `Doc` also share the same selection state.

Result: if the same document appears in main and side split, moving the cursor in one view moves it in the other.

## Desired Ownership Model

### `Doc`

Keeps shared document state:

- text lines
- dirty/clean state
- filename/path
- encoding/line endings
- syntax/highlighter state
- undo/redo text history
- save/load/reload behavior

### `DocView`

Owns view-local state:

- scroll position
- cursor/selection state
- last selection/caret tracking for redraw
- horizontal caret movement cache
- IME view location state

Proposed per-view shape:

```lua
self.selection_state = {
  selections = { 1, 1, 1, 1 },
  last_selection = 1,
}
```

## Compatibility Strategy

Avoid rewriting all editor commands immediately.

Instead, add a compatibility layer where `DocView` temporarily binds its own selection state onto the shared `Doc` while existing command code runs.

Conceptually:

```lua
function DocView:with_selection_state(fn, ...)
  local doc = self.doc
  local old_selections = doc.selections
  local old_last_selection = doc.last_selection

  doc.selections = self.selection_state.selections
  doc.last_selection = self.selection_state.last_selection

  local ok, ... = pcall(fn, ...)

  self.selection_state.selections = doc.selections
  self.selection_state.last_selection = doc.last_selection

  doc.selections = old_selections
  doc.last_selection = old_last_selection

  if not ok then error(...) end
  return ...
end
```

This lets existing code keep calling `dv.doc:set_selection(...)`, `dv.doc:text_input(...)`, etc. while operating on the active view's local selection state.

## Required Work

### 1. Add `DocView` selection state

Initialize independent selection state in `DocView:new(doc)`.

For new views over existing docs, initial selection can copy from the current doc selection or from a source view when explicitly splitting.

### 2. Add scoped selection binding

Add a `DocView:with_selection_state(...)` helper.

Use it around:

- text input
- mouse selection
- doc commands
- find/replace commands
- draw/update paths that read selections

The goal is that code executing in the context of a `DocView` sees that view's selection state through the existing `Doc` API.

### 3. Make rendering use view-local selections

`DocView:draw`, `prepare_line_body_draw_cache`, `draw_overlay`, gutter highlighting, caret drawing, current-line highlighting, and IME location should use the view-local selection state.

This can be achieved by wrapping those paths in `with_selection_state` initially.

### 4. Make input/editing use view-local selections

Wrap paths such as:

- `DocView:on_text_input`
- `DocView:on_ime_text_editing`
- mouse selection handling
- command predicates/handlers operating on `DocView`

### 5. Adjust inactive view selections when text changes

This is the main robustness requirement.

When one view edits the shared `Doc`, inactive views for the same doc must have their independent selections adjusted so they still point to the intended logical locations.

Existing adjustment logic lives in:

- `Doc:raw_insert`
- `Doc:raw_remove`

That logic currently updates only `doc.selections`. We should extract reusable position-adjustment helpers and apply them to:

- the active view's bound selection state
- all inactive `DocView.selection_state`s referencing the same doc

Important: inactive views should be position-adjusted by text changes, but should not receive the active view's selection snapshot.

### 6. Undo/redo behavior

Current undo stores selection snapshots in the doc undo stack:

```lua
{ type = "selection", ... }
```

With independent view selections:

- text undo/redo remains doc-global
- selection restoration should apply to the view that invoked undo/redo
- inactive views should only be shifted by the text edit/remove operations

This may require tagging selection undo records with the originating view/session or applying them only through the active view's scoped selection binding.

### 7. View registration / discovery

We need a reliable way to find all `DocView`s for a `Doc` so inactive selection states can be adjusted.

Options:

- use `core.get_views_referencing_doc(doc)` where possible
- add a core helper that returns only `DocView` instances
- ensure side-panel hidden-tab views are included, which they now are because side views live in the root node tree

### 8. Plugin audit

Many plugins access `doc.selections` or `doc:get_selection()` directly. Most should continue working if they run with the active view's selection state bound, but some plugin state may need to move from doc-keyed to view-keyed.

Known areas to audit:

- `data/plugins/intellij_actions.lua`
  - selection history/origin currently keyed by `doc`
  - direct `doc.selections` access
- `data/plugins/autocomplete.lua`
- `data/plugins/bracketmatch.lua`
- `data/core/commands/findreplace.lua`
- `data/plugins/intellij_find.lua`
- `data/plugins/diffview.lua`
- `data/plugins/drawwhitespace.lua`
- `data/plugins/indent_guides.lua`

## Suggested Implementation Phases

### Phase 1: Infrastructure

- Add `DocView.selection_state`.
- Add `DocView:with_selection_state`.
- Add helpers to copy/get/set selection state.
- Make `DocView:get_state` / `DocView.from_state` persist view-local selection.

### Phase 2: Rendering and input

- Wrap `DocView:update`, draw cache generation, overlay/caret drawing, mouse handling, and text input with the view selection binding.
- Verify two views of the same doc can display different carets/selections.

### Phase 3: Command routing

- Wrap core doc command execution for `DocView` predicates so commands operate against the active view's selection state.
- Verify movement, selection, typing, delete, paste, multi-cursor operations.

### Phase 4: Inactive selection adjustment

- Extract selection adjustment logic from `Doc:raw_insert` / `Doc:raw_remove`.
- Apply text-change adjustments to every other `DocView.selection_state` referencing the edited doc.
- Verify edits in one split keep the other split's caret logically positioned.

### Phase 5: Undo/redo

- Ensure undo/redo text changes are doc-global.
- Ensure selection restore applies only to the invoking view.
- Verify inactive split selections are adjusted, not overwritten.

### Phase 6: Plugin cleanup

- Audit direct `doc.selections` access.
- Convert plugin-private cursor/selection state from doc-keyed to view-keyed where needed.
- Keep compatibility wrappers where practical.

## Test Checklist

- Open the same file in main and side editor.
- Move cursor in main; side cursor does not move.
- Move cursor in side; main cursor does not move.
- Select text in main; side selection is unchanged.
- Type in main before side cursor; side cursor shifts correctly.
- Delete in side before main cursor; main cursor shifts correctly.
- Multi-cursor edits work independently per view.
- Undo in one view restores that view's selection only.
- Find/replace previews and selections behave per active view.
- Autosave/autoreload/conflict detection still work because the `Doc` is shared.
- Closing one split does not close the doc if another view references it.

## Open Questions

- Should inactive split views show their caret, or only selections? Current behavior draws carets only for active view.
- Should search selections remain doc-global or view-local? Existing search highlighting is doc-owned and may be acceptable, but split-specific search preview may need view-local state later.
- Should undo selection snapshots be attached to views directly, or should they remain doc undo records interpreted through the active view binding?
