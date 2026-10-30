local common = require "core.common"
local style = require "core.style"
local ui = require "core.ui"
local Control = require "core.ui.control"

-- A button with a label, an icon, or both. A click or Enter calls `on_click`.
-- `kind` sets its look:
--   "primary"   the accent fill, for the main choice of a Dialog
--   "secondary" a quiet fill, the default
--   "danger"    a quiet fill with the error color, for a choice that removes something
--   "ghost"     no fill until the pointer is over it, for icon buttons
local Button = Control:extend()

Button.focusable = true
Button.cursor = "hand"

---@param options { label: string?, icon: string?, kind: string?, on_click: fun(button: table)?, enabled: boolean?, focusable: boolean?, tooltip: string? }
function Button:new(options)
  Button.super.new(self, options)
  self.label = options.label
  self.icon = options.icon
  self.kind = options.kind or "secondary"
  self.on_click = options.on_click
  if options.focusable == false then self.focusable = false end
end

---The button's natural size.
function Button:measure()
  local m = ui.metrics()
  local font, icon_font = ui.font(), ui.icon_font()
  if not self.label then return m.control_h, m.control_h end
  local w = font:get_width(self.label) + 2 * m.pad_x + 2 * SCALE
  if self.icon then w = w + icon_font:get_width(self.icon) + m.icon_gap end
  return math.max(math.floor(w), math.floor(64 * SCALE)), m.control_h
end

function Button:activate()
  if not self.enabled then return false end
  if self.on_click then self.on_click(self) end
  return true
end

function Button:on_mouse_released(x, y)
  if self.pressed and self:contains(x, y) then self:activate() end
  return true
end

local function colors(self)
  local kind = self.kind
  if kind == "primary" then return style.accent, style.button_primary_text end
  if kind == "danger" then return style.button, style.error end
  if kind == "ghost" then return nil, style.card_text end
  return style.button, style.text
end

function Button:draw(focused)
  local m = ui.metrics()
  local x, y, w, h, r = self.x, self.y, self.w, self.h, m.radius
  local alpha = self.enabled and 1 or 0.4
  if focused then ui.draw_focus_ring(x, y, w, h, r) end
  local fill, text = colors(self)
  local hover = ui.approach(self, "hover_amount", self.enabled and self.hovered and 1 or 0, 30)
  if fill then renderer.draw_rounded_rect(x, y, w, h, r, ui.fade(fill, alpha)) end
  if self.pressed and self.hovered then
    renderer.draw_rounded_rect(x, y, w, h, r, style.button_pressed)
  elseif hover > 0 then
    -- A ghost button shows the quiet fill under the pointer. The others brighten.
    local over = self.kind == "danger" and ui.fade(style.error, 0.16)
      or (fill and style.button_hover or style.button)
    renderer.draw_rounded_rect(x, y, w, h, r, ui.fade(over, hover))
    if self.kind == "ghost" then text = ui.mix(text, style.text, hover) end
  end
  text = ui.fade(text, alpha)
  local font, icon_font = ui.font(), ui.icon_font()
  if not self.label then
    common.draw_text(icon_font, text, self.icon, "center", x, y, w, h)
    return
  end
  local content_w = font:get_width(self.label) + (self.icon and icon_font:get_width(self.icon) + m.icon_gap or 0)
  local cx = math.floor(x + (w - content_w) / 2)
  if self.icon then
    cx = common.draw_text(icon_font, text, self.icon, "left", cx, y, 0, h) + m.icon_gap
  end
  common.draw_text(font, text, self.label, "left", cx, y, 0, h)
end

return Button
