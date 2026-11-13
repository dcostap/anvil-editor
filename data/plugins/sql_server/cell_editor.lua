-- The editor of one result cell. It draws over the cell and edits a copy of the value with the user's bindings
-- for the editor's line commands. It takes the keyboard until Enter, Tab, Up, Down, a click outside it or Escape
-- ends it. Escape keeps the old value; the other ends keep the text.
local core = require "core"
local common = require "core.common"
local keymap = require "core.keymap"
local style = require "core.style"
local Object = require "core.object"
local LineInput = require "core.line_input"

local CellEditor = Object:extend()

local line_commands = {}
for _, name in ipairs(LineInput.COMMANDS) do line_commands[name] = true end

local function padding() return common.round(8 * SCALE) end

-- `select_all` selects the value, as F2 does. Otherwise the caret follows `text`, as after a typed character.
function CellEditor:new(view, row, column, display_row, text, select_all)
  self.view, self.row, self.column, self.display_row = view, row, column, display_row
  self.input = LineInput(text)
  if select_all then self.input:perform("select_all") end
  self.scroll = 0
  local editor = self
  core.root_panel:push_modal_input(self, { label = "sql-cell-editor", handlers = {
    key_pressed = function(key, event) return editor:on_key_pressed(key, event) end,
    text_input = function(typed) editor.input:insert(typed); core.redraw = true; return true end,
    ime_text_editing = function() return true end,
    mouse_pressed = function(...) return editor:on_mouse_pressed(...) end,
    mouse_moved = function(x, y, ...)
      if editor.dragging then editor:place_caret(x, true) end
      core.root_panel:on_mouse_moved(x, y, ...)
      return true
    end,
    mouse_released = function(...) editor.dragging = false; core.root_panel:on_mouse_released(...); return true end,
    mouse_wheel = function() return "keymap" end,
    mouse_left = function() core.root_panel:on_mouse_left(); return true end,
  } })
  core.redraw = true
end

function CellEditor:text() return self.input.text end

-- The editor covers its cell, and grows to the right for a longer text, up to the View's edge.
function CellEditor:rect()
  local view = self.view
  local x, y, w, h = view:cell_screen_rect(self.display_row, self.column)
  local wanted = style.code_font:get_width(self.input.text) + padding() * 2 + style.caret_width
  local right = view.position.x + view.size.x - style.scrollbar_size
  return x, y, math.max(w, math.min(wanted, right - x)), h
end

function CellEditor:place_caret(x, select)
  local left = self:rect() + padding() - self.scroll
  self.input:set_caret(self.input:offset_at(style.code_font, x - left), select)
  core.redraw = true
end

-- Closes the editor. `keep` hands the text to the View, then the selection moves by the deltas.
function CellEditor:close(keep, row_delta, column_delta)
  if self.closed then return end
  self.closed = true
  core.root_panel:pop_modal_input(self)
  self.view:end_cell_edit(self, keep, row_delta, column_delta)
  core.redraw = true
end

function CellEditor:on_key_pressed(key, event)
  if keymap.is_modifier_key(key) then return "keymap" end
  local mods = keymap.modkeys
  if key == "escape" then self:close(false); return true end
  if key == "return" or key == "keypad enter" then self:close(true, mods.shift and -1 or 1, 0); return true end
  if key == "tab" then self:close(true, 0, mods.shift and -1 or 1); return true end
  if key == "up" or key == "down" then self:close(true, key == "up" and -1 or 1, 0); return true end
  for _, name in ipairs(keymap.map[keymap.stroke_for_event(key, event)] or {}) do
    local edit = type(name) == "string" and name:match("^core:(.+)$")
    if edit and line_commands[edit] then
      self.input:perform(edit)
      core.redraw = true
      return true
    end
  end
  if mods.ctrl or mods.alt or mods.super or mods.cmd then return true end
  -- The key's text arrives in a later text event.
  return "text"
end

function CellEditor:on_mouse_pressed(button, x, y, clicks)
  local cx, cy, cw, ch = self:rect()
  if x >= cx and x < cx + cw and y >= cy and y < cy + ch then
    if button == "left" then
      if (clicks or 1) >= 2 then self.input:perform("select_all") else self:place_caret(x, keymap.modkeys.shift) end
      self.dragging = (clicks or 1) < 2
      core.redraw = true
    end
    return true
  end
  -- A press elsewhere keeps the text and still reaches its target.
  self:close(true, 0, 0)
  if not core.root_panel:on_mouse_pressed(button, x, y, clicks) then keymap.on_mouse_pressed(button, x, y, clicks) end
  return true
end

function CellEditor:draw()
  local view = self.view
  local x, y, w, h = self:rect()
  local font, pad = style.code_font, padding()
  local body_y = view.position.y + view:header_height()
  core.push_clip_rect(view.position.x, body_y, view.size.x, math.max(0, view.position.y + view.size.y - body_y))
  renderer.draw_rect(x, y, w, h, style.background)
  local text, first, last = self.input.text, self.input:selection()
  local caret_x = font:get_width(text:sub(1, self.input.caret))
  local inner = w - pad * 2 - style.caret_width
  if caret_x - self.scroll > inner then self.scroll = caret_x - inner end
  if caret_x < self.scroll then self.scroll = caret_x end
  local left = x + pad - self.scroll
  local text_y = common.round(y + (h - font:get_height()) / 2)
  core.push_clip_rect(x + pad, y, math.max(0, w - pad * 2), h)
  if first ~= last then
    local x1, x2 = font:get_width(text:sub(1, first)), font:get_width(text:sub(1, last))
    renderer.draw_rect(left + x1, text_y, x2 - x1, font:get_height(), style.selection)
  end
  renderer.draw_text(font, text, left, text_y, style.text)
  renderer.draw_rect(left + caret_x, text_y, style.caret_width, font:get_height(), style.caret)
  core.pop_clip_rect()
  local t = math.max(1, common.round(2 * SCALE))
  renderer.draw_rect(x, y, w, t, style.accent)
  renderer.draw_rect(x, y + h - t, w, t, style.accent)
  renderer.draw_rect(x, y, t, h, style.accent)
  renderer.draw_rect(x + w - t, y, t, h, style.accent)
  core.pop_clip_rect()
end

return CellEditor
