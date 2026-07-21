# Semantic Inline Markdown Rendering

Implemented July 10, 2026 as the first Phase 3 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Snapshot continuity

A cold Markdown Document renders raw until its first current semantic snapshot arrives. Existing unaffected cached lines retain their prior current semantic output during later incremental publications. Before an ordinary edit mutates the Document, the active view captures the touched line's current presentation even if a caret move already invalidated its resident cache entry. That presentation is cloned and patched from the exact transaction, so current text appears immediately without changing fonts, exposing unrelated markers, or dropping decorations while parsing is pending. The optimistic line is revision- and source-checked and is replaced wholesale by authoritative semantic output on publication. Unsupported, stale, failed, detached, or structurally uncertain states retain conservative raw fallback.

## Semantic families

The Live Preview renderer now consumes semantic nodes directly for:

- emphasis and strong emphasis;
- combined bold/italic delimiter nesting;
- strikethrough;
- Obsidian highlights;
- inline code;
- backslash escapes; and
- inline or multiline Obsidian comments.

The former local parser is no longer called for these syntax families. It remains temporarily isolated to Markdown links and image/embed target decoding for later Phase 3/4 slices.

## Nested composition

Formatting nodes are converted into source-column boundaries. Each leaf interval composes all enclosing attributes rather than allowing an outer range to suppress an inner one. This preserves combinations such as bold inside highlight, italic inside strong, escaped characters inside bold, and enclosing formatting on both sides of a hidden comment. Adjacent leaves with identical style/identity are merged.

Markers stay source-addressable: inactive markers are hidden, while active/revealed lines show them in the hidden-syntax color. Escaped marker bytes and comments participate in the same boundary composition, including heading content.

## Generic decorations

Render fragments now support first-class `background`, `strikethrough`, and `underline` drawing in both wrapped and unwrapped paths. The first-party style schema adds `style.markdown_live_highlight_bg`; inline code uses the existing `style.markdown_live_inline_code_bg`.

## Dependency invalidation

Fence and multiline-comment delimiters can affect a suffix. Provider transaction invalidation therefore widens edits involving backticks, tildes, or any percent-bearing changed line. Structural edits already widen shifted suffixes. Async publication re-adopts the same dependency range, preventing unchanged middle comment lines from retaining stale visibility.

## Red-green evidence

Focused tests cover cold pending fallback, incremental pending-render continuity, direct semantic rendering without the ad hoc parser, CommonMark intraword-underscore behavior, nested attribute composition, escapes/comments inside formatting and headings, multiline delimiter removal/formation, active marker reveal, generic decoration drawing, wrapping, image regressions, and semantic identity retention.
