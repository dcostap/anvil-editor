# Line Wrapping Core Refactor Plan

## Goal

Make soft line wrapping a first-class `DocView` capability instead of a method-patching plugin, with no user-visible regressions and with simpler ownership of wrapping state, navigation, drawing, and performance diagnostics.

The refactor should preserve current Anvil-fork behavior while removing plugin override chains and setting up the later visible-row culling optimization for very long wrapped lines.

## Current State Summary

`data/plugins/linewrapping.lua` currently owns soft wrapping by monkey-patching:

- `Doc.raw_insert`, `Doc.raw_remove`, `Doc.on_text_transaction`, `Doc.on_close`
- `DocView.new`, `DocView.update`, scroll size methods, scrolling helpers
- `DocView.get_visible_line_range`, coordinate/position translation helpers
- mouse handlers for wrapped line-end affinity
- `DocView.draw_line_text`, current-line highlights, line body, overlay, gutter
- `core.doc.translate` start/end-of-line helpers
- many document navigation commands
- `line-wrapping:toggle` command and keymap

`data/plugins/linewrapping_deep_indent.lua` further patches `LineWrapping.compute_line_breaks`, gutter height, and `DocView.draw` to provide deeper continuation indentation and partially cull work to visible logical lines.

Other first-party code already treats wrapping as core state:

- `data/plugins/centered_editor.lua` checks `view.wrapping_enabled` / `view.wrapped_settings` and patches `config.plugins.linewrapping.width_override`.
- `data/plugins/diffview.lua` reads `wrapped_settings`, `wrapped_lines`, and `wrapped_line_to_idx` directly.
- UI tests in `tests/lua/ui/linewrap.lua`, centered editor tests, LSP diagnostic hint/underline tests, and diffview-adjacent code construct or inspect wrapped state.

Recent perf recordings showed two wrapping-specific facts:

1. Wrapping recomputation is not the active bottleneck in the test case.
2. Wrapped drawing can still iterate all ~2000 visual rows of a single logical line when only viewport rows are visible. Core integration should make viewport-aware drawing straightforward.

## Non-Goals

- Do not rewrite wrapping in C in this refactor.
- Do not change default user-visible wrapping behavior, command names, or config names unless explicitly called out below.
- Do not optimize every wrapping hotspot in the same patch. The required performance-sensitive design point is to avoid making visible-row culling harder.
- Do not keep a compatibility plugin that re-patches the old API. This is a first-party fork; update in-repo callers/tests instead.

## Design Principles

1. **Single ownership:** `DocView` owns wrapping state and behavior. `Doc` should not know about every wrapping view except through explicit view registration hooks that already exist or can be core-owned.
2. **No monkey-patch chain:** Replace plugin overrides with direct methods in `data/core/docview.lua`, `data/core/doc/init.lua`, `data/core/doc/translate.lua`, and `data/core/commands/doc.lua` as appropriate.
3. **Small public surface:** expose stable helpers for other first-party modules instead of direct table surgery where possible.
4. **Tests before behavior changes:** move existing linewrap tests to core-facing requirements and add regression coverage for integration points before removing plugin patches.
5. **Visible-row aware model:** expose helpers that can answer logical-line / visual-row ranges efficiently so a follow-up or same refactor can cull long wrapped line drawing.
6. **Keep diagnostic counters:** keep the useful linewrapping perf counters added during investigation, but place them in core-owned code and rename only if all references are updated.

## Proposed Core API / Data Ownership

### `DocView` state

Keep field names initially to minimize broad churn, but make them core-owned:

- `view.wrapping_enabled` — user toggle / requested wrap mode.
- `view.wrapped_settings` — active cache settings, including width and font.
- `view.wrapped_lines` — current compact mapping: pairs of logical line and start col.
- `view.wrapped_line_to_idx` — logical line -> first visual row index.
- `view.wrapped_line_offsets` — continuation x offset per logical line.
- `view.wrapped_line_end_affinity` — caret affinity state at soft-wrap boundaries.

Add core methods around them:

- `DocView:is_wrapping_enabled()`
- `DocView:set_wrapping_enabled(enabled)`
- `DocView:has_wrapping()` / `DocView:is_wrapped()`
- `DocView:update_wrap_cache()`
- `DocView:clear_wrap_cache()`
- `DocView:compute_wrap_width()`
- `DocView:get_total_visual_lines()`
- `DocView:get_visual_row(line, col, line_end)`
- `DocView:get_visual_row_line_col(idx)`
- `DocView:get_visual_row_count_for_line(line)`
- `DocView:get_visual_row_bounds_for_line(line, row_idx)`
- `DocView:iter_visible_wrap_rows_for_line(line, y)` or equivalent for culling.

`DiffView`, tests, and LSP diagnostic tests may continue reading old fields during the first migration, but new code should prefer methods.

### Core config

Keep the existing user-facing table for now:

- `config.plugins.linewrapping.mode`
- `config.plugins.linewrapping.width_override`
- `config.plugins.linewrapping.guide`
- `config.plugins.linewrapping.guide_color`
- `config.plugins.linewrapping.indent`
- `config.plugins.linewrapping.wrapping_indent`
- `config.plugins.linewrapping.enable_by_default`
- `config.plugins.linewrapping.require_tokenization`

This avoids churn in `anvil_defaults.lua`, tests, and centered editor. Later cleanup can rename to `config.line_wrapping` if desired, but not in this refactor.

Move the config spec out of the plugin into a core-owned place. Candidate: keep a tiny `data/plugins/linewrapping.lua` module only as a non-patching config/spec facade during transition, or move config spec registration to a new core module required from startup. Prefer the core module if the settings UI can discover it without plugin metadata; otherwise use a facade module with no method overrides.

### Core module placement

Recommended split:

- `data/core/linewrapping.lua`
  - pure wrapping model helpers, break computation, cache mutation, row/col mapping, affinity helpers.
  - returns a module used by `DocView`, commands, tests, and optional facade.
- `data/core/docview.lua`
  - calls core wrapping helpers directly from native DocView methods.
  - owns drawing integration, scroll sizes, coordinate conversion, visible range, mouse affinity application.
- `data/core/commands/doc.lua`
  - uses DocView wrapping helpers for navigation commands rather than plugin replacing commands.
- `data/core/doc/translate.lua`
  - exposes wrapping-aware start/end-of-line only when an active wrapped DocView context exists, or better moves that context-sensitive behavior into command/view navigation paths so pure doc translation remains pure.

## Migration Phases

### Phase 0: Baseline and test inventory

1. Run and record current focused tests:
   - `meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/linewrap.lua --print-errorlogs`
   - `meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/centered_editor.lua --print-errorlogs`
   - `meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/lsp_diagnostic_hints.lua --print-errorlogs`
   - `meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/lsp_diagnostic_underlines.lua --print-errorlogs`
2. Note known unrelated failures separately. Do not mask regressions introduced by this refactor.
3. Add/update tests for any currently untested behavior before moving code:
   - toggle command preserves scroll/caret semantics.
   - mouse click at visual row end preserves line-end affinity.
   - vertical navigation across wrap boundaries.
   - current-line highlight appears only on the caret visual row.
   - wrapped selection/search background spans correct visual rows.
   - centered editor wrap width still limits to the centered lane.

### Phase 1: Extract pure wrapping model without changing behavior

1. Create `data/core/linewrapping.lua` from the non-patching parts of `data/plugins/linewrapping.lua`:
   - config access helpers.
   - token iteration / `compute_line_breaks`.
   - `reconstruct_breaks`, `update_breaks`, `update_docview_breaks`.
   - row/col mapping helpers.
   - line-end affinity helpers.
2. Integrate the deep-indent behavior directly into the core computation path:
   - support numeric spaces, `"indent"`, `"deepIndent"`, and `"none"` if those values are currently accepted by first-party defaults/tests.
   - preserve the existing `config.plugins.linewrapping.wrapping_indent = 6` default behavior.
   - update the moved config schema/spec so `wrapping_indent` advertises the real accepted union rather than only `number`; the settings UI/config contract must match runtime behavior.
