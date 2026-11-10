local core = require "core"
local common = require "core.common"
local style = require "core.style"
local ui = require "core.ui"
local surface = require "core.ui.surface"
local Control = require "core.ui.control"

-- A list of choices where one is on, each with a round mark, a label and an optional description.
-- A click, or the editor's line and character moves, change it. Tab reaches the group once.
-- Each option is `{ value = ..., label = "...", description = "...", enabled = true }`.
-- `on_change(value)` returns false to refuse the change.
local RadioGroup = Control:extend()

RadioGroup.focusable = true
RadioGroup.cursor = "hand"

---@param options { options: table[], value: any, on_change: (fun(value: any): boolean?)?, enabled: boolean? }
function RadioGroup:new(options)
  RadioGroup.super.new(self, options)
  self.options = options.options or {}
  self.value = options.value
  self.on_change = options.on_change
  self.amounts, self.hover_amounts = {}, {}
end

local function mark_size() return math.floor(16 * SCALE + 0.5) end
local function gap() return math.floor(8 * SCALE + 0.5) end
local function row_gap() return math.floor(10 * SCALE + 0.5) end

local function line_height()
  return math.max(mark_size(), ui.role_font("label"):get_height())
end

local function row_height(option)
  local h = line_height()
  if option.description then h = h + ui.metrics().text_gap + ui.role_font("description"):get_height() end
  return h
end

function RadioGroup:measure()
  local font, small = ui.role_font("label"), ui.role_font("description")
  local w, h = 0, 0
  for i, option in ipairs(self.options) do
    w = math.max(w, font:get_width(option.label), option.description and small:get_width(option.description) or 0)
    h = h + row_height(option) + (i > 1 and row_gap() or 0)
  end
  return math.ceil(mark_size() + gap() + w), h
end

function RadioGroup:set_value(value)
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

---Choose a value, as a click does. Returns true when it changed.
function RadioGroup:choose(value)
  local index = index_of(self, value)
  if not (self.enabled and index and enabled(self.options[index])) or value == self.value then return false end
  if self.on_change and self.on_change(value) == false then return false end
  self.value = value
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

function RadioGroup:perform(name)
  if name == "move_to_previous_line" or name == "move_to_previous_char" then
    step(self, -1)
    return true
  elseif name == "move_to_next_line" or name == "move_to_next_char" then
    step(self, 1)
    return true
  end
  return false
end

---The index of the option at height `y`, or nil.
function RadioGroup:index_at(y)
  local top = self.y
  for i, option in ipairs(self.options) do
    local h = row_height(option)
    if y >= top and y < top + h then return i end
    top = top + h + row_gap()
  end
end

function RadioGroup:on_mouse_pressed(x, y)
  if not self.enabled then return false end
  local index = self:index_at(y)
  if index then self:choose(self.options[index].value) end
  return true
end

function RadioGroup:on_mouse_moved(x, y)
  local index = self:index_at(y)
  if index ~= self.hover_index then
    self.hover_index = index
    core.redraw = true
  end
  return true
end

function RadioGroup:draw(focused)
  local size, line_h = mark_size(), line_height()
  local font, small = ui.role_font("label"), ui.role_font("description")
  local pushed = ui.push_look(self.x, self.y, self.w, self.h, 1, self.enabled and 1 or ui.DISABLED_OPACITY)
  local chosen = index_of(self, self.value)
  local ring_index = chosen or 1
  local tx, tw = self.x + size + gap(), self.w - size - gap()
  local top = self.y
  local ink = surface.get("lit").text
  for i, option in ipairs(self.options) do
    local my = top + math.floor((line_h - size) / 2)
    if focused and i == ring_index then ui.draw_ring(self.x, my, size, size, size / 2) end
    local hovered = self.enabled and self.hovered and self.hover_index == i and enabled(option)
    local hover = ui.approach(self.hover_amounts, i, hovered and 1 or 0, 30)
    surface.draw_faded("well", "well_hover", hover, self.x, my, size, size, size / 2)
    local amount = ui.approach(self.amounts, i, i == chosen and 1 or 0, 30)
    if amount > 0 then
      local faded = ui.push_look(self.x, my, size, size, 1, amount)
      surface.draw_faded("lit", "lit_hover", hover, self.x, my, size, size, size / 2)
      local dot = math.floor(6 * SCALE + 0.5)
      local offset = (size - dot) / 2
      renderer.draw_rounded_rect(self.x + offset, my + offset, dot, dot, dot / 2, ink)
      ui.pop_look(faded)
    end
    local color = (hovered or i == chosen) and style.dialog_text_strong or style.dialog_text
    if not enabled(option) then color = ui.fade(color, 0.5) end
    common.draw_text(font, color, ui.fit_text(font, option.label, tw), "left", tx, top, tw, line_h)
    if option.description then
      common.draw_text(small, style.dialog_text_muted, ui.fit_text(small, option.description, tw), "left",
        tx, top + line_h + ui.metrics().text_gap, tw, small:get_height())
    end
    top = top + row_height(option) + row_gap()
  end
  ui.pop_look(pushed)
end

return RadioGroup
