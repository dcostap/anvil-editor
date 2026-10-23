-- Private renderer samples of the same pulse at three points in its lifetime.
local View = require "core.view"
local style = require "core.style"
local FocusFeedback = require "core.focus_feedback"
local Scene = View:extend()

function Scene:new()
  Scene.super.new(self)
  self.feedback = FocusFeedback()
  self.feedback:update(self, 0)
end

function Scene:get_name() return "Focus feedback" end

function Scene:draw()
  self:draw_background(style.background)
  local pad = 24 * SCALE
  local width = (self.size.x - 4 * pad) / 3
  local y, height = self.position.y + pad, self.size.y - 2 * pad
  for index, sample in ipairs {
    {time=0, label="Focus enters"}, {time=0.19, label="Fading"}, {time=1, label="Resting"},
  } do
    local x = self.position.x + pad + (index - 1) * (width + pad)
    renderer.draw_rect(x, y, width, height, style.background2)
    renderer.draw_text(style.font, sample.label, x + pad, y + pad, style.text)
    renderer.draw_text(style.font, "Content stays still.", x + pad, y + pad * 3, style.dim)
    self.feedback:draw(x, y, width, height, sample.time)
  end
end

return Scene
