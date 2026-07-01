# Text Folding Regions Plan

## Goal

Implement proper text folding as a core Document View feature. A folded region should hide real Document text behind a visible Fold Widget Row that shows how many lines are hidden. Hidden text remains normal document content for selection, copy, cut, replace, undo/redo, search, diagnostics, language navigation, and diff viewers.

The current DiffView folding code is a useful prototype but should not remain the architecture. Folding must move into core `DocView` visual mapping so ordinary Editors, Text Diff Views, and future code/semantic folding all share one behavior.

## Terminology

- **Fold Region**: a real range of Document text that can be visually collapsed in one Document View.
- **Fold Widget Row**: the visible non-document row representing a collapsed Fold Region.
- **Collapsed**: a Fold Region is hidden behind its Fold Widget Row.
- **Expanded**: a Fold Region is visible as normal Document text.

## Current state

Existing folding lives in `data/plugins/diffview.lua` only.

DiffView currently:

- computes long unchanged equal blocks,
- stores `diff_folds_a` / `diff_folds_b`,
- treats `hidden_start` as a fake visible widget line,
- hides `hidden_start + 1 .. hidden_end`,
- monkey-patches each side's `DocView` methods:
  - `get_line_screen_position`,
  - `resolve_screen_position`,
  - `get_visible_line_range`,
  - `get_scrollable_size`,
  - `draw`,
  - selected `Doc` selection setters,
  - scroll/caret synchronization.

Tests exist in `tests/lua/ui/diffview_batch.lua` for basic fold creation, toggling, click-to-expand, and synchronization.

Problems with the current approach:

- It is DiffView-specific and cannot support normal Editors.
- It duplicates and partially replaces core `DocView` mapping/rendering behavior.
- It clamps caret/selection away from hidden lines, which conflicts with desired selection/search semantics.
- It composes poorly with future features because folding is not part of core line/row mapping.

## IntelliJ lessons to copy

From the IntelliJ source investigation:

1. Folding is a core editor visual mapping feature, not a diff plugin hack.
2. Fold state belongs to the editor/view, not the document.
3. Collapsed regions are real document ranges, not synthetic document lines.
4. Folding mutations are batched so layout, selection, scroll, and caches update once.
5. Visual mapping centrally composes logical document lines, soft wraps, and folded regions.
6. Search/navigation that targets folded content unfolds first.
7. Diff viewers compute fold ranges but use the same core folding APIs as normal editors.

Anvil should follow the same model, with a full-row Fold Widget Row instead of IntelliJ's usual inline placeholder.

## Desired user-facing behavior

### Rendering

- A collapsed Fold Region is represented by one Fold Widget Row.
- The widget should indicate the hidden line count, for example:

  ```text
  ⋯ 42 lines folded ⋯
  ```

- Fold Widget Rows are not Document lines.
- Initial implementation is line-only: a collapsed Fold Region hides complete logical lines `line1..line2` and shows one Fold Widget Row at `line1`'s visual position.
- The widget represents the entire hidden range; `hidden_count = line2 - line1 + 1`.
- `get_line_screen_position(line1, ...)` returns the widget row while collapsed; positions for `line1 + 1 .. line2` are not visible and must either map to the widget boundary or unfold first depending on caller policy.
- `resolve_screen_position` on the widget row returns a deterministic fold boundary, initially `line1, 1`, unless the click is handled as expand/toggle.
- Line numbers should make clear that real lines are hidden. Initial implementation can show the start line number on the widget row; later gutter styling can be refined.
- Fold Widget Rows should use first-party style keys in `data/colors/default.lua`, not hardcoded plugin-local colors.

### Selection and editing

Hidden text remains part of the Document.

- Selecting across a folded region selects the hidden contents too.
- Copy copies hidden contents.
- Cut deletes hidden contents.
- Typing while a selection covers a folded region replaces all selected hidden contents.
- Backspace/delete at fold boundaries should behave as if operating on the underlying Document positions.
- Undo/redo should restore both text and selection normally.
- Multi-cursor edits should work using real Document selections.

Caret behavior:

- A caret cannot remain invisibly inside a collapsed Fold Region.
- If a direct user action targets a folded widget row, place the caret at a deterministic visible boundary, usually the fold start.
- If search/navigation targets a precise hidden position, expand the Fold Region first, then place the caret at the precise target.

### Manual folding commands

The main user interaction for manual folding should be command/keymap driven:

- `doc:fold-at-caret` bound to `ctrl+-`.
- `doc:unfold-at-caret` bound to `ctrl++` / the platform's actual plus key representation, likely also `ctrl+=` on keyboard layouts where `+` is shifted `=`.

These commands operate on the primary caret/selection, not on arbitrary visible folds.

`doc:fold-at-caret` should choose a **Fold Target**: the best foldable range containing the caret or current selection. The target resolver should be provider-based and reusable:

