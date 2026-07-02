# Diff View Core Integration Plan

## Problem statement

The current Diff View mostly behaves like two `DocView`s with diff behavior bolted on. It now uses some core `DocView` facilities, such as Fold Regions and virtual visual rows, but it still monkey-patches child `DocView` and `Doc` methods for drawing, scroll synchronization, selection synchronization, Point of Interest generation, and document change tracking.

The target is a first-class, reusable Diff View architecture that feels like core Anvil functionality and can support:

- Git-backed Commit Diff View content.
- Text Diff View comparisons of arbitrary text.
- future arbitrary Document-to-Document comparisons.
- editable standalone diff views where either side can be edited freely.
- side-by-side, and eventually unified or three-way diff modes.

IntelliJ's architecture is the reference model: callers create diff requests from diffable contents; the diff framework chooses a viewer; viewers use normal editor instances plus clean editor decorations, listeners, folds, inlays/virtual rows, gutter actions, and explicit sync mappings.

## Goals

1. Remove `DiffView:patch_views()` style monkey-patching.
2. Make Diff View a reusable request/content/viewer system instead of a string/file helper only.
3. Move diff computation and line mapping into a reusable model.
4. Add clean `DocView` extension hooks for diff decorations.
5. Make paired scroll, paired Fold Regions, virtual rows, gutter actions, and POIs explicit core concepts or clean extension-provider concepts.
6. Preserve existing Git View and Text Diff View user workflows while migrating internals.

## Non-goals for the first pass

- Reimplementing IntelliJ's whole diff feature set.
- Three-way merge conflict resolution.
- Pixel-perfect IntelliJ UI matching.
- External diff tool integration.
- Long-term compatibility shims for old internal `diffview` fields unless needed for in-repo migration.
- Variable-height virtual rows in the first provider pass. Initial virtual rows should be one `DocView:get_line_height()` tall unless/until `DocView` scroll geometry is generalized.

## Current code hotspots

- `data/plugins/diffview.lua`
  - owns the current `DiffView` implementation.
  - computes diff changes directly in the view.
  - patches child `DocView` and `Doc` methods.
  - draws diff line backgrounds by overriding `draw_line_text`.
  - does paired scroll/caret sync manually.
- `data/core/docview.lua`
  - already has useful primitives:
    - `set_visual_row_extension`
    - Fold Regions
    - composed visual row APIs
    - Selection State support
    - POI-compatible navigation surfaces
- `data/core/doc/init.lua`
  - has `Doc.register_text_transaction_handler`, but current raw undo/redo paths call `raw_insert` / `raw_remove` directly and are not fully covered by `on_text_transaction`.
- `data/plugins/git/view.lua`
  - currently creates Git diff panes via `diffview.string_to_string(...)`.

## Architectural decisions from plan review

### DiffView owns rediff initially

Do **not** introduce a vague separate `DiffSession` in the first implementation pass.

Initial ownership should be:

- `DiffRequest`: immutable-ish description of what to compare.
- `DiffContent`: source/resolution of side Documents.
- `DiffView`: owns child `DocView`s, current `DiffModel`, rediff scheduling/cancellation, installed listeners/providers, focus, layout, divider drawing, and disposal.
- `MutableDiffRequestHost` or `MutableDiffRequestChain`: later wrapper for blank diff/source-swapping workflows. It owns changing the active request and asks the active view to reload/recreate as needed.

This mirrors IntelliJ more closely: the viewer owns model/editors/rediff; mutable request chains are a higher-level feature for swapping content sources.

### Structural model vs visual helpers

`DiffModel` should own structural diff state only:

- hunks.
- line states.
- inline ranges in document coordinates.
- side-to-side line mapping.
- fold candidates.
- POIs expressed in document coordinates.

Visual geometry, such as screen ranges and row heights, belongs in `DiffView` or dedicated viewer helpers that can query the current `DocView`s, wrapping, folds, and virtual rows.

### Provider APIs must support multiple consumers

All new `DocView` provider APIs need ordering/layering semantics. Diff will not be the only consumer forever. Providers should include a stable `id` plus a priority/layer where relevant.

### Core listener APIs are prerequisites, not cleanup details

Before removing monkey patches, core must expose clean listeners for:

- document text changes, including raw insert/remove and undo/redo paths.
- Selection State changes for a specific `DocView`.
- Fold Region expand/collapse/removal changes, if paired folds are implemented through callbacks.

## Target architecture

