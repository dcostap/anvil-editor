# Markdown table editing

## Semantic presentation

Implemented as the first Phase 7 GFM table slice.

Parser-confirmed GFM tables render as compact aligned grids while inactive. SemiBold header and body cells share measured per-column widths and honor delimiter-row left/center/right alignment, source pipes become subtle renderer-drawn outer and per-cell grid borders that do not depend on font glyph coverage, and the delimiter source row becomes the horizontal rule between header and body instead of a padded text row. Cells use neutral backgrounds, proportional horizontal padding, and vertical breathing room rather than accent-colored headers and dense Editor-height stripes. Whole-cell inline code hides its backtick markers, uses the normal code face/background, and remains an unbroken inline-code chip. The grid occupies only its natural measured content width when it fits rather than painting a full-width Editor background. Pipe-shaped text outside a confirmed table remains ordinary Markdown.

Tables may use the full editor viewport even when prose uses a narrower configured wrap column. When the natural grid is still wider than that viewport, flexible columns shrink toward header- and unbreakable-code-aware minimum widths and ordinary cell text wraps internally. Every logical table row remains one source/wrapping row while its visual-row height expands to the tallest wrapped cell. Borders and every following column therefore stay aligned across continuation text instead of allowing the generic Document line wrapper to restart content at the editor margin. Width changes and viewport changes participate in each line's render-cache identity, ensuring every row adopts one table layout instead of mixing stale widths. The compact delimiter source row is too short to contain gutter text, so its line number is intentionally suppressed instead of overlapping the following row's number.

Cell fragments retain explicit displayed-text source bounds after whitespace trimming and inline-code marker removal, including a valid zero-width position for empty cells. Every internal wrapped text line also retains its own source range, so pointer resolution uses both the cell's horizontal position and the clicked continuation row. Multiline fragments paint and advance by their assigned column width rather than their unwrapped source width, keeping every later border fixed. Focusing any table row reveals that row's complete source and restores normal raw-row metrics; in particular, an active delimiter row is never left at its compact one-pixel presentation height. Edits touching a resident table invalidate that complete table's layout while unrelated edits leave its measured layout cached.

Touching a table line uses the safe whole-line Editor path, so its exact source and caret geometry return immediately while the other rows stay aligned. Width changes invalidate and remeasure the complete semantic table. Escaped pipes and matched backtick runs do not split cells. Inconsistent, oversized, malformed/incomplete tables, parser uncertainty, and capture overflow remain raw.

The presentation remains a source-mapped grid rather than a second editable data model. The following commands edit canonical leading/trailing-pipe tables through ordinary Document transactions:

- `markdown-live-preview:table-insert-row`
- `markdown-live-preview:table-delete-row`
- `markdown-live-preview:table-move-row-up` / `table-move-row-down`
- `markdown-live-preview:table-insert-column`
- `markdown-live-preview:table-delete-column`
- `markdown-live-preview:table-move-column-left` / `table-move-column-right`

Row commands preserve existing row text and never delete/move the header or delimiter row. Column commands preserve exact cell interiors, including alignment-marker text, and apply one undoable multi-line transaction. The command context must come from a current semantic table and every affected row must have consistent canonical outer pipes. Optional-pipe, malformed, incomplete, inconsistent, or stale structures are declined instead of normalized or partially rewritten. Pipe discovery ignores escaped pipes and matched backtick runs.

Focused UI coverage verifies aligned header/body cells, padded neutral presentation, internal multi-line cell drawing with one source wrapping row, variable row height, compact delimiter and bounded backgrounds, active-line reveal, whole-table and viewport width remeasurement, row insertion/deletion/movement, column insertion/deletion/movement, and undo restoration.