```lua
view:get_fold_target(line1, col1, line2, col2, opts)
```

Provider priority should be deterministic:

1. explicit selection range, when the user has a non-empty multi-line selection;
2. Tree-sitter node ranges from the existing `core.treesitter.selection` / `language_intelligence.node_ranges` path, filtered to meaningful multi-line ranges;
3. outline/document-symbol ranges from the existing Tree-sitter/LSP outline paths, especially enclosing symbols such as functions, methods, classes, structs, and namespaces;
4. indentation or blank-line block fallback using existing text navigation concepts when no semantic provider is available.

The selected Fold Target should usually be the smallest meaningful multi-line range containing the caret. Avoid folding one-line ranges unless a provider explicitly marks them useful.

`doc:unfold-at-caret` should expand the collapsed Fold Region at the caret/Fold Widget Row. If the caret is in visible text inside an expanded parent, it should not unexpectedly unfold unrelated child folds elsewhere.

Do not test exact shortcuts; tests should call commands directly.

### Search and navigation

Search should still inspect all real Document text.

- If a match is inside a collapsed Fold Region, expand that Fold Region before selecting/scolling to the match.
- Repeat-find/previous-find should behave the same way.
- Local IntelliJ-style find in `data/plugins/intellij_find.lua` is the first integration target because it is first-party and loaded by defaults.
- Core find/replace and `search_ui` should be updated or routed through the same unfold-before-select helper.

Navigation that jumps to a line/range should unfold target folds first. Because fold state is per `DocView`, this should be a view-level API rather than scattered direct `doc:set_selection(...)` calls:

```lua
view:select_and_reveal(line1, col1, line2, col2, opts)
view:reveal_range(line1, col1, line2, col2, opts)
```

Those helpers should expand folds according to `opts.fold_policy`, set the view-owned selection state, and scroll through the fold-aware mapping layer. In-repo navigation callers should migrate to this API instead of bypassing it.

Important callers include:

- go-to-line,
- project/fuzzy file open at line,
- project search result activation,
- POI navigation,
- diagnostics navigation,
- LSP definition/declaration/references,
- Tree-sitter/local language navigation,
- bracket/structure navigation,
- navigation/edit-location history restore when appropriate.

### Diff View behavior

Diff View should compute unchanged ranges and install corresponding Fold Regions on each side.

Diff-specific ownership remains for:

- deciding which unchanged ranges to fold,
- pairing left/right folds,
- synchronized fold expand/collapse,
- diff gap rows and pane scroll synchronization,
- diff connector drawing.

Core ownership should move to:

- fold storage,
- fold widget row rendering/hit testing,
- visible range calculation,
- logical-to-visual coordinate mapping,
- selection/edit/search semantics.

## Proposed architecture

### 1. Add a core Fold Region model

Create a small core module, likely `data/core/folding.lua`, or keep an internal model in `docview.lua` if it stays compact.

A Fold Region should contain at least:

```lua
{
  id = string|integer,
  line1 = integer,
  col1 = integer,
  line2 = integer,
  col2 = integer,
  collapsed = boolean,
  placeholder = string|function|nil,
  kind = string|nil,
  metadata = table|nil,
}
```

Line-oriented folds can use full-line ranges. The model should still be range-based enough to later support code folding over partial syntactic ranges.

Initial invariants:

- collapsed Fold Regions are sorted by start position,
- collapsed Fold Regions are non-overlapping,
- adjacent regions may coexist only when their widget rows remain unambiguous,
- nested or partially overlapping collapsed regions are rejected, merged, or force-expanded by `add_fold_region` according to explicit options,
- tests must cover adjacent, overlapping, nested, and duplicate fold ranges.

This keeps the first mapping layer deterministic. Nested semantic folds can be introduced later by storing a full tree while exposing a flat set of top-level collapsed regions to visual mapping.

Store fold state on `DocView`, e.g.:

```lua
view.fold_regions = {}
view.fold_generation = 0
```

Do not store collapsed fold state on `Doc` by default, because two views of the same Document may need different fold state.

### 2. Add a fold transaction API

Add batching similar to IntelliJ:

```lua
view:run_fold_transaction(function()
  view:add_fold_region(...)
  view:remove_fold_region(...)
end)
```

During a fold transaction:

- defer mapping cache rebuilds,
- defer scroll clamping,
- defer redraw/logging,
- preserve visible anchor if possible.

Initial implementation may rebuild caches eagerly after each transaction; the important API boundary should exist early.

Fold Region lifecycle must include explicit disposal:

- removing one Fold Region removes its owned range marker,
- clearing folds removes all owned markers,
- closing a `DocView` clears its folds and unregisters fold-owned markers/callbacks,
- closing a `Doc` must not leave fold marker callbacks reachable through stale views.

