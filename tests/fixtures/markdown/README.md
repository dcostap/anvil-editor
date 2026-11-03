# Markdown test fixtures

## CommonMark inline examples

`commonmark-inline.json` contains 137 examples from [CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/). The source is [spec.json](https://spec.commonmark.org/0.31.2/spec.json).

The CommonMark specification and its examples are copyright John MacFarlane, licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). The derived JSON fixture uses the same license. The importer selects examples and adds text runs with font semantics. It keeps each example's number, Markdown, and reference HTML unchanged.

`tools/import_markdown_spec.py` selects single-line examples from Backslash escapes, Code spans, Emphasis and strong emphasis, and Textual content. The reference HTML must contain one paragraph with only text, emphasis, strong emphasis, and code. Selection never depends on Anvil's output. The importer excludes 16 multiline examples and 17 examples with other HTML elements. It records these counts and the source SHA-256 in the fixture.

The tests compare visible text and font semantics through the Editor's line-render API. They merge adjacent runs with the same style. Equivalent nesting, such as bold inside italic or italic inside bold, gives the same result. Font files, font sizes, colors, spacing, and fragment boundaries are not test contracts.

These tests do not prove complete CommonMark compliance. They do not check link destinations, images, multiline inline constructs, raw HTML, or block layout. Runtime syntax contracts cover selected block rules and extension boundaries separately.

### Reviewed differences

`commonmark_review.lua` lists exact example IDs that differ from the reference. Each entry gives a reason. It contains no replacement expected output.

The normal UI suite runs all imported examples except those IDs. The complete audit runs every imported example with the original reference expectation. It reports a mismatch as a failure, including intentional editor differences. No audit case is skipped or marked as passed because it has a review entry.

| Examples | Review |
| --- | --- |
| 17, 329 | Live Preview keeps typed code-span padding. CommonMark removes one leading and trailing space when both exist. The normal presentation contract checks Anvil's rule. |
| 330, 331, 340 | A longer backtick run inside code incorrectly closes a shorter delimiter. |
| 343 | An HTML-like code fragment consumes text after its closing backtick. |
| 353 | Non-breaking spaces incorrectly permit emphasis. |
| 380, 385 | Word and quotation-mark boundaries incorrectly permit emphasis. |
| 391, 397 | A space before a bold closer produces italic text. |
| 392, 398 | Punctuation beside delimiter runs produces unwanted emphasis. |
| 411, 412, 415, 429 | Adjacent and nested delimiter runs differ from the reference. |

Do not add an ID merely to make a failing test pass. Review its visible behavior first. Separate an intended Anvil rule from a defect. Give an intended rule a normal presentation contract. Keep defects failing in the complete audit. After a fix, remove its review entry so the normal suite also runs it.

### Refresh the fixture

Run from the repository root:

```sh
python tools/import_markdown_spec.py
python tools/import_markdown_spec.py --check
python -m unittest discover -s tests/tools -p test_markdown_spec_import.py
```

The importer downloads the pinned version and checks its SHA-256. Use `--source path/to/spec.json` to read a local copy. Normal editor tests use the committed fixture and need neither Python nor network access.

Review the source, license, selection counts, and generated diff before changing the version or digest pin.

## Anvil contracts

`inline_harness.lua` creates isolated Buffers and Editor Views. It keeps the caret outside the tested source, so Live Preview hides valid syntax. It waits for the real semantic model and layout workers.

`runtime/markdown_syntax_contract.lua` checks source ownership and selected block types. It covers headings, lists, quotes, code, links, images, HTML, frontmatter, tables, comments, highlights, tags, and Wikilinks. For example, `#not` is an Anvil tag, not an ATX heading.

`ui/markdown_inline_contract.lua` checks composed styles, extension precedence, code padding, and resolved and unresolved references. Its edit cases compare the result with a fresh parse, then check undo and redo. This proves edit consistency, not standards compliance: two parses can agree on the same defect.

`ui/markdown_link_labels.lua` checks standard formatting inside Markdown and resolved reference link labels. It covers mixed styles, enclosing styles, escapes, link targets, UTF-8 source positions, and source reveal. The table tests check the same formatting inside cells. Wikilink aliases, images, and attachment chips keep their own presentation.
