# Point of Interest Navigation Plan

## Goal

Introduce a first-party **Point of Interest / POI** navigation model that generalizes the current Git/diff-region navigation and extends it to Command Output Views.

A Point of Interest is a navigable target within a view. It may also be activatable, such as a Command Output View reference to a real file location.

## Confirmed UX decisions

- `ctrl+alt+,` and `ctrl+alt+.` become previous/next POI navigation.
- Standard Editors keep their current behavior: their POI provider is Git changes/diff regions.
- Command Output Views provide Text POIs from compiler/build-output file-location references.
- Command Output Text POIs are drawn as underlined text exactly over the matched POI text bounds.
- Git/diff-region POIs are not underlined; their existing visual representation remains the right fit for that provider.
- `alt+r` activates the POI under the **text caret**. Mouse-pointer/link-click activation can be added later.
- POI activation only applies when the target resolves to a real existing file/location.
- POI navigation keeps the current no-wrap behavior and uses Navigation Boundary Feedback at boundaries.
- `alt+8` / `alt+9` navigate previous/next POI in the Right Pane and immediately activate it into the Left Pane.
- Right Pane POI commands preserve the starting focus:
  - If focus starts in the Left Pane, it remains in the Left Pane.
  - If focus starts in the Right Pane, it remains in the Right Pane.

## User-facing commands and keymaps

### Commands

Add a new command family:

- `poi:previous`
- `poi:next`
- `poi:activate`
- `poi:right-previous-activate`
- `poi:right-next-activate`

Existing commands should be migrated cleanly where possible:

- `gitdiff:previous-change` delegates to or is replaced by `poi:previous` for Editors.
- `gitdiff:next-change` delegates to or is replaced by `poi:next` for Editors.
- `diff-view:prev-change` / `diff-view:next-change` should either become DiffView POI-provider behavior or remain view-specific only if needed for sync semantics.

### Keymaps

- `ctrl+alt+,` -> `poi:previous`
- `ctrl+alt+.` -> `poi:next`
- `alt+r` -> `poi:activate`
- `alt+8` -> `poi:right-previous-activate`
- `alt+9` -> `poi:right-next-activate`

`alt+r` must be registered in a way that allows existing contextual uses, such as File Tree open and fuzzy picker confirm, to continue when no activatable POI exists.

## Core model

Add `data/core/poi.lua` as the shared POI module.

### POI record

A POI is a Lua table with these core fields:

```lua
{
  line = 12,
  col = 5,
  line2 = 12,      -- optional, defaults to line
  col2 = 22,       -- optional, defaults to col
  kind = "git-change" | "command-output-location" | "diff-change" | string,
  label = "...",  -- optional display/log/debug text
  activate = function(view, poi, opts) ... end, -- optional
  text_bounds = true, -- optional; true when the POI is a concrete text-range POI
}
```

Conventions:

- `line` / `col` define the navigation anchor.
- `line2` / `col2` define text bounds for caret-hit activation and optional text decoration when present.
- Providers return POIs sorted in document order.
- Activation returns truthy on success, false/nil when unavailable.
- Text POIs are a subset of POIs with concrete text bounds; not every POI is a Text POI.

### Provider protocol

Views may implement:

```lua
function View:get_points_of_interest(opts) end
function View:get_point_of_interest_at(line, col, opts) end
function View:activate_point_of_interest(poi, opts) end
```

`core.poi` should provide helper functions:

- `poi.points_for_view(view, opts)`
- `poi.point_at_caret(view, opts)`
- `poi.next(view, direction, opts)`
- `poi.activate(view, poi, opts)`
- `poi.navigate(view, direction, opts)`

For DocViews, helpers can use `view.doc:get_selection()` and `view.doc:set_selection(...)` through the normal selection-state path.

### Boundary feedback

Use `core.navigation_feedback`:

- no POIs at all: `No Points of Interest`
- no next: `No next Point of Interest`
- no previous: `No previous Point of Interest`
- provider temporarily unavailable: provider-specific warning, e.g. `Git changes are still loading`

## Editor / Git change provider

Current Git-diff navigation lives in `data/plugins/gitdiff_highlight/init.lua`.

Refactor the existing range navigation into a provider:

- Each Git range becomes a POI.
- Anchor line is the range's `current_start`, clamped into the document.
- Deletions use their existing current-line behavior.
- Existing loading/too-large/not-in-repo/no-ranges checks remain provider feedback.
- `ctrl+alt+,` / `ctrl+alt+.` behavior in standard Editors should not visibly change.

Important: avoid hardcoding fallback style/config defaults in this plugin. Any new style/config keys must go into first-party defaults.

## DiffView provider

`data/plugins/diffview.lua` already owns hunk navigation and sync commands.

Plan:

- Expose current diff changes as POIs for each internal DocView.
- Preserve `ctrl+return` sync behavior separately.
- Keep `diff-view:prev-change` / `diff-view:next-change` only if useful as command aliases or internal helpers.
- Ensure comparison views continue to navigate hunks with the new global POI commands.

## Command Output View provider

Implement in `data/plugins/command_slots.lua`, attached to `CommandOutputView`.

### Scope

Only Command Output Views detect output-location Text POIs. The read-only Command Output Document remains plain text; no terminal emulation is required.

### Caching

Cache parsed POIs per output entry / displayed text state:

- Invalidate when output text changes.
- Avoid reparsing on every keypress.
- Store enough source text identity to know when cache is stale.

