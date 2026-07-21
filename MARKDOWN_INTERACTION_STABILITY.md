# Markdown Interaction Stability

Implemented July 10, 2026 as the fourth Phase 2 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Pointer and IME freeze

`DocView` already exposes a generic line-render interaction snapshot used by mouse drag selection. IME composition now enters the same contract on the first non-empty composition event and exits it when composition ends. Selection mutations during either interaction cannot repeatedly collapse/expand rendered Markdown underneath the pointer or composition window.

## Multi-cursor reveal

The Markdown provider evaluates every selection range in the view-local selection state. Collapsed carets reveal their containing construct. Non-empty selections reveal only constructs whose source ranges intersect the selected range, rather than switching every touched line to source presentation. Multiple carets and ranges remain independent, and lines between disjoint selections remain rendered. Cache invalidation targets the union of old/new selection lines and any intersected multiline reveal units.

## Viewport anchoring

Targeted visual-height updates now identify the old first visible metric row before applying Fenwick-tree deltas. Height changes strictly above that row adjust both current and target scroll positions by the aggregate delta. The visible content anchor therefore stays at the same screen y-coordinate when Markdown above it expands or collapses.

Current Line Highlights, selections, search markers, line-number layout, decoration backgrounds, and carets resolve the same visual-row metric as rendered text. Enlarged headings therefore keep their text, row chrome, and caret geometry aligned instead of mixing heading metrics with the base Editor line height.

## Pending-publication continuity

Once a current semantic snapshot has produced a rendered line, ordinary single-line text input does not send that line through raw Source presentation while the background parser catches up. A pre-change Document listener captures the authoritative presentation before selection and transaction invalidation can discard it. The line-render transaction hook then clones those fragments, applies the exact source edit to the containing identity-mapped fragment, and keeps the same fonts, hidden markers, decorations, source columns, and visual-row height. Repeated keystrokes can advance this view-local optimistic render through several pending parser generations.

The optimistic entry is accepted only when its reconstructed source exactly matches the current Document revision. Unsupported or structural edits remain conservative, and the first parse of a cold Document still uses raw source. Publication discards all optimistic entries and re-adopts authoritative semantic output. Provider cache signatures no longer query transient semantic state, so unrelated resident rows also remain visually stable while a parse is pending.

Visual-metric reconstruction follows the same continuity rule. During an ordinary non-structural edit, unchanged lines may read the last published semantic result only outside the coalesced changed range. This preserves heading, image, compact-table, and other nonstandard row heights when wrapping forces a full metric-tree rebuild. Delimiter-sensitive and structural edits mark their affected suffix unsafe, so stale semantics are never used where block structure may have changed.

Structural edits preserve geometry without querying stale shifted semantics. The view maintains published per-line metric results and represents each pending line insertion/removal as an O(1) line-map layer over those results. Unaffected heights therefore shift to their new line numbers immediately, while split rendered lines derive their own fragment/widget heights. Repeated Enter presses chain line maps without rescanning the Document or collapsing headings and other tall rows to the base Editor height.

Sticky Lines consume the same visual-row metrics as the document. Stacked Markdown headings use each source line's resolved height for backgrounds, text placement, hit testing, hover, and scroll occlusion rather than multiplying the base Editor line height. While the asynchronous hierarchy model rebuilds after an edit, Sticky Lines use a cached direct hierarchy calculation from current source instead of disappearing for the debounce interval.

## Red-green evidence

Before implementation:

- changing a row above the viewport moved the anchored line by the full height delta; and
- IME composition did not create a line-render interaction snapshot.

Focused tests now verify stable screen y, synchronized current/target scroll positions, IME begin/end ownership, pointer freeze, disjoint multi-cursor reveal behavior, repeated pending paragraph edits, pre-edit capture after selection invalidation, wrapped metric-tree reconstruction with nonstandard row heights, single and repeated pending line insertion with shifted custom heights, and source-revealed inline edits without raw-frame flicker.
