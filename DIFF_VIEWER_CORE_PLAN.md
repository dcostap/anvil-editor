# Diff View Core Integration Plan

## Current status

Diff View has been moved most of the way from a monkey-patched two-`DocView` plugin toward a first-class diff viewer built on core extension points.

This plan now tracks only what is done and what still needs implementation. Historical exploration details have been removed.

## Reference stance

Use the local IntelliJ source as a golden reference for architectural pressure points, lifecycles, and edge cases, not as a 1:1 API or complexity target. Prefer the smallest Anvil-native design that preserves the useful lessons:

- request/content records own diff intent and request-scoped state.
- viewer/controller code owns active UI lifecycle and reload/disposal ordering.
- editor extension points should be view-scoped when global document mutation would leak outside the diff view.
- fold, scroll, row-composition, and editability features should handle the bugs Anvil can realistically hit, without importing IntelliJ-only abstraction layers until they are useful here.

Intentional divergences from IntelliJ should be called out in the relevant section so future work does not accidentally “fix” them back into IntelliJ parity.

## Completed

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
  - visual-row providers for line-height row counts.
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

### Request/content normalization

Completed:

- Existing helper inputs are internally normalized into `DiffRequest` / `DiffContent` records.
- Added public-ish construction helpers:
  - `diffview.open(request, noshow)`
  - `diffview.content.text(text, opts)`
  - `diffview.content.file(path, opts)`
  - `diffview.content.document(doc, opts)`
  - `diffview.content.empty(opts)`
- Legacy helpers still route through the new request path:
  - `string_to_string`
  - `file_to_file`
  - `file_to_string`
  - `string_to_file`

Design decisions:

- Text contents create owned untitled documents.
- `empty` currently means an Anvil-owned blank untitled document for the existing helper flow, not IntelliJ's non-document empty placeholder. During API hardening, introduce `blank` as the canonical public name for this mutable blank-document content and keep `empty` only as a compatibility alias/current helper name. If add/delete placeholder semantics are needed later, add a separate `placeholder`/`missing` content kind instead of overloading mutable blank documents.
- Caller-provided document contents are caller-owned unless explicitly marked owned.
- File contents create file-backed documents and are not owned by the Diff View.

### Initial Git View migration

Completed:

- Git View creates commit diff panes through `diffview.open(request, true)` instead of `string_to_string(...)`.
- Git requests include request user data for:
  - selected changed file.
  - selected file path/index.
  - left/right revision endpoints.
  - read-only policy.

### Initial visual-row providers

Completed:

- Added `DocView:add_visual_row_provider(id, provider, opts)` and `remove_visual_row_provider(id)`.
- Diff gap/alignment rows use the provider API instead of direct `set_visual_row_extension` calls.

Current limitation:

- Providers currently expose line-height row counts only. They do not yet expose row objects, drawing callbacks, or hit-testing.

### Initial paired fold listeners

Completed:

- Added `DocView:add_fold_listener(id, fn)` and `remove_fold_listener(id)`.
- Fold listeners fire for fold add/remove/expand/collapse/change/invalidate events.
- Diff paired fold expansion now reacts through fold listeners instead of intercepting fold-widget clicks before `DocView` handles them.

Current limitation:

- Fold state is still preserved by equal-block index, not by stable content identity.

## Remaining work

### 1. Rich visual-row provider objects

Current state:

- Visual-row providers support only count-style line-height rows before/after document lines.
- Current count semantics are cumulative for `before[line]`: a diff gap provider can say "there are N total extra rows before this document line" and `DocView` computes the per-line delta.

Finish by adding provider-owned row objects while preserving existing count providers.

Provider API:

```lua
provider:visual_rows(view, line, placement, previous_line_total) -> {
  {
    id = "stable-row-id",
    kind = "diff-gap" | "action" | string,
    height_rows = 1,
    draw = function(view, row, x, y, w, h) end,
    hit_test = function(view, row, x, y) end,
    on_click = function(view, row, button, x, y, clicks) end,
    metadata = {},
  }
}

provider:generation(view) -> number|string|nil
```

Do not overload the legacy count-provider methods to return row objects. `rows_before`, `rows_after`, and table-based `before` / `after` providers remain count-only compatibility APIs. Object rows are exposed only through `visual_rows(...)`.

Add an explicit invalidation path so providers do not rely only on passive generation polling:

```lua
docview:invalidate_visual_rows(provider_id?)
```

Providers with cheap immutable generations may still expose `generation(view)`; providers with event-driven state should call the invalidation API when their row set changes.

Provider row validation contract:

- Provider row identity is scoped as `{ provider_id, line, placement, row.id }`.
- `row.id` should be stable within that anchor. Duplicate ids from one provider at the same line/placement should be quiet-logged and disambiguated internally rather than corrupting the cache.
- `height_rows` is reserved for the future. In this phase, only `nil` or `1` is valid; other values should be quiet-logged and treated as `1` or skipped consistently.
- Provider callbacks must be isolated with `pcall`; callback failures should quiet-log the provider id and skip the failed draw/hit/click action without breaking ordinary Document View input.

Core composition contract:

- Rows are still one `DocView:get_line_height()` tall. Arbitrary pixel-height rows are not part of this phase.
- Build a normalized composed-row sequence/cache before drawing or hit-testing. Each entry must have stable identity and enough data to reverse-map from visual row to document/fold/provider content:

```lua
{
  absolute_row = n,
  type = "provider" | "line" | "fold",
  provider_id = id?,
  line = line,
  placement = "before" | "after"?,
  row_in_provider = n?,
  row_in_line = n?,
  provider_row = row_object?,
}
```

- Invalidate the composed-row cache when any of these change:
  - document line count/text that affects wrapping.
  - line wrapping state.
  - fold add/remove/expand/collapse/invalidate.
  - provider registration/removal.
  - explicit `invalidate_visual_rows(...)` calls.
  - provider data generation, when a provider exposes one.
- Count providers stay supported:
  - `before[line]` keeps its existing cumulative meaning.
  - `rows_before(view, line)` and `rows_after(view, line)` return counts only.
  - legacy anonymous count rows are synthesized as internal provider entries with generated ids.
- Object rows are anchored to a document line plus placement:
  - `placement = "before"` rows appear before that line's fold/line rows.
  - `placement = "after"` rows appear after that line's fold/line rows. Intermediate `after` rows must be included, not only trailing EOF rows.
- Row ordering is deterministic:
  - provider priority.
  - provider id.
  - row order returned by that provider.
- The composed-row cache becomes the single source of truth for visual row count, line-to-row mapping, row-to-line mapping, drawing order, mouse hit-testing, and diff scroll/line-transfer calculations while composed rows are active.
- `DocView:get_visual_row_entry(row)` must return the normalized entry for provider rows, preserving provider identity and provider row object.
- Drawing should dispatch provider row `draw(...)` for visible provider rows before ordinary line text drawing.
- Mouse resolution should preserve provider row identity. A click on a provider row should call `row.hit_test` / `row.on_click` before falling back to ordinary document-line selection.
- Diff gap rows can remain anonymous blank rows until a visible action row is needed.
- Keep diff sync/apply arrows owned by the Diff View divider/gutter path for now, matching IntelliJ's separation between diff change operations and editor row composition. Do not move apply actions into provider rows unless a later visible in-text action row explicitly needs it.

Tests to add/update:

- provider row draw callback runs for visible extra rows.
- click hit-testing resolves to the provider row and does not start normal text selection.
- wrapped document lines plus before/after provider rows compose correctly.
- count-style diff gap providers remain compatible.
- provider removal restores ordinary `DocView` row counts and hit-testing.
- provider generation changes invalidate and rebuild the composed-row cache.
- duplicate provider row ids do not corrupt row lookup and produce a quiet diagnostic.
- provider draw/hit/click callback errors are isolated and ordinary text hit-testing still works.

### 2. Stable diff fold identity

Current state:

- Diff fold expansion state is keyed by equal-block index.
- Edits can shift/reorder equal blocks, so expansion state can be lost or applied to the wrong block.

IntelliJ reference:

- IntelliJ's `FoldingModelSupport` stores fold state in request user data as range-based expanded/collapsed cache entries.
- It restores state by finding a cached range that covers the newly created fold range.
- IntelliJ explicitly accepts that edits since cache creation can produce imperfect fold restoration.

Anvil decision:

- Use IntelliJ's request-scoped fold-state cache as the lifecycle model: fold state belongs to the active diff request/view context, not to global document state.
- Intentionally improve on IntelliJ's range-only matching with content/neighbor identity so edits before a fold do not commonly lose or misapply expansion state.
- Treat this as an intentional Anvil divergence from the golden reference, not an accidental API mismatch.

