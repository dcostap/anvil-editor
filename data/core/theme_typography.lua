-- Apply bundled theme fonts without replacing user font choices in other themes.
local typography = {}
local previous = {}
local cache = setmetatable({}, {__mode = "k"})

local function primary_path(font)
  local path = font:get_path()
  return type(path) == "table" and path[1] or path
end

function typography.restore(style)
  for role, state in pairs(previous) do
    local current = style[role]
    if current == state.applied or (current and primary_path(current) == state.path) then
      local size = current:get_size()
      style[role] = size == state.base:get_size() and state.base or state.base:copy(size)
    end
    previous[role] = nil
  end
end

function typography.apply(style, fonts)
  for role, filename in pairs(fonts or {}) do
    local base = style[role]
    if base and type(filename) == "string" then
      local size = base:get_size()
      local by_file = cache[base]
      if not by_file then by_file = {}; cache[base] = by_file end
      local key = filename .. ":" .. tostring(size)
      local font = by_file[key]
      if not font then
        local path = DATADIR .. "/fonts/" .. filename
        local primary = renderer.font.load(path, size, {ligatures = true})
        local fallbacks = base:copy(size)
        if type(fallbacks) == "table" then
          fallbacks[1] = primary
          font = fallbacks
        else
          font = renderer.font.group({primary, fallbacks})
        end
        by_file[key] = font
      end
      style[role] = font
      previous[role] = {base = base, applied = font, path = primary_path(font)}
    end
  end
end

return typography
