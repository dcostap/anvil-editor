-- The File Types Dialog: the file types that this anvil.exe opens, with a check box for each.
-- A check registers the type's extensions at once, and a clear removes them. "Set as Default" opens Anvil's page in
-- Windows Settings, where the user makes Anvil the default app.

local core = require "core"
local common = require "core.common"
local style = require "core.style"
local file_icons = require "core.file_icons"
local ui = require "core.ui"
local Dialog = require("core.ui.dialog").Dialog
local Button = require "core.ui.button"
local List = require "core.ui.list"
local file_types = require "plugins.file_types"

local FileTypesDialog = Dialog:extend()

function FileTypesDialog:__tostring() return "FileTypesDialog" end

-- The most rows that show before the list scrolls.
local VISIBLE_ROWS = 12

function FileTypesDialog:new()
  FileTypesDialog.super.new(self, { title = "File Types", width = 520 })
  -- How far each type's check box shows its check, by type name. The check fades in and out.
  self.check_amounts = {}
  self.list = self:add(List({
    row_height = ui.metrics().control_h + math.floor(4 * SCALE),
    click_activates = true,
    draw_row = function(...) self:draw_row(...) end,
    on_activate = function(row) self:toggle(row) end,
  }))
  self.all_button = self:add(Button({
    label = "Select All",
    on_click = function() self:set_all(not self:all_checked()) end,
  }))
  self.default_button = self:add(Button({
    label = "Set as Default", icon = ui.icons.open_in_new, kind = "primary",
    on_click = function() self:set_default() end,
  }))
  self:refresh()
end

---Read the registered types again. The selection stays on the same row.
function FileTypesDialog:refresh()
  self.list:set_rows(file_types.types(), self.list.selected)
  local any = false
  for _, row in ipairs(self.list.rows) do any = any or row.checked end
  self.default_button.enabled = any
  self.all_button.label = self:all_checked() and "Clear All" or "Select All"
  core.redraw = true
end

function FileTypesDialog:all_checked()
  for _, row in ipairs(self.list.rows) do
    if not row.checked then return false end
  end
  return #self.list.rows > 0
end

function FileTypesDialog:toggle(row)
  if not file_types.set(row, not row.checked) then
    core.error("File Types: could not change the registry for %s", row.name)
  end
  self:refresh()
end

function FileTypesDialog:set_all(checked)
  for _, row in ipairs(self.list.rows) do
    if row.checked ~= checked and not file_types.set(row, checked) then
      core.error("File Types: could not change the registry for %s", row.name)
    end
  end
  self:refresh()
end

function FileTypesDialog:set_default()
  file_types.open_settings()
  self:close()
end

-- Space checks or clears the selected row, as in a check box.
function FileTypesDialog:on_modal_key_pressed(key, event)
  if key == "space" and self.focused == self.list then
    local row = self.list:selected_row()
    if row then self:toggle(row) end
    return true
  end
  return FileTypesDialog.super.on_modal_key_pressed(self, key, event)
end

------------------------------------------------------------------------------------------------------------------
-- Layout

function FileTypesDialog:layout_content(x, y, w, max_h)
  local um = ui.metrics()
  local footer_gap = math.floor(20 * SCALE + 0.5)
  local list = self.list
  local rows = math.max(1, math.min(#list.rows, VISIBLE_ROWS))
  local list_h = math.max(list.row_height, math.min(rows * list.row_height, max_h - footer_gap - um.control_h))
  list:set_rect(x, y, w, list_h)
  local cy = y + list_h + footer_gap
  self.all_button:set_rect(x, cy, self.all_button:measure(), um.control_h)
  local default_w = self.default_button:measure()
  self.default_button:set_rect(x + w - default_w, cy, default_w, um.control_h)
  return cy + um.control_h - y
end

------------------------------------------------------------------------------------------------------------------
-- Drawing

function FileTypesDialog:draw_row(row, x, y, w, h, state)
  local um = ui.metrics()
  local font = ui.font()
  local pad = um.pad_x
  local box = math.floor(16 * SCALE + 0.5)
  local amount = ui.approach(self.check_amounts, row.name, row.checked and 1 or 0, 30)
  ui.draw_check_box(x + pad, y + math.floor((h - box) / 2), box, amount)
  local cx = x + pad + box + um.gap + um.icon_gap
  if row.icon_height ~= h then
    row.icon = file_icons.prepare("file." .. row.extensions[1], h)
    row.icon_height = h
  end
  local _, icon_w = file_icons.draw_prepared(row.icon, cx, y)
  cx = cx + (icon_w or file_icons.column_width(h)) + um.icon_gap
  row.extensions_label = row.extensions_label or ("." .. table.concat(row.extensions, "  ."))
  local extensions = row.extensions_label
  local extensions_w = font:get_width(extensions)
  common.draw_text(font, state.selected and style.text or style.card_text, extensions, "right",
    x + w - pad - extensions_w, y, extensions_w, h)
  local name_w = x + w - pad - extensions_w - um.gap - cx
  local name_x = common.draw_text(font, style.text, ui.fit_text(font, row.name, name_w), "left", cx, y, 0, h)
  -- A type that another anvil.exe opens says so, after its name.
  if row.other then
    local note = "Another Anvil"
    local note_x = name_x + 2 * um.gap
    if note_x + font:get_width(note) <= cx + name_w then
      common.draw_text(font, style.warn, note, "left", note_x, y, 0, h)
    end
  end
end

------------------------------------------------------------------------------------------------------------------
-- Module

local M = { Dialog = FileTypesDialog }

---Open the Dialog, or read the registry again in the open one.
function M.open()
  local open = require("core.ui.dialog").current()
  local instance = (open and open:is(FileTypesDialog)) and open or FileTypesDialog()
  instance:refresh()
  instance:open(instance.list)
  return instance
end

return M
