# Markdown table editing

## Semantic presentation

Implemented as the first Phase 7 GFM table slice.

Parser-confirmed GFM table ranges receive a first-party table background while preserving every source line and column. Header cells, body cells, and delimiter rows use distinct source-preserving styles. Cell fragment identity comes directly from Tree-sitter semantic IDs; pipe-shaped text outside a confirmed table remains ordinary Markdown.

Touching a table line uses the safe whole-line Editor path. Malformed/incomplete tables, parser uncertainty, and capture overflow remain raw. Links, images, tags, and other nested inline constructs continue to use the normal semantic fragment composition when their ranges do not conflict with table cell presentation.

The current slice intentionally remains styled source rather than replacing the block with a second grid model. Row/column editing commands are the next table slice; they must edit the Document through ordinary transactions and fall back rather than serialize uncertain structures.

Focused UI coverage verifies header/body semantic cells, delimiter/background styling, non-table boundaries, exact source text, and active-line reveal.
