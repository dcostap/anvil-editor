# Building Dialogs

A Dialog is a modal card over the Project, for management tasks that need more than a prompt. This guide shows how to build one with `core.ui`. Open the UI Gallery (`ui_gallery:open`) to see each control in each Color Theme.

Each module in `data/core/ui` starts with a comment that lists its options. This guide does not repeat them. Read it first, then read the comment of each module that you use.

## A minimal Dialog

```lua
local command = require "core.command"
local dialog = require "core.ui.dialog"
local layout = require "core.ui.layout"
local Button = require "core.ui.button"
local Switch = require "core.ui.switch"
local TextField = require "core.ui.text_field"

local Column, Row, Group, Field = layout.Column, layout.Row, layout.Group, layout.Field

local ServerDialog = dialog.Dialog:extend()

function ServerDialog:new(settings)
  ServerDialog.super.new(self, { title = "Server", description = "Where the plugin connects.", width = 560 })
  self.host = TextField {
    text = settings.host,
    placeholder = "host.example",
    on_submit = function(text)
      if text == "" then return false, "Type a host." end
      settings.host = text
    end,
  }
  self:set_body(Column {
    Group {
      Field { title = "Host", stacked = true, control = self.host },
      Field {
        title = "Use TLS",
        description = "Encrypt the connection.",
        control = Switch { value = settings.tls, on_change = function(value) settings.tls = value end },
      },
    },
  })
  self.footer = Row {
    justify = "end",
    Button { label = "Done", kind = "primary", on_click = function() self:close() end },
  }
end

command.add(nil, {
  ["example:server"] = command.palette(function()
    return ServerDialog(require("core.config").plugins.example):open()
  end),
})
```

These are the parts:

- `dialog.Dialog` draws the card, the title, the description and the close button. It dims the Window and takes all input while it is open.
- `set_body` takes a layout node. The body scrolls when the Window is too short, and a focused control scrolls into view.
- `self.footer` is a node below the body. It does not scroll.
- `open(control)` puts keyboard focus on `control`, or on the first control that takes focus.
- `command.palette` puts the command in the Command Palette. A plain function makes a command that only keys and code can run.

## Rules

- **Each change applies at once.** There is no Save or Cancel. A Switch saves in `on_change`. A Text Field saves in `on_submit`, which runs on Enter and when the field loses focus. A Done button only closes the Dialog.
- **Refuse bad input in the control.** `on_submit` returns `false, "message"` to keep the text and show a red rim. `on_change` returns `false` to refuse a choice.
- **Use layout nodes, not coordinates.** Do not override `layout_content` or `draw_content`. Some older Dialogs still use them. Do not copy those Dialogs.
- **Use the theme.** Controls draw with `style.dialog_surfaces` and the `dialog_text*` colors. To draw your own content, use `core.ui.surface`, `ui.role_font(role)` and `ui.role_color(role)`. Do not write colors or font sizes in a Dialog.
- **Sizes are pixels at scale 1.** Layout options such as `gap`, `width` and `padding` scale with the display and Zoom. In your own drawing code, use `layout.px(n)` or `ui.metrics()`.
- **Put defaults in the defaults layer.** A first-party setting gets its default in `data/plugins/anvil_defaults.lua`, not in the Dialog.
- **Log state changes** with `core.log_quiet`.

## Layout

`Row` and `Column` work like CSS flexbox. The comment at the top of `data/core/ui/layout.lua` gives each option. In short:

| Option | On | Values |
|---|---|---|
| `gap` | Row, Column | Space between children. A Row defaults to 8, a Column to 16. |
| `padding` | Row, Column | `8`, `{ vertical, horizontal }` or `{ top, right, bottom, left }` |
| `justify` | Row, Column | `"start"`, `"center"`, `"end"`, `"between"` |
| `align` | Row, Column | `"start"`, `"center"`, `"end"`, `"stretch"`. A Row centres, a Column stretches. |
| `grow` | each node and control | A weight for a share of the free space. `true` is 1. |
| `width`, `height` | each node and control | A fixed size |
| `min_width`, `max_width`, `min_height`, `max_height` | each node and control | Limits, also when a Row grows or shrinks the node |

A Row shrinks children that are too wide, in proportion to their widths, down to their `min_width`. Text in a shrunk child wraps. A Column does not shrink its children.

The other nodes:

- `Text { text = ..., role = ... }`: text that wraps. Roles are `title`, `strong`, `label`, `body`, `description` and `meta`.
- `Field { title, description, control }`: a settings row, with the control at the right. `stacked = true` puts the control below the text at the full width. Use it for a Text Field.
- `Group { title = ..., ... }`: rows on a card, with a line between them, and an optional title above the card.
- `Separator`, and `Spacer { height = 12 }` or `Spacer { grow = 1 }`.
- `Scroll { height = 400, child }`: a scrolling area. The Dialog body already has one.

### Patterns

A form row: the host grows, the port has a fixed width, and the button keeps its natural width.

```lua
Row {
  TextField { text = host, grow = 1, min_width = 120 },
  TextField { text = port, width = 96 },
  Button { label = "Test" },
}
```

A list with a detail panel beside it:

```lua
Row {
  gap = 16, align = "start",
  List { rows = rows, row_height = ui.metrics().control_h, draw_row = draw_row, width = 220,
    on_select = function(row) self:show(row) end },
  Column { grow = 1, gap = 12, self.name_field, self.role_choice },
}
```

A footer with an action at the left and the main button at the right:

```lua
self.footer = Row {
  justify = "between",
  Button { label = "Add Folder", icon = ui.icons.add },
  Button { label = "Done", kind = "primary", on_click = function() self:close() end },
}
```

Content at the top and buttons at the bottom of an area with a fixed height:

```lua
Column { height = 240, Text { text = "..." }, layout.Spacer { grow = 1 }, Row { justify = "end", ... } }
```

## Controls

| Need | Control |
|---|---|
| An action | `Button`. `kind` is `primary` for the main action, `secondary` (the default), `ghost` for quiet and icon buttons, `danger` and `danger_primary` for an action that removes something. `size` is `default`, `small` or `tiny`. |
| One line of text | `TextField`. `secret = true` hides the text and refuses Copy. |
| A setting that is on or off | `Switch`, in a `Field` |
| One item of a set of items, or a "mixed" state | `Checkbox` |
| One of 2 to 4 short choices | `Segmented` |
| One of several choices that need a description | `RadioGroup` |
| A list of items with one selected | `List`. You draw each row with `draw_row`. |
| Pages of a large Dialog | `Nav` at the left, with a `Scroll` beside it. The UI Gallery does this. |

Each control takes `enabled` and `visible`. Change them at any time; the next frame shows the change. A disabled control fades and refuses input. A control that is not visible takes no space.

To change the content, change the controls (`set_value`, `set_text`, `set_rows`, `set_options`), or give a node new children with `set_children`. `Dialog:on_update()` runs in each frame before the layout, for state that comes from outside the Dialog.

Icons are in `ui.icons`. Each one must exist in the Nerd Font that Anvil ships. Check a new icon's code point before you add it.

## A new kind of control or node

Most Dialogs need only the controls above. When you need a new one:

- **A node that only draws**, such as a preview: extend `layout.Node`. Give `content_width()` and `content_height(w)`, and draw in `draw_node(dialog)`. `self.x`, `self.y`, `self.w` and `self.h` hold its rect.
- **A control that takes input**: extend `core.ui.control`. Give its natural size in `measure()`, and draw in `draw(focused)`. Set `focusable = true` to take Tab focus. The comment at the top of `control.lua` lists the input methods.
- Draw its parts with `surface.draw(name, x, y, w, h, radius)`. Draw a focus ring with `ui.draw_ring` when `focused` is true.
- Add it to the UI Gallery, so it shows in each Color Theme.

## Keys

The Dialog takes Tab, Enter and Escape. Tab moves through the controls in layout order. Enter activates the focused control. Escape first undoes an unsubmitted text edit, then closes the Dialog.

Other keys reach the focused control as editor commands, with the user's bindings. For example, Up and Down reach a List as `move_to_previous_line` and `move_to_next_line`. A Text Field gets the editor's line commands. Never test a key binding; test the command or the method.

## Tests and render checks

- Drive the Dialog through its methods and its controls, as `tests/lua/ui/dialog.lua` does: `instance:focus(control)`, `instance:perform("move_to_next_line")`, `command.perform("dialog:confirm")`, `field:submit()`, `switch:set_value(true)`. Check the saved settings and the shown state.
- Call `dialog.update()` after a change, to run a layout before you check positions or focus.
- For a visual change, add a render scenario to `tools/run_render_perf_gate.py` and open the Dialog in `data/plugins/perf_benchmark.lua`, as `databases-dialog` does. Read [the render gate](../tools/RENDER_PERF_GATE.md) first.
- After a change to `core.ui`, run `ui/dialog.lua`, `ui/ui_layout.lua` and `ui/graphics.lua`, and check the `ui-gallery-*` render scenarios.
