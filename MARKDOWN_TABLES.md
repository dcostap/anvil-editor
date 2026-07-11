# Markdown table editing

## Semantic presentation

Implemented as the first Phase 7 GFM table slice.

Parser-confirmed GFM table ranges receive a first-party table background while preserving every source line and column. Header cells, body cells, and delimiter rows use distinct source-preserving styles. Cell fragment identity comes directly from Tree-sitter semantic IDs; pipe-shaped text outside a confirmed table remains ordinary Markdown.

Touching a table line uses the safe whole-line Editor path. Malformed/incomplete tables, parser uncertainty, and capture overflow remain raw. Links, images, tags, and other nested inline constructs continue to use the normal semantic fragment composition when their ranges do not conflict with table cell presentation.

The table remains styled source rather than a second grid model. The following commands edit canonical leading/trailing-pipe tables through ordinary Document transactions:

- `markdown-live-preview:table-insert-row`
- `markdown-live-preview:table-delete-row`
- `markdown-live-preview:table-move-row-up` / `table-move-row-down`
- `markdown-live-preview:table-insert-column`
- `markdown-live-preview:table-delete-column`
- `markdown-live-preview:table-move-column-left` / `table-move-column-right`

Row commands preserve existing row text and never delete/move the header or delimiter row. Column commands preserve exact cell interiors, including alignment-marker text, and apply one undoable multi-line transaction. The command context must come from a current semantic table and every affected row must have consistent canonical outer pipes. Optional-pipe, malformed, incomplete, inconsistent, or stale structures are declined instead of normalized or partially rewritten. Pipe discovery ignores escaped pipes and matched backtick runs.

Focused UI coverage verifies header/body semantic cells, delimiter/background styling, non-table boundaries, exact source text, active-line reveal, row insertion/deletion/movement, column insertion/deletion/movement, and undo restoration.
