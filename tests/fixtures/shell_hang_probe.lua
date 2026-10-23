-- mod-version:3
-- Seam: an owned hosted Window on a private desktop. The Project shows a modal overlay, which normally sends
-- clicks on the dimmed Sidebar to the Project. When the Project stops answering, the Sidebar takes clicks
-- again and the Window says the Project is not responding. When the Project answers again, its overlay
-- covers the Sidebar again.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "hang-overlay" then return end
local core, common = require "core", require "core.common"
local ffi = require "ffi"
ffi.cdef [[
 unsigned long __stdcall GetCurrentProcessId(void);
 int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
 unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
 void * __stdcall GetPropW(void *, const wchar_t *);
 intptr_t __stdcall SendMessageW(void *, unsigned int, uintptr_t, intptr_t);
 int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
 unsigned int __stdcall GetDpiForWindow(void *);
 void * __stdcall OpenProcess(unsigned long, int, unsigned long);
 int __stdcall TerminateProcess(void *, unsigned int);
 int __stdcall CloseHandle(void *);
 long __stdcall NtSuspendProcess(void *);
 long __stdcall NtResumeProcess(void *);
]]
local user32, kernel, ntdll = ffi.load("user32"), ffi.load("kernel32"), ffi.load("ntdll")
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
 error(message or "shell hang probe timed out")
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
local function project_row(window)
 local scale = user32.GetDpiForWindow(window) / 96
 return math.floor(40 * scale) + math.floor(54 * scale) * 65536
end
-- Clicks the Project's Sidebar row and reports whether the Sidebar drew a frame for that input.
-- The row belongs to the Selected Project, so the click collapses or expands it.
local function click_project(window)
 local _, before = trace():gsub("Shell Sidebar input frame:", "")
 -- The shell's routing probe message: posted Win32 clicks are ignored on an inactive desktop.
 for step = 0, 2 do user32.PostMessageW(window, 0x804a, step, project_row(window)); coroutine.yield(.1) end
 local deadline = system.get_time() + 3
 repeat
  coroutine.yield(.05)
  local _, after = trace():gsub("Shell Sidebar input frame:", "")
  if after > before then return true end
 until system.get_time() >= deadline
 return false
end
local function quit() core.exit(function() core.quit_request = true end, true) end

if path:match("/driver$") then
 core.add_background_thread(function()
  local shell, suspended
  local ok, err = pcall(function()
   shell = assert(require("core.process").start({EXEFILE, "--shell", root .. "/Project"},
    {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
   local layout = wait(function() return load("layout") end, 30, "Project did not report its layout")
   wait(function() return trace():find("Shell Sidebar surface Ready", 1, true) end, 15, "Sidebar did not become Ready")
   local window = wait(function() return shell_window(shell:pid()) end, 10, "shell Window not found")
   coroutine.yield(1)
   assert(click_project(window), "a Sidebar click did not reach the Sidebar")
   save("overlay-go", {go=true})
   wait(function() return trace():find("Shell Window overlay: id=%d+ shown=1") end, 10,
    "the Project overlay did not reach the shell")
   assert(not click_project(window), "the Sidebar took a click under the Project's modal overlay")
   wait(function() return load("outside-click") end, 5, "the Project did not receive the click on the dimmed Sidebar")

   suspended = kernel.OpenProcess(0x800, 0, layout.pid)
   assert(suspended ~= nil and ntdll.NtSuspendProcess(suspended) == 0, "could not suspend the Project")
   -- This click goes to the Project, which no longer answers.
   for step = 0, 2 do user32.PostMessageW(window, 0x804a, step, project_row(window)); coroutine.yield(.1) end
   wait(function() return trace():find("Shell Project not responding: id=%d+") end, 6,
    "the shell did not notice that the Project stopped answering")
   assert(user32.SendMessageW(window, 0x804d, 3, 0) ~= 0, "the Window does not say the Project is not responding")
   assert(click_project(window), "the Sidebar did not take a click while the Project was not responding")

   local mark = #trace()
   assert(ntdll.NtResumeProcess(suspended) == 0, "could not resume the Project")
   kernel.CloseHandle(suspended); suspended = nil
   wait(function() return trace():find("Shell Project responding again: id=%d+", mark) end, 6,
    "the shell did not notice that the Project answers again")
   assert(not click_project(window), "the Sidebar took a click under the overlay after the Project recovered")
  end)
  if suspended then ntdll.NtResumeProcess(suspended); kernel.CloseHandle(suspended) end
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
 local on_event = core.on_event
 core.on_event = function(kind, button, x, ...)
  if kind == "mousepressed" and core.root_panel.app_overlay and x < system.get_window_content_x() then
   save("outside-click", {x=x})
  end
  return on_event(kind, button, x, ...)
 end
 core.add_background_thread(function()
  coroutine.yield(.5)
  save("layout", {pid=tonumber(kernel.GetCurrentProcessId())})
  wait(function() return load("overlay-go") end, 30)
  core.root_panel:show_app_overlay({}, "nagbar_dim")
 end)
end