3. Keep exported names temporarily close to the old `LineWrapping` module so existing tests can be updated mechanically.
4. Keep perf counters in the extracted functions.
5. Update `tests/lua/ui/linewrap.lua` to require `core.linewrapping` (or the facade if necessary), but do not yet delete the plugin.

### Phase 2: Convert plugin to facade and move DocView + edit hooks into core atomically

This phase must convert `data/plugins/linewrapping.lua` to a no-patching facade, or update `data/plugins/anvil_defaults.lua` to stop loading it, in the same commit that first adds core wrapping behavior. Do not allow the mandatory defaults path to load both new core methods and the old patching plugin.

The same commit must also replace the old plugin's edit invalidation hooks (`Doc.raw_insert`, `Doc.raw_remove`, `Doc.on_text_transaction`), typed-input affinity hook (`Doc.text_input_by_selection`), wrapping-aware navigation/translate behavior, mouse command affinity handling, and `line-wrapping:toggle` command/keymap registration. Otherwise wrapped views can draw/navigate from stale wrap caches after edits in the intermediate state, or wrapping can draw while visual-line navigation/toggle behavior regresses. Targeted tests are not enough here; validate at least one full-default startup/test path with the facade/no-op module in place.

Replace plugin wrappers with direct logic in `data/core/docview.lua`:

1. `DocView:new`
   - initialize `wrapping_enabled` from config.
   - register the view for doc wrap-cache updates if a per-doc view registry is still required.
2. `DocView:update`
   - update wrap cache when enabled and geometry is valid.
3. Scroll sizing:
   - `get_scrollable_line_count`
   - `get_scrollable_size`
   - `get_h_scrollable_size`
4. Visibility and coordinate mapping:
   - `get_visible_line_range`
   - `get_x_offset_col`
   - `get_col_x_offset`
   - `get_line_screen_position`
   - `resolve_screen_position`
5. Scrolling helpers:
   - `scroll_to_line`
   - `scroll_to_make_visible`
6. Mouse affinity:
   - `on_mouse_pressed`
   - `on_mouse_moved`
7. Drawing:
   - `draw_current_line_highlights`
   - `draw_line_text`
   - `draw_line_body`
   - `draw_overlay`
   - `draw_line_gutter`
   - integrate the deep-indent `DocView:draw` behavior so drawing iterates visible logical lines and is ready to iterate visible visual rows.
8. Ensure centered-editor geometry still wraps the draw through lane geometry rather than plugin-provided wrappers.

During this phase, avoid duplicate wrappers in the normal app, not only in tests. The old plugin should no longer patch `Doc`, `DocView`, translate helpers, or commands once core methods exist. If a temporary `plugins.linewrapping` facade remains for `require` compatibility, it should only return `require "core.linewrapping"` and possibly expose config metadata. If implementation pressure makes command migration impossible in the same commit, the facade may temporarily register commands/keymaps only, but it must not patch `Doc`, `DocView`, or translate helpers; the preferred path is a fully core-owned atomic cutover.

### Phase 3: Harden doc mutation and typed-input core integration

Phase 2 must already provide equivalent core hooks for `Doc.raw_insert`, `Doc.raw_remove`, `Doc.on_text_transaction`, and `Doc.text_input_by_selection`. Use this phase to harden and simplify that integration after the atomic migration, not to introduce it for the first time.

Current plugin patches these methods because wrap caches and soft-wrap boundary affinity are per-DocView. Replace/verify those hooks with core-owned notifications or direct core integration.

Preferred:

- Reuse `DocView.registry` to find views for a doc in `DocView`/core code.
- Add core functions like `DocView.update_wrap_caches_for_doc_raw_insert/remove(doc, ...)`, `DocView.update_wrap_caches_for_doc_transaction(doc, transaction)`, and `DocView.capture_wrap_affinity_after_text_input(doc, result)`.
- Call them from the existing raw edit, transaction, and text-input paths.