Finish by replacing index-only fold preservation with request-scoped stable identity matching. Keep this simpler than IntelliJ unless tests prove more is needed: the goal is to avoid common wrong/lost restoration after edits, not to perfectly preserve fold state across arbitrary rewrites.

Request-scoped cache model:

```lua
request.user_data.diff_fold_state = {
  default_expanded = boolean,
  states = {
    {
      identity = table,
      side_ranges = {
        left = { start_line = n, end_line = n }?,
        right = { start_line = n, end_line = n }?,
      },
      state = "expanded" | "collapsed",
      description = string?,
    }
  }
}
```

Lifecycle contract:

- Store fold state on the active request's `user_data`, not on the global documents.
- Update the request cache from the currently installed fold regions before clearing/rebuilding them during rediff, matching IntelliJ's update-before-install lifecycle.
- Preserve both expanded and collapsed exceptions relative to the current default fold mode; do not model only expanded folds.
- If the request's default fold mode changes, ignore incompatible cached state and use the new default behavior. Cache compatibility is based on `default_expanded` matching the current default.
- If a mutable request/controller rebuild changes side content identity, carry fold cache forward only for sides whose semantic content identity is compatible. Do not blindly reuse old fold state after replacing a side with an unrelated file/text document.

Identity model:

- Primary identity must be content/neighbor based, not position based.
- Primary identity fields, implemented in the smallest useful subset first:
  - previous hunk signature, if present.
  - next hunk signature, if present.
  - normalized first visible unchanged line in the candidate.
  - normalized last visible unchanged line in the candidate.
  - a small normalized digest/sample of the folded unchanged block when boundary lines are not unique enough.
  - hidden-line count bucket/exact count, used only when it improves uniqueness.
- Position fields such as side starts/counts are **tie-breakers only**. They must not be part of the strict identity key, because insertion before a fold shifts positions.
- Hunk signatures should be small and stable:
  - hunk tag.
  - first changed line text hash/summary on both sides when available.
  - last changed line text hash/summary on both sides when available.
  - hunk changed-line counts.
- Ambiguity handling:
  - Build candidate identities for old cached fold states and new fold candidates.
  - If exactly one new candidate matches an old identity, preserve the cached expanded/collapsed state.
  - If zero candidates match, reset to default fold behavior.
  - If multiple candidates match, use position as a tie-breaker only if it chooses one clearly nearest candidate; otherwise reset to default fold behavior.
  - If sides disagree about the restored state or identity match, reset to default instead of guessing.
- Keep numeric `index` only for diagnostics/display. Do not use it as persisted expansion state.

Tests to add:

- expanding a long unchanged region survives insertion before the region.
- expanding a region does not expand a different equal block after repeated-content edits.
- deleting/touching the folded unchanged block safely resets fold state.
- identical repeated equal blocks become ambiguous and reset instead of preserving incorrectly.
- fold state is request/view-scoped and does not leak to another Diff View over the same documents.
- changing the default fold mode ignores incompatible cached state and uses the new default.
- manually collapsed and manually expanded fold exceptions both survive a compatible rediff.

### 3. Public DiffRequest / DiffContent API hardening

Current state:

- Request/content helpers exist and legacy helpers route through them.
- API is usable but not documented as stable.

Finish by making the contract explicit and validating requests before opening a view.

Request schema:

```lua
{
  title = string?,
  kind = "text" | "git" | "blank" | "file" | string,
  contents = { content1, content2, content3? },
  content_titles = { string?, string?, string? }?,
  editable_policy = "read-only" | "content" | "editable"?,
  preferred_focus_side = "left" | "right" | "base"?,
  user_data = table?,
}
```

Compatibility sugar:

- Public helpers may still accept `{ contents = { left = content, right = content } }` and `{ content_titles = { left = "...", right = "..." } }`.
- `diffview.open(request)` must normalize that sugar immediately into list-based `contents` and `content_titles`, matching IntelliJ's `ContentDiffRequest` / `SimpleDiffRequest` model.
- `metadata` should be normalized into `user_data` or request-kind-specific user-data keys. Generic Diff View code should read named user-data fields, not Git-specific ad-hoc metadata tables.

`DiffContent` is a discriminated union. Common optional fields:

```lua
{
  kind = string,
  name = string?,
  editable = boolean?,
  owns_doc = boolean?,
  read_only_reason = string?,
  syntax_hint = string?,
}
```

Kind-specific fields:

```lua
-- text: DiffView creates an owned untitled Doc from text.
{ kind = "text", text = string, ... }

-- blank: DiffView creates an owned mutable blank untitled Doc.
-- This is intentionally different from IntelliJ's non-document EmptyContent placeholder.
{ kind = "blank", ... }

-- empty: compatibility alias for current Anvil helper behavior; new code should prefer blank.
{ kind = "empty", ... }

-- future, only if add/delete placeholder UI needs IntelliJ-style EmptyContent semantics:
-- { kind = "placeholder", ... }

-- file: DiffView creates/opens a normal file-backed Doc.
{ kind = "file", filename = string, ... }

-- document: caller provides an existing Doc.
{ kind = "document", doc = Doc, ... }
```

Request/content lifecycle contract:

- Add lightweight assignment hooks before treating this as stable public API:
  - `request:on_assigned(is_assigned, context)?`
  - `content:on_assigned(is_assigned, request, side)?`
  - `content:dispose?()` for owned resolver-created resources that are not ordinary docs.
- A request may be shown/reloaded more than once. Assignment calls must be balanced so request/content listeners or temporary resources do not leak, matching IntelliJ's `DiffRequest.onAssigned(...)` / content assignment lifecycle.
- Request user data has two scopes:
  - chain/controller-persistent user data copied into each rebuilt request.
  - per-built-request transient user data owned by the active view instance.
- Fold, scroll, and focus state should be restored from persistent request/chain data only when side content identity is compatible with the previous request.

Validation/defaulting rules:

- Exactly two normalized contents are required for the current side-by-side Diff View. Three contents are recognized request shape but should return an explicit "three-way viewer not implemented" validation/open error until the future three-way viewer exists.
- Unknown content kinds are invalid unless a future content resolver is explicitly registered.
- `content_titles[index]` overrides `content.name` for UI side labels when present.
- `content.name` is used as the created document name when no side title is given.
- Missing `editable_policy` defaults to `"content"`.
- Requests that resolve to the same `Doc` instance on more than one side are invalid for the current viewer. Validate this after content resolution/opening, not only on raw request tables. If file contents can resolve to the same already-open document or same canonical file path, reject those too. This is an intentional Anvil divergence from IntelliJ: IntelliJ logs a warning because same-document diff requests have confusing listener and mutation behavior; Anvil rejects them deterministically.
- Invalid requests should return a clear error object/string; they should not fail later with a nil-field crash.

Ownership decisions:

- `DiffView` owns docs only when `content.owns_doc == true` or when it creates a text/blank/empty-compat transient doc.
- A future non-document placeholder/missing content kind would not create or own a `Doc`.
- Caller-owned document content is never closed/disposed by closing one Diff View.
- File-backed docs are ordinary documents with ordinary dirty/save behavior.
- Git historical contents are text contents with read-only policy, not file-backed editable documents.

Tests to add:

- request helpers create equivalent views to legacy helpers.
- `{ left = ..., right = ... }` sugar normalizes to list-based contents/titles.
- invalid requests produce deterministic validation errors.
- same-`Doc` requests are rejected with a deterministic validation error.
- title precedence: `content_titles[index]` over `content.name` over filename basename.
- caller-owned document content is not closed/disposed by closing a Diff View.
- owned transient text/blank/empty-compat docs are cleaned up when the Diff View is disposed.
- request/content assignment hooks are balanced across open, reload, replacement, and disposal.

### 4. Editable policy and file-backed diff sides

Current state:

- Text Diff View and Git Diff View content can be represented by requests.
- Detailed editability enforcement is not complete.

Finish by enforcing editability consistently at Diff View input/action boundaries without globally changing caller-owned documents. IntelliJ often uses editor viewer/read-only flags for this; Anvil should use a smaller view-scoped guard because the same `Doc` can be open normally elsewhere.

Effective editability:

- false when request `editable_policy == "read-only"`.
- true when request `editable_policy == "editable"`, unless content explicitly sets `editable = false`.
- content-owned when request `editable_policy == "content"`:
  - `content.editable == false` means read-only.
  - `content.editable == true` means editable.
  - missing `content.editable` defaults to editable for ordinary text/blank/file/document contents; `empty` compatibility content follows the blank default; Git requests set read-only explicitly.

