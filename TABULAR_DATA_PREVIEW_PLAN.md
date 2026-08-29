# Tabular Data Preview plan

## Status

This document is an implementation plan.

It does not change Anvil behavior.

The working feature name is **Tabular Data Preview**.

Do not add this term to `CONTEXT.md` until the name is confirmed.

## Decision summary

Build a live, read-only View for delimiter-separated files.

Keep the source Buffer as the only source of file data.

Open the Preview from an existing Editor through a command.

Draw the table with one custom View.

Draw only visible rows and columns.

Use fixed-height rows and single-line cell presentation.

Support these formats:

| Extension | Delimiter |
| --- | --- |
| `.csv` | comma |
| `.tsv` | tab |
| `.psv` | pipe |
| `.ssv` | semicolon |

Include the useful Zed behavior:

- live updates from source Buffer changes
- fixed headers
- a fixed source-row column
- horizontal and vertical scrolling
- independent column resize
- text sorting by one column
- value filters on several columns
- right-click copy for cells and headers
- full support for quotes, escaped quotes, and multiline fields
- same-Pane and side-Pane opening commands
- Workspace restore

Do not build a generic table framework first.

Do not add grid editing in the first version.

This is the small design that gives most of the value.

## What Zed shipped

Zed shipped a **Tabular Data Preview**, not a CSV Editor.

The Preview stays linked to an Editor Buffer.

Users still edit source text in the Editor.

Zed made the feature available to all users in version 1.17.x.

The current feature supports CSV, TSV, PSV, and SSV files.

The current Preview includes:

- live parsing after Editor changes
- quoted and multiline fields
- sortable columns
- resizable columns
- value filters with search
- a fixed source-line column
- right-click copy for cells and headers
- row virtualization

The current Preview does not include:

- inline cell editing
- cell-range selection
- keyboard grid navigation
- copy as CSV, TSV, or Markdown
- automatic column sizing
- column reordering

These missing functions confirm the correct first Anvil scope.

### Zed source structure

The current crate is `crates/tabular_data_preview`.

It contains about 117 KB across 18 Rust source files.

Its main parts are:

- `tabular_data_preview.rs` for View state and workspace actions
- `parser.rs` for delimiter parsing and source positions
- `table_data_engine.rs` for display-row mapping
- `filtering_by_column.rs` for filter state and counts
- `sorting_by_column.rs` for sorting
- seven renderer files for the table and controls
- three coordinate and cell type files

Zed also changed its shared data-table UI.

Those changes added variable rows, independent resize, scrolling, and fixed columns.

That architecture fits GPUI and other Zed features.

Anvil does not need that complete system for this feature.

### Important Zed changes

