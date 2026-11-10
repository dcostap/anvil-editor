local core = require "core"
local config = require "core.config"
local style = require "core.style"
local ui = require "core.ui"
local layout = require "core.ui.layout"

-- A turning arc that shows work in progress, for a place that has no text to show it. It takes no input.
-- `size` is its diameter in pixels at scale 1. Without transitions, it stands still.
local Spinner = layout.Node:extend()

local px = layout.px
local DOTS = 24
local ARC = 0.75
local TURN_SECONDS = 0.9

---@param options { size: number? }
function Spinner:new(options)
  Spinner.super.new(self, options)
  self.size = options and options.size or 16
end

function Spinner:content_width() return px(self.size) end
function Spinner:content_height() return px(self.size) end

function Spinner:draw_node()
  local size = math.min(px(self.size), self.w, self.h)
  local stroke = math.max(1, px(self.size / 8))
  local x, y = self.x + (self.w - size) / 2, self.y + (self.h - size) / 2
  local color = style.dialog_text_muted
  renderer.draw_rounded_rect(x, y, size, size, size / 2, ui.tint(color, 0.18), nil, 0, stroke)
  local moving = config.transitions and not core.in_live_resize_frame
  local start = moving and (system.get_time() / TURN_SECONDS % 1) * 2 * math.pi or 0
  local cx, cy, r = x + size / 2, y + size / 2, (size - stroke) / 2
  -- The arc is a row of dots that fade toward its tail.
  for i = 1, DOTS do
    local angle = start + (i / DOTS) * ARC * 2 * math.pi
    renderer.draw_rounded_rect(cx + math.cos(angle) * r - stroke / 2, cy + math.sin(angle) * r - stroke / 2,
      stroke, stroke, stroke / 2, ui.tint(color, i / DOTS))
  end
  if moving then core.redraw = true end
end

return Spinner
