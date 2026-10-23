local Object = require "core.object"
local style = require "core.style"

-- One short pulse per focus destination. Layout changes do not restart it.
local FocusFeedback = Object:extend()
local DURATION = 0.38

function FocusFeedback:update(target, now)
  now = now or system.get_time()
  local changed = target ~= self.target
  if changed then
    self.target = target
    self.started = target and now or nil
  end
  local active = self:active(now)
  local finished = self.started ~= nil and not active
  if finished then self.started = nil end
  return active, changed, finished
end

function FocusFeedback:active(now)
  return self.started ~= nil and (now or system.get_time()) - self.started < DURATION
end

function FocusFeedback:draw(x, y, width, height, now)
  now = now or system.get_time()
  if not self:active(now) or width <= 0 or height <= 0 then return false end
  local strength = (1 - math.max(0, now - self.started) / DURATION) ^ 2
  local source = style.focus_feedback
  local color = {source[1], source[2], source[3], source[4] * strength}
  local inset = math.min(2 * SCALE, width / 4, height / 4)
  x, y, width, height = x + inset, y + inset, width - 2 * inset, height - 2 * inset
  local stroke = math.min(math.max(1, math.floor(2 * SCALE)), width / 2, height / 2)
  renderer.draw_rect(x, y, width, height, {color[1], color[2], color[3], color[4] * 0.06})
  renderer.draw_rect(x, y, width, stroke, color)
  renderer.draw_rect(x, y + height - stroke, width, stroke, color)
  renderer.draw_rect(x, y + stroke, stroke, height - 2 * stroke, color)
  renderer.draw_rect(x + width - stroke, y + stroke, stroke, height - 2 * stroke, color)
  return true
end

return FocusFeedback
