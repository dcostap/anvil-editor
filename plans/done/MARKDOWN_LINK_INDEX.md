# Markdown Link Index and Status Presentation

Implemented July 10, 2026 as the first Phase 4 slice in `plans/done/MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Cooperative cold-start index

Each Project-root Markdown vault index has explicit `cold`, `indexing`, and `ready` states, a monotonic generation, cancellable rebuild serial, and listener publication. `Index:ensure()` starts a cooperative directory traversal that yields every bounded batch instead of recursively scanning and parsing the entire Project on the UI step.

The traversal excludes repository/test-artifact roots, isolates unreadable/pathological files through quiet diagnostics, skips paths represented by tracked open Documents, and reapplies every tracked Document overlay before publishing readiness. Oversized cold-start notes receive bounded shallow note entries (path/name resolution without heading/block anchors) until opened or explicitly indexed, preventing one file from monopolizing the UI step. The directory worklist is a LIFO stack, so removal is constant-time. The existing synchronous `rebuild()` remains an explicit test/manual boundary.

Open Document edits, path updates/removals, close, and ready transitions publish generation changes. Close deterministically removes the overlay and restores a bounded/shallow disk entry when one exists. Save As preserves and reindexes an old file that remains on disk while adding the new open-Document path. A tracked cross-Project rename cancels/restarts an in-flight old-root scan before publication. Live Preview views share the Project index but own independent listeners, rebind on filename changes, and detach them deterministically.

## Filesystem reconciliation

An index is watched only while at least one Live Preview consumer is attached. Consumer acquisition starts a recursive `DirWatch` lifecycle; final release removes watches and stops its cooperative polling thread. Every scanned or newly discovered directory is registered for cross-platform behavior.

Watch notifications reconcile the changed directory rather than rebuilding the Project. File metadata avoids reparsing unchanged entries; supported creates/modifications are adopted with the oversized-note bound, deleted files and deleted subtrees are removed, and newly discovered directory trees are scanned and watched in 32-entry cooperative batches. Each effective direct or subtree batch publishes one `filesystem-reconciled` generation. Open-Document entries remain authoritative even when their disk file changes or disappears.

## Status presentation

Semantic link fragments now carry a normalized `link_resolution`:

- `pending` while the internal index is building;
- `resolved` for notes, headings, blocks, and attachments;
- `missing` when no target exists; and
- `external` for URI schemes or external paths.

Link paths resolve as Obsidian's `getLinkpathDest` does. Candidates are the files
whose name matches the link's last part, ignoring case. A name with a dot is
tried as written first, and then `.md`, `.markdown`, and `.mdown` are tried.
A bare name with one match resolves to it. `./` and `../` paths need an exact
match from the source note's folder. Otherwise an exact path from the Project
root wins, and a leading `/` names the root only. Remaining candidates are
files whose path ends with the link: those inside the source note's folder
come first, then the shortest path, then the path in alphabetical order. The
first candidate wins; there is no ambiguity prompt. Aliases are completion
labels, not link targets.

Anvil differs from Obsidian in four ways. Backslashes count as folder
separators. A path ending matches only at a folder boundary, so `[[A/Note]]`
does not match `BA/Note.md`. Ties of equal length are broken alphabetically.
`.markdown` and `.mdown` notes are also link candidates.

When an Obsidian vault enables `showUnsupportedFiles`, the index also adopts
non-Markdown files outside `.obsidian`, so extension-qualified links such as
`[[message.msg]]` resolve by the same file-name rules as supported
attachments. A missing heading or block inside an existing note retains the
resolved note and records `subtarget_missing`; activation falls back to line 1
instead of treating the whole file target as missing.

Fragment-only heading and block targets resolve against the source Document. Heading entries retain their structural ancestor path, so targets such as `[[Note#Parent#Child]]` distinguish repeated child headings under different parents while ordinary single-heading targets remain supported. Local query/fragment suffixes are removed before path lookup, and Windows drive paths are classified as absolute paths before URI-scheme checks.

Every textual link uses the same blue underlined Live Preview style. Status remains normalized metadata for navigation, creation, diagnostics, and cache invalidation; it does not recolor the link. Link index status/generation participates in provider cache generation, and index publications invalidate attached views. Images retain the same semantic resolution metadata while preserving widget/placeholder styling.

## Open-Document overlays

A tracked unsaved Document immediately replaces its disk entry and updates heading/block resolution and aliases after edits. Cooperative scans do not overwrite that overlay. Filename changes continue to remove the stale path and attach the Document to its new owning Project index.

## Regression evidence

Focused tests cover cooperative cold indexing across multiple yield batches, readiness events, targeted filesystem create/modify/delete/subtree reconciliation, watcher consumer lifecycle, overlay preservation, note/heading/nested-heading/block/attachment/URL resolution, duplicate file names, unsaved edits, Project ownership, rename/move behavior, unified styling with distinct status metadata, semantic rendering, and lifecycle regressions.