```text
DiffContent
  - Document content
  - file content
  - text content
  - empty content

DiffRequest
  - title
  - left/right/base contents
  - content titles
  - editable/read-only policy
  - initial focus/scroll hints
  - extension/user data

DiffView
  - owns layout and child DocViews
  - owns current DiffModel
  - owns rediff lifecycle and cancellation
  - owns installed Doc/DocView listeners and providers
  - owns divider drawing and focus routing

MutableDiffRequestHost / MutableDiffRequestChain
  - optional later wrapper for blank/source-swapping workflows
  - owns replacing request contents and reloading the DiffView

DiffModel
  - computes hunks
  - owns side line mappings
  - owns inline ranges
  - owns fold candidates
  - owns POIs and overview markers in document coordinates

DocView extension providers
  - line backgrounds
  - inline highlights
  - gutter actions
  - overview markers
  - visual row providers
  - Fold Region groups/callbacks
  - POIs
```

## Proposed new concepts

### DiffContent

A diffable input. Initial variants:

- `document`: wraps an existing `Doc`.
- `text`: creates an untitled `Doc` from text.
- `file`: opens a file-backed `Doc`.
- `empty`: represents a missing side for additions/deletions.

Fields to support early:

- `doc`
- `text`
- `filename`
- `name`
- `syntax_hint`
- `editable`
- `read_only_reason`
- `line_number_base` or line number converter later

### DiffRequest

A display request independent of UI placement.

Fields to support early:

- `title`
- `contents = { left, right }`
- `content_titles = { left, right }`
- `kind = "text" | "git" | "blank" | ...`
- `preferred_focus_side`
- `editable_policy`
- `metadata`

### MutableDiffRequestHost / MutableDiffRequestChain

Needed for standalone blank diff behavior, but not part of the first extraction.

Responsibilities:

- replace left/right content from file, recent text, or empty editable Document.
- reload/recreate the active DiffView without losing the surrounding tab/window/tool placement.
- persist source-selection state for blank diff if desired.

### DiffModel

Owns computed diff state:

- `hunks`
- per-side line states: equal/insert/delete/modify
- inline changed ranges
- side-to-side line mapping
- fold candidates for unchanged regions
- POIs

The model should answer structural questions like:

- `line_state(side, line)`
- `inline_ranges(side, line)`
- `hunk_at(side, line)`
- `next_hunk(side, line, direction)`
- `map_line(source_side, line)`
- `map_range(source_side, line)`

The model should **not** answer screen geometry questions like `visual_range_for_hunk`; those belong to `DiffView`/`DocView` helpers.

## DocView and Doc APIs to add or harden

### Decoration providers

Add a provider API instead of overriding draw methods.

Candidate API shape:

```lua
doc_view:add_decoration_provider(id, provider, opts)
doc_view:remove_decoration_provider(id)
```

Provider capabilities:

- `line_background(line, row)`
- `inline_ranges(line)`
- `gutter_markers(line)`
- `overview_markers()`
- `points_of_interest(opts)`
- `line_hint(line)` if useful later

Provider options should include at least:

- `priority` or `layer` for deterministic ordering.
- `owner` / `disposable` if a disposal convention is introduced.

Diff View should provide diff decorations through this API.

### Gutter/action providers

Diff sync/apply arrows currently live inside the `draw_line_text` monkey patch. They need their own clean route.

Candidate approaches:

- include `gutter_markers(line)` in decoration providers; or
- add a separate `add_gutter_action_provider(id, provider, opts)`.

The provider must support:

- icon/text drawing near a line or hunk.
- hover state.
- click hit-testing.
- tooltip/action text later.
- deterministic ordering with other gutter consumers.

### Virtual visual row providers

Current `set_visual_row_extension` supports counts and is already used for diff gap rows. The missing pieces are identity, draw callbacks, and hit-testing. Do not generalize to arbitrary pixel heights in the first pass.

Candidate API shape:

```lua
doc_view:add_visual_row_provider(id, provider, opts)
doc_view:remove_visual_row_provider(id)
```

Initial provider capabilities:

- line-height rows before/after a Document line.
- row kind/id.
- optional draw callback.
- optional hit-test/click callback.

Use this for empty-side alignment rows and, later, richer action rows.

Variable-height rows require a separate `DocView` scroll geometry project because current composed rows assume every row is one line height.

### Fold Region groups and callbacks

Diff folds must be paired. Expanding the left Fold Region should expand the matching right Fold Region.

Possible API:

```lua
doc_view:add_fold_region({ group = group_id, ... })
doc_view:add_fold_listener(id, fn)
doc_view:remove_fold_listener(id)
```

