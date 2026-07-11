# Markdown Attachment Workflow

Implemented July 10, 2026 as a Phase 5 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Generic drop routing

`DocView` now owns a generic ordered file-drop provider contract. Providers receive the target Editor, file, and screen position; failures are isolated through quiet diagnostics; returning true consumes the drop. Markdown Live Preview attaches/detaches its provider with the rest of its owned lifecycle and moves the view-local caret to the drop position before insertion.

## Generic clipboard routing

`DocView` also owns an ordered clipboard-paste provider contract. The ordinary `doc:paste` command offers providers the paste before text handling; isolated provider failures are quietly diagnosed and fall through to normal text paste. Markdown consumes only supported binary image data when the text clipboard is empty, so copied text and Anvil's multicursor clipboard semantics retain precedence.

The native `system.get_clipboard_data(mime)` boundary exposes bounded binary MIME payloads (64 MiB maximum). Markdown checks PNG, JPEG, then BMP, writes a uniquely scoped temporary source, routes it through the same attachment import transaction as file drops, and always removes the temporary source. The resulting copied artifact intentionally follows the same undo policy as dropped files.

## Import and insertion

Dropping an existing Project file inserts a link without copying it. Dropping an external file:

1. resolves the Obsidian `attachmentFolderPath` when present, otherwise `config.markdown_live_attachment_folder` (default `attachments`);
2. rejects configured destinations outside the owning Project;
3. creates missing parent directories;
4. copies the source in bounded chunks to a collision-safe name (`name-1.ext`, etc.); and
5. inserts source only after the copy succeeds.

Images use embed syntax; other files use ordinary links. `config.markdown_live_attachment_link_format` selects `wikilink` (default, Project-root-relative) or `markdown` (source-note-relative, angle-bracketed when whitespace requires it). Alt-drop inserts an absolute `file:///` Markdown link without copying. Document insertion uses the normal text-input transaction and is independently undoable; copied filesystem artifacts are intentionally not deleted by editor undo.

Imported paths are immediately published to the owning Markdown Link Index. Read-only Editors decline before any copy.

## Live attachment chips

Parser-confirmed links and embeds targeting PDF, audio, or video attachments render as compact source-mapped chips while inactive. Chips retain ordinary Project-index resolution colors, generic Markdown link POIs, platform-primary-modifier activation, aliases, and construct-sensitive source reveal. Activation continues through the shared link contract rather than introducing a second attachment-opening path.

Supported groups are PDF, audio (`flac`, `mp3`, `ogg`, `wav`), and video (`mov`, `mp4`, `webm`). Images continue through the dedicated image asset service. Unknown file types remain ordinary links rather than being guessed from arbitrary URL suffixes.

## Regression evidence

Focused tests cover the generic drop and clipboard routing, clipboard MIME import, external image copying, collision naming, Project-local no-copy links, Wikilink versus Markdown serialization, nested-note relative paths, undo/redo of insertion, real drop routing, PDF/audio/video chip presentation and reveal, and existing Markdown image/link rendering suites.
