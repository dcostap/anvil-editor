local common = require "core.common"
local style = require "core.style"
local ui = require "core.ui"
local layout = require "core.ui.layout"

-- A colored dot for a state, with an optional label, such as "Connected". It takes no input.
-- `tone` is "neutral" (the default), "success", "warning", "danger" or "info".
local StatusDot = layout.Node:extend()

local px = layout.px

---@param options { tone: string?, label: string? }
function StatusDot:new(options)
  StatusDot.super.new(self, options)
  self.tone = options.tone or "neutral"
  self.label = options.label
end

function StatusDot:set(tone, label)
  self.tone, self.label = tone, label
end

function StatusDot:content_width()
  if not self.label then return px(8) end
  return px(8) + px(6) + math.ceil(ui.role_font("description"):get_width(self.label))
end

function StatusDot:content_height()
  return self.label and ui.role_font("description"):get_height() or px(8)
end

function StatusDot:draw_node()
  local size = px(8)
  local color = self.tone == "neutral" and style.dialog_text_dim or ui.tone_color(self.tone)
  renderer.draw_rounded_rect(self.x, self.y + math.floor((self.h - size) / 2), size, size, size / 2, color)
  if self.label then
    local font = ui.role_font("description")
    local x = self.x + size + px(6)
    common.draw_text(font, style.dialog_text_muted, ui.fit_text(font, self.label, self.x + self.w - x), "left",
      x, self.y, 0, self.h)
  end
end

return StatusDot
