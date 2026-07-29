# Markdown Live Preview Native Layout Performance

Implemented July 29, 2026.

## Permanent benchmarks

`tests/lua/benchmarks/markdown_live_layout.lua` covers the two cold paths that were previously absent from the regular Markdown render benchmark:

- whole-Document visual-metric initialization for a 100 KiB rich Markdown Document;
- rendered wrapping for 1,000, 2,000, and 4,000-byte source-preserving lines.

`tests/lua/benchmarks/markdown_semantic_model.lua` also reports a normalized 60-line semantic-node query.

## Native text layout

Fonts expose `font:text_layout(text, options)`. The returned native layout stores UTF-8 byte boundaries and cumulative advances and provides:

- `width()`;
- `width_at(byte_offset)`;
- `byte_at_x(x)`;
- `wrap(width, mode, start_byte, first_leading, continuation_leading)`.

`DocView` caches one native layout per normalized rendered fragment. Column mapping and hit testing consume that layout instead of allocating substrings and repeatedly crossing from Lua into the renderer. A source-preserving single-fragment rendered line uses the native wrapping scan directly. Mixed hidden/widget/font fragments retain the general source-column mapping path, but each visible text fragment still has linear-time native advances.

## Shared presentation and sparse metrics

Markdown metric calculation resolves the line through `DocView:get_line_render()`. Drawing and metrics therefore consume the same cached fragments, widgets, table layout, and inline-image rows instead of constructing those presentations independently.

Visual metric providers may publish a complete sparse descriptor with a default height and exceptional lines. For unwrapped Markdown Live Preview, ordinary prose uses the body-height default while headings, code, tables, images, math, and raw semantic blocks are measured explicitly. The Fenwick tree is built linearly after heights are known. Wrapped Documents retain per-row measurement because one source line can own several different visual rows.

Diagnostics now include `metric_provider_queries` and `metric_sparse_skips`.

## Native semantic normalization

The native Tree-sitter result handle exposes `semantic_nodes_for_lines()`. It performs line-index lookup, extension-conflict suppression, parent-node normalization, marker/content association, attribute construction, and deduplication before creating Lua node tables. `core.markdown.model` stabilizes IDs on those normalized nodes and no longer materializes full capture tables merely to build a second Lua representation.

## Measured result

The permanent focused benchmark reported:

| Path | Previous diagnostic | Current |
|---|---:|---:|
| 1,201-line cold metrics | 357.0 ms | 47.370 ms |
| Render 60 lines after metrics | 21.7 ms | 1.445 ms |
| 1,000-byte rendered wrap | 18.8 ms | 0.148 ms |
| 2,000-byte rendered wrap | 72.5 ms | 0.102 ms |
| 4,000-byte rendered wrap | 262.6 ms | 0.145 ms |
| Normalized 60-line semantic query | 11.2 ms | 0.466 ms (100 KiB fixture) |
| 303-line cold semantic wrap reconstruction | 72.656 ms | 48.434 ms (median of 3) |

The cold metric run made 156 provider queries and skipped 1,045 ordinary rows. Warm-cache behavior remains covered by `markdown_live_render.lua`.

## Validation

Focused validation covers native text layout behavior, Markdown model normalization and stable identities, generic rendered-fragment mapping, the complete Markdown Live Preview UI file, and both permanent benchmark files.

## Publication callback drilldown

Performance recordings retain the thirty slowest Markdown model publications and the thirty slowest Live Preview publication listeners. Summary rows share the performance-clock timestamp used by slow-frame rows and identify the Document path, byte/line count, generation, revision, incremental/full status, changed range, and native parse/total time.

Model publication rows split time across native-result summary access, previous-result release, state publication, and listener notification, including the slowest listener ID and elapsed time. Per-view listener rows split reset work, fenced-code reconciliation, semantic range/table expansion, image-reference pruning, line-render invalidation, and visual-metric invalidation. They also record wrapping state, active/visible state, view width, publication range/line counts, and whether publication used a global invalidation.

