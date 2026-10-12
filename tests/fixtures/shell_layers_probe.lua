-- mod-version:3
-- Seam: an owned hosted Window on a private desktop. The Project surface spans the Window and lays out its UI
-- right of the Sidebar, the Sidebar is blended over the Project's backdrop where the renderer allows it, and a
-- modal overlay dim reaches the shell so it can cover the Sidebar too.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "layers" then return end
local core, common = require "core", require "core.common"
local ffi = require "ffi"
ffi.cdef [[
 unsigned long __stdcall GetCurrentProcessId(void);
 int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
 unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
 void * __stdcall GetPropW(void *, const wchar_t *);
 intptr_t __stdcall SendMessageW(void *, unsigned int, uintptr_t, intptr_t);
 void * __stdcall OpenProcess(unsigned long, int, unsigned long);
 int __stdcall TerminateProcess(void *, unsigned int);
 int __stdcall CloseHandle(void *);
]]
local user32, kernel = ffi.load("user32"), ffi.load("kernel32")
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
 error(message or "shell layers probe timed out")
end
local function trace()
 local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
 local text = file:read("*a"); file:close(); return text
end
local function shell_window(pid)
 local property = ffi.new("wchar_t[17]", {65,110,118,105,108,83,104,101,108,108,87,105,110,100,111,119,0})
 local found
 local cb = ffi.cast("int (__stdcall *)(void *, intptr_t)", function(window)
  local owner = ffi.new("unsigned long[1]"); user32.GetWindowThreadProcessId(window, owner)
  if tonumber(owner[0]) == pid and user32.GetPropW(window, property) ~= nil then found = window end
  return 1
 end)
 user32.EnumWindows(cb, 0); cb:free(); return found
end
-- Saves the shell's next composed frame beside the result, for visual review.
local function capture(window, index)
 user32.SendMessageW(window, 0x8052, index, 0)
 wait(function() return trace():find("capture%-" .. index .. "%.bmp") end, 5,
  "shell capture " .. index .. " was not written")
end
local function quit() core.exit(function() core.quit_request = true end, true) end

if path:match("/driver$") then
 core.add_background_thread(function()
  local shell
  local ok, err = pcall(function()
   shell = assert(require("core.process").start({EXEFILE, "--shell", root .. "/Project"},
    {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
   local layout = wait(function() return load("layout") end, 30, "Project did not report its layout")
   assert(layout.content_x > 0, "the Project surface does not reserve the Sidebar")
   assert(layout.root_x == layout.content_x, "the Project UI does not start at the Sidebar edge")
   assert(layout.root_x + layout.root_w == layout.window_w, "the Project UI does not reach the Window's right edge")
   wait(function() return trace():find("Shell Sidebar surface Ready", 1, true) end, 15, "Sidebar did not become Ready")
   if os.getenv("ANVIL_RENDERER") ~= "software" then
    wait(function() return trace():find("Shell Sidebar layer: Window=%d+ transparent=1") end, 10,
     "the D3D11 Sidebar was not blended")
   end
   local window = wait(function() return shell_window(shell:pid()) end, 10, "shell Window not found")
   coroutine.yield(1)
   capture(window, 1)
   save("overlay-go", {go=true})
   wait(function() return trace():find("Shell Window overlay: id=%d+ shown=1") end, 10,
    "the Project overlay did not reach the shell")
   coroutine.yield(1)
   capture(window, 2)
   save("overlay-hide", {go=true})
   wait(function() return trace():find("Shell Window overlay: id=%d+ shown=0") end, 10,
    "the shell kept the Project overlay after it closed")
  end)
  local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
  file:write("return ", common.serialize{ok=ok, error=ok and nil or tostring(err), action=action})
  file:close()
  if shell and shell:running() then shell:terminate(); shell:wait(1) end
  local layout = load("layout")
  if layout then
   local handle = kernel.OpenProcess(0x1F0FFF, 0, layout.pid)
   if handle ~= nil then kernel.TerminateProcess(handle, 9); kernel.CloseHandle(handle) end
  end
  quit()
 end)
elseif path == root .. "/Project" then
 core.add_background_thread(function()
  coroutine.yield(.5)
  local width = core.window:get_size()
  save("layout", {pid=tonumber(kernel.GetCurrentProcessId()), content_x=system.get_window_content_x(),
   root_x=core.root_panel.position.x, root_w=core.root_panel.size.x, window_w=width})
  wait(function() return load("overlay-go") end, 30)
  local owner = {}
  core.root_panel:show_app_overlay(owner, "nagbar_dim")
  wait(function() return load("overlay-hide") end, 30)
  core.root_panel:hide_app_overlay(owner)
 end)
end
