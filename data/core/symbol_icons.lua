local core = require "core"
local style = require "core.style"

local symbol_icons = {}

local ICON_FILES = {
  ["function"] = "function",
  procedure = "function",
  method = "method",
  event = "method",
  operator = "method",
  constructor = "constructor",
  class = "class",
  object = "class",
  struct = "struct",
  union = "union",
  record = "record",
  enum = "enum",
  interface = "interface",
  field = "field",
  enum_member = "constant",
  variable = "variable",
  reference = "variable",
  array = "variable",
  property = "property",
  key = "property",
  constant = "constant",
  value = "constant",
  string = "constant",
  number = "constant",
  boolean = "constant",
  null = "constant",
  parameter = "parameter",
  type_parameter = "type",
  type = "type",
  symbol = "type",
  macro = "constant",
  module = "package",
  namespace = "package",
  package = "package",
  snippet = "template",
}

local cache = {}
local failed = {}

local function normalized_kind(kind)
  kind = tostring(kind or ""):lower():gsub("[%s%-%.]+", "_")
  return kind ~= "" and kind or nil
end

local function dark_theme()
  local background = style.background
  if type(background) == "table" and type(background[1]) == "table" then
    background = background[1]
  end
  if type(background) ~= "table" then return true end
  local r = tonumber(background[1]) or 0
  local g = tonumber(background[2]) or 0
  local b = tonumber(background[3]) or 0
  return r * 0.2126 + g * 0.7152 + b * 0.0722 < 145
end

function symbol_icons.resolve_kind(kind)
  kind = normalized_kind(kind)
  return kind and ICON_FILES[kind] or nil
end

function symbol_icons.size_for_row(row_height)
  local scale = SCALE or 1
  local desired = math.max(1, math.floor(16 * scale + 0.5))
  if row_height then
    desired = math.min(desired, math.max(1, math.floor(row_height - math.max(2, 2 * scale))))
  end
  return desired
end

function symbol_icons.get(kind, size)
  local name = symbol_icons.resolve_kind(kind)
  if not name then return nil, "unknown symbol kind" end
  size = math.max(1, math.floor(tonumber(size) or symbol_icons.size_for_row()))
  local variant = dark_theme() and "_dark" or ""
  local key = name .. variant .. ":" .. tostring(size)
  if cache[key] then return cache[key] end
  if failed[key] then return nil, failed[key] end

  local path = DATADIR .. PATHSEP .. "icons" .. PATHSEP .. "symbols" .. PATHSEP .. name .. variant .. ".svg"
  local icon, err = canvas.load_svg_image(path, size, size)
  if not icon then
    err = tostring(err or "could not load SVG")
    failed[key] = err
    if core.log_quiet then
      core.log_quiet("Symbol icon load failed kind=%s path=%s: %s", tostring(kind), path, err)
    end
    return nil, err
  end
  cache[key] = icon
  return icon
end

function symbol_icons.draw(kind, x, y, row_height, size)
  size = size or symbol_icons.size_for_row(row_height)
  local icon = symbol_icons.get(kind, size)
  if not icon then return false end
  local draw_y = y + math.max(0, math.floor(((row_height or size) - size) / 2))
  renderer.draw_canvas(icon, math.floor(x), math.floor(draw_y))
  return true, size
end

function symbol_icons.reset_cache()
  cache = {}
  failed = {}
end

return symbol_icons
