-- mod-version:3
-- Runtime-only editor for currently loaded theme colors.

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local Widget = require "widget"
local Button = require "widget.button"
local ColorPicker = require "widget.colorpicker"
local Label = require "widget.label"
local ListBox = require "widget.listbox"
local TextBox = require "widget.textbox"

local theme_editor = {}

local editor

local function is_identifier(text)
  return type(text) == "string" and text:match("^[%a_][%w_]*$") ~= nil
end

local function field_expr(parent, key)
  if is_identifier(key) then
    return parent .. "." .. key
  end
  return parent .. "[" .. string.format("%q", tostring(key)) .. "]"
end

local function clamp_byte(value, default)
  value = tonumber(value) or default or 0
  return common.clamp(common.round(value), 0, 255)
end

local function is_color(value)
  return type(value) == "table"
    and type(value[1]) == "number"
    and type(value[2]) == "number"
    and type(value[3]) == "number"
    and (value[4] == nil or type(value[4]) == "number")
end

local function normalize_color(value)
  return {
    clamp_byte(value and value[1], 0),
    clamp_byte(value and value[2], 0),
    clamp_byte(value and value[3], 0),
    clamp_byte(value and value[4], 255),
  }
end

local function copy_color(value)
  local color = normalize_color(value)
  return { color[1], color[2], color[3], color[4] }
end

local function color_text(value)
  local color = normalize_color(value)
  return string.format("#%02X%02X%02X%02X", color[1], color[2], color[3], color[4])
end

local function same_color(a, b)
  if not a or not b then return false end
  a, b = normalize_color(a), normalize_color(b)
  return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4]
end

local function snapshot_colors(entries)
  local snapshot = {}
  for _, entry in ipairs(entries or {}) do
    snapshot[entry.expr] = copy_color(entry.container[entry.key])
  end
  return snapshot
end

local function snapshot_color_refs(entries)
  local snapshot = {}
  for _, entry in ipairs(entries or {}) do
    snapshot[entry.expr] = entry.container[entry.key]
  end
  return snapshot
end

local excluded_tables = {
  syntax_fonts = true,
}

local function collect_table(entries, tbl, expr, seen, depth)
  if type(tbl) ~= "table" or seen[tbl] then return end
  seen[tbl] = true
  if depth > 4 then return end

  for key, value in pairs(tbl) do
    if type(key) == "string" then
      local child_expr = field_expr(expr, key)
      if is_color(value) then
        entries[#entries + 1] = {
          expr = child_expr,
          display = child_expr,
          container = tbl,
          key = key,
        }
      elseif type(value) == "table" and not excluded_tables[key] then
        collect_table(entries, value, child_expr, seen, depth + 1)
      end
    end
  end
end

local function collect_color_entries()
  local entries = {}
  collect_table(entries, style, "style", {}, 0)
  table.sort(entries, function(a, b) return a.display < b.display end)
  return entries
end

local FRIENDLY_NAMES = {
  ["style.background"] = { "Core UI", "Window background" },
  ["style.background2"] = { "Core UI", "Raised background" },
  ["style.background3"] = { "Core UI", "Popup background" },
  ["style.text"] = { "Core UI", "Main text" },
  ["style.dim"] = { "Core UI", "Dim text" },
  ["style.accent"] = { "Core UI", "Accent" },
  ["style.selection"] = { "Editor", "Selection" },
  ["style.line_highlight"] = { "Editor", "Current line" },
  ["style.line_number"] = { "Editor", "Line number" },
  ["style.line_number2"] = { "Editor", "Active line number" },
  ["style.caret"] = { "Editor", "Caret" },
  ["style.whitespace"] = { "Editor", "Whitespace" },
  ["style.good"] = { "Status / Diagnostics", "Good" },
  ["style.warn"] = { "Status / Diagnostics", "Warning" },
  ["style.error"] = { "Status / Diagnostics", "Error" },
  ["style.gitdiff_addition"] = { "Git / File Tree", "Git addition" },
  ["style.gitdiff_modification"] = { "Git / File Tree", "Git modification" },
  ["style.gitdiff_deletion"] = { "Git / File Tree", "Git deletion" },
}

