# Markdown link maintenance after note rename

Implemented as the initial confirmed-update Phase 4 slice.

## Planning

When a tracked Markdown Document changes filename within its owning Project, the link index plans updates before removing the old note identity. It considers indexed, parser-confirmed outbound links and rewrites only links whose pre-rename resolution points exactly to the renamed note. Code spans and fenced code are excluded by the indexing parser.

Plans preserve:

- Wikilink versus Markdown-link syntax;
- embed prefixes and display aliases because only target ranges change;
- heading and block fragments;
- query suffixes;
- unrelated links with similar text; and
- exact surrounding source and formatting.

Wikilink targets use the Project's generated-link policy (`shortest_unique`, `relative`, or `root`). Markdown destinations remain source-note-relative and preserve existing angle brackets, adding them only when a newly generated destination requires whitespace protection.

## Preview and confirmation

A rename with affected links opens the filterable **Markdown links affected by rename** preview. It lists every affected Project-relative file and edit count. Selecting the explicit apply entry opens a second **Update Markdown Links** yes/no confirmation. Nothing is rewritten merely by opening or filtering the preview. The command `markdown-live-preview:review-rename-link-updates` reopens the pending plan for the active renamed note.

## Applying updates

Open Documents receive one ordinary `markdown-link-rename` transaction per Document, preserving undo and unsaved state. Closed files use the generic safe-write boundary with backup restoration. Each successful file is immediately reconciled into the Project index.

Updates stop on the first failed file and visibly report the applied count, failed path, and error. Already-applied plans cannot run twice. This is explicit partial-failure recovery rather than claiming a cross-file atomic transaction.

The automatic preview currently has an exact old/new identity only for first-class tracked Document filename changes. Directory watchers report dirty directories rather than paired rename events, so external filesystem delete/create pairs reconcile the index but do not guess that two paths are one rename.

## Regression evidence

Runtime tests cover exact resolution filtering, Wikilink/embed/Markdown forms, aliases, headings, query suffixes, code exclusion, target-only ranges, safe-write application, and resulting source. UI tests cover the affected-file preview, unchanged files before confirmation, confirmation text, and post-confirmation application.
