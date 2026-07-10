# Markdown Attachment Workflow

Implemented July 10, 2026 as a Phase 5 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Generic drop routing

`DocView` now owns a generic ordered file-drop provider contract. Providers receive the target Editor, file, and screen position; failures are isolated through quiet diagnostics; returning true consumes the drop. Markdown Live Preview attaches/detaches its provider with the rest of its owned lifecycle and moves the view-local caret to the drop position before insertion.

## Import and insertion

Dropping an existing Project file inserts a link without copying it. Dropping an external file:

1. resolves the Obsidian `attachmentFolderPath` when present, otherwise `config.markdown_live_attachment_folder` (default `attachments`);
2. rejects configured destinations outside the owning Project;
3. creates missing parent directories;
4. copies the source in bounded chunks to a collision-safe name (`name-1.ext`, etc.); and
5. inserts source only after the copy succeeds.

Images use embed syntax; other files use ordinary links. `config.markdown_live_attachment_link_format` selects `wikilink` (default, Project-root-relative) or `markdown` (source-note-relative, angle-bracketed when whitespace requires it). Alt-drop inserts an absolute `file:///` Markdown link without copying. Document insertion uses the normal text-input transaction and is independently undoable; copied filesystem artifacts are intentionally not deleted by editor undo.

Imported paths are immediately published to the owning Markdown Link Index. Read-only Editors decline before any copy.

## Regression evidence

Focused tests cover the generic provider contract/removal, external image copying, collision naming, Project-local no-copy links, Wikilink versus Markdown serialization, nested-note relative paths, undo/redo of insertion, real drop routing, and existing Markdown image/link rendering suites.