local function prettify_key(key)
  key = tostring(key or ""):gsub("_", " "):gsub("%.", " ")
  return (key:gsub("^%l", string.upper))
end

local function entry_presentation(entry)
  local mapped = FRIENDLY_NAMES[entry.expr]
  if mapped then return mapped[1], mapped[2] end

  local expr = entry.expr
  local syntax = expr:match('^style%.syntax%["(.*)"%]$') or expr:match("^style%.syntax%.(.+)$")
  if syntax then return "Syntax", prettify_key(syntax) end
  local log = expr:match('^style%.log%["(.*)"%]%.color$') or expr:match("^style%.log%.(.+)%.color$")
  if log then return "Logs", prettify_key(log) .. " log" end

  local key = expr:match("^style%.(.+)$") or expr
  if key:match("^diff_") then return "Diff View", prettify_key(key:gsub("^diff_", "")) end
  if key:match("^gitdiff_") then return "Git / File Tree", prettify_key(key:gsub("^gitdiff_", "Git ")) end
  if key:match("^filetree_git_") then return "Git / File Tree", prettify_key(key:gsub("^filetree_git_", "File tree git ")) end
  if key:match("^filetree_operation_") then return "File Operations", prettify_key(key:gsub("^filetree_operation_", "")) end
  if key:match("^filetree_") then return "File Tree", prettify_key(key:gsub("^filetree_", "")) end
  if key:match("^diagnostic_") then return "Status / Diagnostics", prettify_key(key:gsub("^diagnostic_", "")) end
  if key:match("^titlebar") or key:match("^tab_") then return "Title Bar", prettify_key(key) end
  if key:match("search") or key:match("fuzzy") then return "Search", prettify_key(key) end
  if key:match("bracketmatch") then return "Bracket Matching", prettify_key(key:gsub("^bracketmatch_", "")) end
  if key:match("performance_hud") then return "Performance HUD", prettify_key(key:gsub("^performance_hud_", "")) end
  if key:match("nagbar") then return "Messages", prettify_key(key) end
  return "Other", prettify_key(key)
end

local CATEGORY_ORDER = {
  ["Core UI"] = 1,
  ["Title Bar"] = 2,
  ["Editor"] = 3,
  ["Syntax"] = 4,
  ["Diff View"] = 5,
  ["Git / File Tree"] = 6,
  ["File Tree"] = 7,
  ["File Operations"] = 8,
  ["Status / Diagnostics"] = 9,
  ["Search"] = 10,
  ["Messages"] = 11,
  ["Bracket Matching"] = 12,
  ["Performance HUD"] = 13,
  ["Logs"] = 14,
  ["Other"] = 99,
}

