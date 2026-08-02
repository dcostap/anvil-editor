# Render Widget Input Contract

Implemented July 10, 2026 as the fifth Phase 2 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Generic DocView routing

Rendered fragments may expose a `widget` with:

- `width` / `height` and optional padding/layout offsets;
- optional `wrapping = "inline"` for one-row atomic widgets that can safely
  participate in rendered-width wrapping;
- `cursor` for hover feedback;
- `draw(...)`; and
- `on_mouse_pressed(widget, view, hit, button, x, y, clicks)`.

`DocView:get_render_widget_at_position()` resolves line geometry and fragment layout once. When widgets overlap, the last-drawn widget receives the hit, allowing transient controls to sit above decorative widgets. Core mouse movement applies the widget cursor, and core mouse press dispatches through the callback before ordinary text selection/fold handling. Failures are isolated through quiet diagnostics.

This removes Markdown-specific global wrappers around `DocView.on_mouse_moved` and `DocView.on_mouse_pressed`.

Rendered lines may also expose `on_text_input(...)` and
`on_ime_text_editing(...)` when a source-backed interaction needs to normalize
all text-entry paths consistently. The IME hook returns adjusted composition
offsets when normalization changes source byte lengths, such as escaping a
table pipe. Source Mode and ordinary rendered lines continue through the
standard Document input paths.

## Intra-line caret rows

A rendered Document line that places editable text in more than one vertical
location may expose `render_line.position_rows`. Each row owns a half-open
source-column range plus `y_offset` and `height`. DocView uses that one mapping
for caret placement, pointer hit testing, vertical navigation, Home/End
boundaries, selection painting, and Current Line Highlight geometry.

Shared source columns at a row boundary use view-local affinity, analogous to a
soft-wrap boundary, so moving into a suffix row does not jump back to the row
above merely because revealing Markdown source rebuilt the render fragments.
Rows may override Current Line Highlight geometry with `highlight_y_offset` and
`highlight_height`. Inline image layout uses this only for the prefix row: a
prefix caret highlights the complete prefix/image/suffix presentation, while a
caret in text below the image highlights only that text row.

Rows may also provide `hit_x1` / `hit_x2` when several independently editable
regions share one vertical band, as in an interactive table row. Vertical
navigation can keep moving inside one region through `navigation_group` and
`navigation_index`, then choose the horizontally nearest region when it crosses
to another Document line. `position_rows_draw_full_line` allows these caret
regions to coexist with one full-line fragment draw, so table borders and cell
backgrounds are painted once rather than once per caret region.

Fragment backgrounds may opt into drawing below ordinary selection geometry.
Interactive table cells use that layer so partial text selections stay visible,
while complete Table Cell Selections additionally receive a cell outline.

The regression fixture uses `aaaa ![[image.png]] Testing this change`. Before
the caret-row integration, the suffix highlight inherited the complete image
height, Up skipped the suffix, and Shift+Home selected from source column 1.
Focused tests now cover both wrapping modes, bidirectional vertical movement,
suffix-only Home selection, and row-local selection painting.

Text segments above and below an inline image own their wrapping internally so
the block image remains atomic while surrounding prose can still produce more
caret rows at the editor edge. Optimistic same-line edits rebuild this row
layout immediately from the transformed render fragments. The caret therefore
keeps text height, and newly typed suffix text wraps before the asynchronous
Markdown semantic publication completes.

## Image integration

Markdown image fragments now use the generic contract. Their widget requests the hand cursor and opens the existing full-window image overlay on left click after moving the source selection to the image line. `live_render.image_at_position()` remains a narrow query helper implemented on top of the generic hit result, not a separate geometry implementation.

## Red-green evidence

A generic render-fragment test first failed because widget hover remained `ibeam` and clicks entered text selection. It now verifies cursor and click dispatch through only public DocView event methods. Existing Markdown image hover, overlay-open, drawing, and close tests continue to pass after deleting the Markdown mouse wrappers.
