local Object = require "core.object"

-- A control in a Dialog, such as a button or a text field. The Dialog places it, sends it input and draws it.
--
-- The Dialog calls these methods. Each returns true when the control used the input:
--   on_mouse_pressed(x, y, clicks), on_mouse_moved(x, y), on_mouse_released(x, y), on_mouse_wheel(dy)
--   on_text(text)     typed text, for a control with `takes_text`
--   perform(name)     an editor command without its "core:" prefix, such as "move_to_next_line"
--   activate()        Enter
--   cancel()          Escape. A control that has nothing to cancel returns false, and the Dialog closes.
--   on_focus(), on_blur()
-- `hovered` is true while the pointer is over the control, and `pressed` while a press on it lasts.
local Control = Object:extend()

-- Whether Tab and a click give the control keyboard focus.
Control.focusable = false
-- Whether the control takes typed text.
Control.takes_text = false
-- The pointer's shape over the control.
Control.cursor = "arrow"

function Control:new(options)
  options = options or {}
  self.x, self.y, self.w, self.h = 0, 0, 0, 0
  self.enabled = options.enabled ~= false
  self.visible = true
  self.hovered, self.pressed = false, false
end

function Control:set_rect(x, y, w, h)
  self.x, self.y, self.w, self.h = x, y, w, h
end

function Control:contains(x, y)
  return self.visible and x >= self.x and y >= self.y and x < self.x + self.w and y < self.y + self.h
end

function Control:can_focus()
  return self.focusable and self.enabled and self.visible
end

function Control:on_mouse_pressed() return self.enabled end
function Control:on_mouse_moved() return false end
function Control:on_mouse_released() return false end
function Control:on_mouse_wheel() return false end
function Control:on_text() return false end
function Control:perform() return false end
function Control:activate() return false end
function Control:cancel() return false end
function Control:on_focus() end
function Control:on_blur() end

---Draw the control. `focused` is true while it has keyboard focus.
function Control:draw(focused) end

return Control