local function collect_color_groups(entries)
  entries = entries or collect_color_entries()
  local by_color, groups = {}, {}
  for _, entry in ipairs(entries) do
    local color = entry.container[entry.key]
    local key = tostring(color)
    local group = by_color[key]
    if not group then
      group = { entries = {}, display = "" }
      by_color[key] = group
      groups[#groups + 1] = group
    end
    group.entries[#group.entries + 1] = entry
  end
  for _, group in ipairs(groups) do
    local raw_names = {}
    table.sort(group.entries, function(a, b) return a.display < b.display end)
    group.category, group.label = entry_presentation(group.entries[1])
    for _, entry in ipairs(group.entries) do
      local category, label = entry_presentation(entry)
      if (CATEGORY_ORDER[category] or 99) < (CATEGORY_ORDER[group.category] or 99) then
        group.category, group.label = category, label
      end
      raw_names[#raw_names + 1] = entry.display
    end
    group.raw_display = table.concat(raw_names, "\n")
    group.display = group.category .. " " .. group.label .. "\n" .. group.raw_display
    group.primary = group.entries[1]
  end
  table.sort(groups, function(a, b)
    local ao = CATEGORY_ORDER[a.category] or 99
    local bo = CATEGORY_ORDER[b.category] or 99
    if ao ~= bo then return ao < bo end
    if a.label ~= b.label then return a.label < b.label end
    return a.raw_display < b.raw_display
  end)
  return groups
end

local function group_changed(group, original_colors)
  if not original_colors then return false end
  for _, entry in ipairs(group.entries) do
    if not same_color(entry.container[entry.key], original_colors[entry.expr]) then
      return true
    end
  end
  return false
end

local function row_for_group(group, original_colors)
  local primary = group and group.primary
  local color = primary and primary.container and primary.container[primary.key]
  local changed = group_changed(group, original_colors)
  local label = (changed and "* " or "") .. group.label
  local value = color_text(color)
  if group and #group.entries > 1 then
    value = value .. string.format("\n%d linked keys", #group.entries)
  end
  if changed then value = value .. "\nchanged" end
  return {
    changed and style.accent or style.dim, group.category,
    ListBox.COLEND,
    style.text, label,
    ListBox.NEWLINE,
    style.dim, group.raw_display,
    ListBox.COLEND,
    color or style.text, value,
  }
end

local function export_theme_text(entries, original_colors)
  entries = entries or collect_color_entries()
  local lines = {
    "local style = require \"core.style\"",
    "",
    "-- Generated by Anvil's Runtime Theme Editor.",
    "-- Paste into a color theme file if you want to keep these runtime colors.",
    "",
  }

  local changed_count = 0
  for _, entry in ipairs(entries) do
    local color = normalize_color(entry.container[entry.key])
    if not original_colors or not same_color(color, original_colors[entry.expr]) then
      changed_count = changed_count + 1
      lines[#lines + 1] = string.format(
        "%s = {%d, %d, %d, %d}",
        entry.expr,
        color[1], color[2], color[3], color[4]
      )
    end
  end

  if changed_count == 0 then
    lines[#lines + 1] = "-- No runtime theme color changes."
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "return style"
  return table.concat(lines, "\n")
end

---@class plugins.theme_editor.view : widget
local ThemeEditor = Widget:extend()

function ThemeEditor:new()
  ThemeEditor.super.new(self)
  self.name = "Runtime Theme Editor"
  self.draggable = true
  self.scrollable = false
  self.entries = collect_color_entries()
  self.groups = collect_color_groups(self.entries)
  self.original_colors = snapshot_colors(self.entries)
  self.original_color_refs = snapshot_color_refs(self.entries)
  self.selected_group = nil
  self.suppress_picker_change = false
  self.resizing = nil

  self:set_size(780 * SCALE, 560 * SCALE)
  self:set_position(80 * SCALE, 80 * SCALE)

  self.title = Label(self, "Runtime Theme Editor")
  self.help = Label(self, "Runtime-only edits. Rows are friendly theme concepts; smaller text shows the raw style keys.", true)
  self.selected = Label(self, "Select a theme color.", true)
  self.filter = TextBox(self, "", "filter colors or keys...")
  self.list = ListBox(self)
  self.list.border.width = 0
  self.list:add_column("Area", 90 * SCALE, false)
  self.list:add_column("Theme color", 230 * SCALE, false)
  self.list:add_column("Value", 105 * SCALE, false)

  self.picker = ColorPicker(self, {255, 255, 255, 255})
  self.copy_button = Button(self, "Copy 0 Changes")
  self.reset_button = Button(self, "Reset Selected")
  self.reset_all_button = Button(self, "Reset All")
  self.refresh_button = Button(self, "Refresh")
  self.close_button = Button(self, "Close")

  local this = self

  function self.filter:on_change(value)
    this.list:filter(value)
  end

  function self.list:on_row_click(_, data)
    this:select_group(data)
  end

  function self.picker:on_change(value)
    if this.suppress_picker_change or not this.selected_group then return end
    this:apply_color_to_selected(value)
  end

  function self.copy_button:on_click()
    local changed = this:changed_entries()
    system.set_clipboard(export_theme_text(changed))
    core.log("Runtime theme changes copied to clipboard (%d colors)", #changed)
  end

  function self.reset_button:on_click()
    this:reset_selected()
  end

  function self.reset_all_button:on_click()
    this:reset_all_changes()
  end

  function self.refresh_button:on_click()
    this:reload_entries()
  end

  function self.close_button:on_click()
    this:hide()
  end

  self:reload_entries()
end

function ThemeEditor:update_change_count()
  local count = #self:changed_entries()
  self.copy_button:set_label(string.format("Copy %d Changes", count))
end

function ThemeEditor:reload_entries()
  self.entries = collect_color_entries()
  self.groups = collect_color_groups(self.entries)
  self.list:clear()
  for _, group in ipairs(self.groups) do
    self.list:add_row(row_for_group(group, self.original_colors), group)
  end
  self.selected_group = nil
  self.selected:set_label("Select a theme color.")
  if self.filter:get_text() ~= "" then
    self.list:filter(self.filter:get_text())
  end
  self:update_change_count()
  core.log_quiet("Runtime Theme Editor refreshed %d color keys in %d groups", #self.entries, #self.groups)
end

function ThemeEditor:changed_entries()
  local changed = {}
  for _, entry in ipairs(collect_color_entries()) do
    if not same_color(entry.container[entry.key], self.original_colors[entry.expr]) then
      changed[#changed + 1] = entry
    end
  end
  return changed
end

function ThemeEditor:select_group(group)
  self.selected_group = group
  if not group then
    self.selected:set_label("Select a theme color.")
    return
  end
  local entry = group.primary
  local color = copy_color(entry.container[entry.key])
  local linked = #group.entries > 1 and string.format("\nLinked keys: %d", #group.entries) or ""
  self.selected:set_label(string.format(
    "%s / %s = %s%s\n%s",
    group.category,
    group.label,
    color_text(color),
    linked,
    group.raw_display
  ))
  self.suppress_picker_change = true
  self.picker:set_color(color)
  self.suppress_picker_change = false
end

function ThemeEditor:select_entry(entry)
  if not entry then return self:select_group(nil) end
  local category, label = entry_presentation(entry)
  return self:select_group({
    entries = { entry },
    primary = entry,
    category = category,
    label = label,
    raw_display = entry.display,
    display = category .. " " .. label .. "\n" .. entry.display,
  })
end

function ThemeEditor:apply_color_to_selected(value)
  local group = self.selected_group
  if not group then return end
  local color = copy_color(value)
  for _, entry in ipairs(group.entries) do
    entry.container[entry.key] = color
  end
  self:select_group(group)

  local selected = self.list:get_selected()
  if selected then
    self.list:set_row(selected, row_for_group(group, self.original_colors))
    self.list:set_row_data(selected, group)
  end

  self:update_change_count()
  core.redraw = true
end

function ThemeEditor:reset_group(group)
  if not group then return end
  for _, entry in ipairs(group.entries) do
    local original = self.original_color_refs[entry.expr] or self.original_colors[entry.expr]
    if original then entry.container[entry.key] = original end
  end
  self:select_group(group)
  self:reload_entries()
  core.redraw = true
end

function ThemeEditor:reset_selected()
  self:reset_group(self.selected_group)
end

function ThemeEditor:reset_all_changes()
  for _, entry in ipairs(collect_color_entries()) do
    local original = self.original_color_refs[entry.expr] or self.original_colors[entry.expr]
    if original then entry.container[entry.key] = original end
  end
  self:reload_entries()
  core.redraw = true
end

function ThemeEditor:resize_grip_size()
  return math.max(14 * SCALE, style.padding.x)
end

function ThemeEditor:is_on_resize_grip(x, y)
  local grip = self:resize_grip_size()
  return x >= self.position.x + self:get_width() - grip
    and y >= self.position.y + self:get_height() - grip
    and x <= self.position.x + self:get_width()
    and y <= self.position.y + self:get_height()
end

function ThemeEditor:on_mouse_pressed(button, x, y, clicks)
  if button == "left" and self:is_on_resize_grip(x, y) then
    self.resizing = {
      x = x,
      y = y,
      w = self:get_width(),
      h = self:get_height(),
    }
    system.set_cursor("sizeh")
    return true
  end
  return ThemeEditor.super.on_mouse_pressed(self, button, x, y, clicks)
end

function ThemeEditor:on_mouse_released(button, x, y)
  if self.resizing then
    self.resizing = nil
    system.set_cursor("arrow")
    return true
  end
  return ThemeEditor.super.on_mouse_released(self, button, x, y)
end

function ThemeEditor:on_mouse_moved(x, y, dx, dy)
  if self.resizing then
    local min_w = 620 * SCALE
    local min_h = 380 * SCALE
    self:set_size(
      math.max(min_w, self.resizing.w + x - self.resizing.x),
      math.max(min_h, self.resizing.h + y - self.resizing.y)
    )
    self.perform_update_size_position = true
    core.redraw = true
    system.set_cursor("sizeh")
    return true
  end
  local handled = ThemeEditor.super.on_mouse_moved(self, x, y, dx, dy)
  if self:is_on_resize_grip(x, y) then system.set_cursor("sizeh") end
  return handled
end

function ThemeEditor:draw_resize_grip()
  local grip = self:resize_grip_size()
  local x = self.position.x + self:get_width() - grip
  local y = self.position.y + self:get_height() - grip
  local t = math.max(1, style.divider_size)
  for i = 0, 2 do
    local o = (i * 4 + 4) * SCALE
    renderer.draw_rect(x + grip - o, y + grip - t, o, t, style.dim)
    renderer.draw_rect(x + grip - t, y + grip - o, t, o, style.dim)
  end
end

function ThemeEditor:draw()
  if not ThemeEditor.super.draw(self) then return false end
  self:draw_resize_grip()
  return true
end

function ThemeEditor:show()
  ThemeEditor.super.show(self)
  core.log_quiet("Runtime Theme Editor opened")
end

function ThemeEditor:update_size_position()
  ThemeEditor.super.update_size_position(self)

  local pad = style.padding.x
  local gap = style.padding.y
  local width = self:get_width()
  local height = self:get_height()
  local picker_width = 330 * SCALE
  local left_width = math.max(360 * SCALE, width - picker_width - pad * 3)
  local right_x = left_width + pad * 2
  local right_width = math.max(220 * SCALE, width - right_x - pad)

  self.title:set_position(pad, gap)
  self.help:set_position(pad, self.title:get_bottom() + gap / 2)
  self.help:set_size(left_width, nil)

  self.close_button:set_position(width - self.close_button:get_width() - pad, gap)

  self.filter:set_position(pad, self.help:get_bottom() + gap)
  self.filter:set_size(left_width)

  local list_y = self.filter:get_bottom() + gap
  local button_y = height - self.copy_button:get_height() - gap
  self.list:set_position(pad, list_y)
  self.list:set_size(left_width, math.max(120 * SCALE, button_y - list_y - gap))

  self.selected:set_position(right_x, list_y)
  self.selected:set_size(right_width, nil)
  self.picker:set_position(right_x, self.selected:get_bottom() + gap)

  self.copy_button:set_position(pad, button_y)
  self.reset_button:set_position(self.copy_button:get_right() + pad, button_y)
  self.reset_all_button:set_position(self.reset_button:get_right() + pad, button_y)
  self.refresh_button:set_position(self.reset_all_button:get_right() + pad, button_y)
end

function theme_editor.show()
  if not editor then
    editor = ThemeEditor()
  end
  editor:show()
  return editor
end

function theme_editor.hide()
  if editor then editor:hide() end
end

function theme_editor.toggle()
  if editor and editor:is_visible() then
    editor:hide()
  else
    theme_editor.show()
  end
end

theme_editor.collect_color_entries = collect_color_entries
theme_editor.collect_color_groups = collect_color_groups
theme_editor.export_theme_text = export_theme_text
theme_editor.is_color = is_color

theme_editor.ThemeEditor = ThemeEditor

command.add(nil, {
  ["theme-editor:toggle"] = theme_editor.toggle,
  ["theme-editor:show"] = theme_editor.show,
  ["theme-editor:hide"] = theme_editor.hide,
})

return theme_editor
