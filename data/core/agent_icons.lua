-- Official program marks for Terminal Tabs. Never infer identity from a window title.
local style = require "core.style"
local file_icons = require "core.file_icons"
local agent_icons = {}
local cache = {}

function agent_icons.size(app, row_height)
  return app == "pi" and file_icons.size_for_row(row_height) or 0
end

function agent_icons.draw(app, x, y, row_height)
  local size = agent_icons.size(app, row_height)
  if size == 0 then return end
  local background = style.background
  if type(background[1]) == "table" then background = background[1] end
  local dark = background[1] * 0.2126 + background[2] * 0.7152 + background[3] * 0.0722 < 145
  local variant = dark and "_dark" or ""
  local key = app .. variant .. ":" .. size
  if cache[key] == nil then
    local path = DATADIR .. PATHSEP .. "icons" .. PATHSEP .. "agents" .. PATHSEP .. app .. variant .. ".svg"
    local image, err = canvas.load_svg_image(path, size, size)
    cache[key] = image or false
    if not image then require("core").log_quiet("Agent icon load failed: %s: %s", path, tostring(err)) end
  end
  if cache[key] then
    renderer.draw_canvas(cache[key], math.floor(x), math.floor(y + (row_height - size) / 2))
  end
end

return agent_icons
