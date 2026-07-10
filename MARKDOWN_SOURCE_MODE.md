# Markdown Source Mode

Implemented July 10, 2026 as the third Phase 3 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## View-local override

Source Mode is a property of one Editor (`DocView`), not its shared Document. Switching modes keeps the same view, selection owner, selections, scroll positions, undo history, folds, and semantic model. Split Editors can independently use Live Preview or Source Mode.

In Source Mode the Markdown providers return raw passthrough and no replacement metric. Normal editor syntax highlighting, wrapping, selection, and input behavior remain in charge. Returning to Live Preview invalidates render and metric caches and immediately adopts the current semantic snapshot.

## Commands

The public commands are:

- `markdown-live-preview:toggle-source-mode`
- `markdown-live-preview:source-mode`
- `markdown-live-preview:live-mode`

They apply only to Markdown `DocView` instances. Tests invoke commands rather than asserting configurable key bindings.

## Workspace persistence

`DocView` now offers a generic optional owned-feature state contract:

- `feature:get_state(view)` contributes state under its ownership ID;
- `feature:set_state(view, state)` restores it after the feature attaches; and
- state for lazily attached features remains pending and is replayed by `add_owned_feature`; and
- failures are isolated through quiet diagnostics.

Rendered line-width and maximum-content-width caches are view-local and invalidated with render output, preventing Source Mode in one split from contaminating another split's horizontal scrollbar.

Markdown persists only the temporary `source_mode = true` override. Live Preview remains the absence/default state. Workspace restoration therefore does not hard-code Markdown fields into generic DocView serialization.

## Regression evidence

Focused tests verify command behavior, raw/live rendering transitions, independent split state, owned-feature state round trips, and unchanged selection/scroll state. Existing lifecycle, semantic rendering, image, wrapping, and cache tests continue to pass.
