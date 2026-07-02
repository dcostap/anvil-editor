# Diff View Core Integration Plan

## Current status

Diff View has been moved from a monkey-patched two-`DocView` plugin toward a first-class diff viewer built on core extension points. The main core-integration work is now implemented in the working tree. The remaining work is hardening, edge-case tests, and deciding exactly when request-scoped state should survive mutable request replacement.

No commits have been made for this implementation pass.

## Reference stance

Use the local IntelliJ source as a golden reference for architectural pressure points, lifecycles, and edge cases, not as a 1:1 API or complexity target. Prefer the smallest Anvil-native design that preserves the useful lessons:

- request/content records own diff intent and request-scoped state.
- viewer/controller code owns active UI lifecycle and reload/disposal ordering.
- editor extension points should be view-scoped when global document mutation would leak outside the diff view.
- fold, scroll, row-composition, and editability features should handle the bugs Anvil can realistically hit, without importing IntelliJ-only abstraction layers until they are useful here.

Intentional divergences from IntelliJ should be called out in the relevant section so future work does not accidentally “fix” them back into IntelliJ parity.

## Completed in the current working tree

### Core listener/provider groundwork

Completed:

- `Doc` has per-document text change listeners:
  - `add_text_change_listener(id, listener)`
  - `remove_text_change_listener(id)`
  - covers `apply_edits`, undo/redo transaction paths, and direct `raw_insert` / `raw_remove` mutations.
- `DocView` has extension/listener APIs:
  - decoration providers for line backgrounds, inline ranges, and provider text color.
  - POI providers.
  - selection listeners.
  - scroll listeners.
  - fold listeners.
  - visual-row providers.
  - view-scoped edit guards.
- Provider/listener registration is keyed by stable ids and supports deterministic priority ordering where ordering matters.

### Structural diff model

Completed:

- `data/plugins/diff/model.lua` contains reusable structural diff state:
  - per-side changes.
  - inline changed ranges.
  - equal blocks for fold candidates.
  - side-to-side line mapping.
  - hunk lookup/navigation helpers.
- Diff computation is no longer embedded directly in `DiffView:update_diff()`.
- `DiffView` still owns scheduling, generation IDs, stale-result rejection, listener/provider installation, layout, and disposal.

Design decision:

- `DiffModel` stays under `data/plugins/diff` for now. It can move to `data/core` later if another first-party feature needs it outside the diff plugin.

### DiffView no longer monkey-patches child instances

Completed:

- Removed `DiffView:patch_views()` method replacement behavior.
- Diff View no longer replaces child `DocView` or `Doc` methods for:
  - drawing.
  - scroll synchronization.
  - selection/caret synchronization.
  - text-change detection.
  - POI generation.
  - previous/next change navigation.
- Diff rendering uses `DocView` decoration providers.
- Diff POIs use `DocView` POI providers.
- Diff rediff uses document text-change listeners.
- Caret sync uses selection listeners.
- Scroll sync uses scroll listeners.
- Divider connectors and sync arrows remain owned by `DiffView`, because they are divider UI, not child gutter UI.

### Rich visual-row provider objects

Completed:

- `DocView:add_visual_row_provider(id, provider, opts)` and `remove_visual_row_provider(id)` support both legacy count providers and provider-owned row objects.
- `DocView:invalidate_visual_rows(provider_id?)` provides explicit invalidation.
- Providers may expose `generation(view)` for passive cache invalidation.
- Object rows support:
  - stable row ids scoped by provider/line/placement.
  - deterministic ordering by priority/provider id/row order.
  - `draw`, `hit_test`, and `on_click` callbacks isolated with `pcall`.
  - duplicate-id diagnostics and internal disambiguation.
- A composed visual-row cache is now the source of truth while composed rows are active:
  - visual row count.
  - line-to-row and row-to-line mapping.
  - drawing order.
  - mouse hit-testing.
  - diff scroll/line-transfer calculations.
- Count-style diff gap providers remain compatible.
- Wrapped document lines compose with provider rows.

Caveat:

- The composed-row cache is currently materialized for the full document when active. This is correctness-first and may need profiling/virtualization later for very large files with row providers.

### Stable diff fold identity

Completed:

