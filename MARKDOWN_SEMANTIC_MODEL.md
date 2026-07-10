# Markdown Semantic Model Foundation

Implemented July 10, 2026 as the worker/publication portion of Phase 1 in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Implemented path

1. `core.markdown.model` creates at most one semantic model for a Markdown Document.
2. First use snapshots the authoritative Document source and submits a native `markdown_parse` job through Anvil's existing worker pool.
3. The native worker runs the composite Tree-sitter block/inline parser, then executes bounded block and inline semantic queries.
4. Parse/query captures remain in a native result handle. Lua requests only a bounded source-line range when a caller needs semantic nodes.
5. Publication checks parse generation, `Doc.text_revision`, filename, absolute filename, syntax identity, and continued Markdown eligibility.
6. Text transactions debounce and supersede old requests. Running native work observes job and shared cancel tokens.
7. Pending, stale, failed, unsupported, and malformed input remains on the raw-source path.

The model exposes capture and node queries; it is not connected to drawing yet. Phase 2 render/cache work consumes this model instead of parsing during draw or hit testing.

## Semantic statuses

- `cold`: no parse requested yet.
- `pending`: a snapshot is queued/running or waiting for the debounce window.
- `ready`: a revision-checked native result is published.
- `error`: parsing/querying failed; callers render source.
- `detached`: the Document is no longer Markdown.
- `closed`: explicit model teardown.

## Conservative behavior

The pinned upstream grammar currently interprets the inner `[Note|Alias]` portion of `[[Note|Alias]]` as a CommonMark shortcut reference. The semantic model detects that exact outer-bracket shape and suppresses the false reference-link node and its link-content captures. Wikilinks therefore remain raw until the dedicated Obsidian syntax layer publishes an exact, confident node.

The compatibility corpus similarly verifies raw fallback for incomplete emphasis, unsupported highlight/comment syntax, raw HTML contents, and delimiter-heavy malformed input.

## Diagnostics

Each model records:

- requests, coalesced requests, and cancellations;
- stale results discarded;
- successful and failed publications;
- bytes submitted; and
- last native parse time.

Transitions and stale/error decisions use `core.log_quiet(...)`.

## Current boundaries before the Phase 1 exit gate

- Worker jobs currently perform a fresh composite parse; persistent incremental block/inline tree reuse across jobs remains to be added.
- Node IDs are snapshot-derived, not yet reconciled into stable identities across edits.
- The complete Obsidian extension layer (Wikilinks, embeds, highlights, comments, and later callouts) remains pending.
- Final 100 KiB/1 MiB end-to-end parse plus publication budgets still need a repeatable benchmark covering the composite worker path.
- First-class filename/syntax/close lifecycle listeners are Phase 2 work; the model already rejects stale metadata at publication.

These are explicit raw-fallback boundaries, not compatibility aliases or hidden use of the old line parser.

## Red-green evidence

The focused semantic-model test was run with `data/core/markdown/model.lua` temporarily removed and failed because the public model module did not exist. With the implementation restored, the focused model suite passes, including shared Document state, pending raw fallback, stale revision rejection, malformed input, Wikilink ambiguity suppression, raw HTML suppression, and non-Markdown fast path.

## Validation

```sh
meson test -C build-windows-x86_64 anvil:worker_pool anvil:markdown_parser --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/worker_pool_native.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/markdown_model.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/markdown_parser_compatibility.lua --print-errorlogs
```
