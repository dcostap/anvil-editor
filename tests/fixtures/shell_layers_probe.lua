-- mod-version:3
-- Seam: an owned hosted Window on a private desktop. The Project surface spans the Window and lays out its UI
-- right of the Sidebar, the Sidebar is blended over the Project's backdrop where the renderer allows it, and a
-- modal overlay dim reaches the shell so it can cover the Sidebar too. A click on the covered Sidebar goes to the
-- Project, whose modal UI decides what an outside click does. Sidebar hover appears without waiting for a later
-- event.
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
 int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
 unsigned int __stdcall GetDpiForWindow(void *);
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
-- Clicks the Sidebar's Refresh button and reports whether the shell started a status scan.
local function click_refresh(window, layout)
 local scale = user32.GetDpiForWindow(window) / 96
 local point = math.floor(layout.content_x - 6 * scale) + math.floor(46 * scale) * 65536
 local _, before = trace():gsub("Shell Sidebar status scan started", "")
 -- The shell's routing probe message: posted Win32 clicks are ignored on an inactive desktop.
 for action = 0, 2 do user32.PostMessageW(window, 0x804a, action, point); coroutine.yield(.1) end
 local deadline = system.get_time() + 3
 repeat
  coroutine.yield(.05)
  local _, after = trace():gsub("Shell Sidebar status scan started", "")
  if after > before then return true end
 until system.get_time() >= deadline
 return false
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
   assert(layout.tabs_right <= layout.controls_x, "the Title Bar's tabs reach " .. layout.tabs_right
    .. ", under the Window controls at " .. layout.controls_x)
   wait(function() return trace():find("Shell Sidebar surface Ready", 1, true) end, 15, "Sidebar did not become Ready")
   if os.getenv("ANVIL_RENDERER") ~= "software" then
    wait(function() return trace():find("Shell Sidebar layer: Window=%d+ transparent=1") end, 10,
     "the D3D11 Sidebar was not blended")
   end
   local window = wait(function() return shell_window(shell:pid()) end, 10, "shell Window not found")
   coroutine.yield(1)
   capture(window, 1)
   assert(click_refresh(window, layout), "a Sidebar click did not reach the Sidebar")
   -- Hover alternates between the Project row and empty space; each change draws one Sidebar frame.
   local scale = user32.GetDpiForWindow(window) / 96
   local mark = #trace()
   for i = 1, 20 do
    local y = math.floor((i % 2 == 0 and 88 or 400) * scale)
    user32.PostMessageW(window, 0x804a, 0, 100 + y * 65536); coroutine.yield(.1)
   end
   local latencies = {}
   for ms in trace():sub(mark + 1):gmatch("Shell Sidebar input frame: input_to_frame_ms=([%d%.]+)") do
    latencies[#latencies + 1] = tonumber(ms)
   end
   table.sort(latencies)
   assert(#latencies >= 15, "Sidebar hover produced too few frames: " .. #latencies)
   local median = latencies[math.ceil(#latencies / 2)]
   assert(median < 30, string.format("Sidebar hover waited %.1f ms for its frame (median)", median))
   save("overlay-go", {go=true})
   wait(function() return trace():find("Shell Window overlay: id=%d+ shown=1") end, 10,
    "the Project overlay did not reach the shell")
   coroutine.yield(1)
   capture(window, 2)
   assert(not click_refresh(window, layout), "the Sidebar took a click under the Project's modal overlay")
   wait(function() return load("outside-click") end, 5, "the Project did not receive the click on the dimmed Sidebar")
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
 local on_event = core.on_event
 core.on_event = function(kind, button, x, ...)
  if kind == "mousepressed" and core.root_panel.app_overlay and x < system.get_window_content_x() then
   save("outside-click", {x=x})
  end
  return on_event(kind, button, x, ...)
 end
 core.add_background_thread(function()
  coroutine.yield(.5)
  local width = core.window:get_size()
  local lane, controls_x = core.title_bar.tab_lane, system.get_window_controls()
  save("layout", {pid=tonumber(kernel.GetCurrentProcessId()), content_x=system.get_window_content_x(),
   root_x=core.root_panel.position.x, root_w=core.root_panel.size.x, window_w=width,
   tabs_right=lane.x + lane.w, controls_x=controls_x})
  wait(function() return load("overlay-go") end, 30)
  local owner = {}
  core.root_panel:show_app_overlay(owner, "nagbar_dim")
  wait(function() return load("overlay-hide") end, 30)
  core.root_panel:hide_app_overlay(owner)
 end)
end