- Diff fold state is request-scoped under `request.user_data.diff_fold_state`.
- Fold state is saved before compatible rebuilds and reapplied when new fold candidates match safely.
- Identity matching is content/neighbor based instead of equal-block-index based.
- Current identity model uses:
  - hidden-line count bucket.
  - normalized tail samples from both sides.
  - prefix-window validation to avoid tail-only state transfer.
  - previous/next change flags.
- Ambiguous repeated folds:
  - can be expanded locally in the current view.
  - are not persisted by identity.
  - reset on rediff instead of applying state to the wrong block.
- Controller reloads preserve compatible fold state.
- Incompatible default fold mode clears cached fold state.

Intentional Anvil divergence from IntelliJ:

- IntelliJ restores fold state mostly by request-scoped ranges and accepts imperfect restoration after edits.
- Anvil uses request-scoped lifecycle but prefers content/neighbor identity so insertion before a fold does not commonly lose or misapply expansion state.
- This is not intended to perfectly preserve fold state across arbitrary rewrites.

### Public DiffRequest / DiffContent API hardening

Completed:

- Existing helper inputs are internally normalized into `DiffRequest` / `DiffContent` records.
- Added public-ish construction helpers:
  - `diffview.open(request, noshow)`
  - `diffview.content.text(text, opts)`
  - `diffview.content.file(path, opts)`
  - `diffview.content.document(doc, opts)`
  - `diffview.content.blank(opts)`
  - `diffview.content.empty(opts)` as a compatibility alias for mutable blank content.
- Legacy helpers still route through the new request path:
  - `string_to_string`
  - `file_to_file`
  - `file_to_string`
  - `string_to_file`
- `{ left = ..., right = ... }` request/content-title sugar normalizes immediately into list-based `contents` / `content_titles`.
- `metadata` is normalized into `user_data`.
- Invalid requests fail deterministically instead of later nil-field crashes.
- Same-`Doc`, same-file, and mixed document/file aliases are rejected.
- Three-content requests are recognized but return an explicit "three-way diff viewer is not implemented" error.
- Assignment lifecycle hooks are balanced:
  - `request:on_assigned(is_assigned, context)`
  - `content:on_assigned(is_assigned, request, side)`
  - `content:dispose()` for resolver-owned resources.

Design decisions:

- `blank` is the canonical public name for Anvil-owned mutable blank documents.
- `empty` remains only a compatibility alias for current Anvil behavior.
- If add/delete placeholder semantics are needed later, add a separate `placeholder`/`missing` content kind instead of overloading mutable blank documents.
- Caller-provided document contents are caller-owned unless explicitly marked owned.
- File contents create file-backed documents and are not owned by the Diff View.

### Editable policy and file-backed diff sides

Completed:

- Added view-scoped edit guards:
  - `DocView:add_edit_guard(id, guard)`
  - `DocView:remove_edit_guard(id)`
  - `DocView:can_edit(reason, opts)`
- Diff View installs side-aware edit guards on child `DocView`s instead of globally locking caller-owned documents.
- Core and first-party command paths that mutate through the active `DocView` now consult edit guards.
- Read-only diff sides block:
  - typing.
  - paste.
  - delete/backspace/newline command paths.
  - undo/redo when invoked from the guarded side.
  - DiffView sync/apply actions targeting the read-only side.
- Caller-owned documents remain editable in normal editor views even when shown read-only inside a Diff View.
- Direct external document mutation remains the caller's responsibility; Diff View observes it through text-change listeners and rediffs.
- Git historical/commit contents are read-only and carry useful read-only reasons.
- File-backed editable diff sides use normal dirty/save behavior.

### Mutable blank diff workflow

Completed:

- Added `MutableDiffRequestChain`:
  - owns mutable request state.
  - supports `set_content`, `build_request`, `put_user_data`, and `get_user_data`.
  - copies chain-persistent user data into rebuilt requests.
- Added `DiffRequestController`:
  - owns active `DiffView` lifecycle.
  - reloads/replaces the current view.
  - preserves surrounding tab/node placement on reload.
  - handles close/dispose ordering.
- Added phase-1 commands:
  - `diff-view:open-blank-diff`
  - `diff-view:replace-left-with-file`
  - `diff-view:replace-right-with-file`
