local common = require "core.common"
local style = require "core.style"
local ui = require "core.ui"
local Control = require "core.ui.control"

-- A row of choices where one is on, such as a role. A click, or the editor's character moves, change it.
-- A highlight slides to the chosen segment. Each option is `{ value = ..., label = "...", enabled = true }`.
-- `on_change(value)` returns false to refuse the change.
local Segmented = Control:extend()

Segmented.focusable = true
Segmented.cursor = "hand"

---@param options { options: table[], value: any, on_change: (fun(value: any): boolean?)?, enabled: boolean? }
function Segmented:new(options)
  Segmented.super.new(self, options)
  self.on_change = options.on_change
  self:set_options(options.options or {}, options.value)
end

---Replace the options and the chosen value.
function Segmented:set_options(options, value)
  self.options, self.value = options, value
  self.thumb_x, self.thumb_w = nil, nil
end

function Segmented:set_value(value)
  self.value = value
end

local function enabled(option)
  return option.enabled ~= false
end

---The natural size: each segment fits the widest label.
function Segmented:measure()
  local m = ui.metrics()
  local widest = 0
  for _, option in ipairs(self.options) do widest = math.max(widest, ui.font():get_width(option.label)) end
  local segment_w = math.floor(widest + 2 * m.pad_x + 4 * SCALE)
  return segment_w * #self.options + 2 * m.border * 2, m.control_h
end

local function segment_rect(self, index)
  local inset = 2 * ui.metrics().border
  local segment_w = (self.w - 2 * inset) / math.max(1, #self.options)
  return self.x + inset + (index - 1) * segment_w, self.y + inset, segment_w, self.h - 2 * inset
end

local function index_of(self, value)
  for i, option in ipairs(self.options) do
    if option.value == value then return i end
  end
end

---Choose a value, as a click does. Returns true when it changed.
function Segmented:choose(value)
  local index = index_of(self, value)
  if not (self.enabled and index and enabled(self.options[index])) or value == self.value then return false end
  if self.on_change and self.on_change(value) == false then return false end
  self.value = value
  return true
end

local function step(self, delta)
  local index = index_of(self, self.value) or 0
  local count = #self.options
  for _ = 1, count do
    index = index + delta
    if index < 1 or index > count then return false end
    if enabled(self.options[index]) then return self:choose(self.options[index].value) end
  end
  return false
end

function Segmented:perform(name)
  if name == "move_to_previous_char" or name == "move_to_previous_word_start" then
    step(self, -1)
    return true
  elseif name == "move_to_next_char" or name == "move_to_next_word_end" then
    step(self, 1)
    return true
  end
  return false
end

function Segmented:on_mouse_pressed(x, y)
  if not self.enabled then return false end
  for i, option in ipairs(self.options) do
    local sx, sy, sw, sh = segment_rect(self, i)
    if x >= sx and x < sx + sw and y >= sy and y < sy + sh then
      self:choose(option.value)
      break
    end
  end
  return true
end

function Segmented:draw(focused)
  local m = ui.metrics()
  local x, y, w, h, r = self.x, self.y, self.w, self.h, m.radius
  if focused then ui.draw_focus_ring(x, y, w, h, r) end
  renderer.draw_rounded_rect(x, y, w, h, r, style.card_field)
  local index = index_of(self, self.value)
  if index then
    local sx, sy, sw, sh = segment_rect(self, index)
    -- The highlight slides to a new choice.
    local tx = ui.approach(self, "thumb_x", sx, 28)
    local tw = ui.approach(self, "thumb_w", sw, 28)
    -- The highlight is the card's color, so it stands up from the darker track.
    renderer.draw_rounded_rect(tx, sy, tw, sh, r - m.border, style.card)
    renderer.draw_rounded_rect(tx, sy, tw, sh, r - m.border, self.enabled and style.button or style.card_selection)
  end
  local font = ui.font()
  for i, option in ipairs(self.options) do
    local sx, sy, sw, sh = segment_rect(self, i)
    local color = i == index and style.text or style.card_text
    if not (self.enabled and enabled(option)) then color = ui.fade(color, i == index and 0.7 or 0.4) end
    common.draw_text(font, color, option.label, "center", sx, sy, sw, sh)
  end
end

return Segmented
