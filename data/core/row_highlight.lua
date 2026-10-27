local core = require "core"
local config = require "core.config"
local Object = require "core.object"

-- A highlight behind one row of a list, such as the selected or the hovered result. It glides from row to row
-- and fades in or out where no row had it. The rates match the Project Sidebar's highlights.
local RowHighlight = Object:extend()

-- Rates per second. A change is 95% done after 3 / rate seconds.
RowHighlight.selection = {move = 49, fade = 37}
RowHighlight.hover = {move = 84, fade = 63}

---@param speed {move: number, fade: number}
function RowHighlight:new(speed)
  self.speed = speed
end

---Forget the shown place, so the next row fades in where it is.
function RowHighlight:reset()
  self.y, self.h, self.alpha = nil, nil, nil
end

---Move one step toward the row at `y` with height `h`, or fade out when `y` is nil.
---@param y number?
---@param h number?
function RowHighlight:step(y, h)
  local now = system.get_time()
  -- One step covers at most one frame, so a change after a pause starts where it stopped.
  local frame = 1 / core.fps
  local dt = self.time and math.min(now - self.time, frame) or frame
  self.time = now
  if not config.transitions or core.in_live_resize_frame then dt = math.huge end
  local moving = false
  local function ease(value, target, rate, epsilon)
    local next = value + (target - value) * (1 - math.exp(-rate * dt))
    if math.abs(target - next) <= epsilon then return target end
    moving = true
    return next
  end
  if y then
    if not self.alpha then self.y, self.h, self.alpha = y, h, 0 end
    self.y = ease(self.y, y, self.speed.move, 0.25)
    self.h = ease(self.h, h, self.speed.move, 0.25)
    self.alpha = ease(self.alpha, 1, self.speed.fade, 0.01)
  elseif self.alpha then
    self.alpha = ease(self.alpha, 0, self.speed.fade, 0.01)
    if self.alpha <= 0 then self:reset() end
  end
  if moving then core.redraw = true end
end

---Draw the highlight at its shown place, measured from `top`.
function RowHighlight:draw(x, top, w, radius, color)
  if not self.alpha then return end
  if self.alpha < 1 then color = {color[1], color[2], color[3], (color[4] or 255) * self.alpha} end
  renderer.draw_rounded_rect(x, top + self.y, w, self.h, radius, color)
end

return RowHighlight
