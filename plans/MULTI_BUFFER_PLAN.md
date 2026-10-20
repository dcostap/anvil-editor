# Combined Buffer and Multi-Buffer Plan

## Status

Idea, not started. Nothing in this plan is implemented.

The Unified Diff keeps its current design until this plan is picked up:
removed lines are drawn rows between Buffer lines, and the caret does not move
into them. Mouse selection and copying across them still work.

## Problem

The Unified Diff shows the editable side's own Buffer. The other side's
changed lines are rows drawn between its lines. They are not Buffer text.

Every text feature in Anvil works on Buffer positions. None of them can see
the drawn rows. Each feature needs a second code path to reach them.

Commit `77bd33ae` tried this for caret movement. It intercepted the move and
select commands through `TextView:handle_selection_command` and moved a caret
through the drawn rows. Arrow, word, Home/End, page and Buffer-edge moves
worked. Other commands still had gaps, such as moving with a selection,
select word or line, Find, add next match, several carets, semantic selection
and block moves. Each gap needs its own copy of an existing text behavior.
The approach can never become fully seamless. Commit `17bc2707` reverted it.

VS Code's inline diff uses the same drawn-row design. Its removed lines are
not navigable for the same reason.

## Idea

Show the Unified Diff as one real Buffer that contains every line in drawn
order: unchanged, removed and added. Removed lines are locked text in that
Buffer. Caret movement, selection, Find, several carets and every other text
command then work without special code, because it is ordinary text.

Generalize this into a combined Buffer built from parts. Each part is either:

- a live excerpt of a source Buffer, editable when that source is editable;
- locked text that does not belong to any file, such as a diff's old lines.

Clients:

- Unified Diff: the whole file as one excerpt, with locked old text inserted
  at each change.
- Multi-buffer Views, as in Zed (https://zed.dev/features#multi-buffers):
  editable excerpts from many files in one View. Candidates are Text Search
  results, Project Usage Search results, diagnostics and rename previews.
  Several carets can edit across files at once.

As far as we understand, Zed's project diff is itself a multi-buffer that
includes deleted text as read-only content, so its cursor moves through
deleted lines. Confirm this before relying on it.

## Required pieces

1. Locked ranges. The Buffer rejects any edit that touches locked text. This
   is a general core feature. The current `TextView:add_edit_guard` only
   decides per View, not per range.
2. Two-way edit sync. An edit in an excerpt is applied to its source Buffer
   at the mapped position. An edit to a source Buffer from another Editor,
   a reload or a tool is applied to the excerpt. Sync works edit by edit.
   `data/plugins/diff/fragment_buffer.lua` is a single-excerpt prototype, but
   it replaces the whole text on every change and clears undo.
3. Excerpt tracking. Excerpt edges follow edits outside them.
   `core.range_marker` already provides sticky ranges.
4. Edits across part edges. Reject an edit that touches locked text, or that
   would join excerpts of different sources, such as deleting the line break
   between them. Split a multi-caret edit by source.
5. Undo across sources. The combined Buffer records its own undo steps. Each
   step records the change it made in every source Buffer. Undo reverts all
   of them together. Do not route undo to a single source Buffer: that only
   works for the diff and does not generalize.
6. Rebuilding. When the diff changes, or a View changes its excerpts, add or
   remove parts in place. A rebuild creates no undo step and keeps every
   caret and selection on the same text.
7. Syntax colours per part. Each line takes its colours from its source
   Buffer, or from the other Diff Side for locked old text. Tokenizing the
   mixed text as one document would break, for example when a removed line
   opens a string.
8. Language features through mapping. Completion, go to definition,
   diagnostics and similar features map a combined position to its source
   position. For the diff this keeps it as capable as an Editor. For
   multi-buffers every View uses the same mapping.
9. No file of its own. A combined Buffer is never saved, autosaved, given a
   Changes Baseline, or restored as a file. Edits reach source Buffers at
   once; Autosave saves those.
10. Headers. File-name headers between excerpts can stay drawn rows, which
    Anvil already supports. The caret does not need to enter a header.

## Trade-off against the current design

Today the editable lines are the file's own Buffer. Autosave, the file's undo
history, other Editors on the file, and other features attached to that Buffer
work without extra code. Text navigation into removed lines does not.

With a combined Buffer, text navigation works everywhere without extra code.
Features attached to a file must go through the mapping and sync layer
instead. That layer is one place to build and test. With multi-buffers, every
client shares it.

## Phases

1. Core combined Buffer: parts, locked text, two-way sync, undo across
   sources, and rebuilding without undo steps. The Unified Diff is the first
   client because it has a single source. It replaces the drawn rows for
   removed lines.
2. Language features mapped into excerpts.
3. Multi-buffer Views, starting with Text Search results, then Project Usage
   Search and diagnostics.

Write a design document for phase 1 before coding it.

## Open questions

- Which language features must work inside the Unified Diff and in
  multi-buffer excerpts?
- The glossary name for a combined Buffer and for a multi-buffer View. Add
  them to `CONTEXT.md` once chosen.
- How a combined View is restored with a Workspace.
- Memory and time cost of keeping a combined copy of a large file, and of
  rebuilding it after each re-diff.
- How Diff Gap Rows and folds of unchanged lines map onto parts.
