# Document Split View Selection Middle-Ground Plan

## Goal

Support practical independent cursor/selection state for multiple `DocView`s showing the same `Doc`, without a broad rewrite of editor commands and plugins.

The intended compromise is:

> `DocView.selection_state` becomes the real per-view selection/caret state.  
> `doc.selections` and `doc.last_selection` remain as temporary compatibility mirrors for existing code.

This should satisfy the main split-view requirements:

1. Each split/view of the same document remembers its own caret and selections.
2. When a split is focused, normal editor operations act on that split.
3. Other visible splits of the same document keep and render their own selections/carets.

## Non-Goal

Do not immediately refactor all commands/plugins to stop using `doc:get_selection()`, `doc:set_selection()`, `doc.selections`, etc.

Existing APIs should continue to work during a scoped compatibility binding.

## Current Problem

`Doc` currently owns both text and selection state:

- `doc.selections`
- `doc.last_selection`
- `Doc:get_selection()` / `Doc:set_selection()`
- `Doc:get_selections()` / `Doc:set_selections()`
- cursor movement and text editing methods such as `text_input`, `move_to`, `select_to`, `delete_to`

`DocView` owns scroll/layout/rendering state, but not cursor/selection state. Therefore two `DocView`s over the same `Doc` share one caret/selection.

## Proposed Model

### Shared `Doc`

`Doc` remains the shared document model:

- lines/text
- filename/path
- dirty state
- undo/redo text history
- syntax/highlighter
- save/load/reload/autoreload behavior

### Per-view `DocView`

Each `DocView` owns:

```lua
self.selection_state = {
  selections = { 1, 1, 1, 1 },
  last_selection = 1,
}
```

`doc.selections` and `doc.last_selection` are not the source of truth for split views. They are a compatibility mirror for code currently running in a specific `DocView` context.

## Core Invariants

- `DocView.selection_state.selections` is owned by exactly one `DocView`.
- Selection-state helper APIs copy tables when getting/setting state.
- The only intentional aliasing is during scoped compatibility binding, where `doc.selections` temporarily points at the bound view's owned table.
- Binding must track the current owner/view, preferably with a small stack, so edit adjustment can identify the active bound state and avoid adjusting it twice.
- Track a default compatibility mirror owner, normally the focused/current editor view for that doc, without retaining closed views. Use a weak owner table rather than a strong `doc.selection_mirror_view` reference:

  ```lua
  DocView.mirror_owner = setmetatable({}, { __mode = "k" }) -- doc -> session_id
  DocView.session_views = setmetatable({}, { __mode = "v" }) -- session_id -> view
  ```

  A weak `doc -> view` table is also acceptable if simpler, but the `Doc` must not strongly retain a closed view.
- Outside a scoped binding, `doc.selections`/`doc.last_selection` should be a copied compatibility mirror of the mirror owner's state, not a long-lived alias to `DocView.selection_state.selections`.
- Rebinding the same view while it is already the bound view should be a no-op wrapper: just call the function and let the outer binding capture/restore state.
- Nested binding to a different view must use a real stack and restore the previous mirror exactly.
- At the outermost binding exit, if the bound view is also the current mirror owner, refresh `doc.selections`/`doc.last_selection` as a copy from the updated view state so unbound compatibility reads do not see stale pre-operation selection.
- Binding scopes should be short and should not yield. Do not allow coroutines to suspend while `doc.selections` is temporarily aliased to a view.
- Any `DocView` registry used for inactive selection adjustment should be weak, so closed views are not retained.
- Suggested registry shape:

  ```lua
  DocView.registry = setmetatable({}, { __mode = "k" }) -- doc -> weak view set
  DocView.registry[doc] = setmetatable({}, { __mode = "k" }) -- view -> true
  ```

- New split/side views created from a source view should copy the source view's selection positions explicitly, not rely on whatever `doc.selections` happens to mirror. Copy `selections` and `last_selection`, but do not copy a stable selection-session/view id used for undo ownership; the new view needs its own id.

## Compatibility Binding

Add a scoped helper similar to:

```lua
function DocView:with_selection_state(fn, ...)
  local doc = self.doc

  if doc.bound_selection_view == self then
    return fn(...)
  end

  local old_selections = doc.selections
  local old_last_selection = doc.last_selection
  local old_bound_view = doc.bound_selection_view

  doc.bound_selection_view = self
  doc.selections = self.selection_state.selections
  doc.last_selection = self.selection_state.last_selection

  local ok, a, b, c, d, e, f = xpcall(function(...)
    return fn(...)
  end, debug.traceback, ...)

  self.selection_state.selections = doc.selections
  self.selection_state.last_selection = doc.last_selection

  doc.selections = old_selections
  doc.last_selection = old_last_selection
  doc.bound_selection_view = old_bound_view

  if not ok then error(a, 0) end
  return a, b, c, d, e, f
end
```

