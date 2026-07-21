# Markdown Semantic Model Foundation

Implemented July 10, 2026 as the worker/publication portion of Phase 1 in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Implemented path

1. `core.markdown.model` creates at most one semantic model for a Markdown Document.
2. First use snapshots the authoritative Document source and submits a native `markdown_parse` job through Anvil's existing worker pool.
3. The native worker runs the composite Tree-sitter block/inline parser, then executes bounded block and inline semantic queries.
4. A published native result retains its composite tree. The next same-Document job retains that result, computes one aggregate UTF-8-safe `TSInputEdit`, incrementally reparses the block tree, and incrementally reuses matching inline-region trees. Unchanged block captures are reused only for an identical, previously complete query that the worker validates as simple root-node/capture patterns with no context or source-text predicates. Changed, limited, predicate-bearing, contextual, and other custom queries run in full.
5. Semantic capture identities are reconciled by capture kind and edit-mapped range, preserving node IDs when unchanged constructs move or surrounding text changes.
6. Parse/query captures remain in a refcounted native result handle. Per-query interval indexes answer source-line ranges without scanning every capture; Lua adopts only the bounded matches. Superseded/closed models release their Lua ownership deterministically while queued jobs retain their own native reference.
7. Publication checks parse generation, `Doc.text_revision`, filename, absolute filename, syntax identity, and continued Markdown eligibility. Published snapshots include the coalesced changed source-line range.
8. Text transactions debounce and supersede old requests. Running native work observes job and shared cancel tokens.
9. Pending changed/unsafe ranges, stale revisions, failed states, unsupported constructs, and malformed input remain on the raw-source path. Rendering may explicitly read the last publication for unchanged lines outside a non-structural pending range so visual metrics do not collapse while the next snapshot is computed.

The model exposes capture and node queries; it is not connected to drawing yet. Phase 2 render/cache work consumes this model instead of parsing during draw or hit testing.

## Semantic statuses

- `cold`: no parse requested yet.
- `pending`: a snapshot is queued/running or waiting for the debounce window.
- `ready`: a revision-checked native result is published.
- `error`: parsing/querying failed; callers render source.
- `detached`: the Document is no longer Markdown.
- `closed`: explicit model teardown.

## Conservative behavior

The pinned upstream grammar interprets the inner `[Note|Alias]` portion of `[[Note|Alias]]` as a CommonMark shortcut reference. The native Obsidian extension scanner now publishes the exact outer Wikilink/embed node, and the Lua adapter suppresses that conflicting inner reference capture. Complete highlights and comments are also published; escaped/incomplete forms remain raw.

The compatibility corpus verifies raw fallback for incomplete emphasis and extension delimiters, raw HTML/code suppression, and delimiter-heavy malformed input. Details are recorded in `MARKDOWN_OBSIDIAN_EXTENSIONS.md`.

## Diagnostics

Each model records:

- requests, coalesced requests, and cancellations;
- stale results discarded;
- successful full and incremental publications;
- incrementally reused block captures and inline regions;
- bytes and lines submitted; and
- block, inline, aggregate parse, and total native publication time.

Transitions and stale/error decisions use `core.log_quiet(...)`.

## Current boundaries after the Phase 1 exit gate

- The measured 100 KiB incremental native total is 17–18 ms against a calibrated 20 ms background budget; the 1 MiB update remains background/cancellable and takes about 174–183 ms on the benchmark fixture, primarily in Tree-sitter's block parse.
- Callout syntax composes blockquote semantics later with the block rendering slice rather than the inline extension scanner.
- First-class filename/syntax/close lifecycle listeners are Phase 2 work; the model already rejects stale metadata at publication.

These are explicit raw-fallback boundaries, not compatibility aliases or hidden use of the old line parser.

## Red-green evidence

The focused semantic-model test was run with `data/core/markdown/model.lua` temporarily removed and failed because the public model module did not exist. The incremental slice was then run before implementation and failed because captures exposed no semantic identity. With the implementation restored, the focused model and native-worker suites pass, including shared Document state, pending raw fallback, stale revision rejection, malformed input, stable IDs across incremental publication, shifted constructs, bounded line-index queries, Wikilink ambiguity suppression, raw HTML suppression, and non-Markdown fast path.

## Validation

```sh
meson test -C build-windows-x86_64 anvil:worker_pool anvil:markdown_parser --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/worker_pool_native.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/markdown_model.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/markdown_parser_compatibility.lua --print-errorlogs
```
