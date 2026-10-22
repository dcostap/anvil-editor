-- The Zoom is one setting for every Project and the Sidebar. USERDIR keeps it as ratios over the base scale, so
-- each process applies it over its own display scale.
local storage = require "core.storage"

local zoom = {}

---The saved interface and code Zoom ratios. Without a saved Zoom, both are 1.
---@return number interface
---@return number code
function zoom.load()
  local saved = storage.load("zoom", "global")
  local interface = type(saved) == "table" and tonumber(saved.interface) or 1
  local code = type(saved) == "table" and tonumber(saved.code) or interface
  return interface, code
end

---@param interface number
---@param code number
function zoom.save(interface, code)
  storage.save("zoom", "global", { interface = interface, code = code })
end

return zoom
