# Markdown Live Preview Lifecycle

Implemented July 10, 2026 as the first Phase 2 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Document metadata contract

`core.doc` now owns filename and syntax transitions instead of requiring consumers to poll or monkey-patch setters.

Per-Document observers use:

```lua
doc:add_metadata_listener(id, function(doc, event) ... end)
doc:remove_metadata_listener(id)
```

A `set_filename()` operation publishes one batched `metadata` event after syntax detection, with old/new filename, absolute filename, and syntax values plus `filename_changed` and `syntax_changed` flags. `set_syntax()` and `reset_syntax()` publish the same shape for direct syntax transitions. Document closure publishes a `close` event and clears the listener table.

Listener failures are isolated and recorded through `core.log_quiet(...)`.

## Semantic-model lifecycle

The shared per-Document Markdown semantic model owns one metadata listener while it exists:

- Markdown → non-Markdown cancels pending work, releases the native result, and enters `detached` immediately.
- Non-Markdown → Markdown re-enters `pending` and publishes a fresh revision/metadata-checked result.
- Markdown filename/syntax changes resubmit automatically so relative-path consumers and published metadata cannot remain stale.
- Document close cancels work, releases native ownership, removes the listener, and removes the model from the weak registry.

## Editor feature ownership

Every encountered `DocView` receives independent Markdown Live Preview lifecycle ownership, even while the feature is ineligible for that Document. This lets an already-open `.txt` view attach immediately when renamed to `.md`, and lets all split views detach together on the reverse transition.

Provider attachment remains view-local. `DocView` now exposes generic owned-feature registration/removal/release hooks; confirmed close, singleton Main Editor replacement, bulk Node closure, and core Node/Main Editor/Side Editor removal paths release those features. Live Preview uses that contract to remove metric/render providers and metadata listeners when one split closes even if another keeps the Document alive.

Eligible Markdown-to-Markdown metadata changes invalidate line-render and visual-metric caches. Filename/syntax changes also discard path-dependent image resolution entries, so moving a note cannot retain images resolved relative to its old directory.

## Red-green evidence

Before implementation:

- `runtime/doc_metadata.lua` failed because `Doc:add_metadata_listener` did not exist;
- the semantic-model lifecycle test remained `ready` after a Markdown → text rename; and
- the UI lifecycle test remained attached until manual `refresh_view()`; and
- the owned-feature close test failed because `DocView:add_owned_feature()` did not exist.

After implementation, the focused Document metadata, Markdown model, and Markdown Live Editor UI suites pass, including split-view and close cleanup coverage.
