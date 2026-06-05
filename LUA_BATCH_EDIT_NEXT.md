# Lua Batch Edit Refactor — Next Work

## Just completed: `Doc:ime_text_editing`

`Doc:ime_text_editing` has been migrated to the Lua batch edit transaction path.

Completed coverage:

- collapsed multi-caret IME input
- selected range replacement
- final composition selection anchor direction (`end -> start`)
- one public `on_text_change` notification for multi-caret IME input

Implementation notes:

- the method now builds one edit per original selection
- final selections are computed explicitly so the composing text remains selected backwards
- `start` and `length` remain part of the public signature but are not interpreted by the migrated path

## Just completed: paste helper cleanup

Whole-line paste helper duplication has been consolidated.

Completed cleanup:

- `paste_matching_whole_lines(...)` and `paste_all_whole_line_clipboards(...)` now share `paste_whole_lines_by_selection(...)`
- shared helper owns edit construction, line-delta selection math, and the final `apply_edits(...)` call
- existing paste characterization tests continue to pass

## Just completed: IntelliJ local find replace-all

The local find plugin's replace-all operation now builds one replacement edit per match and applies them in one batch transaction.

Completed coverage:

- UI characterization for local find replace-all replacing multiple matches
- asserts replace-all emits one public document `on_text_change` notification

## Just completed: `Doc:replace_cursor`

`Doc:replace_cursor` now routes changed replacements through `Doc:apply_edits(...)`.

Completed coverage:

- selected-range replacement returns the callback result
- collapsed cursor replacement keeps selecting the inserted text

## Just completed: Search UI replace-all

`data/plugins/search_ui.lua` replace-all now collects replacements and applies them through one `Doc:apply_edits(...)` transaction.

Completed coverage:

- UI characterization for Search UI replace-all replacing multiple matches
- asserts replace-all emits one public document `on_text_change` notification

## Current next target: remaining search/replace paths

Inspect remaining search/replace command code and plugin paths for per-selection edit loops that still call:

- `insert`
- `remove`
- `replace_cursor`
- `set_selections` after each individual edit

Migrate safe paths to `apply_edits` after adding characterization tests.

### Documentation update

Keep `LUA_BATCH_EDIT_PLAN.md` current as each implementation chunk lands.