Add a lifecycle test for closing one folded view while another view of the same Document remains open.

### 3. Centralize visual mapping in DocView

Introduce core helpers that every relevant `DocView` method uses:

- logical line/col -> visual row/x/y,
- visual row/x/y -> logical line/col or Fold Widget Row,
- visible logical line/range iteration,
- scrollable visual row count,
- fold membership queries,
- view-owned non-document visual row providers.

This mapping must compose:

- normal document lines,
- wrapped visual rows,
- collapsed Fold Widget Rows,
- hidden folded lines,
- plugin/view-owned visual rows such as DiffView gap rows.

DiffView's current gap rows already participate in positioning, hit testing, visible ranges, and scrollable size. If core mapping does not provide a general extension point for those rows, DiffView will still need to monkey-patch the same methods after fold migration. Add the extension point before migrating DiffView.

The current DiffView helper ideas are useful source material:

- `visual_rows_before_line`,
- `visual_line_count`,
- `folded_rows_before_line`,
- `line_for_effective_row`.

But they should become generic `DocView` behavior instead of DiffView monkey patches.

### 4. Integrate rendering

Core `DocView:draw` / `draw_wrapped` should iterate visible visual rows through the mapping layer.

For a Fold Widget Row:

- draw gutter,
- draw widget background,
- draw placeholder text,
- draw selection highlight if selection overlaps the hidden range,
- do not draw normal Document text for hidden lines.

For normal rows:

- keep existing line body, selection, search, line hint, diagnostic underline, and caret rendering.

### 5. Integrate hit testing and mouse selection

`DocView:resolve_screen_position(x, y)` needs to understand Fold Widget Rows.

Proposed behavior:

- clicking the Fold Widget Row body toggles or expands the fold;
- clicking/dragging through the row resolves to a fold boundary for selection purposes;
- shift-selection across a fold selects the real hidden range;
- mouse drag crossing a fold should select through the real folded contents, not just the widget label.

Keep click-to-expand behavior available for DiffView and ordinary Editors.

### 6. Integrate selection/editing semantics

Do not special-case copy/cut/type by operating on widget text. Keep real `Doc` selections.

Add helpers on `DocView`:

```lua
view:expand_folds_covering_range(line1, col1, line2, col2, reason)
view:expand_folds_at_line(line, reason)
view:normalize_selection_for_folds(line1, col1, line2, col2, mode)
view:select_and_reveal(line1, col1, line2, col2, opts)
view:reveal_range(line1, col1, line2, col2, opts)
```

Suggested rules:

- Precise navigation/search into hidden content: expand first.
- User selection crossing a collapsed region: keep real endpoints and draw coverage on widget row.
- Selection endpoint placed inside a collapsed region by ambiguous visual action: snap to fold boundary unless the caller explicitly requests unfolding.
- Keyboard movement/select/delete commands must be fold-aware; update `DocView.translate`, `data/core/commands/doc.lua` movement helpers, wrapped movement helpers, and delete/select-to commands so ordinary arrow-style navigation cannot leave carets invisibly inside collapsed content.

Avoid changing `Doc:get_text`, `Doc:text_input`, `Doc:apply_edits`, etc. unless necessary. The Document should remain unaware of visual folding except for fold-range adjustment hooks if we choose to preserve fold regions across edits.

### 7. Maintain fold regions across edits

Fold Regions should adjust after document edits.

Use the existing `data/core/range_marker.lua` machinery unless a concrete mismatch appears. It already tracks ranges through `Doc` transactions and invalidation callbacks, so folding should not duplicate edit-mapping semantics by hand.

Initial policy on top of range markers:

- If an edit is entirely before a Fold Region, the marker shifts it.
- If an edit is entirely after a Fold Region, leave it.
- If an edit overlaps a Fold Region boundary or content, either expand and remove it, or conservatively remove it.

Prefer conservative removal for the first implementation. Add quiet logs for fold invalidation decisions.

## Implementation phases

### Phase 0: Tests first

Add `tests/lua/ui/docview_folding.lua` with red-green coverage for core behavior.

Initial tests:

1. collapsed fold reduces scrollable visual row count;
2. Fold Widget Row renders/exists at expected visual position;
3. vertical movement skips collapsed content visibly;
4. selection crossing a fold copies hidden text;
5. typing over a selection crossing a fold replaces hidden text;
6. search match inside a fold expands the fold before selecting;
7. clicking a Fold Widget Row expands it;
8. fold ranges are removed or adjusted after edits;
9. same Document in two DocViews can have independent fold state;
10. wrapping plus folding composes correctly;
11. fold range overlap/nesting invariants are enforced;
12. project-search or another representative external navigation path expands a hidden target;
13. Sticky Scroll does not draw/select hidden folded lines;
14. keyboard movement/select/delete commands skip or expand folds according to policy;
15. closing one folded view removes its fold markers without affecting another view of the same Document.