Enforcement boundary:

- Add a core `DocView` edit-guard extension point so view-scoped editability is enforceable without mutating global `Doc` state:

```lua
docview:add_edit_guard(id, guard)
docview:remove_edit_guard(id)
docview:can_edit(reason, opts) -> boolean, reason?
```

- Core typing, paste, delete/backspace/newline, undo/redo, and command-routed editing paths must consult the active `DocView` edit guard before mutating the document.
- Audit older command paths that mutate `core.active_view.doc` directly and route them through `DocView:can_edit(...)` or an equivalent command predicate before this feature is considered complete.
- Decide whether existing read-only monkey-patch flows (`git/historical_document.lua`, Git View pane docs, Command Output View command guards) remain special cases or migrate onto the new guard API; do not leave overlapping guard systems ambiguous.
- Add a side-aware edit guard owned by `DiffView` and installed on side `DocView`s, not as a global lock on caller-owned `Doc`s.
- The guard must cover user mutations routed through the Diff View:
  - typing.
  - paste.
  - delete/backspace/newline commands.
  - undo/redo commands when invoked from the read-only diff side.
  - DiffView's own sync/apply actions (`DiffView:sync`, divider clicks, `diff-view:sync-change`).
- Do **not** install a global per-`Doc` mutation gate for caller-owned document or file contents. A read-only Diff View over a `Doc` must not make that same `Doc` read-only in a normal Editor.
- Direct external `Doc:apply_edits`, `raw_insert`, or `raw_remove` calls on caller-owned docs remain the caller's responsibility; Diff View should observe the text-change listener and rediff afterward.
- Owned transient read-only contents, such as Git historical snapshots, may be backed by an actually read-only/guarded `Doc` because no other owner should edit them.
- DiffView-originated sync/apply actions must check target-side editability before calling `replace`/`apply_edits`, and should not show sync arrows/actions for read-only targets unless they are disabled with a clear reason.
- Read-only rejection should surface `read_only_reason`:
  - visible warning for direct user edit attempts inside the Diff View.
  - quiet log for background/programmatic DiffView-originated attempts unless user initiated.

File-backed side decisions:

- Editable file-backed sides use normal document dirty/save behavior.
- File-backed read-only sides reject edits but can still be viewed, folded, searched, and navigated.
- Git commit/historical sides remain read-only.
- Working-tree Git editing remains disabled until explicitly implemented and tested.

Tests to add:

- core `DocView` edit guards block command-routed edits only for the guarded view.
- read-only diff side rejects typing, paste, delete/backspace, and undo/redo invoked from that side.
- read-only target rejects `diff-view:sync-change` and divider sync click.
- opening a caller-owned `Doc` in a read-only Diff View does not prevent editing the same `Doc` through a normal Editor; both views observe the resulting rediff/update behavior.
- direct external `Doc:apply_edits` on caller-owned content is observed and rediffs, not blocked globally.
- owned transient read-only snapshot docs reject direct mutation through their configured guard/read-only mechanism.
- editable text side accepts edits and rediffs exactly once per user edit.
- editable file-backed side becomes dirty and saves through normal document save.
- Git commit diff sides are read-only and expose a useful read-only reason.

### 5. Mutable blank diff workflow

Current state:

- `DiffContent.empty` exists with the current Anvil meaning of an owned blank document, but there is no standalone blank diff command/mutable request workflow.
- Add `DiffContent.blank` / `diffview.content.blank(...)` as the canonical public name for mutable blank documents; keep `empty` only as a compatibility alias unless/until IntelliJ-style placeholder content is introduced.

Finish by adding an Anvil equivalent of IntelliJ's mutable blank-diff flow. Match IntelliJ's useful separation of concerns, not every feature: `MutableDiffRequestChain` owns mutable request state, while a processor/controller owns active `DiffView` lifecycle and reloads.

Phase-1 commands:

- `diff-view:open-blank-diff`
- `diff-view:replace-left-with-file`
- `diff-view:replace-right-with-file`

Deferred optional features inspired by IntelliJ:

- switch side back to a blank editable document.
- replace side from recent blank content.
- remember recent non-empty blank diff text.
- drag/drop file replacement.
- swap sides.
- optional three-side blank diff toggle.

Mutable request chain API:

```lua
local chain = MutableDiffRequestChain(request, opts)
chain:set_content(side, content, opts)
chain:build_request(opts) -> request
chain:put_user_data(key, value)
chain:get_user_data(key)
```

Processor/controller API:

```lua
local controller = DiffRequestController(chain, opts)
controller:get_view()
controller:reload(opts)
controller:try_close(callback)
controller:dispose()
```

Chain responsibilities:

- Own the active mutable request and chain-persistent request user data.
- Produce normalized `DiffRequest` records from current chain state and copy chain-persistent user data into each built request.
- Keep per-built-request transient data separate from chain-persistent data so stale viewer state is not accidentally reused after side replacement.
- Mark blank-diff requests in user data.
- Set blank-flow defaults when building the initial request:
  - preferred focus side = left.
  - suppress equal-contents notifications for newly opened blank documents.
- Keep commands from mutating `DiffView` internals directly.

Processor/controller responsibilities:

- Produce/reload the current `DiffView` from the chain's request.
- Preserve surrounding tab/node/tool placement when reloading or replacing content.
- On replacement, first finish dirty-content confirmation. Only dispose the old `DiffView` integrations after replacement/close is confirmed, so a cancelled dirty prompt leaves the existing view fully functional.
- Treat this ordering as a blocker for blank-diff work: `DiffView:try_close()` must not dispose integrations before a close/replacement has been confirmed.
- Dispose the old `DiffView` integrations before installing the confirmed replacement view.
- Increment generation IDs so stale diff computations cannot apply after replacement.
- Preserve focus side, scroll/caret state, and folding state where it is safe and side contents are semantically the same. Reset those states when side content identity changes or matching is ambiguous.

Dirty-content protection:

- Blank diff starts with two normal owned untitled documents.
- Owned editable docs must be protected on close and side replacement.
- Closing through the controller/view should prompt or otherwise reuse the normal `DocView:try_close()` dirty-document confirmation behavior for each dirty owned side doc.
- Replacing a dirty owned side must confirm before discarding it.
- If the user cancels the dirty prompt, replacement/close is cancelled and the existing view remains active.
- Non-owned caller docs are not closed by the controller/view; their normal owners remain responsible for dirty state.

Replacement decisions:

- Replacement from file should use a normal file-backed `Doc` when the user intends to edit/save that file.
- Replacement from snapshot/recent text should use owned text content.
- Reload/replacement should keep the same outer tab placement; recreating the internal `DiffView` is acceptable.

Tests to add:

- blank diff opens with editable left/right documents.
- editing either side schedules one rediff.
- replacing left or right with a file keeps the same outer tab placement.
- replacing a dirty blank side prompts and cancels correctly.
- closing a dirty blank diff prompts and can cancel close.
- closing a clean blank diff disposes owned untitled docs.

### 6. Git View polish after request migration

Current state:

- Git View builds a `kind = "git"` request and passes useful request user data.

Finish by using that user data for richer Git diff behavior.

Design decisions:

- Commit diff requests are read-only by default.
- Divider/apply/revert labels should be sourced from Git request user data, not hardcoded in generic Diff View.
- Reloading a selected changed file should reuse the same surrounding Git View tab placement and Git View state.
- If working-tree editing is added later, it should be opt-in and only for the working-tree side.

Tests to add:

- Commit Diff View opens through `DiffRequest` with expected Git user data.
- selecting another changed file reloads the viewer without losing Git pane focus state.
- Git request user data is available to divider/action code.

### 7. Unified and three-way modes

Current state:

- Structural pieces should support future viewers, but only side-by-side two-way diff is implemented.

Design decisions:

- Do not build unified or three-way UI until the two-way request/content/model contracts are stable.
- Unified and three-way should be separate viewer implementations selected from request shape/kind.
- `DiffModel.compute(...)` remains a pure worker body. Viewer/controller code owns async lifecycle.

Future tests:

- viewer selection chooses side-by-side for two contents.
- future unified viewer can consume the same `DiffModel` without depending on `DocView` side-by-side geometry.

## Validation checklist for future phases

Run targeted tests while developing:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/diff_model.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/doc_text_change_listener.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/docview_decorations.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/diffview_batch.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/git_view.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/linewrap.lua --print-errorlogs
```

Use the full Anvil suite when unrelated known failures are cleared:

```sh
meson test -C build-windows-x86_64 --suite anvil --print-errorlogs
```
