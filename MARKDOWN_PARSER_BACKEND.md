# Markdown Parser Backend Selection

Decision recorded July 10, 2026 for Phase 1 of `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Selection

Anvil will use the pinned **tree-sitter-markdown 0.5.3 block and inline grammars** as the Markdown semantic backend.

The selected revision is `tree-sitter-grammars/tree-sitter-markdown@c3570720f7f7bbad22fe96603f106276618e0cf5`. It builds reproducibly through `subprojects/tree-sitter-markdown.wrap` and the Anvil-owned Meson definition under `subprojects/packagefiles/tree-sitter-markdown`.

Obsidian-only constructs that the generated upstream grammar does not expose remain the responsibility of the separate `obsidian_syntax.lua` layer. They must use exact source ranges and conservative raw fallback; they must not mutate or normalize Document text.

## Candidate evidence

### MD4C

The spike pinned `mity/md4c@65c6c9d72cebd9a731aaa5597414ce04d9ea5de3` and compiled it as a static Meson subproject in the normal Windows build. A temporary native target passed against CommonMark/GFM plus Wikilink, highlight, and math flags and parsed a 1,114,112-byte fixture within the target's approximately 0.02-second total runtime.

Strengths:

- strongest CommonMark-focused correctness claim of the candidates;
- compact implementation and excellent full-parse speed;
- built-in tables, tasks, footnotes, strikethrough, highlight, math, Wikilinks, and admonitions;
- text callbacks that point into the original input can expose exact content byte offsets.

Blocking cost for this editor model:

- public enter/leave block and span callbacks do not provide source offsets;
- exact opening/closing marker ranges would require a maintained Anvil fork of parser internals or a second delimiter parser;
- no incremental tree is retained;
- full semantic publication and cancellation would need a new native result format and worker integration despite Anvil already owning those facilities for Tree-sitter.

The temporary MD4C build/test integration was removed after the comparison, as required by the plan. MD4C is not a shipped dependency.

### tree-sitter-markdown

Both block and inline grammars compile against Anvil's pinned Tree-sitter 0.27 runtime and are registered as `markdown` and `markdown_inline`.

Measured/proven behavior on the development machine:

- exact ATX marker range: bytes `0..1`;
- exact heading inline-content range: bytes `2..16`;
- exact emphasis range: bytes `8..15`;
- exact emphasis delimiters: bytes `8..9` and `14..15`;
- the production `treesitter.parse_markdown(...)` API collects every block `inline` and `pipe_table_cell` region, excludes embedded named block children according to the upstream split-parser contract, applies `ts_parser_set_included_ranges`, and retains associated block/inline trees behind one native result handle;
- a roughly 1 MiB block parse took about 293–303 ms synchronously;
- a same-length one-byte incremental edit in that 1 MiB fixture took about 23 ms;
- frontmatter, tasks, GFM tables, and raw HTML blocks are source-ranged block nodes;
- the existing Anvil Tree-sitter service already provides immutable snapshots, generation checks, coalescing, cancellation, worker execution, stale-result rejection, compact native trees, and bounded range queries.

The full 1 MiB parse is not suitable for the UI thread. It validates the plan's requirement to keep large/slow reconciliation in the existing worker-backed service. The current composite API is a synchronous publication boundary for fixtures and bounded inputs; worker scheduling, cancellation, incremental reuse of both block and inline trees, and compact semantic adoption are completed in the next milestone.

## Why Tree-sitter won

Exact source and delimiter ranges are non-negotiable for caret, selection, wrapping, and hidden-marker mapping. Tree-sitter provides those ranges directly and fits Anvil's existing asynchronous lifecycle. That advantage outweighs MD4C's better full-parse speed and broader built-in extensions.

This selection does **not** treat the upstream grammar as infallible. Its own documentation warns about Markdown inaccuracies. Anvil therefore requires:

- an independent CommonMark/GFM/Obsidian fixture corpus;
- confidence/error states that never hide uncertain syntax;
- raw fallback while block and inline generations disagree;
- exact range and malformed-input tests for every construct Anvil presents;
- bounded worker publication and revision checks; and
- no claim of support for an extension until its fixtures pass.

If later fixtures expose an unfixable correctness failure, changing backend is an explicit architecture decision rather than silently layering an ad hoc parser over incorrect ranges.

## Reproducible validation

```sh
meson test -C build-windows-x86_64 anvil:markdown_parser --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/markdown_parser_backend.lua --print-errorlogs
```

The native target validates registry compatibility, production composite split-parser coordination across prose/table regions, exact marker/content ranges, representative block constructs, and large/incremental parse behavior without flaky timing gates. Running `build-windows-x86_64/src/markdown_parser_test.exe` prints repeatable timing measurements. The Lua target validates that the composite native result handle and exact block/inline byte-column captures cross Anvil's Lua API boundary.