Run targeted tests through:

```sh
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/docview_folding.lua --print-errorlogs
```

### Phase 1: Core fold model and simple unwrapped mapping

- Add fold storage/API to `DocView`.
- Add fold widget style keys/defaults in `data/colors/default.lua` before drawing widgets.
- Implement explicit fold marker ownership and cleanup on fold removal, fold clear, `DocView` close, and `Doc` close.
- Implement collapsed line counting for unwrapped views.
- Wire `get_scrollable_size`, `get_visible_line_range`, `get_line_screen_position`, and `resolve_screen_position` through fold-aware mapping.
- Draw Fold Widget Rows in unwrapped mode.
- Gate user-facing folding while wrapping is active until Phase 3, because line wrapping is enabled by default in `anvil_defaults.lua`.

Do not migrate DiffView yet. Do not expose ordinary editor fold commands beyond test-only/internal APIs until wrapped mapping is supported or explicitly disabled for the view.

### Phase 2: Core selection/search/navigation integration

- Draw selection coverage on Fold Widget Rows.
- Add `select_and_reveal` / `reveal_range` helpers with fold policy options.
- Update keyboard movement/select/delete paths in `data/core/commands/doc.lua` and `DocView.translate` so carets do not land invisibly inside collapsed folds.
- Update first-party local find (`data/plugins/intellij_find.lua`) to expand target folds before selecting matches.
- Update core find/replace and `search_ui` navigation paths to use the same helper.
- Migrate in-repo navigation/result-activation callers that currently do direct `doc:set_selection(...)` plus scroll, including go-to-line, POI, language navigation, diagnostics, project search, file pickers, and navigation/edit-location history.
- Keep these integrations gated from wrapped default Editors until Phase 3 unless the helper expands or rejects folds in wrapped views.

### Phase 3: Wrapped mapping and visual-row consumers

- Compose folds with `core.linewrapping` visual rows.
- Ensure wrapped lines before/after folds map correctly.
- Preserve wrapped line-end affinity outside folded content.
- Update Sticky Scroll (`data/plugins/sticky_scroll.lua`) to consume the fold-aware visual row iterator or skip/expand folded rows deterministically.

This is the highest-risk phase. Keep tests focused on durable behavior, not exact pixel constants.

### Phase 4: Editing/fold invalidation

- Add fold updates after `Doc` transactions for registered views.
- Start conservatively: remove or expand folds touched by edits.
- Keep quiet logs for invalidation decisions.
- Confirm undo/redo and selection-state restoration continue to work.

### Phase 5: Migrate DiffView

- First add a core visual-row extension point capable of representing DiffView gap rows in positioning, hit testing, visible range, and scrollable-size calculations.
- Remove DiffView's fold-specific monkey patches only after gap rows no longer require those same method overrides.
- Keep unchanged-block computation.
- Install core Fold Regions on `doc_view_a` and `doc_view_b`.
- Keep paired fold IDs for synchronized expand/collapse.
- Express DiffView gap rows through the core mapping extension point and keep DiffView-specific connector drawing on top.
- Rewrite existing `diffview_batch.lua` folding tests against the new APIs/behavior, including gaps + folds + wrapping + synchronized scrolling.

### Phase 6: Polish and persistence

- Add manual fold commands/keymaps:
  - `doc:fold-at-caret` (`ctrl+-`),
  - `doc:unfold-at-caret` (`ctrl++` and likely `ctrl+=` where needed),
  - unfold all.
- Implement the provider-based Fold Target resolver using existing Tree-sitter node ranges, outline/document symbols, and text fallback ranges.
- Consider Workspace persistence of manual folds after behavior stabilizes.
- Consider semantic/language folding providers later.

## Open decisions

1. Should clicking a Fold Widget Row always expand, or should gutter/body clicks have different behavior?

2. Should `doc:fold-at-caret` fold an explicit single-line selection, or require multi-line Fold Targets only?
   - Recommended initial policy: multi-line only.

3. Should manual folds persist in Workspace immediately, or wait until core behavior is stable?

4. What should happen when editing inside a collapsed fold through an external operation?
   - Recommended initial policy: expand or remove the touched fold.

5. What visual-row extension API should DiffView use for gap rows?
   - This must be resolved before removing DiffView's mapping overrides.

## Success criteria

- Core `DocView` owns fold state and visual mapping.
- Ordinary Editors can fold text without DiffView.
- Copy/cut/type over folded selections operate on hidden text correctly.
- Search/navigation into hidden text unfolds before landing.
- DiffView uses core folding instead of monkey-patching `DocView` internals.
- Existing DiffView tests continue to pass after migration, with updated expectations where needed.
