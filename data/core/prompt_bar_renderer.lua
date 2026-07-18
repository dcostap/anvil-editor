local core = require "core"
local common = require "core.common"
local style = require "core.style"

---Shared rendering helpers for Global Prompt Bar and DocView Prompt Bar rows.
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

function prompt_bar_renderer.text_y(y, h, font)
  return y + (h - resolve_font(font):get_height()) / 2
end

function prompt_bar_renderer.label_text_width(label, font)
  return resolve_font(font):get_width(label or "") + style.padding.x
end

function prompt_bar_renderer.label_input_gap()
  return math.max(2, style.padding.x * 1)
end

function prompt_bar_renderer.label_width(label, font)
  return prompt_bar_renderer.label_text_width(label, font)
    + prompt_bar_renderer.label_input_gap()
end

function prompt_bar_renderer.label_color(brightness)
  return common.lerp(style.text, style.accent, (brightness or 0) / 100)
end

function prompt_bar_renderer.top_separator_color()
  return style.divider
end

function prompt_bar_renderer.draw_background(x, y, w, h)
  renderer.draw_rect(x, y, w, h, style.background)
end

function prompt_bar_renderer.draw_top_divider(x, y, w)
  local h = math.max(1, style.divider_size or 1)
  renderer.draw_rect(x, y, w, h, prompt_bar_renderer.top_separator_color())
end

function prompt_bar_renderer.draw_vertical_divider(x, y, h)
  local w = math.max(1, style.divider_size or 1)
  renderer.draw_rect(x, y, w, h, style.divider)
end

function prompt_bar_renderer.draw_label(font, label, x, y, w, h, brightness)
  if not label or label == "" or w <= 0 or h <= 0 then return end
  font = resolve_font(font)
  core.push_clip_rect(x, y, w, h)
  renderer.draw_text(
    font,
    label,
    x + style.padding.x,
    prompt_bar_renderer.text_y(y, h, font),
    prompt_bar_renderer.label_color(brightness)
  )
  core.pop_clip_rect()
end

function prompt_bar_renderer.draw_info(font, text, x, y, w, h, color)
  if not text or text == "" or w <= 0 or h <= 0 then return end
  font = resolve_font(font)
  core.push_clip_rect(x, y, w, h)
  common.draw_text(font, color or style.dim, text, "right", x, y, w, h)
  core.pop_clip_rect()
end

return prompt_bar_renderer
