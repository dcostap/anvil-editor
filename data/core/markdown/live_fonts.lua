-- Fonts for Markdown live presentation. Sized copies are cached per view.
local config = require "core.config"
local style = require "core.style"

local live_fonts = {}

function live_fonts.scaled(view, source, size)
  size = size or view:get_font():get_size()
  if source:get_size() == size then return source end
  local cache = view.__markdown_live_scaled_fonts or {}
  view.__markdown_live_scaled_fonts = cache
  local fonts = cache[source]
  if not fonts then
    fonts = {}
    cache[source] = fonts
  end
  if not fonts[size] then
    fonts[size] = source:copy(size)
    view.__markdown_live_font_measurements = view.__markdown_live_font_measurements or {}
    view.__markdown_live_font_measurements[fonts[size]] = {
      source = source, anchor = "scale", factor = size / SCALE,
    }
  end
  return fonts[size]
end

function live_fonts.body(view)
  return live_fonts.scaled(
    view, style.markdown_body_font, style.markdown_body_font:get_size()
  )
end

function live_fonts.body_line_height(view)
  return math.floor(live_fonts.body(view):get_height() * config.line_height)
end

function live_fonts.heading(view, level)
  local size = level == 1 and 32
    or level == 2 and 24
    or level == 3 and 20
    or level == 4 and 18
    or level == 5 and 16
    or 15
  return live_fonts.scaled(
    view, style.prose_heading_font,
    math.max(1, math.floor(size * SCALE + 0.5))
  )
end

function live_fonts.heading_italic(view, level)
  return live_fonts.scaled(
    view, style.prose_heading_emphasis_font,
    live_fonts.heading(view, level):get_size()
  )
end

function live_fonts.heading_text_row_height(view, level)
  local font_height = live_fonts.heading(view, level):get_height()
  return math.max(
    font_height,
    math.floor(font_height * config.markdown_live_heading_line_height + 0.5)
  )
end

function live_fonts.block_gap(view)
  return math.max(1, math.floor(live_fonts.body(view):get_height() * 0.7))
end

function live_fonts.inline_style(
  view, span_type, base_font, base_bold, base_italic_font
)
  view.__markdown_live_inline_fonts = view.__markdown_live_inline_fonts or {}
  local cache = view.__markdown_live_inline_fonts
  local font
  if span_type == "code" then
    font = style.code_font
  elseif base_bold and (span_type == "emphasis" or span_type == "strong_emphasis")
    and base_italic_font
  then
    font = base_italic_font
  elseif base_bold and span_type == "strong" and base_font then
    font = base_font
  elseif span_type == "strong_emphasis" or base_bold and span_type == "emphasis" then
    font = style.prose_strong_emphasis_font
  elseif span_type == "strong" then
    font = style.prose_strong_font
  elseif span_type == "emphasis" then
    font = style.prose_emphasis_font
  else
    font = base_font or style.markdown_body_font
  end
  local size = base_font and base_font:get_size()
    or span_type == "code" and view:get_font():get_size()
    or live_fonts.body(view):get_size()
  local key = tostring(font) .. ":" .. tostring(size) .. ":" .. tostring(span_type)
  if not cache[key] then
    cache[key] = font:copy(size)
    view.__markdown_live_font_measurements = view.__markdown_live_font_measurements or {}
    local base_measurement = view.__markdown_live_font_measurements[base_font]
    local anchor = base_measurement and base_measurement.anchor == "scale" and "scale"
      or span_type == "code" and not base_font and "code" or "body"
    local anchor_size = anchor == "scale" and SCALE
      or anchor == "code" and view:get_font():get_size()
      or live_fonts.body(view):get_size()
    view.__markdown_live_font_measurements[cache[key]] = {
      source = font, anchor = anchor, factor = size / anchor_size,
    }
  end
  return cache[key]
end

return live_fonts
