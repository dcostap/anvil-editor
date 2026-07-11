# Markdown note, heading, and block embeds

Implemented as the Phase 7 internal-note embed slice.

## Presentation

Resolved `![[Note]]`, `![[Note#Heading]]`, current-note heading embeds, and `![[Note#^block-id]]` retain their editable source line and add bounded composed visual rows beneath it:

- note embeds publish up to three representative non-empty source lines;
- heading embeds publish up to two non-empty lines within that heading section;
- block embeds publish the referenced source line without its block ID.

Preview lines are extracted cooperatively while the Project Markdown index already owns the note text. Rendering never synchronously opens or scans a target file. Per-entry preview storage is capped by line count and 240 characters per line; oversized shallow notes safely produce an empty preview.

Rows use stable semantic IDs, first-party card styles, and generic `DocView` visual-row composition. Clicking a row activates the shared resolved link, so navigation history, heading/block positioning, ambiguity safety, Project boundaries, and stale-target checks remain owned by the existing link interaction layer.

## Consistency and fallback

The visual-row generation key includes both semantic and link-index generations. Tracked unsaved Documents therefore update embed previews through the same authoritative index overlay used by link resolution. Source Mode removes preview rows. Missing, ambiguous, pending, attachment, image, comment-overlapped, capture-overflow, or unavailable previews remain ordinary source/status presentation.

The rows intentionally show bounded styled source rather than recursively instantiating nested Editors. This prevents embed recursion, unbounded layout growth, synchronous I/O, and independent selection/focus state while satisfying the selected note/heading/block preview scope.

Focused runtime and UI tests cover bounded index previews, heading-section boundaries, block-ID removal, all three resolved embed forms, visual-row attachment, and non-embed fallback.
