# Markdown table editing

## Semantic presentation

Implemented as the first Phase 7 GFM table slice.

Parser-confirmed GFM tables render as compact aligned grids while inactive. Bold header and body cells share measured per-column widths and honor delimiter-row left/center/right alignment, source pipes become renderer-drawn grid borders that do not depend on font glyph coverage, and the delimiter source row becomes the horizontal rule between header and body instead of a padded text row. The grid occupies only its measured content width rather than painting a full-width Editor background. Pipe-shaped text outside a confirmed table remains ordinary Markdown.

Touching a table line uses the safe whole-line Editor path, so its exact source and caret geometry return immediately while the other rows stay aligned. Width changes invalidate and remeasure the complete semantic table. Escaped pipes and matched backtick runs do not split cells. Inconsistent, oversized, malformed/incomplete tables, parser uncertainty, and capture overflow remain raw.

The presentation remains a source-mapped grid rather than a second editable data model. The following commands edit canonical leading/trailing-pipe tables through ordinary Document transactions:

- `markdown-live-preview:table-insert-row`
- `markdown-live-preview:table-delete-row`
- `markdown-live-preview:table-move-row-up` / `table-move-row-down`
- `markdown-live-preview:table-insert-column`
- `markdown-live-preview:table-delete-column`
- `markdown-live-preview:table-move-column-left` / `table-move-column-right`

Row commands preserve existing row text and never delete/move the header or delimiter row. Column commands preserve exact cell interiors, including alignment-marker text, and apply one undoable multi-line transaction. The command context must come from a current semantic table and every affected row must have consistent canonical outer pipes. Optional-pipe, malformed, incomplete, inconsistent, or stale structures are declined instead of normalized or partially rewritten. Pipe discovery ignores escaped pipes and matched backtick runs.

Focused UI coverage verifies aligned header/body cells, compact delimiter and bounded backgrounds, active-line reveal, whole-table width remeasurement, row insertion/deletion/movement, column insertion/deletion/movement, and undo restoration.
