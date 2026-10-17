-- Helpers for scenes that run in a hosted Project of the native shell.
-- The shell writes its events to ANVIL_SURFACE_LOG. Scenes read that log to
-- learn when the shell showed a result that another process presented.
local support = require "scenes.support"

local shell = {}

local Log = {}
Log.__index = Log

---Open the surface log for incremental reads.
function shell.log()
  local path = assert(os.getenv("ANVIL_SURFACE_LOG"), "shell scenes require ANVIL_SURFACE_LOG")
  return setmetatable({ path = path, offset = 0, pending = "", replaced = {} }, Log)
end

---Read new complete lines and collect the shell's frame-replacement times.
function Log:poll()
  local file = io.open(self.path, "rb")
  if not file then return end
  file:seek("set", self.offset)
  local text = file:read("*a") or ""
  file:close()
  self.offset = self.offset + #text
  text = self.pending .. text
  local last = 1
  for line, stop in text:gmatch("([^\n]*)\n()") do
    last = stop
    local ms = line:match("Shell replaced the previous Project's frame: Window=%d+ Project=%d+ after ([%d%.]+) ms")
    if ms then self.replaced[#self.replaced + 1] = tonumber(ms) end
  end
  self.pending = text:sub(last)
end

---Select the Project at `path` in this Window and wait until its frame replaces the previous one.
---Returns the shell's measured time from the selection to that frame, in milliseconds.
function shell.select_project(log, path, timeout)
  log:poll()
  local before = #log.replaced
  local started = system.get_time()
  assert(system.select_project(path), "the shell refused the Project selection: " .. path)
  support.wait_until(function()
    log:poll()
    return #log.replaced > before
  end, timeout or 15, "the selected Project did not present a frame: " .. path)
  return log.replaced[before + 1], started
end

return shell
