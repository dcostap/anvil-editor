-- mod-version:3
-- The UI Gallery: a Dialog that shows each control and surface of core.ui, for design reviews and render checks.
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local style = require "core.style"
local ui = require "core.ui"
local layout = require "core.ui.layout"
local surface = require "core.ui.surface"
local dialog = require "core.ui.dialog"
local Button = require "core.ui.button"
local Checkbox = require "core.ui.checkbox"
local List = require "core.ui.list"
local Nav = require "core.ui.nav"
local RadioGroup = require "core.ui.radio_group"
local Segmented = require "core.ui.segmented"
local Switch = require "core.ui.switch"
local TextField = require "core.ui.text_field"

local gallery = {}

local Column, Row, Group, Field, Text = layout.Column, layout.Row, layout.Group, layout.Field, layout.Text

------------------------------------------------------------------------------------------------------------------
-- Pages

local function buttons_page()
  local function sizes(kind, label, icon)
    return Row {
      Button { kind = kind, label = label, icon = icon },
      Button { kind = kind, label = label, size = "small" },
      Button { kind = kind, label = label, size = "tiny" },
    }
  end
  return Column {
    Group {
      title = "Kinds",
      Field { title = "Primary", description = "The main choice of a Dialog.", control = sizes("primary", "Save") },
      Field { title = "Secondary", description = "Other choices.", control = sizes("secondary", "Cancel") },
      Field { title = "Ghost", description = "Quiet choices, such as icon buttons.", control = sizes("ghost", "Details") },
      Field { title = "Danger", description = "A choice that removes something.", control = sizes("danger", "Remove") },
      Field {
        title = "Danger primary", description = "The main choice, when it removes something.",
        control = sizes("danger_primary", "Delete"),
      },
    },
    Group {
      title = "Icons",
      Field {
        title = "Icon and label",
        control = Row {
          Button { kind = "secondary", icon = ui.icons.add, label = "Add Folder" },
          Button { kind = "primary", icon = ui.icons.check, label = "Apply" },
        },
      },
      Field {
        title = "Icon only",
        control = Row {
          Button { kind = "ghost", icon = ui.icons.close },
          Button { kind = "secondary", icon = ui.icons.delete, size = "small" },
          Button { kind = "ghost", icon = ui.icons.search, size = "small" },
        },
      },
    },
    Group {
      title = "States",
      Field {
        title = "Disabled", description = "Disabled controls fade, and take no input.",
        control = Row {
          Button { kind = "primary", label = "Save", enabled = false },
          Button { kind = "secondary", label = "Cancel", enabled = false },
          Button { kind = "danger", label = "Remove", enabled = false },
        },
      },
    },
  }
end

local function inputs_page()
  local refused = TextField { text = "Dev Server", placeholder = "Name" }
  refused:set_error("A database with this name exists.")
  return Column {
    Group {
      title = "Text fields",
      Field { title = "Name", stacked = true, control = TextField { placeholder = "Development" } },
      Field {
        title = "Password", description = "A secret field hides its text and refuses Copy.",
        stacked = true, control = TextField { text = "correct horse", secret = true },
      },
      Field {
        title = "Refused text", description = "A refused text has a red rim until the next edit.",
        stacked = true, control = refused,
      },
      Field { title = "Disabled", stacked = true, control = TextField { text = "localhost", enabled = false } },
    },
    Group {
      title = "Settings rows",
      Field {
        title = "Server", description = "A field at the right of its row.",
        control = TextField { text = "test-only.invalid" },
      },
      Field {
        title = "Port", control = TextField { text = "1433", width = 96 },
      },
    },
  }
end

local function choices_page()
  return Column {
    Group {
      title = "Switches",
      Field {
        title = "Save automatically", description = "A switch applies its change at once.",
        control = Switch { value = true },
      },
      Field { title = "Check for updates", control = Switch { value = false } },
      Field { title = "Disabled", control = Switch { value = true, enabled = false } },
    },
    Group {
      title = "Check boxes",
      Column {
        gap = 12,
        Checkbox { label = "Include ignored files", value = true },
        Checkbox {
          label = "Search in Terminal Sessions", description = "Uses the screen that each host saved last.",
        },
        Checkbox { label = "Some Projects", value = "mixed" },
        Checkbox { label = "Disabled", value = true, enabled = false },
      },
    },
    Group {
      title = "Radio group",
      RadioGroup {
        value = "full",
        options = {
          { value = "full", label = "Full control", description = "The device can edit files and run shells." },
          { value = "view", label = "View", description = "The device can only read." },
          { value = "none", label = "No access", enabled = false },
        },
      },
    },
    Group {
      title = "Segmented",
      Field {
        title = "Authentication",
        control = Segmented {
          value = "windows",
          options = { { value = "windows", label = "Windows" }, { value = "sql", label = "SQL Login" } },
        },
      },
      Field {
        title = "Disabled",
        control = Segmented {
          value = "dark", enabled = false,
          options = {
            { value = "light", label = "Light" }, { value = "dark", label = "Dark" }, { value = "auto", label = "Auto" },
          },
        },
      },
    },
  }
