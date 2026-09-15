local core = require "core"
local common = require "core.common"
local keymap = require "core.keymap"
local style = require "core.style"
local TextView = require "core.textview"
local View = require "core.view"

-- A text-backed list. Selection State remains the source of selected rows.
local RowTextView = TextView:extend()

function RowTextView:new(buffer)
  RowTextView.super.new(self, buffer)
  self.row_selection_mode = true
  self:set_wrapping_enabled(false)
  self:add_selection_listener("row-selection", function()
    if self.row_selection_mode then self:normalize_row_selection() end
  end)
  self:normalize_row_selection()
end

function RowTextView:get_selectable_row_count()
  return #self.buffer.lines
end

function RowTextView:normalize_row_selection()
  local state = self:get_selection_state()
  local changed = false
  local count = math.max(1, math.min(#self.buffer.lines, self:get_selectable_row_count()))
  for i = 1, #state.selections, 4 do
    local s = state.selections
    local head, anchor = common.clamp(s[i], 1, count), common.clamp(s[i + 2], 1, count)
    local hc = head >= anchor and #self.buffer.lines[head] or 1
    local ac = head >= anchor and 1 or #self.buffer.lines[anchor]
    changed = changed or s[i] ~= head or s[i + 1] ~= hc or s[i + 2] ~= anchor or s[i + 3] ~= ac
    s[i], s[i + 1], s[i + 2], s[i + 3] = head, hc, anchor, ac
  end
  if changed then self:set_selection_state(state) end
end

function RowTextView:get_selected_rows()
  local selected, rows = {}, {}
  local s = self:get_selection_state().selections
  for i = 1, #s, 4 do
    local first, last, end_col = s[i], s[i + 2], s[i + 3]
    if first > last then first, last, end_col = last, first, s[i + 1] end
    if not self.row_selection_mode and last > first and end_col == 1 then last = last - 1 end
    for row = first, math.min(last, self:get_selectable_row_count()) do selected[row] = true end
  end
  for row in pairs(selected) do rows[#rows + 1] = row end
  table.sort(rows)
  return rows
end

function RowTextView:select_row(row, extend, add)
  local count = self:get_selectable_row_count()
  if count == 0 then return false end
  row = common.clamp(row, 1, count)
  local state = self:get_selection_state()
  local anchor = extend and state.selections[(state.last_selection - 1) * 4 + 3] or row
  local s = (add or extend) and state.selections or {}
  local i = add and (#s + 1) or extend and ((state.last_selection - 1) * 4 + 1) or 1
  s[i], s[i + 1], s[i + 2], s[i + 3] = row, 1, anchor, 1
  self:set_selection_state({ selections = s, last_selection = (i + 3) / 4 })
  self:normalize_row_selection()
  core.redraw = true
  return true
end

function RowTextView:set_row_selection_mode(enabled)
  local state = self:get_selection_state()
  if enabled and not self.row_selection_mode then
    for i = 1, #state.selections, 4 do
      local s = state.selections
      local endpoint = s[i] > s[i + 2] and i or s[i + 2] > s[i] and (i + 2)
      if endpoint and s[endpoint + 1] == 1 then
        s[endpoint] = s[endpoint] - 1
        s[endpoint + 1] = #self.buffer.lines[s[endpoint]]
      end
    end
  end
  self.row_selection_mode = enabled
  self.mouse_selecting = nil
  if enabled then
    self:set_selection_state(state)
    self:normalize_row_selection()
  end
  self:invalidate_line_render("row-selection-mode")
  core.blink_reset()
  core.redraw = true
end

function RowTextView:handle_selection_command(name, x, y)
  if not self.row_selection_mode then return false end
  if name:match("^core:set_cursor") or name == "core:select_to_cursor" or name == "core:split_cursor" then
    self:select_row_at(x, y, name == "core:select_to_cursor" or keymap.modkeys.shift,
      name == "core:split_cursor")
    return true
  end
  local state = self:get_selection_state()
  local row = state.selections[(state.last_selection - 1) * 4 + 1]
  local extend = name:match("^core:select_to_") ~= nil
  local target = name:match("_to_(.*)$")
  local page = math.max(1, math.floor(self.size.y / self:get_line_height()) - 1)
  if target == "previous_line" then row = row - 1
  elseif target == "next_line" then row = row + 1
  elseif target == "previous_page" then row = row - page
  elseif target == "next_page" then row = row + page
  elseif target == "start_of_buffer" or target == "start_of_line" then row = 1
  elseif target == "end_of_buffer" or target == "end_of_line" then row = self:get_selectable_row_count()
  elseif name == "core:select_all" then
    self:select_row(1)
    self:select_row(self:get_selectable_row_count(), true)
    return true
  elseif name ~= "core:select_none" then
    -- Character, word, and extra-caret commands have no effect in row mode.
    return true
  end
  self:select_row(row, extend)
  return true
end

function RowTextView:select_row_at(x, y, extend, add)
  local row = self:resolve_screen_position(x, y)
  self.buffer:clear_search_selections()
  self:select_row(row, extend, add)
  local s = self:get_selection_state()
  local anchor = s.selections[(s.last_selection - 1) * 4 + 3]
  self.mouse_selecting = { anchor, 1, "rows" }
end

function RowTextView:on_mouse_pressed(button, x, y, clicks)
  if not self.row_selection_mode then return RowTextView.super.on_mouse_pressed(self, button, x, y, clicks) end
  if View.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if button == "left" then
    self:select_row_at(x, y, keymap.modkeys.shift, keymap.modkeys.ctrl or keymap.modkeys.cmd)
    return true
  end
end

function RowTextView:on_mouse_moved(x, y, ...)
  if not self.row_selection_mode then return RowTextView.super.on_mouse_moved(self, x, y, ...) end
  View.on_mouse_moved(self, x, y, ...)
  self.cursor = "arrow"
  if self.mouse_selecting then
    self:select_row(self:resolve_screen_position(x, y), true)
  end
end

function RowTextView:scroll_to_make_visible(line, col, ...)
  -- Whole-row selection must not scroll horizontally to the row's end.
  if not self.row_selection_mode then return RowTextView.super.scroll_to_make_visible(self, line, col, ...) end
  local x, target = self.scroll.x, self.scroll.to.x
  RowTextView.super.scroll_to_make_visible(self, line, 1, ...)
  self.scroll.x, self.scroll.to.x = x, target
end

function RowTextView:get_current_line_highlight_mode()
  if self.row_selection_mode then return false end
  return RowTextView.super.get_current_line_highlight_mode(self)
end

function RowTextView:draw_row_selection(line, x, y, width)
  if self.row_selection_mode and line <= self:get_selectable_row_count() then
    local s = self:get_selection_state().selections
    for i = 1, #s, 4 do
      if line >= math.min(s[i], s[i + 2]) and line <= math.max(s[i], s[i + 2]) then
        renderer.draw_rect(x, y, width, self:get_line_height(), style.selection)
        break
      end
    end
  end
end

function RowTextView:draw_line_body(line, x, y)
  self:draw_row_selection(line, self.position.x, y, self.size.x)
  return RowTextView.super.draw_line_body(self, line, x, y)
end

function RowTextView:draw_overlay()
  if not self.row_selection_mode then return RowTextView.super.draw_overlay(self) end
end

return RowTextView