Fallback:

- Keep a small core-owned weak registry inside `core.linewrapping`, but register/unregister from `DocView:new` / `DocView:on_close` without patching `Doc` from a plugin.

Rules:

- Do not rely only on `Doc.on_text_transaction`: current raw edit paths still exist, including legacy undo/redo code. Either convert those paths to transactions in the same change or add core-owned raw insert/remove notifications for wrap-cache updates.
- A multi-range transaction should reconstruct affected wrap caches if incremental update is not reliable.
- Single-range transactions should preserve current incremental behavior.
- Preserve the current typed-input soft-wrap boundary affinity behavior from `Doc:text_input_by_selection`; typing at a visual row start created by soft wrapping should keep the caret on the intended previous-row/end affinity when appropriate.
- Add a wrapped undo/redo regression test and keep the existing typed-at-wrap-boundary test passing.
- Closing a doc/view must not leave stale weak references.

### Phase 4: Audit and harden wrapping-aware navigation in core commands

Phase 2 must already preserve wrapping-aware navigation, translate-dependent command behavior, mouse command affinity, and the toggle command/keymap before the old plugin stops owning commands. Use this phase to audit, simplify, and fill gaps in the core command implementation.

1. Update or verify `data/core/commands/doc.lua` command implementations directly instead of replacing command entries from a plugin.
2. Preserve command names and semantics:
   - previous/next visual line navigation.
   - start/end of visual line behavior.
   - selection variants.
   - delete-to-line-boundary commands generated from translate helpers, including `doc:delete-to-end-of-line`, `doc:delete-to-start-of-line`, and indentation delete variants.
   - all consumers of `DocView.translate.previous_line` / `DocView.translate.next_line`, including `doc:split-cursor`, not only the obvious move/select commands.
   - forward endpoint affinity for char/word/block/end-of-doc motions.
   - mouse cursor commands applying resolved line-end affinity.
3. Decide whether `core.doc.translate.start_of_line/end_of_line/start_of_indentation` should remain pure logical-line helpers. Prefer command-level wrapping when a `DocView` context is available, but explicitly update every command that currently receives visual-row semantics through the plugin's global translate patch.
4. Decide whether `DocView.translate.previous_line/next_line` should become wrapping-aware core helpers or whether each caller should be updated. Do not miss indirect callers such as split cursor.
5. Ensure non-DocView uses and unwrapped views keep existing behavior.
6. Confirm typed-input affinity remains covered even though it is not a command path; it belongs to Phase 2/3 but is a navigation/caret regression risk.

### Phase 5: Update or remove plugins

1. Replace `data/plugins/linewrapping.lua` with either:
   - nothing, if all `require "plugins.linewrapping"` users/tests are migrated, or
   - a tiny facade that returns `require "core.linewrapping"` and registers config metadata only, without monkey-patching.
2. Remove or fold `data/plugins/linewrapping_deep_indent.lua` into core:
   - update tests to stop requiring it separately.
   - remove plugin if no longer referenced.
3. Update `data/plugins/anvil_defaults.lua`:
   - stop `require_core_plugin "linewrapping"` if no plugin remains.
   - keep config defaults and command/keymap registration in core/defaults.
4. Update `data/plugins/centered_editor.lua`:
   - stop patching `config.plugins.linewrapping.width_override` if possible.
   - prefer a core hook like `DocView:compute_wrap_width()` that checks `core.centered_editor` or an explicit callback registered by centered editor.
   - keep centered editor tests passing.
5. Update `data/plugins/diffview.lua` to use core wrapping helper methods where reasonable.
6. Update tests that require old plugin modules.

### Phase 6: Visible-row culling and performance verification

Once wrapping is core-owned, implement or enable culling in the draw path:

