local style = require "core.style"

---Shared metrics for the single-line inputs of the Global Prompt Bar and Find.
local prompt_bar_renderer = {}

local function resolve_font(font)
  return font or style.font
end

function prompt_bar_renderer.line_height(font)
  return math.floor(resolve_font(font):get_height() * 1.2)
end

function prompt_bar_renderer.height(font)
  return resolve_font(font):get_height() + style.padding.y * 2
end

function prompt_bar_renderer.line_y(y, h, font)
  return y + (h - prompt_bar_renderer.line_height(font)) / 2
end

return prompt_bar_renderer