The output size limit is already bounded by `config.plugins.command_slots.max_output_bytes`; parsing can be line-based and should avoid pathological backtracking.

### Pattern families

Best-effort pattern support should include common compiler/build formats:

1. GCC/Clang/Rust-like:

```text
path/to/file.c:12:34: error: message
path/to/file.c:12: error: message
C:\project\file.c:12:34: error: message
```

2. Rust secondary location:

```text
--> src/main.rs:12:34
```

3. MSVC-like:

```text
C:\project\file.cpp(12): error C1234: message
C:\project\file.cpp(12,34): error C1234: message
src\file.cpp(12,34): error C1234: message
```

4. Python/traceback-like:

```text
File "path/to/file.py", line 12
```

5. Generic quoted path with line/column when unambiguous:

```text
"src/file.ts", line 12, column 34
```

### Path resolution rules

For each match candidate:

1. Trim quotes, whitespace, prefixes such as `-->`, and trailing punctuation that is not part of the path.
2. Reject URLs and URI-like references that are not local file paths.
3. If absolute, normalize and test directly.
4. If relative, resolve against the Root Project path.
5. Candidate is activatable only if the file exists and is not a directory.
6. Clamp line to `>= 1`; clamp column to `>= 1`; if column is absent, use `1`.
7. Preserve matched text bounds for caret-hit activation.

When multiple candidates occur on one line, keep all real file-location POIs in source order.

### Text decoration

Command Output Text POIs should be rendered as underlined text over the exact matched text bounds.

Implementation notes:

- Draw the underline in `CommandOutputView`, not in the core POI model.
- Reuse the provider/cache so drawing does not reparse output every frame.
- Clip decoration to visible lines and visible columns.
- Use the POI's `line`/`col`/`line2`/`col2` bounds. Initial output patterns should produce same-line bounds; multi-line POI bounds are not required for this feature.
- Do not add underline rendering to Git/diff-region POIs. Those are region/navigation POIs, not Text POIs.
- If a future non-command-output view exposes Text POIs, it can opt into a shared helper later.

### Activation

Command Output POI activation opens the target in the Left Pane:

```lua
panes.open_path(path, {
  pane = "left",
  line = poi.target_line,
  col = poi.target_col,
  preserve_focus = opts and opts.preserve_focus,
})
```

For ordinary `alt+r` while focused in Command Output View, preserve focus according to the command's opts. The default should be sensible for repeated activation from output; the Right Pane navigation commands explicitly preserve the starting focus.

## Right Pane POI navigation

`poi:right-previous-activate` / `poi:right-next-activate` should target the active/restorable Right Pane focus view.

Target selection:

1. If the active view is a Right Pane focus view, use that owner/focus view.
2. Otherwise use the current visible Right Pane view's restorable focus view.
3. If that view is a container, ask it for its focus view, e.g. `CommandOutputPanel:get_focus_view()`.
4. If there is no Right Pane POI provider or no POIs, show boundary feedback.

Flow:

1. Save `starting_focus = core.active_view`.
2. Navigate Right Pane target view to previous/next POI.
3. Activate the selected POI into the Left Pane.
4. Restore `starting_focus` if it is still valid and the command is configured to preserve focus.

This is what allows staying in the editor while stepping through compiler errors in the Command Output View, and also staying in the Command Output View when focus started there.

## Testing plan

Follow red-green regression workflow for behavior changes.

### Runtime tests

Add parser-focused tests for Command Output POI extraction:

- Unix relative `src/main.c:10:2`
- Windows absolute `C:\...\main.c:10:2`
- MSVC `file.cpp(10,2)`
- Rust `--> src/main.rs:10:2`
- Python `File "src/main.py", line 10`
- Multiple POIs on one line when real files exist
- Reject nonexistent files
- Reject URLs
- Column missing defaults to 1

### UI tests

Add UI tests under `tests/lua/ui`:

- `poi:next` / `poi:previous` navigate an Editor's Git-change provider without wrapping.
- Command Output View POI navigation moves the caret to detected output locations.
- Command Output View draws underlines only for detected Text POI bounds.
- `poi:activate` opens an existing referenced file in Left Pane at the expected line/column.
- `poi:right-next-activate` from Left Pane activates Command Output POIs and preserves Left Pane focus.
- `poi:right-next-activate` from Right Pane activates Command Output POIs and preserves Right Pane focus.

Do not test exact shortcut bindings; invoke commands with `command.perform(...)`.

## Implementation phases

1. Add `core.poi` model, navigation helpers, commands, keymaps, and no-provider feedback.
2. Refactor Git change navigation into an Editor POI provider while preserving current behavior.
3. Wire DiffView hunk navigation into the POI provider model.
4. Add Command Output View parser/provider and activation.
5. Add Right Pane navigate-and-activate commands.
6. Add targeted tests, run relevant Lua syntax checks and Meson test targets.
7. Remove obsolete duplicated navigation code where cleanly migrated.

## Validation commands

For Lua syntax after edits:

```sh
./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua \
  data/core/poi.lua \
  data/plugins/gitdiff_highlight/init.lua \
  data/plugins/diffview.lua \
  data/plugins/command_slots.lua
```

Targeted tests:

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 anvil:lua-ui --print-errorlogs --test-args ui/command_slots.lua
```

Broader Anvil suite:

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 --suite anvil --print-errorlogs
```
