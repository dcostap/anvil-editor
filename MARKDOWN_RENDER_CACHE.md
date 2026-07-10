# Markdown Live Preview Render Caching

Implemented July 10, 2026 as the second Phase 2 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Line render cache

`DocView:get_line_render(line)` now caches the resolved provider output—including intentional raw/nil results—per source line. Cache identity includes:

- source text and Document text revision (covering contextual, reload, and legacy raw-edit changes);
- provider registration/generation;
- provider priority; and
- provider-specific `line_generation(view, line)` state.

Repeated coordinate mapping, hit testing, and drawing therefore share one provider result instead of reparsing the same line independently. `invalidate_line_render(provider_id, line1, line2)` invalidates a target range; the no-range form remains a full invalidation for provider/schema changes and contextual text transactions.

## Range-based visual metrics

Unwrapped visual metrics now use a Fenwick height index with logarithmic prefix lookup and y-position search. Initial construction still measures each row once, but targeted invalidation recomputes only dirty rows and updates prefix heights in logarithmic time. Caret movement in Markdown Live Preview invalidates the old/new selected lines rather than rebuilding metrics for the Document.

Wrapped/composed-row invalidation conservatively uses the full path until the wrapping integration slice owns source/render row mapping.

## Markdown provider integration

The Markdown provider exposes active/inactive state through `line_generation`. A view-local selection listener targets old/new selection lines in both caches. Shared async image entries track every consuming line and invalidate all occurrences on completion. Metadata changes and contextual text transactions still invalidate conservatively for correctness. Existing visual-metric provider `generation(view)` values remain part of the global metric signature.

## Diagnostics

`DocView:get_render_cache_diagnostics()` reports:

- line cache hits/misses;
- line invalidations;
- metric recomputations; and
- metric invalidations.

These are counters, not timing assertions.

## Red-green evidence

Before implementation, the baseline caret test recomputed all 80 Document rows and repeated line rendering across coordinate mapping and draw paths. The updated tests failed with 80 recomputations and multiple provider calls. After implementation, the same caret move recomputes exactly the old/new rows, and mapping plus drawing shares one provider render.

Focused generic render-fragment, variable-row, Markdown baseline, and Markdown Live Editor UI suites pass.
