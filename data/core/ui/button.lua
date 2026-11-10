local common = require "core.common"
local style = require "core.style"
local ui = require "core.ui"
local surface = require "core.ui.surface"
local Control = require "core.ui.control"

-- A button with a label, an icon, or both. A click or Enter calls `on_click`.
-- `kind` sets its look:
--   "primary"         a bright fill, for the main choice of a Dialog
--   "secondary"       a raised fill, the default
--   "ghost"           no fill until the pointer is over it, for icon buttons
--   "danger"          a raised fill with the danger color, for a choice that removes something
--   "danger_primary"  a danger fill, for the main choice when it removes something
-- `size` is "default", "small" or "tiny".
local Button = Control:extend()

Button.focusable = true
Button.cursor = "hand"

-- The surfaces of each kind: at rest, and under the pointer.
local KINDS = {
  primary = { "lit", "lit_hover" },
  secondary = { "raised", "raised_hover" },
  ghost = { nil, "ghost_hover" },
  danger = { "raised", "danger_hover" },
  danger_primary = { "danger_primary", "danger_primary_hover" },
}

---@param options { label: string?, icon: string?, kind: string?, size: string?, on_click: fun(button: table)?, enabled: boolean?, focusable: boolean? }
function Button:new(options)
  Button.super.new(self, options)
  self.label = options.label
  self.icon = options.icon
  self.kind = options.kind or "secondary"
  self.size = options.size or "default"
  self.on_click = options.on_click
  self.text_color = {}
  if options.focusable == false then self.focusable = false end
end

local function sizes(self)
  local m = ui.metrics()
  if self.size == "tiny" then return m.control_xs_h, ui.role_font("meta"), math.floor(7 * SCALE + 0.5) end
  if self.size == "small" then return m.control_sm_h, ui.role_font("description"), math.floor(9 * SCALE + 0.5) end
  return m.control_h, ui.font(), math.floor(11 * SCALE + 0.5)
end

---The button's natural size.
function Button:measure()
  local h, font, pad = sizes(self)
  local icon_font = ui.icon_font()
  if not self.label then return h, h end
  local w = font:get_width(self.label) + 2 * pad
  if self.icon then w = w + icon_font:get_width(self.icon) + ui.metrics().icon_gap end
  local min_w = self.size == "default" and 64 * SCALE or 0
  return math.max(math.ceil(w), math.floor(min_w)), h
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

function Button:draw(focused)
  local m = ui.metrics()
  local x, y, w, h = self.x, self.y, self.w, self.h
  local r = self.size == "default" and m.control_radius or m.small_radius
  local kind = KINDS[self.kind] or KINDS.secondary
  local down = self.enabled and self.pressed and self.hovered
  local hover = ui.approach(self, "hover_amount", self.enabled and (self.hovered or self.pressed) and 1 or 0, 30)
  local scale = ui.approach(self, "press_scale", down and 0.97 or 1, 40)
  local opacity = self.enabled and 1 or ui.DISABLED_OPACITY
  -- A press shrinks the surface only. Scaled text moves its glyphs between pixels, so the label stays.
  local pushed = ui.push_look(x, y, w, h, scale, opacity)
  if focused then ui.draw_ring(x, y, w, h, r) end
  local rest, over = kind[1] and surface.get(kind[1]), surface.get(kind[2])
  if rest then surface.draw(rest, x, y, w, h, r) end
  if hover > 0 then
    -- The surface under the pointer fades in over the surface at rest.
    local faded = ui.push_look(x, y, w, h, 1, hover)
    surface.draw(over, x, y, w, h, r)
    ui.pop_look(faded)
  end
  ui.pop_look(pushed)
  pushed = ui.push_look(x, y, w, h, 1, opacity)
  local base = rest and rest.text or (self.kind == "danger" and style.dialog_danger) or style.dialog_text_muted
  if self.kind == "danger" then base = style.dialog_danger end
  local text = ui.mix(base, over.text or base, hover, self.text_color)
  local _, font, pad = sizes(self)
  local icon_font = ui.icon_font()
  if not self.label then
    common.draw_text(icon_font, text, self.icon, "center", x, y, w, h)
  else
    local icon_w = self.icon and icon_font:get_width(self.icon) + m.icon_gap or 0
    local label = ui.fit_text(font, self.label, w - 2 * pad - icon_w)
    local cx = math.floor(x + (w - font:get_width(label) - icon_w) / 2)
    if self.icon then
      cx = common.draw_text(icon_font, text, self.icon, "left", cx, y, 0, h) + m.icon_gap
    end
    common.draw_text(font, text, label, "left", cx, y, 0, h)
  end
  ui.pop_look(pushed)
end

return Button