or keep group ownership in `DiffView`, but subscribe through a clean fold callback.

Avoid intercepting mouse clicks before `DocView` has a chance to handle its own Fold Widget Row.

### Document text change listeners

Use core listeners instead of replacing `raw_insert`, `raw_remove`, or `on_text_transaction`.

The listener must cover:

- `Doc:apply_edits` transactions.
- undo/redo paths that currently call `raw_insert` / `raw_remove`.
- direct raw mutations used by existing code.

Candidate API:

```lua
doc:add_text_change_listener(id, listener)
doc:remove_text_change_listener(id)
```

Listener callbacks:

- `before_change(doc, change)`
- `after_change(doc, change)`
- batch/transaction metadata when available.

Do not remove Diff View's raw method wrappers until this core API covers all current mutation paths.

### Selection State listeners

Stop overriding `doc.set_selection`, `doc.set_selections`, and `doc.set_selection_list` by exposing a per-`DocView` Selection State observer.

Candidate API:

```lua
doc_view:add_selection_listener(id, fn)
doc_view:remove_selection_listener(id)
```

This should fire when the view's own Selection State changes, not merely when the compatibility Selection Mirror changes.

### Paired scroll mapping

Introduce explicit line mapping similar to IntelliJ's `SyncScrollable`:

```lua
mapping:transfer(source_side, line) -> target_line
mapping:get_range(source_side, line) -> source_start, source_end, target_start, target_end
```

Then `DiffView` scroll sync can use mapping boundaries rather than raw identical scroll offsets.

## Migration phases

### Phase 0: Core listener prerequisites

Before replacing any monkey patches, add or harden core listener APIs:

- Document text change listener covering raw insert/remove, undo/redo, and apply-edits transactions.
- DocView Selection State listener.
- optional Fold Region listener if paired folds need callback-based synchronization.

Tests:

- `Doc:apply_edits` fires listener once with transaction metadata.
- undo/redo fires listener.
- direct `raw_insert` / `raw_remove` fires listener or is migrated behind a transaction path.
- Selection State listener fires for view-local selection changes.

### Phase 1: Extract a structural DiffModel without changing UI behavior

- Move diff computation from `DiffView:update_diff()` into a new module.
- Keep existing `DiffView` fields temporarily populated from the model.
- Keep visual geometry out of the model.
- Decide model location together with diff engine ownership:
  - if under `data/core`, the `diff` engine must be treated as core or injected.
  - if under `data/plugins/diff`, keep a path for later promotion.

Expected files:

- `data/core/diff_model.lua` or `data/plugins/diff/model.lua`
- `tests/lua/runtime/diff_model.lua`

Tests:

- equal text.
- insert-only hunk.
- delete-only hunk.
- modify hunk with inline ranges.
- long unchanged fold candidates.
- side line mapping around insert/delete hunks.

### Phase 2: Add DocView decoration and gutter provider APIs

- Add provider registration/removal to `DocView`.
- Route line backgrounds and inline highlight drawing through providers.
- Add deterministic layering/priority semantics.
- Add gutter/action provider support for sync/apply arrows, or define it as a first-class provider capability before removing current arrow drawing.

Expected files:

- `data/core/docview.lua`
- `tests/lua/ui/docview_decorations.lua`

Tests:

- line background drawing.
- inline range drawing.
- wrapped visual rows.
- provider ordering/layering.
- provider removal.
- gutter marker rendering and hit-testing.

### Phase 3: Move Diff View line/inline/gutter rendering to providers

- Remove the `draw_line_text` override from `DiffView:patch_views()`.
- Register a diff decoration provider on each side `DocView`.
- Register a gutter/action provider for hunk arrows.
- Keep divider connector drawing in `DiffView`, but source positions from the model and `DocView` geometry.
- Validate existing line wrap diff tests still pass.

Target removals:

- `wrap_draw_line_text`
- sync arrow drawing from inside `draw_line_text`.
- manual plain-text diff text drawing if it can be expressed through provider options.

### Phase 4: Replace document monkey-patching with listeners

- Register document text-change listeners for both sides.
- Schedule rediff through `DiffView`.
- Use generation IDs/cancellation so stale rediff results cannot apply after disposal or newer edits.
- Remove overrides of:
  - `raw_insert`
  - `raw_remove`
  - `on_text_transaction`

Tests:

- editing either side schedules exactly one rediff.
- undo/redo schedules rediff.
- direct raw mutation is observed or disallowed through a migrated path.
- syncing/applying a hunk emits expected document changes.
- closing a Diff View unregisters listeners.
- stale rediff results are ignored.

### Phase 5: Replace selection/caret monkey-patching

- Stop overriding `doc.set_selection`, `doc.set_selections`, and `doc.set_selection_list`.
- Use the DocView Selection State observer to sync peer caret.
- Use explicit diff line mapping.

Tests:

- caret move on left maps to right around insert-only hunks.
- caret move on right maps to left around delete-only hunks.
- folded regions do not land selection on hidden lines.
- multi-cursor/multi-selection changes do not recurse or corrupt Selection State.

### Phase 6: Rich line-height virtual visual rows / alignment rows

- Extend current virtual row extension API to support provider-owned line-height visual row objects.
- Migrate diff gap rows from count tables to provider-owned alignment rows.
- Support optional row drawing and hit-testing.
- Keep arbitrary pixel-height rows out of this phase.

Tests:

- inserted lines create empty alignment rows on the opposite side.
- row hit-testing resolves to stable Document positions.
- wrapped Document lines plus alignment rows compose correctly.
- scroll size remains correct with folds and alignment rows.

### Phase 7: Paired Fold Region support

- Introduce a clean paired-fold mechanism.
- DiffModel emits fold candidates.
- DiffView installs paired Fold Regions through core APIs.
- Expanding/collapsing one side updates its pair without click interception hacks.
- Preserve fold state by stable hunk/equal-block identity where possible.

Tests:

- long unchanged regions fold on both sides.
- expanding one side expands the pair.
- fold state survives rediff when possible.
- POI navigation can reveal folded hunks intentionally.

### Phase 8: DiffRequest / DiffContent API

- Introduce public construction helpers:

```lua
diff.open(request)
diff.content.text(text, opts)
diff.content.document(doc, opts)
diff.content.file(path, opts)
diff.content.empty(opts)
```

- Keep compatibility helpers initially:
  - `diffview.string_to_string`
  - `diffview.file_to_file`
  - `diffview.file_to_string`
  - `diffview.string_to_file`

But internally route them through `DiffRequest`.

Tests:

- string-to-string helper creates equivalent request/view.
- file-to-file helper creates equivalent request/view.
- existing commands still open expected Text Diff View.

### Phase 9: Mutable standalone blank diff

- Add a blank Text Diff View command that opens two editable untitled Documents.
- Treat blank contents as ordinary untitled Documents unless a concrete transient-document reason emerges.
- Allow replacing either side from a file or recent text later.
- Ensure both sides are normal editable Editors/DocViews where appropriate.

Initial commands:

- `diff-view:open-blank-diff`
- `diff-view:replace-left-with-file`
- `diff-view:replace-right-with-file`

Tests:

- blank diff opens with editable left/right sides.
- editing either side rediffs.
- replacing one side reloads without losing the surrounding tab/window placement.

### Phase 10: Git View migration

- Change `GitView:ensure_diff_view(tab)` to build a richer `DiffRequest` instead of calling `string_to_string` directly.
- Preserve file-list layout initially.
- Pass metadata:
  - Git side names.
  - selected changed file.
  - read-only/editable policy.
  - future apply/revert labels.

Tests:

- Commit Diff View opens through DiffRequest.
- focus cycling remains stable.
- selected changed file reloads the same viewer/session placement when possible.

## Test strategy

Use red-green regression workflow for behavior changes.

Recommended layers:

- Runtime tests for `DiffModel` and mapping.
- Runtime/UI tests for document and selection listener APIs.
- In-process UI tests for DocView providers, virtual rows, Fold Regions, focus, and POIs.
- Existing Git View UI tests for integration.