1. Calculate the visible visual row range from content bounds and line height.
2. For a logical line with many wrap rows, draw only rows intersecting the viewport.
3. Cull wrapped selection/search/highlight/diagnostic/line-hint work to visible rows where possible.
4. Include custom draw paths, especially `data/plugins/diffview.lua`, whose per-instance document view draw methods can bypass `DocView:draw` and call `draw_line_body` directly. Either refactor DiffView to use shared core wrapped-row drawing helpers or update its custom draw loop to pass/cull visible wrapped rows explicitly.
5. Keep line hint behavior on the final visible or logical row as currently intended; add tests for hints on wrapped long lines.
6. Record a new perf capture on the original slow scenario:
   - expect `linewrapping_draw_line_text_rows` and `renderer.draw_text_known_bounds` calls to drop from thousands to roughly viewport-size counts.
   - ensure tab update remains fast after the recent tab caching work.

## Regression Risks and Mitigations

### Risk: Plugin load order behavior changes

Mitigation:

- Remove dependency on load order by placing wrapping behavior in core methods.
- Convert/remove the old plugin in the same phase as core method integration so normal defaults cannot stack old wrappers on new methods.
- Keep a temporary facade only for module resolution, not behavior patching.
- Run tests with full defaults and targeted direct requires.

### Risk: Centered editor wrapping width changes

Mitigation:

- Add/keep tests for centered editor wrap width.
- Move `width_override` behavior into a named core hook or a documented callback rather than global monkey-patching.

### Risk: Existing tests or modules construct wrapped fields manually

Mitigation:

- Keep old field names initially.
- Add helper constructors in tests only after behavior is stable.
- Update direct field users gradually.

### Risk: Navigation, typing, or undo regress at soft-wrap boundaries

Mitigation:

- Preserve line-end affinity state and add targeted tests for:
  - clicking at wrap ends.
  - typing at a soft-wrap row start.
  - undo/redo or raw edit paths after wrapping has been computed.
  - moving left/right across soft-wrap row starts.
  - end-of-line twice at soft-wrap vs logical line end.
  - delete-to-start/end-of-line and indentation delete commands under wrapping.
  - select variants and primary selection updates.

### Risk: Selection/search/diagnostic rendering regressions

Mitigation:

- Test drawing state rather than exact pixels where possible.
- Keep existing LSP diagnostic hint/underline tests passing.
- Add long-line viewport culling tests that assert offscreen rows do not trigger draw calls but visible rows still render.

### Risk: DiffView wrapping assumptions break

Mitigation:

- Audit `data/plugins/diffview.lua` direct use of `wrapped_lines` and `wrapped_line_to_idx`.
- Add a focused diffview test if none exists for wrapped files.

## Validation Checklist

After each phase that changes behavior:

```sh
./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua \
  data/core/docview.lua data/core/linewrapping.lua data/core/commands/doc.lua \
  data/core/doc/translate.lua data/plugins/anvil_defaults.lua \
  data/plugins/centered_editor.lua data/plugins/diffview.lua

PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 anvil:lua-ui --test-args ui/linewrap.lua --print-errorlogs
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 anvil:lua-ui --test-args ui/centered_editor.lua --print-errorlogs
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 anvil:lua-ui --test-args ui/lsp_diagnostic_hints.lua --print-errorlogs
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 anvil:lua-ui --test-args ui/lsp_diagnostic_underlines.lua --print-errorlogs
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 anvil:lua-ui --test-args ui/node_tabs.lua --print-errorlogs
```

Before finalizing:

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 --suite anvil --print-errorlogs
```

If non-Lua files are edited later, run the portable update BAT. This plan is Lua-only unless native renderer or C APIs are introduced, which is explicitly out of scope.

## Suggested Commit Boundaries

1. Add core wrapping module and tests with old plugin still present.
2. Atomic core cutover: move DocView integration, doc mutation hooks, typed-input affinity, wrapping-aware navigation/translate behavior, mouse command affinity, toggle command/keymap registration, and defaults/plugin facade changes together so the normal app never runs with half-migrated wrapping.
3. Audit/harden navigation and mutation edge cases, update callers/tests, and remove any temporary facade command registration if used.
4. Remove/finalize old plugin facades, fold deep-indent fully into core, and update remaining defaults/callers/tests.
5. Add visible-row culling and perf validation.
