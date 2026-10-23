local core = require "core"

-- The operating system's icon font, for window controls and toolbar buttons.
-- Windows 11 has Segoe Fluent Icons. Windows 10 has the same code points in Segoe MDL2 Assets.
-- Other platforms have neither, so callers draw their own fallback.
local system_icons = {}

local PATHS = {
  "C:/Windows/Fonts/SegoeIcons.ttf",
  "C:/Windows/Fonts/segmdl2.ttf",
}

local fonts = {}

---Return the icon font at `size`, or nil when the system has none.
---@param size number
---@return renderer.font?
function system_icons.font(size)
  local font = fonts[size]
  if font ~= nil then return font or nil end
  fonts[size] = false
  for _, path in ipairs(PATHS) do
    local ok, loaded = pcall(renderer.font.load, path, size, { antialiasing = "grayscale", hinting = "full" })
    if ok and loaded then
      fonts[size] = loaded
      core.log_quiet("System icon font loaded: %s at %g", path, size)
      return loaded
    end
  end
  core.log_quiet("System icon font unavailable at %g", size)
  return nil
end

return system_icons
