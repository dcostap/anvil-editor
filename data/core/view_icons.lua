local common = require "core.common"
local file_icons = require "core.file_icons"
local style = require "core.style"

local view_icons = { registry = {} }

local function assert_prefix(prefix)
  assert(type(prefix) == "string" and prefix:match("^[a-z][a-z0-9_]*$"),
    "View Icon prefix must use snake_case")
end

function view_icons.ui(glyph, color)
  assert(type(glyph) == "string" and glyph ~= "", "View Icon glyph is required")
  return { kind = "ui", glyph = glyph, color = color }
end

function view_icons.file(path)
  assert(type(path) == "string" and path ~= "", "View Icon file type path is required")
  return { kind = "file", path = path }
end

function view_icons.register(prefix, icon)
  assert_prefix(prefix)
  assert(type(icon) == "table", "View Icon is required")
  view_icons.registry[prefix] = icon
  return icon
end

function view_icons.get(prefix)
  return prefix and view_icons.registry[prefix] or nil
end

function view_icons.for_view(view)
  if not view then return nil end
  local icon = view.view_icon
  if type(icon) == "string" then return view_icons.get(icon) end
  return icon
end

function view_icons.width(icon, row_height)
  if not icon then return 0 end
  if icon.kind == "file" then
    return file_icons.size_for_row(row_height)
  end
  local font = icon.font or style.icon_font
  return font:get_width(icon.glyph)
end

function view_icons.draw(icon, x, y, row_height, color)
  if not icon then return 0 end
  if icon.kind == "file" then
    local size = file_icons.size_for_row(row_height)
    local font, glyph, file_color = file_icons.get(icon.path, math.floor(size * 1.5 + 0.5), false)
    if not font then return 0 end
    local width = font:get_width(glyph)
    local draw_x = x + math.floor((size - width) / 2)
    local draw_y = y + math.floor((row_height - font:get_height()) / 2)
    renderer.draw_text(font, glyph, draw_x, draw_y, color or icon.color or file_color)
    return size
  end
  local font = icon.font or style.icon_font
  local glyph = icon.glyph
  local draw_y = y + math.floor((row_height - font:get_height()) / 2)
  renderer.draw_text(font, glyph, x, draw_y, color or icon.color or style.text)
  return font:get_width(glyph)
end

function view_icons.draw_opener_badge(x, y, width, row_height)
  local font = style.icon_font
  local glyph = "]"
  local badge_size = math.max(10 * (SCALE or 1), row_height * 0.68)
  local badge_font = style.get_scaled_font(font, common.round(badge_size))
  local draw_x = x + width - badge_font:get_width(glyph) * 0.50
  local draw_y = y - badge_font:get_height() * 0.08
  renderer.draw_text(badge_font, glyph, draw_x, draw_y, style.good)
end

return view_icons
