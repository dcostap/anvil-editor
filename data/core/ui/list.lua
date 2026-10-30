local core = require "core"
local config = require "core.config"
local style = require "core.style"
local ui = require "core.ui"
local Control = require "core.ui.control"
local RowHighlight = require "core.row_highlight"

-- A scrolling list of rows with one selected row. The editor's line moves select rows, with the user's bindings.
-- The selection and the hover highlights glide from row to row, as in the Context Menu and the Sidebar.
-- `draw_row(row, x, y, w, h, state)` draws one row. `state` has `selected`, `hovered` and `focused`.
-- `on_select(row, index)` follows each new selection. `on_activate(row, index)` follows Enter and a double click,
-- or each click with `click_activates`, as in a list of check boxes.
local List = Control:extend()

List.focusable = true

---@param options { rows: table[]?, row_height: number, draw_row: function, on_select: function?, on_activate: function?, click_activates: boolean? }
function List:new(options)
  List.super.new(self, options)
  self.rows = options.rows or {}
  self.row_height = options.row_height
  self.draw_row = options.draw_row
  self.on_select = options.on_select
  self.on_activate = options.on_activate
  self.click_activates = options.click_activates
  self.selected = #self.rows > 0 and 1 or nil
  self.scroll, self.scroll_to = 0, 0
  self.selection_highlight = RowHighlight(RowHighlight.selection)
  self.hover_highlight = RowHighlight(RowHighlight.hover)
end

---Replace the rows. `selected` is the index to select, or nil for the first row.
function List:set_rows(rows, selected)
  self.rows = rows
  self.selected = #rows > 0 and math.max(1, math.min(selected or 1, #rows)) or nil
  self.hover_index = nil
  self:scroll_to_selected()
  core.redraw = true
end

function List:content_height()
  return #self.rows * self.row_height
end

local function max_scroll(self)
  return math.max(0, self:content_height() - self.h)
end

function List:scroll_to_selected()
  if not self.selected then return end
  local top = (self.selected - 1) * self.row_height
  if top < self.scroll_to then
    self.scroll_to = top
  elseif top + self.row_height > self.scroll_to + self.h then
    self.scroll_to = top + self.row_height - self.h
  end
  self.scroll_to = math.max(0, math.min(self.scroll_to, max_scroll(self)))
end

---Select the row at `index`, and scroll it into view.
function List:select(index)
  if #self.rows == 0 then return false end
  index = math.max(1, math.min(index, #self.rows))
  if index == self.selected then return false end
  self.selected = index
  self:scroll_to_selected()
  core.redraw = true
  if self.on_select then self.on_select(self.rows[index], index) end
  return true
end

function List:selected_row()
  return self.selected and self.rows[self.selected]
end

local function page_rows(self)
  return math.max(1, math.floor(self.h / self.row_height) - 1)
end

function List:perform(name)
  if #self.rows == 0 then return false end
  local index = self.selected or 0
  if name == "move_to_previous_line" then
    self:select(index - 1)
  elseif name == "move_to_next_line" then
    self:select(index + 1)
  elseif name == "move_to_start_of_buffer" then
    self:select(1)
  elseif name == "move_to_end_of_buffer" then
    self:select(#self.rows)
  elseif name == "move_to_previous_page" then
    self:select(index - page_rows(self))
  elseif name == "move_to_next_page" then
    self:select(index + page_rows(self))
  else
    return false
  end
  return true
end

function List:activate()
  local row = self:selected_row()
  if not (row and self.on_activate) then return false end
  self.on_activate(row, self.selected)
  return true
end

function List:index_at(y)
  local index = math.floor((y - self.y + self.scroll) / self.row_height) + 1
  if index >= 1 and index <= #self.rows then return index end
end

function List:on_mouse_pressed(x, y, clicks)
  local index = self:index_at(y)
  if not index then return true end
  self:select(index)
  if self.click_activates or (clicks and clicks >= 2) then self:activate() end
  return true
end

function List:on_mouse_moved(x, y)
  local index = self:contains(x, y) and self:index_at(y) or nil
  if index ~= self.hover_index then
    self.hover_index = index
    core.redraw = true
  end
  return true
end

function List:on_mouse_wheel(dy)
  if max_scroll(self) <= 0 then return false end
  self.scroll_to = math.max(0, math.min(self.scroll_to - dy * config.mouse_wheel_scroll, max_scroll(self)))
  core.redraw = true
  return true
end

function List:draw(focused)
  local m = ui.metrics()
  self.scroll_to = math.max(0, math.min(self.scroll_to, max_scroll(self)))
  self.scroll = ui.approach(self, "scroll", self.scroll_to, 24)
  local x, y, w, h, rh = self.x, self.y, self.w, self.h, self.row_height
  core.push_clip_rect(x, y, w, h)
  local hover = self.hovered and self.hover_index
  if hover and hover ~= self.selected then
    self.hover_highlight:step((hover - 1) * rh, rh)
  else
    self.hover_highlight:step()
  end
  if self.selected then
    self.selection_highlight:step((self.selected - 1) * rh, rh)
  else
    self.selection_highlight:step()
  end
  local top = y - self.scroll
  self.hover_highlight:draw(x, top, w, m.radius, ui.fade(style.card_selection, 0.45))
  -- The selection is quieter while another control has focus.
  self.selection_highlight:draw(x, top, w, m.radius, ui.fade(style.card_selection, focused and 1 or 0.6))
  local first = math.max(1, math.floor(self.scroll / rh) + 1)
  local last = math.min(#self.rows, math.ceil((self.scroll + h) / rh))
  local state = self.row_state or {}
  self.row_state = state
  for index = first, last do
    state.selected, state.hovered, state.focused = index == self.selected, index == hover, focused
    self.draw_row(self.rows[index], x, top + (index - 1) * rh, w, rh, state)
  end
  core.pop_clip_rect()
end

return List