- Dirty owned/file-backed sides are protected on replacement and close.
- Cancelled dirty prompts leave the existing view functional.

### Git View polish after request migration

Completed:

- Git View creates commit diff panes through `diffview.open(request, true)`.
- Git requests include request `user_data` for:
  - selected changed file.
  - selected file path/index.
  - left/right revision endpoints.
  - read-only policy/reason.
- Git diff contents are read-only by default.
- Tests cover Git request user data and read-only behavior.

## Remaining work before calling this phase finished

### 1. Tighten request-scoped state compatibility on mutable side replacement

Current concern:

- `DiffRequestController:reload()` preserves fold state across plain reloads.
- Side replacement currently needs a stricter compatibility rule so state like `diff_fold_state` is not blindly carried from unrelated side content into the replacement request.

Finish by deciding and implementing one of these policies:

- clear viewer state such as `diff_fold_state` whenever either side content changes semantically; or
- attach a lightweight semantic content identity to each side and preserve fold/scroll/focus state only when both relevant sides are compatible.

Tests to add:

- replacing one side with an unrelated file clears old fold state.
- plain controller reload with unchanged side content preserves fold state.
- replacing a side while the other side is adopted does not leak stale fold state into unrelated content.

### 2. Add remaining edge regression tests

Most core behavior now has targeted coverage. Add the last high-value edge tests:

- changing default fold mode ignores incompatible cached fold state and uses the new default.
- deleting/touching the folded unchanged block safely resets fold state.
- identical repeated equal blocks reset instead of preserving incorrectly after edits.
- manually collapsed and manually expanded fold exceptions both survive a compatible rediff, if both interactions are supported by the current UI/API.
- closing a clean blank diff disposes owned untitled docs.
- direct external `Doc:apply_edits` on caller-owned content is observed and rediffs, not blocked globally.

### 3. Final edit-guard/read-only audit

Audit remaining first-party direct document mutators and overlapping read-only systems before treating edit guards as complete:

- older command/plugin paths that still mutate `core.active_view.doc` directly.
- Git historical document read-only behavior.
- Command Output View command guards.
- any unusual first-party plugin mutators that should call `DocView:can_edit(...)` when acting on the active editor view.

Do not add a global per-`Doc` mutation gate for caller-owned documents as part of this audit.

### 4. Refresh plan/tests after the final hardening pass

After the remaining hardening is done:

- update this plan again to move completed hardening items into the completed section.
- run the targeted validation checklist below.
- run the broader Anvil suite if targeted tests are clean and no unrelated known failures block it.

## Deferred / future work

### Unified and three-way modes

Current state:

- Structural pieces should support future viewers, but only side-by-side two-way diff is implemented.
- Three-content requests currently return a deterministic "three-way diff viewer is not implemented" error.

Design decisions:

- Do not build unified or three-way UI until the two-way request/content/model contracts are stable.
- Unified and three-way should be separate viewer implementations selected from request shape/kind.
- `DiffModel.compute(...)` remains a pure worker body. Viewer/controller code owns async lifecycle.

Future tests:

- viewer selection chooses side-by-side for two contents.
- future unified viewer can consume the same `DiffModel` without depending on `DocView` side-by-side geometry.

### Optional mutable blank diff features

Deferred optional features inspired by IntelliJ:

- switch side back to a blank editable document.
- replace side from recent blank content.
- remember recent non-empty blank diff text.
- drag/drop file replacement.
- swap sides.
- optional three-side blank diff toggle.

### Optional visual-row extensions

Deferred until needed:

- arbitrary pixel-height provider rows.
- provider-owned visible action rows for apply/revert controls.
- cache virtualization for very large documents.

Diff sync/apply arrows remain owned by the Diff View divider/gutter path for now.

### Optional Git editing work

Working-tree Git editing remains disabled until explicitly implemented and tested. If added later, it should be opt-in and only for the working-tree side.

## Validation checklist

Run targeted tests while developing:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/diff_model.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/doc_text_change_listener.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/docview_decorations.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/diffview_batch.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/git_view.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/linewrap.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/doc_save_as.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/intellij_actions.lua --print-errorlogs
```

Use the full Anvil suite when unrelated known failures are cleared:

```sh
meson test -C build-windows-x86_64 --suite anvil --print-errorlogs
```