The first drilldown recording identified line-render invalidation as the publication bottleneck: 771.378 ms of 771.865 ms across twelve Live Preview listeners. Result adoption, result release, fenced-code reconciliation, semantic range expansion, image pruning, and metric invalidation were negligible.

Mixed-fragment wrapping now uses a monotonic source-column width cursor so it does not restart the fragment search at every UTF-8 boundary. Full wrapped reconstruction builds its flat row arrays and logical-line index directly in one pass. The Markdown provider also reuses the semantic/fence context already computed for a line's render signature when building that line's presentation. Rendered-line native and cursor branches are now included in linewrap timing and slow-call diagnostics; earlier recordings accidentally omitted those early-return paths.

The corrected wrapping attribution showed that active, visible views still spent up to 94.750 ms synchronously rebuilding initial semantic wrapping, with individual rendered lines occasionally taking 10–14 ms. Whole-Document semantic publication reconstruction is therefore prepared in bounded main-thread slices. The previous wrapped layout remains readable while new row arrays are built, and the completed arrays are adopted atomically. A completion callback invalidates visual metrics against the committed row map. Text revisions and replacement reconstructions cancel stale work.

Recordings report sliced reconstruction calls, processed lines, work time, yields, commits, and cancellations separately. This keeps publication callbacks near one slice rather than charging every logical line to one worker-pool callback; an unusually expensive single line can still exceed the target slice and remains visible in the slow-line table.

## Pathological table cells and very long wrapped lines

The `Alintra system.md` recording exposed a separate content-shaped case: a 354,944-byte Document had only fourteen logical lines, including four approximately 88.7 KiB table-like rows. One cell contained an inline base64 data-image URI and the surrounding exported table rows were padded to the same source width.

The old table word wrapper repeatedly concatenated and remeasured every growing prefix of an unbroken cell, making the data URI quadratic. One line consumed 896 ms inside publication. A malformed/padded row then produced 1,058 soft-wrap rows; a visual-metric rebuild resolved the same logical-line presentation once per soft row, contributing 10.48 seconds across the recording. Alternating host and centered-editor geometry also replaced the single table-layout cache bucket.

Table cell wrapping now consumes native text-layout wrap points. Inline data images are represented by a short embedded-image label, and any other cell beyond 4 KiB receives a bounded presentation rather than rendering its entire payload. Table layouts retain separate geometry buckets. Line-render cache hits compare the immutable source-line string directly instead of rebuilding a signature containing the complete source text. Visual metric providers can publish one logical-line descriptor for all its wrapped rows; Markdown uses that seam to resolve ordinary and final-row heights once per logical line.

A focused run against the reported file reduced cold visual-metric construction from the recording's multi-second behavior to 4–7 ms, while preserving its 1,071 source-derived visual rows. The permanent UI regression verifies that embedded table-image payloads do not become rendered cell text.

## Follow-up complexity audit

A codebase audit identified additional algorithmic-risk leftovers. Diff LCS, inline-diff, and diff-gap findings are intentionally being handled by the separate Myers/histogram diff redesign rather than changed here.

The non-diff findings addressed here are:

- clearing wrapping now invalidates any pending sliced reconstruction, preventing stale work from restoring wrapping after it was disabled;
- native text layouts expose a retained monotonic width cursor, making mixed-fragment source-column scans linear rather than performing one binary search per UTF-8 boundary;
- rich Markdown presentation falls back to the bounded source path for a logical line beyond 64 KiB, so one line cannot hide an arbitrarily expensive semantic/table presentation inside a nominal reconstruction slice;
- table geometry variants use a four-entry LRU instead of retaining every transient viewport width during resize;
- extension-span suppression in native semantic normalization uses sorted interval indexes and binary containment queries instead of comparing every capture with every extension parent.
