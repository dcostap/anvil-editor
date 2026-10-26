local Object = require "core.object"
local style = require "core.style"

-- One short pulse per focus destination. Layout changes do not restart it.
local FocusFeedback = Object:extend()
local DURATION = 0.38

function FocusFeedback:update(target, now, kind)
  now = now or system.get_time()
  local changed = target ~= self.target
  if changed or (target and kind == "numbered") then
    self.target = target
    self.started = target and (now + (kind == "numbered" and 0.25 or 0)) or nil
    self.strength = kind == "pointer" and 0.35 or 1
  end
  local active = self:active(now)
  local finished = self.started ~= nil and not active
  if finished then self.started = nil end
  return active, changed, finished
end

function FocusFeedback:active(now)
  return self.started ~= nil and (now or system.get_time()) - self.started < DURATION
end

local function draw_edge(x, y, length, stroke, vertical, gap, color)
  if length <= 0 then return end
  local count = math.max(1, math.floor(length / (56 * SCALE) + 0.5))
  local segment = (length - (count - 1) * gap) / count
  for index = 0, count - 1 do
    local offset = index * (segment + gap)
    if vertical then
      renderer.draw_rect(x, y + offset, stroke, segment, color)
    else
      renderer.draw_rect(x + offset, y, segment, stroke, color)
    end
  end
end

function FocusFeedback:draw(x, y, width, height, now)
  now = now or system.get_time()
  if not self:active(now) or now < self.started or width <= 0 or height <= 0 then return false end
  local remaining = (1 - (now - self.started) / DURATION) ^ 2
  local strength = self.strength * remaining
  local source = style.focus_feedback
  local color = {source[1], source[2], source[3], source[4] * strength}
  -- The segments lengthen as they fade. The gaps never close.
  local inset = math.min(2 * SCALE, width / 4, height / 4)
  local gap = (4 + 4 * remaining) * SCALE
  x, y, width, height = x + inset, y + inset, width - 2 * inset, height - 2 * inset
  local stroke = math.min(math.max(1, math.floor(2 * SCALE)), width / 2, height / 2)
  renderer.draw_rect(x, y, width, height, {color[1], color[2], color[3], color[4] * 0.06})
  draw_edge(x, y, width, stroke, false, gap, color)
  draw_edge(x, y + height - stroke, width, stroke, false, gap, color)
  draw_edge(x, y + stroke, height - 2 * stroke, stroke, true, gap, color)
  draw_edge(x + width - stroke, y + stroke, height - 2 * stroke, stroke, true, gap, color)
  return true
end

return FocusFeedback
