# Semantic Markdown Rendering Bridge

Implemented July 10, 2026 as the sixth Phase 2 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Shared model ownership

Every attached Markdown Live Preview `DocView` subscribes to the shared per-Document `core.markdown.model`. Split views retain independent listeners and view-local caches while sharing native parse snapshots. Detach and owned-feature release remove the listener deterministically.

The first async publication invalidates the view and establishes semantic render identities. Later publications use changed ranges. A view records the earliest edited suffix while a model is pending so lines rendered from the conservative fallback cannot remain permanently without current semantic identities after a structural edit.

## Semantic identity bridge

The existing Phase 2 renderer remains deliberately narrow, but heading render lines and emphasis fragments now adopt stable IDs from semantic nodes. This includes emphasis nested inside headings and triple-delimiter strong/emphasis reconciliation. Render results expose the semantic generation used to construct them.

The local prototype parser remains as the conservative rendering fallback while the semantic model is cold, pending, unavailable, or while syntax families have not yet migrated. Removing that fallback is Phase 3 work, not hidden in this bridge.

## Contextual invalidation

A generic line-render-provider transaction hook can widen ordinary changed-line invalidation. Markdown widens edits to the suffix because fenced/raw-block and reference context can affect later lines. Sparse line-render caches clear only resident entries in that range. Line-count changes already invalidate shifted suffixes; semantic publication now also re-adopts those suffixes after pending fallback rendering.

Line cache signatures no longer include the global Document revision. Source text, explicit transaction ranges, provider generations, metadata/provider changes, selection state, and async publication notifications are the authoritative invalidation seams. Legacy raw insert/remove and full load/reload paths now publish the same transaction contract (without duplicate wrapping work), so undo, reload, Tree-sitter, range observers, and the Markdown model cannot bypass cache/model refresh. Identical reloads still publish a full-refresh transaction because `Doc:reset()` advances the revision. Snapshot transactions distinguish changed content so range markers invalidate on unrelated replacement text but survive an identical reload. Views attached while a shared model is already pending conservatively invalidate their whole fallback cache on the first publication. This preserves unaffected cached lines across same-line edits without accepting stale contextual Markdown.

## Regression and benchmark evidence

Red-green tests cover:

- heading and inline semantic identity adoption;
- heading-contained and triple-delimiter emphasis identities;
- retention of an unaffected heading cache entry across a same-line edit/publication;
- semantic re-adoption after a line-shifting edit rendered while pending; and
- a fence edit changing a later line from raw passthrough to rendered heading.

The representative 100 KiB benchmark (`tests/lua/benchmarks/markdown_live_render.lua`) measured on July 10, 2026:

- 102,482 bytes / 1,201 lines;
- cached 60-line viewport query p95: **0.378 ms**;
- caret-transition render/update p95: **0.148 ms**.

The benchmark reports timings rather than asserting brittle machine-specific thresholds. Both observed p95 values are below the Phase 2 2 ms viewport and 3 ms caret targets.
