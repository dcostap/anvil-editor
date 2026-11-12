local Object = require "core.object"
local ui = require "core.ui"
local layout = require "core.ui.layout"

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
-- Each control takes a `tooltip` option: text that shows near it while the pointer rests on it. Give one to
-- each button that has only an icon.
-- Override `get_tooltip()` when different parts of a control need different explanations.
-- A focused control can set `overlay` to a popup, such as a Select's list. The Dialog draws it above the card
-- and gives it the pointer: contains(x, y), draw(), and the mouse methods above. A press outside the overlay
-- and the control calls the control's cancel(), which closes the overlay. The overlay closes in on_blur().
-- A control is also a layout node (core.ui.layout): `measure()` gives its natural size, and it takes the size
-- options of a node, such as `width`, `max_width` and `grow`.
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
  self.visible = options.visible ~= false
  self.hovered, self.pressed = false, false
  self.tooltip = options.tooltip
  layout.init_size(self, options)
end

function Control:set_rect(x, y, w, h)
  self.x, self.y, self.w, self.h = x, y, w, h
end

function Control:contains(x, y)
  if not (self.visible and x >= self.x and y >= self.y and x < self.x + self.w and y < self.y + self.h) then
    return false
  end
  local clip = self.clip
  return not clip or (x >= clip.x and y >= clip.y and x < clip.x + clip.w and y < clip.y + clip.h)
end

function Control:can_focus()
  return self.focusable and self.enabled and self.visible
end

function Control:get_tooltip()
  return self.tooltip
end

---The natural size, for layout.
function Control:measure()
  return 0, ui.metrics().control_h
end

function Control:content_width()
  return (self:measure())
end

function Control:content_height(w)
  local _, h = self:measure(w)
  return h
end

Control.width_limits, Control.height_limits = layout.Node.width_limits, layout.Node.height_limits
Control.width, Control.height = layout.Node.width, layout.Node.height

---Take a rect from a layout node. The clip of an enclosing Scroll limits where the pointer reaches the control.
function Control:place(x, y, w, h)
  self:set_rect(x, y, w, h)
  self.clip = ui.layout_clip
end

function Control:draw_node(dialog)
  self:draw(dialog:is_focused(self))
end

function Control:collect(list)
  list[#list + 1] = self
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