The real implementation can support more return values if needed. It must restore state on error and should preserve traceback, e.g. via `xpcall(..., debug.traceback)` and `error(traceback, 0)`. It should not depend on table aliasing outside the binding scope.

The sample omits the outermost-binding mirror refresh for brevity. The implementation must refresh the default compatibility mirror after bound mutations when the bound view is the current weak mirror owner.

## Binding Rule

When code is logically operating on a `DocView`, run it with that `DocView`'s selection state bound.

All selection mutations should be bound or explicitly captured into a target `DocView.selection_state`. Legacy unbound mutations such as `doc:set_selection(...)` or direct `doc.selections = ...` are compatibility hazards because the next bound view operation may overwrite them from view-local state.

MVP unbound-mutation policy:

- `Doc:set_selection`, `Doc:set_selections`, `Doc:add_selection`, `Doc:remove_selection`, and `Doc:merge_cursors` should, when called unbound, update the default mirror view's `selection_state` if a live mirror owner exists
- direct assignment to `doc.selections` or `doc.last_selection` cannot be reliably intercepted in Lua; code paths doing this should be patched when found, or followed by an explicit capture into the intended view
- document edits that happen unbound should position-adjust all registered views for that doc, because there is no active bound selection state to skip

This is broader than focus syncing. Focus syncing alone is not enough.

Binding is needed around:

- `DocView` text input
- IME editing
- mouse selection handling
- command predicates/handlers operating on a `DocView`
- `DocView:update()` paths that inspect caret/selection
- `DocView:draw()` and selection/caret rendering
- explicit non-focused view operations such as find/replace callbacks or side-panel open helpers when needed

## Minimal Implementation Phases

### Phase 1: Selection state infrastructure

- Add `DocView.selection_state` in `DocView:new(doc)`.
- Initialize from the current `doc.selections`/`doc.last_selection` as a copied fallback.
- When splitting or opening a side view from a source `DocView`, explicitly copy the source view's selection positions before any initial scroll/caret positioning. Create a fresh selection-session id for the new view.
  - Patch the root split path in `data/core/commands/root.lua`, where `root:split-*` currently splits then calls `core.root_view:open_doc(av.doc)`.
  - Consider extending `RootView:open_doc(doc, opts)` with `opts.source_view`, because it currently creates the view, adds it, then scrolls using `view.doc:get_selection()`.
  - Patch side-panel source-copy paths in `data/core/sidepanel.lua`.
- Add copy helpers:
  - `DocView:get_selection_state()`
  - `DocView:set_selection_state(state)`
  - `DocView:capture_selection_state()`
  - `DocView:apply_selection_state()`
- Ensure all get/set helpers copy the `selections` table instead of sharing it between views.
- Add `DocView:with_selection_state(fn, ...)`.
- Make `DocView:get_state()` / `DocView.from_state()` persist and restore `selection_state` per view.

### Phase 2: Focus synchronization as compatibility fallback

Hook active-view changes so normal old code still sees the focused view selection by default:

- before leaving an active `DocView`, capture `doc.selections` into that view only if that view is the current mirror owner for the doc
- do not capture if `doc.selections` is currently bound/mirrored for another view due to side-panel/find/explicit callback work
- before entering a `DocView`, set that view as the weak mirror owner and apply a copied mirror of that view's `selection_state` into `doc.selections`

This is a fallback/default mirror, not the whole mechanism.

### Phase 3: Scoped view operation binding

Bind selection state around view operations.

Preferred low-invasive places:

- self-binding public `DocView` entrypoints such as `DocView:update()`, `DocView:draw()`, mouse handlers, text input, and IME handlers
- `Node:update()` / `Node:draw()` can still help normal root-tree views, but should not be the only mechanism
- `RootView:on_text_input()` / `on_ime_text_editing()` around active `DocView`
- mouse press/move/release routing around the target `DocView`
- command predicate evaluation and command execution

Prefer self-binding public `DocView` entrypoints where practical because node/root wrappers can miss embedded `DocView`s where a parent view calls child docviews directly, such as `data/plugins/diffview.lua` and preview/transient views. If self-binding cannot cover a path cleanly, explicitly patch embedded callers.

For commands:

- bind active `DocView` before predicate evaluation, because predicates may call `doc:get_selection()` or `doc:has_selection()`
- cover every predicate evaluation entry point, including `command.perform()`, `command.is_valid()`, and `command.get_all_valid()`; these feed context menus, toolbars, and command palette validity
- predicates are also called directly in places such as `data/core/contextmenu.lua`, `data/core/statusview.lua`, and wrappers in `data/core/sidepanel.lua` / `data/plugins/editree`; prefer a central `command.eval_predicate()` helper or binding inside `command.generate_predicate()` so direct predicate callers are covered too
- choose handler binding from the actual handler arguments: returned predicate args if present, otherwise the original `...` passed to `command.perform()`
- if any actual handler argument is a `DocView`, bind the handler to that view
- many predicates return non-view args such as `doc, bom`, `node`, or raw values; if no handler argument is a `DocView`, keep the active-view binding while running the handler when applicable
- do not keep a binding active across prompts, scheduled threads, coroutines, or async callbacks; command handlers that install callbacks must capture the intended view/session and bind again inside the later callback

The goal is for old code such as:

```lua
local line, col = dv.doc:get_selection()
dv.doc:set_selection(line, col)
dv.doc:text_input(text)
```

...to operate on the correct view-local selection without being rewritten.

### Phase 4: Inactive split selection adjustment MVP

When one view edits the shared document, inactive views for the same `Doc` must have their independent selections adjusted.

Extract reusable selection adjustment logic from:

- `Doc:raw_insert`
- `Doc:raw_remove`

The extracted helpers should operate on an explicit selection state table:

```lua
{ selections = ..., last_selection = ... }
```

They should not implicitly read or write `doc.selections` except through the active bound compatibility path.

Define cursor merge semantics for inactive states:

- inactive adjustment may merge cursors if deletion collapses multiple carets to the same position
- `last_selection` must remain valid after shifting/merging
- if the active selection merge logic changes, inactive adjustment should use the same semantics

Apply it to:

- the active/bound view state through the existing `Doc` operation
- every other `DocView.selection_state` for the same `Doc`
- all registered `DocView.selection_state`s for the same `Doc` when the edit is unbound, because there is no active bound state to skip

Important: inactive views should be shifted/sanitized by text changes, but must not receive the active view's selection snapshot.

The adjustment pass must be owner-aware:

- use the current binding owner/stack, or table identity, to skip the active bound selection state
- do not adjust the active view twice
- sanitize inactive view selections after shifting

A small weak `DocView` registry keyed by `doc` may be safer than relying only on `core.get_views_referencing_doc(doc)`, because some `DocView`s can be embedded in non-root views or temporary previews.

### Phase 5: Rendering support for inactive selections/carets

Selections should render per view because draw is bound per `DocView`.

Caret rendering currently largely depends on:

```lua
core.active_view == self
```

Decide and implement desired behavior:

- active view: normal caret
- inactive visible split: either dim caret or no caret but keep selection visible

For the stated goal, inactive visible splits should show at least their selection and probably a dim caret.

### Phase 6: Undo/redo ownership gate

Undo/redo must be resolved before declaring the split-selection MVP complete.

- Tag selection undo records with a stable per-view selection-session id, not a strong `DocView` reference.
- Selection records created before a split should not later restore into the wrong split.
- New split/side views copy selection positions from the source view but receive a new selection-session id.
- When undo/redo replays text operations, inactive views are position-adjusted only.
- When undo/redo applies inverse operations and pushes redo/undo records, preserve or re-tag selection record ownership consistently for the bound session.
- Legacy/no-owner selection records should restore only in a conservative fallback case, such as when there is exactly one registered view for the doc or the current bound session is the document's only plausible owner; otherwise skip the selection restore.
- Unbound edits should either create no-owner selection records with conservative restore semantics or explicitly use the current mirror owner's session id if a live mirror owner exists.
- When undo/redo sees a selection snapshot, restore it only if the currently bound view/session matches the snapshot owner; otherwise skip that selection restore.

### Phase 7: Targeted edge-case patching

Do not audit/refactor all plugins up front.

After the bridge works for normal split editing, patch only visible breakages.

Likely targeted areas:

- `data/core/commands/findreplace.lua`
- `data/plugins/intellij_find.lua`
- `data/plugins/search_ui.lua`
- `data/core/sidepanel.lua`
- `data/plugins/intellij_actions.lua` selection history/origin keyed by `doc`
- preview/transient DocViews in `data/plugins/fuzzy_searcher/init.lua`

## Special Cases / Known Risk Areas

### `Doc` methods without a `DocView`

`Doc` methods remain the compatibility surface. They should continue operating on `doc.selections`, which should be the currently bound view state when called from editor/view code.

### Find/replace callbacks

Find UIs often focus `CommandView` while mutating `last_view.doc`. These paths need explicit binding to `last_view`, not `core.active_view`, because `CommandView` also extends `DocView` and has its own unrelated input selection state.