end

local LIST_ROWS = {
  { name = "anvil-editor", detail = "D:\\Projects\\c_projects" },
  { name = "t3code-redesign", detail = "D:\\Projects" },
  { name = "notes", detail = "C:\\Users\\me\\Documents" },
  { name = "scratch", detail = "Scratch" },
  { name = "data", detail = "Vendored" },
  { name = "build-windows-x86_64", detail = "Ignored" },
  { name = "tools", detail = "D:\\Projects\\c_projects\\anvil-editor" },
  { name = "android", detail = "D:\\Projects\\c_projects\\anvil-editor" },
  { name = "docs", detail = "D:\\Projects\\c_projects\\anvil-editor" },
  { name = "tests", detail = "D:\\Projects\\c_projects\\anvil-editor" },
}

local function lists_page()
  local m = ui.metrics()
  local function draw_row(row, x, y, w, h, state)
    local font, small = ui.font(), ui.role_font("description")
    local pad = m.pad_x
    local detail_w = math.floor(w * 0.5)
    common.draw_text(small, style.dialog_text_muted, ui.fit_text(small, row.detail, detail_w, true), "right",
      x, y, w - pad, h)
    common.draw_text(font, state.selected and style.dialog_text_strong or style.dialog_text,
      ui.fit_text(font, row.name, w - detail_w - 2 * pad), "left", x + pad, y, w, h)
  end
  return Column {
    Group {
      title = "List",
      Column {
        gap = 8,
        Text { role = "description", text = "Up and Down move the selection, and the highlights glide." },
        List { rows = LIST_ROWS, row_height = m.control_h, draw_row = draw_row },
      },
    },
  }
end

-- A sample of one surface, with its name below it.
local Swatch = layout.Node:extend()

function Swatch:new(options)
  Swatch.super.new(self, options)
  self.surface = options.surface
end

function Swatch:content_width() return layout.px(112) end
function Swatch:content_height() return layout.px(72) + ui.role_font("meta"):get_height() + layout.px(8) end

function Swatch:draw_node()
  local h = layout.px(72)
  surface.draw(self.surface, self.x, self.y, self.w, h, ui.metrics().control_radius)
  local meta = ui.role_font("meta")
  common.draw_text(meta, style.dialog_text_muted, self.surface, "left", self.x, self.y + h + layout.px(8),
    self.w, meta:get_height())
end

