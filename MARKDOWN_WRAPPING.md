# Rendered Markdown Wrapping

Implemented July 10, 2026 as the third Phase 2 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Source-preserving rendered breaks

`core.linewrapping` now accepts the owning `DocView` while computing internal breaks. When a line-render provider returns fragments, wrapping measures the provider's monotonic source-column → rendered-x mapping instead of raw Markdown bytes.

Breaks remain stored as authoritative source byte columns. Hidden markers and long Wikilink targets therefore consume no visual width, aliases consume their rendered width, and caret/selection state remains expressed entirely in source positions.

Queries without a rendered line keep the existing tokenized/raw wrapping path unchanged.

## Drawing and hit testing

Wrapped provider output is drawn row by row, slicing visible fragments by each row's source-column range. Wrapped x mapping subtracts the rendered width before the row start and adds continuation indentation. Pointer hit testing maps row-local x through the same rendered fragment model and clamps the result to that row's source range.

Changing provider state, active-line reveal state, image completion, or provider attachment updates affected wrap breaks. Full provider changes rebuild wrapping; targeted line invalidations rebuild only the affected logical lines.

## Conservative boundaries

Wrapped inline text and aliases are supported in this slice. Complex widgets that need multi-row layout remain constrained to one source/render row until the later generic widget contract. Raw/code lines continue through the established source wrapping path.

## Red-green evidence

The prior baseline deliberately asserted that an actually wrapped Wikilink alias had no rendered line. The updated test failed before implementation. It now verifies that:

- the alias has rendered fragments;
- source-column row starts round-trip through wrapped hit testing;
- wrapped drawing emits `See Alias after` rather than the hidden target; and
- rendered wrapping uses fewer rows than the same raw source.

Focused Markdown baseline, Markdown Live Editor, render-fragment, and variable-row suites pass. The attempted unrelated `ui/docview_selection_state.lua` invocation named a nonexistent file and consequently ran into the already documented broad UI harness timeout; it is not a wrapping regression.
