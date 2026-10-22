-- mod-version:3
-- Seam: an owned shell Window with two loaded Projects. The Zoom is one saved setting: a Project that starts
-- after a Zoom change starts at that Zoom, and a Zoom change in one Project reaches the other Project.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "zoom-global" then return end
local core, common = require "core", require "core.common"
local ffi = require "ffi"
ffi.cdef [[
 unsigned long __stdcall GetCurrentProcessId(void);
 void * __stdcall OpenProcess(unsigned long, int, unsigned long);
 int __stdcall TerminateProcess(void *, unsigned int);
 int __stdcall CloseHandle(void *);
]]
local kernel = ffi.load("kernel32")
local root = assert(os.getenv("ANVIL_PROJECT_PROBE_ROOT"))
local path = core.root_project().path:gsub("\\", "/")
local function save(name, value)
 local file = assert(io.open(root .. "/" .. name .. ".lua", "wb"))
 file:write("return ", common.serialize(value)); file:close()
end
local function load(name)
 local file = io.open(root .. "/" .. name .. ".lua", "rb")
 if not file then return end
 local text = file:read("*a"); file:close(); return assert(loadstring(text))()
end
local function wait(fn, seconds, message)
 local deadline = system.get_time() + (seconds or 10)
 repeat local value = fn(); if value then return value end; coroutine.yield(.01) until system.get_time() >= deadline
 error(message or "Zoom probe timed out")
end
-- The Zoom as ratios over this process's display scale.
local function zoom()
 local scale = require "plugins.scale"
 return {pid = tonumber(kernel.GetCurrentProcessId()), interface = scale.get() / DEFAULT_SCALE,
  code = scale.get_code() / DEFAULT_SCALE}
end
local function same(a, b) return math.abs(a.interface - b.interface) < 1e-6 and math.abs(a.code - b.code) < 1e-6 end
local function show(state) return string.format("interface=%.4f code=%.4f", state.interface, state.code) end

if path:match("/driver$") then
 core.add_background_thread(function()
  local shell
  local ok, err = pcall(function()
   local process = require "core.process"
   shell = assert(process.start({EXEFILE, "--shell", root .. "/Project"},
    {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
   local a = wait(function() return load("a-zoomed") end, 30, "Project A did not start and zoom")
   save("select-b", {go = true})
   local b = wait(function() return load("b-ready") end, 30, "Project B did not start")
   assert(same(b, a), "Project B started at " .. show(b) .. ", not the saved " .. show(a))
   save("b-zoom", {go = true})
   b = wait(function() return load("b-zoomed") end, 10, "Project B did not zoom")
   local other = wait(function() return load("a-changed") end, 10, "Project A kept its old Zoom")
   assert(same(other, b), "Project A applied " .. show(other) .. ", not Project B's " .. show(b))
  end)
  local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
  file:write("return ", common.serialize{ok=ok, error=ok and nil or tostring(err), action=action})
  file:close()
  if shell and shell:running() then shell:terminate(); shell:wait(1) end
  for _, name in ipairs {"a-zoomed", "b-ready"} do
   local state = load(name)
   local handle = state and kernel.OpenProcess(0x1F0FFF, 0, state.pid)
   if handle ~= nil and handle then kernel.TerminateProcess(handle, 9); kernel.CloseHandle(handle) end
  end
  core.exit(function() core.quit_request = true end, true)
 end)
elseif path:match("/Project$") then
 core.add_background_thread(function()
  coroutine.yield(.5)
  require("plugins.scale").increase()
  local zoomed = zoom()
  save("a-zoomed", zoomed)
  wait(function() return load("select-b") end, 60)
  assert(core.open_project_in_same_window(root .. "/Replacement"))
  wait(function() return not same(zoom(), zoomed) end, 60)
  save("a-changed", zoom())
 end)
elseif path:match("/Replacement$") then
 core.add_background_thread(function()
  coroutine.yield(.5)
  save("b-ready", zoom())
  wait(function() return load("b-zoom") end, 60)
  require("plugins.scale").increase()
  save("b-zoomed", zoom())
 end)
end
