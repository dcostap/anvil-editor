-- mod-version:3
-- Seam: an owned shell Window with two loaded Projects and the Sidebar. The Zoom is one saved setting: a Project
-- that starts after a Zoom change starts at that Zoom, and a Zoom change in one Project reaches the other Project
-- and the Sidebar. A fast burst of Zoom steps, as from a mouse wheel, ends at the last step in every process, and
-- the Sidebar keeps running. The Sidebar reports each scale that it draws at in its session log.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "zoom-global" then return end
local core, common = require "core", require "core.common"
local ffi = require "ffi"
ffi.cdef [[
 unsigned long __stdcall GetCurrentProcessId(void);
 void * __stdcall OpenProcess(unsigned long, int, unsigned long);
 int __stdcall TerminateProcess(void *, unsigned int);
 int __stdcall CloseHandle(void *);
 int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
 unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
 void * __stdcall GetPropW(void *, const wchar_t *);
 int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
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
local function trace()
 local file = io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb")
 if not file then return "" end
 local text = file:read("*a"); file:close(); return text
end

if path:match("/driver$") then
 local user32 = ffi.load("user32")
 local function shell_window(pid)
  local property = ffi.new("wchar_t[17]", {65,110,118,105,108,83,104,101,108,108,87,105,110,100,111,119,0})
  local found
  local cb = ffi.cast("int (__stdcall *)(void *, intptr_t)", function(window)
   local owner = ffi.new("unsigned long[1]")
   user32.GetWindowThreadProcessId(window, owner)
   if tonumber(owner[0]) == pid and user32.GetPropW(window, property) ~= nil then found = window end
   return 1
  end)
  user32.EnumWindows(cb, 0); cb:free(); return found
 end
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
   local window = wait(function() return shell_window(shell:pid()) end, 30, "Shell Window missing")
   -- Exercise the shell's wheel routing, first with Project focus, then with Sidebar focus.
   local control = 0x400000e0 -- SDL's left Control key.
   user32.PostMessageW(window, 0x804a, 9, control)
   user32.PostMessageW(window, 0x804a, 3, 40 + 100 * 65536)
   wait(function() return load("wheel-1-done") end, 15, "Ctrl-wheel over the Sidebar did not zoom")
   local mark = #trace() + 1
   save("focus-sidebar", true)
   wait(function() return trace():find("Shell Sidebar focus: Window=%d+ focused=1", mark) end,
    15, "Sidebar did not take focus")
   user32.PostMessageW(window, 0x804a, 3, 40 + 100 * 65536)
   wait(function() return load("wheel-2-done") end, 15, "Ctrl-wheel with Sidebar focus did not zoom")
   assert(not trace():find("Shell Sidebar focus: Window=%d+ focused=0", mark), "Zoom moved keyboard focus")
   user32.PostMessageW(window, 0x804a, 10, control)
   save("b-zoom", {go = true})
   b = wait(function() return load("b-zoomed") end, 10, "Project B did not zoom")
   local other = wait(function() return load("a-changed") end, 10, "Project A kept its old Zoom")
   assert(same(other, b), "Project A applied " .. show(other) .. ", not Project B's " .. show(b))
   local expected = DEFAULT_SCALE * b.interface
   wait(function()
    for _, name in ipairs(system.list_dir(USERDIR .. "/logs") or {}) do
     local file = io.open(USERDIR .. "/logs/" .. name, "rb")
     local text = file and file:read("*a") or ""
     if file then file:close() end
     for scale in text:gmatch("Sidebar scale: Window=%d+ scale=([%d%.]+)") do
      if math.abs(tonumber(scale) - expected) < 1e-3 then return true end
     end
    end
   end, 10, string.format("the Sidebar did not draw at scale %.4f", expected))
   assert(not trace():find("Shell Sidebar automatic restart", 1, true), "the Sidebar stopped during the Zoom burst")
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
  local b = wait(function() return load("b-zoomed") end, 60)
  wait(function() return same(zoom(), b) end, 10)
  save("a-changed", zoom())
 end)
elseif path:match("/Replacement$") then
 core.add_background_thread(function()
  coroutine.yield(.5)
  save("b-ready", zoom())
  local before = zoom()
  wait(function() return zoom().interface < before.interface end, 60, "First Sidebar wheel missing")
  assert(zoom().code < before.code, "Sidebar wheel left text Zoom unchanged")
  save("wheel-1-done", zoom())
  wait(function() return load("focus-sidebar") end, 60)
  assert(require("core.command").perform("core:focus_project_sidebar"))
  before = zoom()
  wait(function() return zoom().interface < before.interface end, 60, "Second Sidebar wheel missing")
  assert(zoom().code < before.code, "Focused Sidebar wheel left text Zoom unchanged")
  save("wheel-2-done", zoom())
  wait(function() return load("b-zoom") end, 60)
  local scale = require "plugins.scale"
  for _ = 1, 20 do scale.increase() end
  for _ = 1, 10 do scale.decrease() end
  save("b-zoomed", zoom())
 end)
end
