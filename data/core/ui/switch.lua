local ui = require "core.ui"
local surface = require "core.ui.surface"
local Control = require "core.ui.control"

-- A switch that turns a setting on or off at once. A click or Enter flips it, and the thumb slides.
-- `on_change(value)` returns false to refuse the change.
local Switch = Control:extend()

Switch.focusable = true
Switch.cursor = "hand"

---@param options { value: boolean?, on_change: (fun(value: boolean): boolean?)?, enabled: boolean? }
function Switch:new(options)
  Switch.super.new(self, options)
  self.value = options.value == true
  self.on_change = options.on_change
end

function Switch:measure()
  return math.floor(30 * SCALE + 0.5), math.floor(18 * SCALE + 0.5)
end

function Switch:set_value(value)
  self.value = value == true
end

---Flip the switch, as a click does. Returns true when it changed.
function Switch:toggle()
  if not self.enabled then return false end
  if self.on_change and self.on_change(not self.value) == false then return false end
  self.value = not self.value
  return true
end

function Switch:activate()
  self:toggle()
  return true
end

function Switch:on_mouse_released(x, y)
  if self.pressed and self:contains(x, y) then self:toggle() end
  return true
end

function Switch:draw(focused)
  local x, y, w, h = self.x, self.y, self.w, self.h
  local r = h / 2
  local amount = ui.approach(self, "on_amount", self.value and 1 or 0, 30)
  local hover = ui.approach(self, "hover_amount", self.enabled and self.hovered and 1 or 0, 30)
  local pushed = ui.push_look(x, y, w, h, 1, self.enabled and 1 or ui.DISABLED_OPACITY)
  if focused then ui.draw_ring(x, y, w, h, r) end
  surface.draw_faded("switch_off", "switch_off_hover", hover, x, y, w, h, r)
  if amount > 0 then
    local faded = ui.push_look(x, y, w, h, 1, amount)
    surface.draw_faded("switch_on", "switch_on_hover", hover, x, y, w, h, r)
    ui.pop_look(faded)
  end
  local inset = math.floor(2 * SCALE + 0.5)
  local size = h - 2 * inset
  local tx = x + inset + (w - 2 * inset - size) * amount
  surface.draw(amount >= 0.5 and "thumb_on" or "thumb_off", tx, y + inset, size, size, size / 2)
  ui.pop_look(pushed)
end

return Switch
