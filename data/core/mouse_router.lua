-- Pointer state for Views that contain child input surfaces.

local Object = require "core.object"

local MouseRouter = Object:extend()

function MouseRouter:new(owner, target_at)
  self.owner = assert(owner)
  self.target_at = assert(target_at)
end

function MouseRouter:call(target, method, ...)
  local fn = target and target[method]
  if not fn then return nil end
  if target.with_selection_state then
    return target:with_selection_state(fn, target, ...)
  end
  return fn(target, ...)
end

function MouseRouter:target(x, y)
  return self.target_at(self.owner, x, y)
end

function MouseRouter:cursor_for(target, x, y)
  if target and target.scrollbar_dragging and target:scrollbar_dragging() then return "arrow" end
  if target and target.scrollbar_overlaps_point
      and target:scrollbar_overlaps_point(x, y) then
    return "arrow"
  end
  return target and target.cursor or "arrow"
end

function MouseRouter:update_hover(target, x, y)
  if target ~= self.hovered then
    self:call(self.hovered, "on_mouse_left")
    self.hovered = target
  end
  self.owner.cursor = self:cursor_for(target, x, y)
  return target
end

function MouseRouter:press_target(x, y)
  self.x, self.y = x, y
  return self:update_hover(self:target(x, y), x, y)
end

function MouseRouter:capture(target)
  self.captured = target
  return target
end

function MouseRouter:press_scrollbar(target, button, x, y, clicks)
  if button ~= "left" or not target or not target.scrollbar_overlaps_point
      or not target:scrollbar_overlaps_point(x, y) then
    return false
  end
  self:capture(target)
  return true, self:call(target, "on_mouse_pressed", button, x, y, clicks)
end

function MouseRouter:captured_target()
  return self.captured
end

function MouseRouter:hovered_target()
  return self.hovered
end

function MouseRouter:has_pointer()
  return self.x ~= nil and self.y ~= nil
end

function MouseRouter:wheel_target()
  if not self:has_pointer() then return self.hovered end
  local target = self:target(self.x, self.y)
  local changed = target ~= self.hovered
  self:update_hover(target, self.x, self.y)
  if changed and target then
    self:call(target, "on_mouse_moved", self.x, self.y, 0, 0)
    self.owner.cursor = self:cursor_for(target, self.x, self.y)
  end
  return target
end

function MouseRouter:move(x, y, dx, dy)
  self.x, self.y = x, y
  local target = self.captured or self:target(x, y)
  if not self.captured then self:update_hover(target, x, y) end
  local handled = self:call(target, "on_mouse_moved", x, y, dx, dy)
  self.owner.cursor = self:cursor_for(target, x, y)
  return handled, target
end

function MouseRouter:release(button, x, y, ...)
  self.x, self.y = x, y
  local target = self.captured or self:target(x, y)
  self.captured = nil
  local handled = self:call(target, "on_mouse_released", button, x, y, ...)
  local hovered = self:update_hover(self:target(x, y), x, y)
  if hovered and hovered ~= target then
    self:call(hovered, "on_mouse_moved", x, y, 0, 0)
    self.owner.cursor = self:cursor_for(hovered, x, y)
  end
  return handled, target
end

function MouseRouter:leave()
  if self.captured then return false end
  self:call(self.hovered, "on_mouse_left")
  self.hovered = nil
  self.x, self.y = nil, nil
  self.owner.cursor = "arrow"
  return true
end

return MouseRouter
