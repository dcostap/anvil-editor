local core = require "core"
local common = require "core.common"
local style = require "core.style"
local ui = require "core.ui"
local surface = require "core.ui.surface"
local layout = require "core.ui.layout"
local Control = require "core.ui.control"

-- Large choices where one is on, each a card with an optional icon, a title and a description, such as the
-- kind of a new connection. The cards share the width in columns of at least 180 px, and go into more rows
-- when the width is too small. A click, or the editor's line and character moves, change the choice.
-- Tab reaches the cards once. Each option is
-- `{ value = ..., label = "...", description = "...", icon = ui.icons.database, enabled = true }`.
-- `on_change(value)` returns false to refuse the change.
local ChoiceCards = Control:extend()

ChoiceCards.focusable = true
ChoiceCards.cursor = "hand"

local px = layout.px
local MIN_CARD_W = 180

---@param options { options: table[], value: any, on_change: (fun(value: any): boolean?)?, enabled: boolean? }
function ChoiceCards:new(options)
  ChoiceCards.super.new(self, options)
  self.on_change = options.on_change
  self:set_options(options.options or {}, options.value)
end

---Replace the options and the chosen value.
function ChoiceCards:set_options(options, value)
  self.options, self.value = options, value
  self.titles, self.descriptions, self.amounts, self.rects, self.heights = {}, {}, {}, {}, {}
  for i, option in ipairs(options) do
    self.titles[i] = layout.Text { text = option.label or "", role = "label" }
    self.descriptions[i] = option.description and layout.Text { text = option.description, role = "description" }
    self.rects[i] = { x = 0, y = 0, w = 0, h = 0 }
  end
  core.redraw = true
end

function ChoiceCards:set_value(value)
  self.value = value
end

local function enabled(option)
  return option.enabled ~= false
end

local function index_of(self, value)
  for i, option in ipairs(self.options) do
    if option.value == value then return i end
  end
end

local function pad() return px(16) end
local function icon_size() return px(20) end

local function icon_space(option)
  return option.icon and icon_size() + px(12) or 0
end

local function text_height(self, i, w)
  local h = self.titles[i]:height(w)
  if self.descriptions[i] then h = h + ui.metrics().text_gap + self.descriptions[i]:height(w) end
  return h
end

local function card_height(self, i, card_w)
  local option = self.options[i]
  local text_h = text_height(self, i, card_w - 2 * pad() - icon_space(option))
  return 2 * pad() + math.max(option.icon and icon_size() or 0, text_h)
end

