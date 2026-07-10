# Render Widget Input Contract

Implemented July 10, 2026 as the fifth Phase 2 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Generic DocView routing

Rendered fragments may expose a `widget` with:

- `width` / `height` and optional padding/layout offsets;
- `cursor` for hover feedback;
- `draw(...)`; and
- `on_mouse_pressed(widget, view, hit, button, x, y, clicks)`.

`DocView:get_render_widget_at_position()` resolves line geometry and fragment layout once. Core mouse movement applies the widget cursor, and core mouse press dispatches through the callback before ordinary text selection/fold handling. Failures are isolated through quiet diagnostics.

This removes Markdown-specific global wrappers around `DocView.on_mouse_moved` and `DocView.on_mouse_pressed`.

## Image integration

Markdown image fragments now use the generic contract. Their widget requests the hand cursor and opens the existing full-window image overlay on left click after moving the source selection to the image line. `live_render.image_at_position()` remains a narrow query helper implemented on top of the generic hit result, not a separate geometry implementation.

## Red-green evidence

A generic render-fragment test first failed because widget hover remained `ibeam` and clicks entered text selection. It now verifies cursor and click dispatch through only public DocView event methods. Existing Markdown image hover, overlay-open, drawing, and close tests continue to pass after deleting the Markdown mouse wrappers.
