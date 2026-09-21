local core = require "core"
local common = require "core.common"
local keymap = require "core.keymap"
local style = require "core.style"
local TextView = require "core.textview"
local View = require "core.view"

-- A text-backed list. Selection State remains the source of selected rows.
local RowTextView = TextView:extend()

local function increase_opacity(color, percent)
  return {
    color[1],
    color[2],
    color[3],
    math.min(255, math.floor(color[4] * (1 + percent / 100))),
  }
end

function RowTextView:new(buffer, enable_row_selection)
  RowTextView.super.new(self, buffer)
  self.row_selection_marks = {}
  self:add_edit_guard("row-selection-mode", function(view)
    if view.row_selection_mode then
      return false, "Disable Row Selection Mode to edit"
    end
    return true
  end)
  self:set_wrapping_enabled(false)
  self:add_selection_listener("row-selection", function()
    if self.row_selection_mode then self:normalize_row_selection() end
  end)
  if enable_row_selection ~= false then self:set_row_selection_mode(true) end
end

function RowTextView:get_row_count()
  return #self.buffer.lines
end

function RowTextView:is_selectable_row(row)
  return row >= 1 and row <= self:get_row_count()
end

function RowTextView:nearest_selectable_row(row, direction)
  local count = math.min(#self.buffer.lines, self:get_row_count())
  row = common.clamp(row, 1, math.max(1, count))
  direction = direction or 1
  for candidate = row, direction > 0 and count or 1, direction do
    if self:is_selectable_row(candidate) then return candidate end
  end
  for candidate = row, direction > 0 and 1 or count, -direction do
    if self:is_selectable_row(candidate) then return candidate end
  end
end

local function same_selection(a, b)
  if not a or not b or a.last_selection ~= b.last_selection or #a.selections ~= #b.selections then return false end
  for i, value in ipairs(a.selections) do
    if value ~= b.selections[i] then return false end
  end
  return true
end

-- Keep separate text selections where non-selectable rows interrupt a range.
local function append_row_range(view, selections, head, anchor)
  local direction = head >= anchor and 1 or -1
  local first
  local function finish(last)
    if not first then return end
    for _, value in ipairs {
      last, direction > 0 and #view.buffer.lines[last] or 1,
      first, direction > 0 and 1 or #view.buffer.lines[first],
    } do selections[#selections + 1] = value end
    first = nil
  end
  for row = anchor, head, direction do
    if view:is_selectable_row(row) then first = first or row
    else finish(row - direction) end
  end
  finish(head)
end

local function append_marked_rows(view, selections, first, last)
  for row in pairs(view.row_selection_marks or {}) do
    if view:is_selectable_row(row) and not (first and row >= first and row <= last) then
      append_row_range(view, selections, row, row)
    end
  end
end

function RowTextView:set_row_selection_state(state)
  self.row_selection_snapshot = state
  self:set_selection_state(state)
end

function RowTextView:normalize_row_selection(force)
  if force then self.row_selection_snapshot = nil end
  local state = self:get_selection_state()
  if same_selection(state, self.row_selection_snapshot) then return end
  local normalized = { selections = {}, last_selection = 1 }
  local base, active_anchor = {}, nil
  local count = math.max(1, math.min(#self.buffer.lines, self:get_row_count()))
  for i = 1, #state.selections, 4 do
    local s = state.selections
    local head, anchor = common.clamp(s[i], 1, count), common.clamp(s[i + 2], 1, count)
    local first = #normalized.selections + 1
    append_row_range(self, normalized.selections, head, anchor)
    if (i + 3) / 4 == state.last_selection then
      active_anchor = self:nearest_selectable_row(anchor, head >= anchor and 1 or -1)
      normalized.last_selection = math.max(1, #normalized.selections / 4)
    else
      for j = first, #normalized.selections do base[#base + 1] = normalized.selections[j] end
    end
  end
  if #normalized.selections == 0 then
    local row = self:nearest_selectable_row(state.selections[1])
    if row then append_row_range(self, normalized.selections, row, row)
    else normalized.selections = { 1, 1, 1, 1 } end
  end
  self:set_row_selection_state(normalized)
  self.row_selection_anchor, self.row_selection_base = active_anchor, base
end

function RowTextView:get_selected_rows()
  local selected, rows = {}, {}
  local s = self:get_selection_state().selections
  for i = 1, #s, 4 do
    local first, last, end_col = s[i], s[i + 2], s[i + 3]
    if first > last then first, last, end_col = last, first, s[i + 1] end
    if not self.row_selection_mode and last > first and end_col == 1 then last = last - 1 end
    for row = first, math.min(last, self:get_row_count()) do
      if self:is_selectable_row(row) then selected[row] = true end
    end
  end
  for row in pairs(selected) do rows[#rows + 1] = row end
  table.sort(rows)
  return rows
end

function RowTextView:select_row(row, extend, add, direction)
  row = self:nearest_selectable_row(row, direction)
  if not row then return false end
  local state = self:get_selection_state()
  local anchor = extend and (self.row_selection_anchor or state.selections[(state.last_selection - 1) * 4 + 3]) or row
  local base
  if add then
    base = state.selections
  elseif extend then
    base = self.row_selection_base or {}
  else
    base = {}
    append_marked_rows(self, base, row, row)
  end
  local selections = { table.unpack(base) }
  append_row_range(self, selections, row, anchor)
  self:set_row_selection_state({ selections = selections, last_selection = #selections / 4 })
  self.row_selection_anchor, self.row_selection_base = anchor, base
  core.redraw = true
  return true
end

function RowTextView:get_marked_rows()
  local rows = {}
  for row in pairs(self.row_selection_marks or {}) do
    if self:is_selectable_row(row) then rows[#rows + 1] = row end
  end
  table.sort(rows)
  return rows
end

function RowTextView:set_marked_rows(rows, preserve_selection)
  self.row_selection_marks = {}
  for _, row in ipairs(rows or {}) do
    if self:is_selectable_row(row) then self.row_selection_marks[row] = true end
  end
  if not preserve_selection then
    local state = self:get_selection_state()
    local row = state.selections[(state.last_selection - 1) * 4 + 1]
    self:select_row(row)
  end
end

function RowTextView:clear_row_marks(preserve_selection)
  self.row_selection_marks = {}
  if self.on_row_marks_cleared then self:on_row_marks_cleared() end
  if not preserve_selection then
    local state = self:get_selection_state()
    local row = state.selections[(state.last_selection - 1) * 4 + 1]
    self:select_row(row)
  end
end

function RowTextView:toggle_selected_row_marks()
  if not self.row_selection_mode then return false end
  local state = self:get_selection_state()
  local focus = state.selections[(state.last_selection - 1) * 4 + 1]
  if not self:is_selectable_row(focus) then return false end
  local rows = self:get_selected_rows()
  local all_marked = #rows > 0
  for _, row in ipairs(rows) do all_marked = all_marked and self.row_selection_marks[row] == true end
  local marked = not all_marked
  for _, row in ipairs(rows) do
    self.row_selection_marks[row] = marked or nil
    if self.on_row_mark_toggled then self:on_row_mark_toggled(row, marked) end
  end
  self:select_row(focus)
  core.log_quiet("Row Selection Mode %s %d selected rows", marked and "marked" or "unmarked", #rows)
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
  if not enabled then
    self:clear_row_marks(true)
  end
  self.mouse_selecting = nil
  self.row_selection_snapshot = nil
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
  local direction = 1
  local page = math.max(1, math.floor(self.size.y / self:get_line_height()) - 1)
  if target == "previous_line" then row, direction = row - 1, -1
  elseif target == "next_line" then row = row + 1
  elseif target == "previous_page" then row, direction = row - page, -1
  elseif target == "next_page" then row = row + page
  elseif target == "start_of_buffer" or target == "start_of_line" then row = 1
  elseif target == "end_of_buffer" or target == "end_of_line" then row, direction = self:get_row_count(), -1
  elseif name == "core:select_all" then
    self:select_row(1)
    self:select_row(self:get_row_count(), true, false, -1)
    return true
  elseif name == "core:select_none" then
    self:clear_row_marks(true)
  else
    -- Character, word, and extra-caret commands have no effect in row mode.
    return true
  end
  self:select_row(row, extend, false, direction)
  return true
end

function RowTextView:select_row_at(x, y, extend, add)
  local row = self:resolve_screen_position(x, y)
  if not self:is_selectable_row(row) then return false end
  self.buffer:clear_search_selections()
  self:select_row(row, extend, add)
  local s = self:get_selection_state()
  local anchor = s.selections[(s.last_selection - 1) * 4 + 3]
  self.mouse_selecting = { anchor, 1, "rows" }
  return true
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
    local row = self:resolve_screen_position(x, y)
    local anchor = self.row_selection_anchor or self.mouse_selecting[1]
    self:select_row(row, true, false, row >= anchor and -1 or 1)
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

function RowTextView:get_selection_background_color()
  if not self.row_selection_mode then return RowTextView.super.get_selection_background_color(self) end
end

function RowTextView:draw_row_selection(line, x, y, width)
  if self.row_selection_mode and self:is_selectable_row(line) then
    local s = self:get_selection_state().selections
    for i = 1, #s, 4 do
      if line >= math.min(s[i], s[i + 2]) and line <= math.max(s[i], s[i + 2]) then
        local color = core.active_view == self and self:active_window_has_focus()
          and style.row_selection or style.row_selection_inactive
        local focus = s[(self.buffer.last_selection - 1) * 4 + 1]
        if line == focus and self.row_selection_marks[line] then
          color = increase_opacity(color, 43)
        end
        renderer.draw_rect(x, y, width, self:get_line_height(), color)
        if self.row_selection_marks[line] then
          local border = increase_opacity(
            core.active_view == self and self:active_window_has_focus()
              and style.row_selection or style.row_selection_inactive,
            75
          )
          local thickness = math.max(1, style.divider_size or 1)
          renderer.draw_rect(x, y, width, thickness, border)
          renderer.draw_rect(x, y + self:get_line_height() - thickness, width, thickness, border)
        end
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
