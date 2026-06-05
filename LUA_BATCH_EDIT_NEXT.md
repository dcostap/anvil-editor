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

## Just completed: `Doc:replace` characterization

`Doc:replace` behavior is now covered for the remaining semantics transform callers depend on.

Completed coverage:

- no-selection whole-document replace behavior and result shape
- different-length multi-selection replacements in one document change
- unchanged replacements returning callback results without text-change notifications

## Just completed: transform plugin coverage

Transform plugins that route through `Doc:replace` now have UI coverage confirming they apply as one document change.

Completed coverage:

- `quote:quote`
- `reflow:reflow`
- `tabularize:tabularize`

Also fixed `quote.lua`'s control-character pattern so NUL is matched with `%z` instead of embedding a NUL byte in the Lua pattern string.

## Just completed: IntelliJ duplicate-current-line

`user:duplicate-current-line` now builds all duplicate-line insertions and applies them through one `Doc:apply_edits(...)` transaction.

Completed coverage:

- multi-selection duplicate-current-line behavior
- asserts the command emits one public document `on_text_change` notification

## Just completed: IntelliJ line-comment-at-start

`user:comment-with-line-comment-at-start` now builds comment/uncomment edits and applies them through one `Doc:apply_edits(...)` transaction.

Completed coverage:

- multi-line comment behavior
- multi-line uncomment behavior
- asserts each command emits one public document `on_text_change` notification

## Just completed: autocomplete completion replacement

`autocomplete:complete` now replaces matching partials at all carets through one `Doc:apply_edits(...)` transaction when the selected completion item does not handle insertion itself.

Completed coverage:

- multi-caret partial completion
- asserts completion emits one public document `on_text_change` notification

## Current next target: remaining first-party edit loops

Inspect remaining command/plugin paths for per-selection edit loops that still call:

- `insert`
- `remove`
- `replace_cursor`
- `set_selections` after each individual edit

Migrate safe paths to `apply_edits` after adding characterization tests.

### Documentation update

Keep `LUA_BATCH_EDIT_PLAN.md` current as each implementation chunk lands.
