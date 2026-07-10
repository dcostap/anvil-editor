# Markdown Link Index and Status Presentation

Implemented July 10, 2026 as the first Phase 4 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

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
- `resolved` for unique notes, headings, blocks, and attachments;
- `missing` when no target exists;
- `ambiguous` when multiple notes match; and
- `external` for URI schemes or external paths.

Fragment-only heading and block targets resolve against the source Document; local query/fragment suffixes are removed before path lookup; and Windows drive paths are classified as absolute paths before URI-scheme checks.

The base style schema defines distinct Live Preview colors for all statuses. Link index status/generation participates in provider cache generation, and index publications invalidate attached views. Images retain the same semantic resolution metadata while preserving widget/placeholder styling.

## Open-Document overlays

A tracked unsaved Document immediately replaces its disk entry and updates heading/block/alias resolution after edits. Cooperative scans do not overwrite that overlay. Filename changes continue to remove the stale path and attach the Document to its new owning Project index.

## Regression evidence

Focused tests cover cooperative cold indexing across multiple yield batches, readiness events, targeted filesystem create/modify/delete/subtree reconciliation, watcher consumer lifecycle, overlay preservation, note/heading/block/attachment/URL resolution, ambiguity, aliases, unsaved edits, Project ownership, rename/move behavior, distinct status styling, semantic rendering, and lifecycle regressions.
