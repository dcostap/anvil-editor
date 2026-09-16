# Semantic Markdown Rendering Bridge

Implemented July 10, 2026. Simplified September 16, 2026.

## Semantic authority

The native Tree-sitter Markdown model is the only authority that selects Markdown presentation or hides source syntax.

Each Markdown Buffer owns one semantic model. Editors share its immutable native snapshot. Each Editor keeps its own reveal state, render cache, metrics, widgets, and interaction state.

Native incremental results publish the semantic line range changed by Tree-sitter. The model merges that range with the Buffer transaction range. Editors invalidate the complete semantic range after publication. This includes dependencies such as a Setext title above its edited marker.

## Edit projection

An edit can occur before the worker publishes current semantics. This interval uses a non-semantic edit projection.

The projection can:

- map an unchanged source line to its new line number;
- retain an exact render and its resolved metrics for unchanged source;
- apply a text edit inside one ordinary visible fragment;
- split a retained render when one edit splits its source line;
- retain known image, callout, table, and code-block presentation from the previous snapshot;
- show current source when a safe edit mapping is not available.

The projection cannot recognize a new heading, list, comment, link, callout, fence, table, or inline construct. It cannot hide new syntax. New syntax remains readable until the native model publishes it.

`data/core/markdown/edit_projection.lua` only maps transaction lines and detects link-target changes for cache invalidation. It does not parse Markdown presentation.

The old `pending_render.lua` source parser and provisional block-topology scanner were removed. This removed the parallel Markdown presentation engine.

## Parse scheduling

A model whose previous native publication took at most 8 ms dispatches its next edit immediately. Slower models retain the 15 ms debounce and worker cancellation path.

All parsing stays on the worker. Large Buffers cannot block the UI thread.

Measurements on the development machine showed:

- normal incremental native parse p50: 1 ms;
- normal incremental native parse p95: 2 ms;
- normal incremental native total p95: 4 ms;
- 10 KiB immediate worker publication: usually 2–3 ms;
- 100 KiB immediate worker publication: usually one 16 ms frame;
- 1 MiB immediate worker publication: approximately 79–131 ms.

The large path therefore stays asynchronous and cancellable.

## Render and metric ownership

A cached line render remains the common source for drawing, wrapping, hit testing, selection geometry, caret geometry, and IME geometry.

Unchanged source retains its last resolved geometry during an edit. Changed source uses mapped fragments or readable source. Semantic publication replaces affected fragments and metrics together while preserving the viewport anchor.

Interactive Table Editing keeps its explicit row projection. It edits an existing semantic table model and does not classify new Markdown tables.

## Behavioral contract

Tests require these rules:

- changed source never disappears while semantics are pending;
- new Markdown syntax stays raw until native semantics publish;
- source created after a line split does not inherit presentation from the old line;
- ordinary text inside an existing presentation keeps that presentation;
- unchanged shifted rows retain their render and geometry;
- native semantic ranges invalidate dependencies outside the direct edit line;
- published semantics replace retained or source presentation;
- no pending path parses Markdown formatting.

The focused model, Live Preview, edit-matrix, pending-visual, heading, wrapping, list, link, and table tests cover these transitions.
