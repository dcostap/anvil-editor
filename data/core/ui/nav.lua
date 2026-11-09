local core = require "core"
local common = require "core.common"
local style = require "core.style"
local ui = require "core.ui"
local surface = require "core.ui.surface"
local Control = require "core.ui.control"

-- A vertical list of pages, as at the left of a settings Dialog. A click, or the editor's line moves, select
-- a page and call `on_select(item)`. Each item is `{ id = ..., label = "...", icon = ui.icons.x }`.
local Nav = Control:extend()

Nav.focusable = true
Nav.cursor = "hand"

---@param options { items: table[], selected: any, on_select: fun(item: table)?, width: number? }
function Nav:new(options)
  Nav.super.new(self, options)
  self.items = options.items or {}
  self.selected = options.selected or (self.items[1] and self.items[1].id)
  self.on_select = options.on_select
  self.amounts = {}
end

local function row_height()
  return ui.metrics().control_h
end

local function row_gap()
  return math.floor(2 * SCALE + 0.5)
end

function Nav:measure()
  local m = ui.metrics()
  local font, icon_font = ui.font(), ui.icon_font()
  local w = 0
  for _, item in ipairs(self.items) do
    local iw = item.icon and icon_font:get_width(item.icon) + m.icon_gap or 0
    w = math.max(w, font:get_width(item.label) + iw)
  end
  local count = #self.items
  return math.ceil(w + 2 * m.pad_x), count * row_height() + math.max(0, count - 1) * row_gap()
end

local function index_of(self, id)
  for i, item in ipairs(self.items) do
    if item.id == id then return i end
  end
end

---Select the page `id`. Returns true when it changed.
function Nav:select(id)
  if id == self.selected or not index_of(self, id) then return false end
  self.selected = id
  core.redraw = true
  if self.on_select then self.on_select(self.items[index_of(self, id)]) end
  return true
end

function Nav:perform(name)
  local index = index_of(self, self.selected) or 0
  if name == "move_to_previous_line" then
    index = index - 1
  elseif name == "move_to_next_line" then
    index = index + 1
  elseif name == "move_to_start_of_buffer" then
    index = 1
  elseif name == "move_to_end_of_buffer" then
    index = #self.items
  else
    return false
  end
  local item = self.items[math.max(1, math.min(index, #self.items))]
  if item then self:select(item.id) end
  return true
end

function Nav:index_at(y)
  local step = row_height() + row_gap()
  local index = math.floor((y - self.y) / step) + 1
  if index >= 1 and index <= #self.items and y - self.y - (index - 1) * step < row_height() then return index end
end

function Nav:on_mouse_pressed(x, y)
  local index = self:index_at(y)
  if index then self:select(self.items[index].id) end
  return true
end

function Nav:on_mouse_moved(x, y)
  local index = self:index_at(y)
  if index ~= self.hover_index then
    self.hover_index = index
    core.redraw = true
  end
  return true
end

function Nav:draw(focused)
  local m = ui.metrics()
  local font, icon_font = ui.font(), ui.icon_font()
  local rh, r = row_height(), m.control_radius
  local selected = index_of(self, self.selected)
  for i, item in ipairs(self.items) do
    local y = self.y + (i - 1) * (rh + row_gap())
    local hover = ui.approach(self.amounts, i, self.hovered and self.hover_index == i and i ~= selected and 1 or 0, 30)
    if i == selected then
      surface.draw("selected", self.x, y, self.w, rh, r)
      if focused then ui.draw_ring(self.x, y, self.w, rh, r) end
    elseif hover > 0 then
      local pushed = ui.push_look(self.x, y, self.w, rh, 1, hover)
      surface.draw("ghost_hover", self.x, y, self.w, rh, r)
      ui.pop_look(pushed)
    end
    local color = (i == selected or hover > 0.5) and style.dialog_text_strong or style.dialog_text_muted
    local tx = self.x + m.pad_x
    if item.icon then tx = common.draw_text(icon_font, color, item.icon, "left", tx, y, 0, rh) + m.icon_gap end
    local tw = self.x + self.w - m.pad_x - tx
    common.draw_text(font, color, ui.fit_text(font, item.label, tw), "left", tx, y, tw, rh)
  end
end

return Nav