### Side panel

Side panel operations can intentionally set selection on a non-focused side view. These should bind to the target side `DocView` instead of blindly setting shared `doc.selections`.

### Search selections

`doc.search_selections` is currently document-global, while find/search plugins may also add focused matches into `doc.selections`.

MVP decision:

- Treat broad search result decorations as document-global if they are intended to mark text in all views of the document.
- Treat focused/current match selections and find-preview caret movement as view-local selection state, bound to the originating `DocView`.
- If `doc.search_selections` tuple tags conflict with view-local selections in practice, move search decoration state into `DocView.selection_state` or a separate per-view search decoration table later.

### Unbound selection mutations

Unbound selection mutations are not part of the desired model, but legacy code may still perform them.

Policy:

- bound mutations are authoritative
- unbound `Doc` selection API calls update the live default mirror view as best effort
- direct `doc.selections = ...` callers should be audited/patched case-by-case because they bypass API hooks

### Undo/redo

Undo/redo is the largest unresolved risk and a blocker for declaring the split-selection MVP complete.

Current undo records store selection snapshots in the shared document undo stack:

```lua
{ type = "selection", ... }
```

With independent split selections, selection snapshots must not blindly overwrite whichever split happens to invoke undo later.

MVP policy:

- text undo/redo remains document-global
- text changes adjust inactive views by position-shifting only
- selection snapshots should restore only for the originating/bound view
- inactive/other views must not receive another view's selection snapshot

Implementation requirements:

- prefer tagging selection undo records with a stable per-view selection-session id instead of a strong `DocView` reference, so undo stacks do not retain closed views
- new split views copy selection positions but receive a new selection-session id; do not clone the source id
- when undo/redo applies a selection record, restore it only if the current bound view/session matches
- otherwise skip the selection restore while still applying text undo/redo operations

Do not leave this as implicit "whichever view is bound" behavior unless tests prove it cannot cross-apply snapshots.

### Session serialization

`DocView:get_state()` / `DocView.from_state()` currently use `doc:get_selection()` and `doc:set_selection()`.

With per-view selections, session/workspace state should persist `DocView.selection_state` directly and restore it into the view. `DocView.from_state()` should restore into `selection_state` and should not call `doc:set_selection()` as the authoritative state because that can clobber the shared compatibility mirror.

Session restore must remain backward-compatible with old workspace data that stores `selection = {...}` instead of full `selection_state`.

### Reload/reset

`Doc:reload()` and `Doc:load()` currently snapshot/restore one doc selection, and `Doc:reset()` resets document selection state directly. Stale-backup restore and other callers that invoke `Doc:load()` or manual reset paths have the same issue. With per-view selections, all reload/load/reset paths should preserve/sanitize relevant `DocView.selection_state`s for that doc where practical. For MVP, reload/autoreload/stale-backup restore must at least sanitize all registered view selection states after the document lines are replaced.

Also note `CommandView:exit()` calls `self.doc:reset()` on its own input doc. CommandView has separate application-context behavior and should not let reset/mirror handling leak into editor split state.

This can be handled after MVP if normal split editing does not hit it immediately, but it should not be forgotten.

## Test Checklist

Minimum MVP tests:

- Open a file in main view.
- Open same file in side panel or split.
- Move cursor in main; side cursor/selection does not change.
- Move cursor in side; main cursor/selection does not change.
- Select text in main; side selection remains independent.
- Type in main before side caret; side caret shifts logically.
- Delete in side before main caret; main caret shifts logically.
- Multi-cursor operations in focused split do not overwrite the other split.
- Focus switching restores each split's own caret.
- Visible inactive split renders its own selection and desired caret state.
- After a bound type/move/select operation, unbound compatibility reads such as statusbar/context-menu predicates see the updated focused-view selection, not a stale restored mirror.
- Close one split without closing the shared doc if another view references it.

Secondary tests:

- Undo in split A after split B has a different selection restores only split A's owned selection.
- Undo record created before a split does not restore into the wrong split.
- Undo/redo in one split restores that split's selection only.
- Find/replace preview works on the originating view while CommandView is focused.
- Find/search highlights behave according to the document-global vs view-local search-selection policy.
- Side-panel open current file copies scroll/caret from source view without contaminating source selection.
- Autoreload/reload preserves or sanitizes split selections.
- Closing a view does not keep it alive through mirror ownership, undo records, or registries.

## Summary

This plan intentionally avoids a broad command/plugin rewrite.

The key compromise is:

- per-view selection state is real
- `doc.selections` remains as the old API mirror
- scoped binding makes old code operate on the correct view
- inactive view selections are adjusted on text changes
- plugin cleanup is targeted and incremental
