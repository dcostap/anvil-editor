local common = require "core.common"
local style = require "core.style"
local ui = require "core.ui"
local surface = require "core.ui.surface"
local Control = require "core.ui.control"

-- A check box with an optional label and description. A click on any part of it, or Enter, flips it.
-- `value` is true, false or "mixed". A flip of "mixed" gives true.
-- `on_change(value)` returns false to refuse the change.
local Checkbox = Control:extend()

Checkbox.focusable = true
Checkbox.cursor = "hand"

---@param options { value: boolean|string?, label: string?, description: string?, on_change: (fun(value: boolean): boolean?)?, enabled: boolean? }
function Checkbox:new(options)
  Checkbox.super.new(self, options)
  self.value = options.value or false
  self.label = options.label
  self.description = options.description
  self.on_change = options.on_change
end

local function box_size()
  return math.floor(16 * SCALE + 0.5)
end

local function gap()
  return math.floor(8 * SCALE + 0.5)
end

function Checkbox:measure()
  local box = box_size()
  if not self.label then return box, box end
  local font, small = ui.role_font("label"), ui.role_font("description")
  local w = math.max(font:get_width(self.label), self.description and small:get_width(self.description) or 0)
  local h = math.max(box, font:get_height())
  if self.description then h = h + ui.metrics().text_gap + small:get_height() end
  return math.ceil(box + gap() + w), h
end

function Checkbox:set_value(value)
  self.value = value
end

---Flip the box, as a click does. Returns true when it changed.
function Checkbox:toggle()
  if not self.enabled then return false end
  local value = self.value ~= true
  if self.on_change and self.on_change(value) == false then return false end
  self.value = value
  return true
end

function Checkbox:activate()
  self:toggle()
  return true
end

function Checkbox:on_mouse_released(x, y)
  if self.pressed and self:contains(x, y) then self:toggle() end
  return true
end

---Draw a check box in the square at (x, y). Radio buttons and list rows can use it.
---@param amount number How far it is on, from 0 to 1.
---@param mixed boolean? Show a dash in place of the check.
function Checkbox.draw_box(x, y, size, amount, mixed)
  local r = math.floor(4 * SCALE + 0.5)
  surface.draw("well", x, y, size, size, r)
  if amount <= 0 then return end
  local pushed = ui.push_look(x, y, size, size, 1, amount)
  surface.draw("lit", x, y, size, size, r)
  local font = style.get_scaled_font(ui.icon_font(), math.floor(size * 0.9))
  local glyph = mixed and ui.icons.minus or ui.icons.check
  common.draw_text(font, surface.get("lit").text, glyph, "center", x, y, size, size)
  ui.pop_look(pushed)
end

function Checkbox:draw(focused)
  local box = box_size()
  local x, y = self.x, self.y
  local font = ui.role_font("label")
  local line_h = self.label and math.max(box, font:get_height()) or self.h
  local by = y + math.floor((line_h - box) / 2)
  local pushed = ui.push_look(self.x, self.y, self.w, self.h, 1, self.enabled and 1 or ui.DISABLED_OPACITY)
  if focused then ui.draw_ring(x, by, box, box, math.floor(4 * SCALE + 0.5)) end
  local amount = ui.approach(self, "on_amount", self.value and 1 or 0, 30)
  Checkbox.draw_box(x, by, box, amount, self.value == "mixed")
  if self.label then
    local tx = x + box + gap()
    local tw = self.w - box - gap()
    common.draw_text(font, style.dialog_text, ui.fit_text(font, self.label, tw), "left", tx, y, tw, line_h)
    if self.description then
      local small = ui.role_font("description")
      common.draw_text(small, style.dialog_text_muted, ui.fit_text(small, self.description, tw), "left",
        tx, y + line_h + ui.metrics().text_gap, tw, small:get_height())
    end
  end
  ui.pop_look(pushed)
end

return Checkbox