Commands:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/diff_model.lua
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/docview_decorations.lua
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/diffview_batch.lua
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/git_view.lua
```

For Lua syntax after edits:

```sh
./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua data/plugins/diffview.lua data/core/docview.lua
```

## Success criteria

- No method replacement of `DocView` or `Doc` instances by Diff View.
- Diff rendering is expressed through `DocView` provider APIs.
- Diff folding uses core Fold Regions with clean paired behavior.
- Diff alignment uses core visual row/block-row APIs.
- Diff scroll/caret sync uses explicit model mapping.
- Diff rediff lifecycle has generation/cancellation/disposal protection.
- Text Diff View and Commit Diff View continue to work.
- Blank editable diff can be opened using normal editable Documents and request/viewer plumbing.
- The structural diff model can be reused by future unified or three-way views.

## Open design questions

1. Should `DiffModel` live under `data/core` immediately, or start under `data/plugins/diff` until the API stabilizes?
2. If `DiffModel` lives in core, where should the `diff` engine live, and should the engine be injectable for tests or future algorithms?
3. Should DocView provider APIs be one combined provider interface or separate providers for decorations, POIs, virtual rows, and gutter actions?
4. Should blank diff contents always be normal untitled Documents, or is there a concrete need for transient Documents owned only by the DiffView/host?
5. How should editable file-backed diff sides handle saving and dirty state?
6. Should Git working-tree diffs eventually allow direct editing of the working-tree side inside Commit Diff View?

## Review round 2 amendments

The second review pass found a few planning gaps that should be treated as accepted amendments before implementation starts.

### Replace all `patch_views()` behaviors, not only drawing/document/selection

The success criterion "no method replacement" includes every current `DiffView:patch_views()` override. Migration work must account for:

- `draw_line_text`
- `scroll_to_line`
- `scroll_to_make_visible`
- `doc.set_selection`
- `doc.set_selections`
- `doc.set_selection_list`
- `doc.raw_insert`
- `doc.raw_remove`
- `doc.on_text_transaction`
- `get_points_of_interest`
- `prev_change`
- `next_change`

Add a dedicated scroll/POI cleanup step before declaring the migration complete:

- use `DocView` scroll or visible-area listeners instead of wrapping scroll methods.
- use POI/navigation providers instead of replacing `get_points_of_interest`, `prev_change`, or `next_change`.
- add tests proving provider removal restores ordinary DocView behavior.

### Divider hunk actions are not ordinary DocView gutter actions

The current hunk arrows live in the central Diff View divider, not inside a child DocView gutter. Treat them as Diff View divider actions sourced from `DiffModel` plus `DocView` line geometry. Only use DocView gutter/action providers for markers that truly belong inside one Document View.

### Introduce internal request/content normalization earlier

Even if public `diff.open(...)` helpers come later, Phase 1 should normalize all existing string/file helper inputs into internal `DiffRequest` / `DiffContent` records. This avoids redesigning editability, document ownership, listener registration, and disposal twice.

### Reconcile document listeners with existing transaction handlers

`Doc.register_text_transaction_handler` already exists, but it is global and transaction-oriented. Diff View needs per-document registration and coverage for raw insert/remove and undo/redo paths. The new listener design must either supersede the global handler cleanly or implement per-document filtering on a hardened central notification path.

### Respect Anvil's Doc-level legacy selection APIs

Anvil differs from IntelliJ because legacy selection mutation APIs live on `Doc`, while the desired ownership is per-`DocView` Selection State. The selection-listener phase must audit diff-side command/event paths so they operate through active DocView selection binding or Selection State APIs. Otherwise `doc:set_selection(...)` calls can bypass view-local listeners.

### Decide scroll sync behavior explicitly

The mapping API should be backed by a clear scroll policy:

- proportional mapping within unchanged/diff boundary ranges, closer to IntelliJ and smoother around large hunks; or
- simpler line-anchored mapping as an initial implementation.

The old identical-`scroll.y` behavior should not remain the long-term sync mechanism except as a temporary fallback.

### Consider range markers/highlighters before inventing draw-only providers

IntelliJ uses RangeHighlighters for diff decorations. Anvil already has `range_marker`. Before adding a broad decoration-provider API, decide whether `range_marker` should evolve into a styled highlighter/marker layer for line and inline decorations. A provider API may still be needed for hot-path line backgrounds or virtual rows, but avoid a diff-only rendering abstraction.

### Make async diff computation ownership explicit

Initial recommendation: `DiffView` owns coroutine scheduling, generation IDs, cancellation, stale-result rejection, and disposal. `DiffModel.compute(...)` should be a pure worker body returning structural diff data. If this changes, the model API must explicitly describe async lifecycle ownership.

### Preserve fold state with stable identity, not only indexes

Current diff folds are rebuilt from equal-block indexes. Edits can shift those indexes. Paired fold state preservation needs a best-effort stable identity, such as neighboring hunk identity plus normalized unchanged-range anchors/content. If identity is ambiguous, safely reset to default collapsed/expanded behavior.

### DiffContent must define document ownership

Each `DiffContent` must say whether the Diff View owns the resulting `Doc` and should close it. Existing file-backed or caller-owned Documents must not be closed merely because one Diff View closes; transient text Documents probably should be. This ownership also affects blank editable diff dirty/save behavior.