local function look_page()
  local function swatches(names)
    local row = Row { gap = 12 }
    for _, name in ipairs(names) do row.children[#row.children + 1] = Swatch { surface = name } end
    return row
  end
  return Column {
    Group {
      title = "Text roles",
      Column {
        gap = 10,
        Text { role = "title", text = "Title: Project Databases" },
        Text { role = "strong", text = "Strong: Development" },
        Text { role = "label", text = "Label: Save automatically" },
        Text { role = "body", text = "Body: Each change applies at once. There is no Save or Cancel." },
        Text { role = "description", text = "Description: Uses the screen that each host saved last." },
        Text { role = "meta", text = "Meta: 12 files · 3 folders" },
      },
    },
    Group {
      title = "Surfaces",
      Column {
        gap = 16,
        swatches { "raised", "raised_hover", "lit", "lit_hover" },
        swatches { "well", "ghost_hover", "selected", "group" },
        swatches { "switch_off", "switch_on", "danger_hover", "danger_primary" },
      },
    },
  }
end

-- A sample box for the Layout page: a raised surface with a label, at a natural size.
local Block = layout.Node:extend()

function Block:new(options)
  Block.super.new(self, options)
  self.label = options.label or ""
  self.natural_w, self.natural_h = options.w or 0, options.h or 32
end

function Block:content_width()
  return math.max(layout.px(self.natural_w), ui.role_font("meta"):get_width(self.label) + layout.px(16))
end

function Block:content_height() return layout.px(self.natural_h) end

function Block:draw_node()
  surface.draw("raised", self.x, self.y, self.w, self.h, ui.metrics().small_radius)
  local meta = ui.role_font("meta")
  common.draw_text(meta, style.dialog_text_muted, ui.fit_text(meta, self.label, self.w - layout.px(8)), "center",
    self.x, self.y, self.w, self.h)
end

-- A sunken frame around one container, so its edges show.
local Frame = layout.Node:extend()

function Frame:content_width() return self.children[1]:width() end
function Frame:content_height(w) return self.children[1]:height(w) end

function Frame:place(x, y, w, h)
  Frame.super.place(self, x, y, w, h)
  self.children[1]:place(x, y, w, h)
end

function Frame:draw_node(dialog)
  surface.draw("well", self.x, self.y, self.w, self.h, ui.metrics().control_radius)
  Frame.super.draw_node(self, dialog)
end

local function layout_page()
  local function frame(child, options)
    options = options or {}
    options[1] = child
    return Frame(options)
  end
  local function example(title, description, control)
    return Field { title = title, description = description, stacked = true, control = control }
  end
  local justify = Column { gap = 6 }
  for _, value in ipairs { "start", "center", "end", "between" } do
    justify.children[#justify.children + 1] = frame(Row {
      justify = value, gap = 6, padding = 6,
      Block { label = value, w = 72 }, Block { w = 40 }, Block { w = 40 },
    })
  end
  local align = Row { gap = 8 }
  for _, value in ipairs { "start", "center", "end", "stretch" } do
    align.children[#align.children + 1] = frame(Row {
      align = value, gap = 6, padding = 6, height = 88,
      Block { label = value, h = 24 }, Block { w = 24, h = 48 },
    }, { grow = 1 })
  end
  return Column {
    Group {
      title = "Grow and shrink",
      example("Weights", "grow = 2 takes twice the free width of grow = 1. A child without grow keeps its width.",
        frame(Row {
          gap = 6, padding = 6,
          Block { label = "natural" }, Block { label = "grow = 2", grow = 2 }, Block { label = "grow = 1", grow = 1 },
        })),
      example("Limits", "max_width stops a growing child, and the others take the rest.",
        frame(Row {
          gap = 6, padding = 6,
          Block { label = "grow, max_width = 160", grow = 1, max_width = 160 }, Block { label = "grow", grow = 1 },
        })),
      example("Shrink", "Children that are too wide shrink in proportion to their widths, down to min_width.",
        frame(Row {
          gap = 6, padding = 6,
          Block { label = "400 wide, min_width = 240", w = 400, min_width = 240 }, Block { label = "400 wide", w = 400 },
        })),
    },
    Group {
      title = "Placement",
      example("Justify", "Where the children go along a Row or Column when space is free.", justify),
      example("Align", "Where each child goes across the axis. A Row centres by default.", align),
      example("Grow in a Column", "A Spacer with grow = 1 pushes the buttons to the bottom of a 160 px Column.",
        frame(Column {
          height = 160, padding = 12, gap = 8,
          Text { role = "description", text = "Content at the top." },
          layout.Spacer { grow = 1 },
          Row { justify = "end", Button { label = "Cancel", size = "small" }, Button { label = "Save", kind = "primary", size = "small" } },
        })),
    },
    Group {
      title = "Form",
      example("Server", "The host grows, the port keeps 96 px, and the button keeps its width.",
        Row {
          TextField { text = "db.example.invalid", grow = 1, min_width = 120 },
          TextField { text = "1433", width = 96 },
          Button { label = "Test" },
        }),
    },
  }
end

local PAGES = {
  { id = "buttons", label = "Buttons", icon = ui.icons.button, build = buttons_page },
  { id = "inputs", label = "Inputs", icon = ui.icons.form, build = inputs_page },
  { id = "choices", label = "Choices", icon = ui.icons.toggle, build = choices_page },
  { id = "lists", label = "Lists", icon = ui.icons.view_list, build = lists_page },
  { id = "layout", label = "Layout", icon = ui.icons.shape, build = layout_page },
  { id = "look", label = "Type and Surfaces", icon = ui.icons.palette, build = look_page },
}

------------------------------------------------------------------------------------------------------------------
-- The Dialog

local Gallery = dialog.Dialog:extend()

function Gallery:new()
  Gallery.super.new(self, {
    title = "UI Gallery",
    description = "Each control and surface of core.ui, in the current Color Theme.",
    width = 900,
  })
  self.pages = {}
  self.page_scroll = layout.Scroll { height = 560, grow = true, layout.Node {} }
  self.nav = Nav {
    items = PAGES, width = 196,
    on_select = function(item) self:show_page(item.id) end,
  }
  self:set_body(Row { gap = 24, align = "start", self.nav, self.page_scroll })
  self:show_page(PAGES[1].id)
end

---Show the page `id`. Each page keeps its controls' state while the Gallery is open.
function Gallery:show_page(id)
  for _, page in ipairs(PAGES) do
    if page.id == id then
      self.pages[id] = self.pages[id] or page.build()
      self.page_id = id
      self.nav.selected = id
      self.page_scroll:set_child(self.pages[id])
      core.log_quiet("UI Gallery page: %s", id)
      return true
    end
  end
  return false
end

---Open the Gallery at the page `id`, or at its first page.
function gallery.open(id)
  local instance = Gallery()
  if id then instance:show_page(id) end
  return instance:open(instance.nav)
end

gallery.pages = PAGES
gallery.Gallery = Gallery

command.add(nil, {
  ["ui_gallery:open"] = command.palette(function() gallery.open() end),
})

return gallery
