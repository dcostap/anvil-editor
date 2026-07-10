# Markdown Interaction Stability

Implemented July 10, 2026 as the fourth Phase 2 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Pointer and IME freeze

`DocView` already exposes a generic line-render interaction snapshot used by mouse drag selection. IME composition now enters the same contract on the first non-empty composition event and exits it when composition ends. Selection mutations during either interaction cannot repeatedly collapse/expand rendered Markdown underneath the pointer or composition window.

## Multi-cursor reveal

The Markdown provider evaluates every selection range in the view-local selection state. Multiple carets reveal each touched source line independently; lines between disjoint carets remain rendered. Cache invalidation targets the union of old/new selection lines.

## Viewport anchoring

Targeted visual-height updates now identify the old first visible metric row before applying Fenwick-tree deltas. Height changes strictly above that row adjust both current and target scroll positions by the aggregate delta. The visible content anchor therefore stays at the same screen y-coordinate when Markdown above it expands or collapses.

## Red-green evidence

Before implementation:

- changing a row above the viewport moved the anchored line by the full height delta; and
- IME composition did not create a line-render interaction snapshot.

Focused tests now verify stable screen y, synchronized current/target scroll positions, IME begin/end ownership, pointer freeze, and disjoint multi-cursor reveal behavior.