| Change | Result |
| --- | --- |
| [#48207](https://github.com/zed-industries/zed/pull/48207) | Added the first live CSV Preview. |
| [#53295](https://github.com/zed-industries/zed/pull/53295) | Added independent column resize and horizontal table scrolling. |
| [#53496](https://github.com/zed-industries/zed/pull/53496) | Added development settings and performance tools. |
| [#56619](https://github.com/zed-industries/zed/pull/56619) | Fixed the first column during horizontal scroll. |
| [#60339](https://github.com/zed-industries/zed/pull/60339) | Added value filters and background filter work. |
| [#60768](https://github.com/zed-industries/zed/pull/60768) | Added TSV, PSV, and SSV support. |
| [#61769](https://github.com/zed-industries/zed/pull/61769) | Added right-click copy. |
| [#61796](https://github.com/zed-industries/zed/pull/61796) | Made filter availability independent of filter order. |
| [#62773](https://github.com/zed-industries/zed/pull/62773) | Removed the feature flag. |

The release note is in [Zed 1.17.2](https://zed.dev/releases/stable/1.17.2).

The follow-up discussion is [#62917](https://github.com/zed-industries/zed/discussions/62917).

### Zed design lessons to keep

Keep these ideas:

1. Keep the Preview linked to the source Buffer.
2. Cancel stale parse results with a generation number.
3. Draw only visible table rows.
4. Keep source row numbers visible during horizontal scroll.
5. Store column widths in View state.
6. Store displayed row order as source row indexes.
7. Treat sorting and filtering as presentation changes.

Do not copy these parts into Anvil:

1. A reusable generic data-table component.
2. Separate Rust types for every data and display coordinate.
3. Variable-height row machinery.
4. A development settings panel.
5. A performance overlay inside the View.
6. Background fuzzy search for filter values.
7. Error plumbing for states that Lua tables cannot represent.

### License note

The Zed crate uses its `LICENSE-GPL` marker.

Anvil uses the MIT license.

Implement the behavior independently.

Do not copy Zed source text into Anvil.

This plan describes behavior and design facts only.

## Anvil seams that already exist

Anvil already has the required base parts.

### View and Editor model

`data/core/view.lua` supplies custom drawing, mouse input, and two scrollbars.

`data/core/editor.lua` owns editable Buffer presentation.

The Preview must extend `core.view`.

It must not extend `core.editor` or `core.textview`.

This keeps the glossary distinction correct.

### Pane placement and Navigation History

`data/core/panes.lua` supports current-Pane and split placement.

A same-Pane Preview suspends the source Editor.

The Back action then restores the exact source Editor place.

A side Preview uses `placement = "split"` and `direction = "right"`.

The feature should reuse an existing matching Preview before it creates another one.

### Shared Buffer lifetime

`data/core/buffer_registry.lua` supports explicit Buffer owners.

The Preview must retain its Buffer during construction.

The Preview must release its Buffer during close.

This rule keeps the Buffer alive without an attached Editor.

### Live updates

`data/core/buffer/init.lua` provides text-change and metadata listeners.

Use an `after_change` listener for parse scheduling.

Use a metadata listener for reload, rename, and close state.

Do not replace Buffer methods.

### Workspace state

`data/plugins/workspace.lua` saves Views through `get_state()` and `from_state()`.

The Preview module must return its View class.

This lets `View:get_module()` find the correct module name.

### Commands and icons

`data/core/command.lua` supports View Opener metadata.

Register these Command Palette commands:

- `tabular_data:open_preview`
- `tabular_data:open_preview_to_the_side`

Set `opens_view = true` on both commands.

Register a `tabular_data` View Icon with `core.view_icons`.

Use a file icon based on a synthetic `.csv` name.

### Rendering

The renderer can draw text, rectangles, and clip regions.

The base View already manages scrollbar input and animation.

No C or C++ change is necessary.

No shared table widget is necessary.

## Product contract

### Opening

A user first opens a supported file in a Standard Editor.

The Preview commands are valid only for supported file-backed Editors.

`tabular_data:open_preview` opens the Preview in the source Pane.

`tabular_data:open_preview_to_the_side` opens it in a right split.

The tab name is `Preview <filename>`.

The source file stays unchanged.

### Live data

The Preview reads the same Buffer as the source Editor.

A source edit schedules a new parse after 200 ms.

A newer edit cancels publication from older work.

The old valid table stays visible during a refresh.

Show `Loading…` only when no valid table exists.

Show a small `Updating…` status when old data stays visible.

### Header and rows

Use the first non-blank record as the header.

Use `Column N` for missing header cells.

Keep the header fixed during vertical scroll.

Keep the source-row column fixed during horizontal scroll.

Show `12` for a single-source-line record.

Show `12–15` for a multiline record.

### Multiline cells

Parse multiline quoted fields completely.

Present each table row at one fixed height.

Replace cell newlines with ` ↵ ` during drawing.

Copy the original cell text without this presentation change.

This avoids variable-row layout while preserving the data.

### Ragged records

Allow records with different field counts.

Treat a missing field as different from an empty field.

Show both values as blank cells.

Show missing values as `<missing>` in filter results.

### Sorting

Click a header sort area to cycle through three states:

1. ascending
2. descending
3. source order

Sort by case-insensitive displayed text.

Keep missing values after real values in both directions.

Use the source row index as the final comparison key.

This makes the result stable and repeatable.

Do not infer numbers, dates, or booleans.

### Filtering

A column filter stores selected exact values.

Selected values use OR behavior within one column.

Filters use AND behavior across columns.

Open filter choices in the existing Global Prompt Bar.

The Prompt Bar must be scoped to the source Pane.

Show selected values first.

Show each value count from the complete parsed data.

Filter the choice list with plain case-insensitive text search.

Limit visible suggestions to a practical internal count.

Pressing Enter toggles one value and reopens the same filter prompt.

Pressing Escape closes the prompt.

Include a `Clear column filter` choice.

Do not implement Zed's blocked-value sections in the first version.

The table result remains correct without that extra presentation.

### Copy

Right-click a cell to copy its complete source value.

Right-click a header name to copy that name.

Right-click the source-row cell to copy its line label.

Show a short Status Bar message after copy.

Do not add a context menu for one action.

### Resize

Start each data column at one internal default width.

Drag a header divider to resize only that column.

Clamp each column to a small minimum width.

Double-click a divider to restore the default width.

Do not add automatic width measurement in the first version.

### Persistence

Save these values in Workspace state:

- source file path
- horizontal and vertical scroll
- column widths
- sort column and direction
- selected filter values

On restore, open the Buffer and parse it again.

Ignore saved filter values that no longer exist.

Clamp restored widths and scroll positions.

### Empty and invalid data

Show `No data to display` for an empty Buffer.

Skip physically blank records before the header.

Accept an unfinished quoted field at end-of-file.

Show a non-blocking warning for that condition.

Do not reject the complete Preview for one malformed record.

## Proposed files

Create only these implementation files:

```text
data/plugins/tabular_data_preview/init.lua
data/plugins/tabular_data_preview/parser.lua
```

Add focused tests here:

```text
tests/lua/runtime/tabular_data_parser.lua
tests/lua/ui/tabular_data_preview.lua
```

Update this existing defaults file:

```text
data/plugins/anvil_defaults.lua
```

Do not add a native module.

Do not add a renderer asset.

Do not add style keys unless existing colors prove insufficient.

Use these existing style values first:

- `style.background`
- `style.background2`
- `style.text`
- `style.dim`
- `style.accent`
- `style.divider`
- `style.selection`
- `style.interactive_hover_background`

If new style keys become necessary, add them to `data/colors/default.lua`.

Other themes must only override those base keys.

## Parser design

Keep the parser independent from the View and renderer.

Use this small interface:

```lua
local result = parser.parse(lines, delimiter, options)
```

The result has this shape:

```lua
{
  headers = { "Name", "Age", "City" },
  rows = {
    {
      cells = { "Ada", "37", "London" },
      source_line1 = 2,
      source_line2 = 2,
    },
  },
  column_count = 3,
  warning = nil,
}
```

Use `false` for a missing cell.

Use an empty string for an existing empty cell.

Lua tables can use `false` as a filter key.

This avoids a new null class or sentinel object.

### Parser state machine

Track these values:

- current record
- current field parts
- quoted state
- field-start state
- current source line
- record start line
- maximum column count

Process one byte sequence at a time.

Use the configured delimiter only outside quotes.

Treat `""` inside a quoted field as one quote.

Keep delimiters and newlines inside quoted fields.

Open quote mode only when a quote starts a field.

Treat a quote inside unquoted text as text.

Finish the final field and record at end-of-file.

Pad short headers and rows after parsing.

Skip only a physically blank record.

Do not skip a record such as `,,`.

### Parser scheduling

Take a shallow snapshot of `buffer.lines` before parsing.

Buffer line strings are immutable after replacement.

The snapshot keeps one stable revision without joining all text.

Run parsing in `core.add_thread()`.

Yield after a short time budget or a fixed byte count.

Check the View generation before each yield resumes.

Publish only when the Buffer revision still matches.

Do not use `core.worker_pool` in the first version.

A worker would copy the complete source and result through channels.

That copy adds memory and code without clear benefit here.

## View data model

The View needs one table model and one display-order vector.

```lua
self.model = {
  headers = {},
  rows = {},
  column_count = 0,
  distinct_values = {},
}

self.display_rows = {}
self.filters = {}
self.sort = nil
self.column_widths = {}
```

`display_rows[n]` contains one source row index.

Rendering resolves one displayed row through that vector.

Sorting only changes this vector.

Filtering only rebuilds this vector.

The parsed row data never moves.

Do not create a display-row hash map.

Do not create data and display coordinate classes.

### Distinct filter values

Build one unique-value table for each column after parsing.

Store source counts with each value.

Reuse the parsed strings as map keys.

Sort a filter choice list only when its prompt opens.

Prune saved filters after every successful parse.

### Display-row rebuild

Use one function for sort and filter updates.

Its steps are:

1. Scan source rows.
2. Keep rows that pass all active filters.
3. Store their source indexes.
4. Sort indexes when sorting is active.
5. Replace `self.display_rows` once.
6. Clamp vertical scroll.
7. Request redraw.

The scan can yield for very large tables.

`table.sort` can remain synchronous in the first version.

Measure it before adding another sorting system.

## Drawing design

Use a fixed row height from `style.code_font`.

Add small vertical and horizontal padding.

Compute these rectangles each frame:

1. complete View bounds
2. fixed header bounds
3. fixed source-row column
4. scrollable body
5. horizontal scrollbar
6. vertical scrollbar

### Row virtualization

Calculate the first visible row from `self.scroll.y`.

Calculate the last visible row from the body height.

Draw one extra row above and below the viewport.

Never loop through all rows during drawing.

### Column virtualization

Keep prefix widths for all data columns.

Rebuild prefix widths only after parse or resize.

Use `self.scroll.x` to find the first visible data column.

Stop after a column passes the right body edge.

Never draw off-screen columns.

This matters for files with hundreds of columns.

### Draw order

Use this order:

1. View background
2. visible striped row backgrounds
3. visible data cells
4. grid dividers
5. fixed header background and content
6. fixed source-row column
7. loading, warning, or empty status
8. scrollbars

Draw the fixed areas after scrolled data.

This prevents scrolled text from appearing above fixed content.

Clip text to each visible cell.

Cache newline-normalized display text only when measurement shows a need.

Do not create one widget object for each cell.

## Mouse behavior

Use one hit-test function for all table input.

It returns one of these targets:

```text
cell
header_text
header_sort
header_filter
column_divider
source_row
none
```

`on_mouse_moved` updates hover state and cursor shape.

Use the `sizeh` cursor over a column divider.

Use the `hand` cursor over sort and filter controls.

`on_mouse_pressed` must call the base View first.

This gives both scrollbars the first input chance.

The Root Panel already holds mouse capture during drag.

`on_mouse_moved` updates a resized column while capture remains active.

`on_mouse_released` ends the resize.

`on_mouse_wheel` changes vertical and horizontal scroll targets.

Use `config.mouse_wheel_scroll` for the movement unit.

## View lifecycle

### Construction

The constructor must:

1. call `View.super.new(self)`
2. set `context = "workspace"`
3. set `scrollable = true`
4. store and retain the Buffer
5. install Buffer listeners
6. initialize widths and presentation state
7. schedule the first parse

### Close

Close must be safe when called more than once.

Close must:

1. increment the generation
2. remove Buffer listeners
3. release the Buffer owner
4. clear large model tables
5. log one quiet close record

### Duplicate

`duplicate()` creates an independent Preview for the same Buffer.

Copy widths, filters, sorting, and scroll state.

Retain the Buffer for the new View.

### Workspace restore

`get_state()` returns plain Lua data only.

`from_state()` validates the path and extension.

It then opens the Buffer and constructs a Preview.

Apply saved presentation state after the first parse.

## Command behavior

Use one supported-source predicate.

The predicate accepts a file-backed Editor with a supported extension.

It returns the source Editor to the command function.

### Open in current Pane

Find the source Pane with `panes.pane_for_view(editor)`.

Search that Pane's retained Views for a matching Preview.

Present the existing Preview when found.

Otherwise place a new Preview with current placement.

### Open to the side

First search the visible Pane Group for a matching Preview.

Focus that Preview when found.

Otherwise split the source Pane to the right.

Use the same source Buffer in the new Preview.

Do not open a second Buffer for the same path.

## First-party integration

Add `tabular_data_preview = true` to `core.first_party_core_plugins`.

Load it through `require_core_plugin "tabular_data_preview"`.

Do not add fallback configuration inside the plugin.

The first version needs no user configuration.

Keep layout constants inside the implementation.

Promote a value to configuration only after a real user need appears.

Use `core.log_quiet(...)` for these events:

- Preview opened or reused
- parse scheduled
- stale parse dropped
- parse completed with bytes, rows, columns, and time
- malformed quote warning
- filter or sort rebuild time
- Preview closed

Use visible errors only when the user must act.

## Test plan

Use red-green work for each behavior slice.

Run only the new targeted test files during development.

### Parser tests

Create `tests/lua/runtime/tabular_data_parser.lua`.

Test these durable rules:

1. comma, tab, pipe, and semicolon delimiters
2. quoted delimiters
3. escaped quotes
4. multiline quoted fields
5. source line ranges
6. empty fields and missing fields stay different
7. ragged records use the maximum column count
8. physically blank records do not become data rows
9. `,,` remains a real record
10. unfinished quotes return data and a warning
11. UTF-8 cell text stays unchanged

Do not test parser helper call counts.

Do not duplicate the parser algorithm in expected-value code.

### UI tests

Create `tests/lua/ui/tabular_data_preview.lua`.

Use commands, Pane methods, Buffer edits, and mouse events.

Test these behaviors:

1. the current command exists only for a supported Editor
2. current placement records a new Navigation Place
3. Back restores the same source Editor
4. side placement shares the source Buffer
5. opening twice reuses the existing matching Preview
6. a Buffer edit updates the visible table after debounce
7. stale parse work cannot replace a newer revision
8. header clicks cycle sort state
9. selected filter values use OR within one column
10. filters use AND across columns
11. right-click copies the complete cell value
12. right-click copies the complete header value
13. a resize drag changes one column only
14. Workspace state restores the Preview path and presentation state
15. close removes listeners and releases Buffer retention

Drive sorting through header mouse input.

Then right-click the first visible cell and inspect the clipboard.

This verifies visible order without reading private tables.

Drive filtering through the Global Prompt Bar.

Then copy visible cells to verify the filtered result.

Do not test exact pixel sizes.

Test that resize changes one column and leaves another unchanged.

### Manual checks

Use these fixtures:

- 10 rows by 5 columns
- 100,000 rows by 12 columns
- 1,000 rows by 500 columns
- quoted commas and escaped quotes
- multiline quoted fields
- ragged records
- empty data

Check these points manually:

- scrolling stays responsive
- fixed headers do not move vertically
- source rows do not move horizontally
- no off-screen row draw loop appears
- no off-screen column draw loop appears
- source edits update a side Preview
- a same-Pane Preview updates while suspended
- dark and light themes remain readable

Treat performance targets as measurements, not exact tests.

## Implementation sequence

### Slice 1: parser

Add the parser test file first.

Confirm the focused test fails because the module is absent.

Implement delimiter parsing and line ranges.

Run only the parser test file.

### Slice 2: basic View and opening

Add one UI test for same-Pane opening and Back.

Confirm it fails before View registration.

Implement the View, icon, commands, and Buffer retention.

Draw fixed headers and visible rows.

Run only the Preview UI test file.

### Slice 3: live refresh

Add one failing Buffer-edit test.

Implement listeners, debounce, snapshots, and generation checks.

Confirm that old work cannot publish.

### Slice 4: scroll, copy, sort, and resize

Add one behavior test for each public interaction.

Implement row and column virtualization first.

Then add hit testing and interactions.

Do not add filter work in this slice.

### Slice 5: value filters

Add failing OR and AND filter tests.

Implement exact-value filter sets and display-row rebuild.

Add the scoped Global Prompt Bar picker.

Keep blocked-value sections out of scope.

### Slice 6: restore and finish

Add the Workspace restore test.

Implement state save, restore, and duplicate.

Add quiet diagnostics.

Run syntax validation for all changed Lua files.

Run the two focused Meson test files.

## Validation commands

Use the repository LuaJIT executable:

```sh
./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua \
  data/plugins/tabular_data_preview/init.lua \
  data/plugins/tabular_data_preview/parser.lua \
  data/plugins/anvil_defaults.lua \
  tests/lua/runtime/tabular_data_parser.lua \
  tests/lua/ui/tabular_data_preview.lua
```

Run the focused runtime test:

```sh
PATH=/c/msys64/mingw64/bin:$PATH \
  /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 \
  anvil:lua-runtime --test-args runtime/tabular_data_parser.lua --print-errorlogs
```

Run the focused UI test:

```sh
PATH=/c/msys64/mingw64/bin:$PATH \
  /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 \
  anvil:lua-ui --test-args ui/tabular_data_preview.lua --print-errorlogs
```

Do not run the complete suite for this feature.

All implementation files use junctioned data paths.

A native rebuild is not necessary.

Reload or restart Anvil after Lua changes.

## Acceptance checklist

The first version is complete when all items are true:

- [ ] Supported source Editors expose both Preview commands.
- [ ] Same-Pane opening works with Navigation History.
- [ ] Side-Pane opening shares one Buffer.
- [ ] CSV, TSV, PSV, and SSV parse correctly.
- [ ] Quotes, escaped quotes, and multiline fields work.
- [ ] Ragged records remain visible.
- [ ] The header stays fixed during vertical scroll.
- [ ] The source-row column stays fixed during horizontal scroll.
- [ ] The renderer draws visible rows and columns only.
- [ ] One column can sort ascending, descending, or not at all.
- [ ] Exact-value filters work across several columns.
- [ ] Right-click copies complete cell and header text.
- [ ] Each data column resizes independently.
- [ ] Source Buffer edits refresh the Preview.
- [ ] Stale parse results never publish.
- [ ] Workspace restore recreates the Preview.
- [ ] Closing the Preview removes listeners and Buffer ownership.
- [ ] Focused runtime and UI tests pass.
- [ ] Session logs contain useful quiet diagnostics.

## Explicit non-goals

Do not include these functions in the first implementation:

- inline grid editing
- row insertion or deletion
- column insertion or deletion
- cell-range selection
- keyboard spreadsheet navigation
- multi-cell copy formats
- automatic delimiter detection
- custom delimiter entry
- numeric or date type inference
- several active sort columns
- variable-height rows
- automatic column sizing
- column reordering
- a generic reusable table widget
- native parsing code
- worker-pool jobs
- a Preview settings panel
- a performance overlay

Each item can follow after real use shows a need.

The first version should remain one View, one parser, and one display-row vector.
