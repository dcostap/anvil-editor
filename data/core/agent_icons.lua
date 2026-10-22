-- Official program marks for Terminal Tabs. Never infer identity from a window title.
local style = require "core.style"
local file_icons = require "core.file_icons"
local agent_icons = {}
local cache = {}

-- The selected model's name determines its maker, not the API service that hosts it.
function agent_icons.provider(model)
  local name = type(model) == "string" and model:lower() or ""
  if name:find("gpt", 1, true) then return "openai" end
  if name:find("claude", 1, true) or name:find("fable", 1, true) then return "anthropic" end
  if name:find("deepseek", 1, true) then return "deepseek" end
end

local function dimensions(app, row_height, model)
  if app ~= "pi" then return 0, 0 end
  local size = file_icons.size_for_row(row_height)
  if not agent_icons.provider(model) then return size, 0 end
  return size, size + math.max(1, math.floor(3 * SCALE + 0.5))
end

function agent_icons.width(app, row_height, model)
  local size, offset = dimensions(app, row_height, model)
  return size + offset
end

local function image(name, size)
  local background = style.background
  if type(background[1]) == "table" then background = background[1] end
  local dark = background[1] * 0.2126 + background[2] * 0.7152 + background[3] * 0.0722 < 145
  local variant = dark and (name == "pi" or name == "openai") and "_dark" or ""
  local key = name .. variant .. ":" .. size
  if cache[key] == nil then
    local path = DATADIR .. PATHSEP .. "icons" .. PATHSEP .. "agents" .. PATHSEP .. name .. variant .. ".svg"
    local value, err = canvas.load_svg_image(path, size, size)
    cache[key] = value or false
    if not value then require("core").log_quiet("Agent icon load failed: %s: %s", path, tostring(err)) end
  end
  return cache[key]
end

function agent_icons.draw(app, x, y, row_height, model)
  local size, offset = dimensions(app, row_height, model)
  if size == 0 then return end
  local mark = image(app, size)
  local top = math.floor(y + (row_height - size) / 2)
  if mark then renderer.draw_canvas(mark, math.floor(x), top) end
  if offset == 0 then return end
  local maker = agent_icons.provider(model)
  local provider = image(maker == "anthropic" and "claude" or maker, size)
  if not provider then return end
  renderer.draw_canvas(provider, math.floor(x + offset), top)
end

return agent_icons
