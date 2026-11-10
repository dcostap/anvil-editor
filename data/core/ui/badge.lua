local common = require "core.common"
local style = require "core.style"
local ui = require "core.ui"
local layout = require "core.ui.layout"

-- A small label for a state or a count, such as "Connected" or "3". It takes no input.
-- `tone` colors it: "neutral" (the default), "success", "warning", "danger" or "info". `icon` goes before the label.
local Badge = layout.Node:extend()

local px = layout.px

---@param options { label: string, tone: string?, icon: string? }
function Badge:new(options)
  Badge.super.new(self, options)
  self.label = options.label or ""
  self.tone = options.tone or "neutral"
  self.icon = options.icon
end

function Badge:set_label(label)
  self.label = label
end

local function icon_width(self)
  return self.icon and ui.small_icon_font():get_width(self.icon) + px(4) or 0
end

function Badge:content_width()
  return math.ceil(ui.role_font("meta"):get_width(self.label) + icon_width(self) + 2 * px(7))
end

function Badge:content_height()
  return ui.role_font("meta"):get_height() + px(4)
end

function Badge:draw_node()
  local neutral = self.tone == "neutral"
  local color = neutral and style.dialog_text or ui.tone_color(self.tone)
  local fill = neutral and ui.tint(style.dialog_text_strong, 0.1) or ui.tint(color, 0.16)
  local h = self:content_height()
  local y = self.y + math.floor((self.h - h) / 2)
  renderer.draw_rounded_rect(self.x, y, self.w, h, ui.metrics().small_radius, fill)
  local x = self.x + px(7)
  if self.icon then
    x = common.draw_text(ui.small_icon_font(), color, self.icon, "left", x, y, 0, h) + px(4)
  end
  local font = ui.role_font("meta")
  common.draw_text(font, color, ui.fit_text(font, self.label, self.x + self.w - px(7) - x), "left", x, y, 0, h)
end

return Badge
