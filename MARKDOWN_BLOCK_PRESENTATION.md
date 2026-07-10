# Markdown Block Presentation

Implemented July 10, 2026 as the first Phase 6 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Semantic marker fragments

Live Preview now composes block-level marker fragments with the existing semantic inline/link pipeline:

- unordered list markers render as `•` while preserving their exact source columns;
- ordered list markers retain their source numbering;
- unchecked/checked task markers render as `☐` / `☑` with distinct first-party styles; and
- blockquote source prefixes render as a compact `│ ` quote marker; and
- semantic thematic breaks render as a styled horizontal rule glyph run.

Markers are sourced from current Tree-sitter block nodes and attributes, not line-shape heuristics, except that the exact visible quote-prefix extent is measured from the semantically confirmed quote line.

Semantically confirmed Obsidian callouts replace their inactive `[!type]` header marker with compact callout chrome, preserve custom titles and nested inline links/images, show fold intent, and apply a first-party card background across the quote range. Known callout names are classified for future type-specific styling; unknown names use the same safe generic fallback while retaining their normalized type. Active headers reveal exact source. This slice presents fold signs but does not yet make them collapse content.

Fenced code blocks use bounded whole-Document semantic ranges: inactive opening fences become a language header, closing fences are visually suppressed, and every block line receives the first-party code background through the generic decoration-provider contract. Code content remains raw, syntax-highlightable Editor text. Active opening/closing lines reveal exact fence source. Comment suppression takes precedence over fenced-looking text, and capture-bound overflow falls back wholly to raw presentation.

## Editing and reveal

Unsupported block constructs use the established safe whole-line Reveal Unit fallback. Moving the caret onto a list/task/quote line therefore exposes its exact Markdown source; moving away restores presentation without replacing the Editor.

Task fragments use generic rendered-fragment input. Clicking a checkbox selects only its exact semantic task range and performs ordinary Document text input (`[ ]` ↔ `[x]`), so the toggle is undoable and participates in normal revision, index, render-cache, and split-view updates.

## Regression evidence

Focused UI tests cover unordered markers, checked/unchecked tasks, quote markers, task pointer activation, resulting source text, callout headers/bodies/unknown types/backgrounds/nested links, active-line raw reveal, fenced language/closing chrome, raw code content, code backgrounds, and fenced-looking text inside comments alongside all existing inline/link/image and generic fragment-routing tests. Callout cards, tables, and properties remain later Phase 6 slices.