-- The column count and the card width at width `w`.
local function columns(self, w)
  local gap, count = ui.metrics().gap, math.max(1, #self.options)
  local cols = common.clamp(math.floor((w + gap) / (px(MIN_CARD_W) + gap)), 1, count)
  return cols, math.floor((w - (cols - 1) * gap) / cols)
end

---The natural width puts all cards in one row. At width `w`, self.heights takes the height of each row.
function ChoiceCards:measure(w)
  local count, gap = #self.options, ui.metrics().gap
  w = w or count * px(MIN_CARD_W) + math.max(0, count - 1) * gap
  local heights = self.heights
  for i = #heights, 1, -1 do heights[i] = nil end
  local cols, card_w = columns(self, w)
  for i = 1, count do
    local row = math.floor((i - 1) / cols) + 1
    heights[row] = math.max(heights[row] or 0, card_height(self, i, card_w))
  end
  local h = math.max(0, #heights - 1) * gap
  for _, row_h in ipairs(heights) do h = h + row_h end
  return w, h
end

function ChoiceCards:place(x, y, w, h)
  ChoiceCards.super.place(self, x, y, w, h)
  self:measure(w)
  local cols, card_w = columns(self, w)
  local gap = ui.metrics().gap
  local row_y = y
  for i, option in ipairs(self.options) do
    local row, col = math.floor((i - 1) / cols) + 1, (i - 1) % cols
    if col == 0 and row > 1 then row_y = row_y + self.heights[row - 1] + gap end
    local r = self.rects[i]
    r.x, r.y, r.w, r.h = x + col * (card_w + gap), row_y, card_w, self.heights[row]
    local tx = r.x + pad() + icon_space(option)
    local tw = card_w - 2 * pad() - icon_space(option)
    local title_h = self.titles[i]:height(tw)
    self.titles[i]:place(tx, r.y + pad(), tw, title_h)
    if self.descriptions[i] then
      local dy = r.y + pad() + title_h + ui.metrics().text_gap
      self.descriptions[i]:place(tx, dy, tw, self.descriptions[i]:height(tw))
    end
  end
end

---Choose a value, as a click does. Returns true when it changed.
function ChoiceCards:choose(value)
  local index = index_of(self, value)
  if not (self.enabled and index and enabled(self.options[index])) or value == self.value then return false end
  if self.on_change and self.on_change(value) == false then return false end
  self.value = value
  core.log_quiet("Choice Cards chose: %s", tostring(value))
  return true
end

local function step(self, delta)
  local index = index_of(self, self.value) or (delta > 0 and 0 or #self.options + 1)
  for _ = 1, #self.options do
    index = index + delta
    if index < 1 or index > #self.options then return false end
    if enabled(self.options[index]) then return self:choose(self.options[index].value) end
  end
  return false
end

function ChoiceCards:perform(name)
  if name == "move_to_previous_line" or name == "move_to_previous_char" then
    step(self, -1)
    return true
  elseif name == "move_to_next_line" or name == "move_to_next_char" then
    step(self, 1)
    return true
  end
  return false
end

---The index of the card at a point, or nil.
function ChoiceCards:index_at(x, y)
  for i, r in ipairs(self.rects) do
    if x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h then return i end
  end
end

function ChoiceCards:on_mouse_pressed(x, y)
  if not self.enabled then return false end
  local index = self:index_at(x, y)
  if index then self:choose(self.options[index].value) end
  return true
end

function ChoiceCards:on_mouse_moved(x, y)
  local index = self:index_at(x, y)
  if index ~= self.hover_index then
    self.hover_index = index
    core.redraw = true
  end
  return true
end

function ChoiceCards:draw(focused)
  local m = ui.metrics()
  local r = m.group_radius
  local pushed = ui.push_look(self.x, self.y, self.w, self.h, 1, self.enabled and 1 or ui.DISABLED_OPACITY)
  local chosen = index_of(self, self.value)
  local ring_index = chosen or 1
  for i, option in ipairs(self.options) do
    local rect = self.rects[i]
    local x, y, w, h = rect.x, rect.y, rect.w, rect.h
    local faded = ui.push_look(x, y, w, h, 1, enabled(option) and 1 or 0.5)
    if focused and i == ring_index then ui.draw_ring(x, y, w, h, r) end
    surface.draw("group", x, y, w, h, r)
    local b = m.border
    if self.hovered and self.hover_index == i and i ~= chosen and enabled(option) then
      surface.draw("ghost_hover", x + b, y + b, w - 2 * b, h - 2 * b, r - b)
    end
    -- The chosen card fades in its fill and an outline in the focus color.
    local amount = ui.approach(self.amounts, i, i == chosen and 1 or 0, 30)
    if amount > 0 then
      local shown = ui.push_look(x, y, w, h, 1, amount)
      surface.draw("selected", x + b, y + b, w - 2 * b, h - 2 * b, r - b)
      ui.draw_rounded_outline(x, y, w, h, r, b, style.dialog_focus_ring)
      ui.pop_look(shown)
    end
    if option.icon then
      common.draw_text(ui.icon_font(), i == chosen and style.dialog_text_strong or style.dialog_text_muted,
        option.icon, "center", x + pad(), y + pad(), icon_size(), icon_size())
    end
    self.titles[i].color = i == chosen and style.dialog_text_strong or style.dialog_text
    self.titles[i]:draw_node()
    if self.descriptions[i] then self.descriptions[i]:draw_node() end
    ui.pop_look(faded)
  end
  ui.pop_look(pushed)
end

return ChoiceCards
