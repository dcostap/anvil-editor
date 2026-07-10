# Markdown Block Presentation

Implemented July 10, 2026 as the first Phase 6 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Semantic marker fragments

Live Preview now composes block-level marker fragments with the existing semantic inline/link pipeline:

- unordered list markers render as `•` while preserving their exact source columns;
- ordered list markers retain their source numbering;
- unchecked/checked task markers render as `☐` / `☑` with distinct first-party styles; and
- blockquote source prefixes render as a compact `│ ` quote marker.

Markers are sourced from current Tree-sitter block nodes and attributes, not line-shape heuristics, except that the exact visible quote-prefix extent is measured from the semantically confirmed quote line. Existing code/comment raw fallback continues to take precedence.

## Editing and reveal

Unsupported block constructs use the established safe whole-line Reveal Unit fallback. Moving the caret onto a list/task/quote line therefore exposes its exact Markdown source; moving away restores presentation without replacing the Editor.

Task fragments use generic rendered-fragment input. Clicking a checkbox selects only its exact semantic task range and performs ordinary Document text input (`[ ]` ↔ `[x]`), so the toggle is undoable and participates in normal revision, index, render-cache, and split-view updates.

## Regression evidence

Focused UI tests cover unordered markers, checked/unchecked tasks, quote markers, task pointer activation, resulting source text, and active-line raw reveal alongside all existing inline/link/image and generic fragment-routing tests. Thematic rules, callout cards, fenced-code chrome, tables, and properties remain later Phase 6 slices.
