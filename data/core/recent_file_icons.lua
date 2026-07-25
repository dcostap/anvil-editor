local core = require "core"
local style = require "core.style"

local recent_file_icons = {}
local cache = {}
local failed = {}
local names = { pencil = true, eye = true }

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

function recent_file_icons.size_for_row(row_height)
  local scale = SCALE or 1
  local desired = math.max(1, math.floor(14 * scale + 0.5))
  if row_height then
    desired = math.min(desired, math.max(1, math.floor(row_height - math.max(2, 2 * scale))))
  end
  return desired
end

function recent_file_icons.get(name, size)
  name = tostring(name or "")
  if not names[name] then return nil, "unknown Recent File icon" end
  size = math.max(1, math.floor(tonumber(size) or recent_file_icons.size_for_row()))
  local variant = dark_theme() and "_dark" or ""
  local key = name .. variant .. ":" .. tostring(size)
  if cache[key] then return cache[key] end
  if failed[key] then return nil, failed[key] end

  local path = DATADIR .. PATHSEP .. "icons" .. PATHSEP .. "recent_files" .. PATHSEP .. name .. variant .. ".svg"
  local icon, err = canvas.load_svg_image(path, size, size)
  if not icon then
    err = tostring(err or "could not load SVG")
    failed[key] = err
    if core.log_quiet then
      core.log_quiet("Recent File icon load failed name=%s path=%s: %s", name, path, err)
    end
    return nil, err
  end
  cache[key] = icon
  return icon
end

function recent_file_icons.draw(name, x, y, row_height, size)
  size = size or recent_file_icons.size_for_row(row_height)
  local icon = recent_file_icons.get(name, size)
  if not icon then return false end
  local draw_y = y + math.max(0, math.floor(((row_height or size) - size) / 2))
  renderer.draw_canvas(icon, math.floor(x), math.floor(draw_y))
  return true, size
end

function recent_file_icons.reset_cache()
  cache = {}
  failed = {}
end

return recent_file_icons
