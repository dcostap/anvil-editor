-- mod-version:3
-- Seam: an owned native Window on a private desktop. Failed Projects keep a draggable Title Bar.
-- Native buttons show pointer feedback and cancel a dragged-out press. Empty Windows open Projects;
-- Sidebar recovery restores its process without taking drag space from the rest of the Title Bar.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "recovery" and action ~= "shell-empty" and action ~= "shell-sidebar" then return end
local core, common = require "core", require "core.common"
local ffi = require "ffi"
ffi.cdef [[
 unsigned long __stdcall GetCurrentProcessId(void);
 int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
 unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
 void * __stdcall GetPropW(void *, const wchar_t *);
 intptr_t __stdcall SendMessageW(void *, unsigned int, uintptr_t, intptr_t);
 unsigned int __stdcall GetDpiForWindow(void *);
 typedef struct { long x, y; } RecoveryPoint;
 int __stdcall ClientToScreen(void *, RecoveryPoint *);
 typedef struct { long left, top, right, bottom; } RecoveryRect;
 int __stdcall GetClientRect(void *, RecoveryRect *);
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
 local text = file:read("*a"); file:close()
 local chunk = loadstring(text)
 return chunk and chunk()
end
local function wait(fn, seconds, message)
 local deadline = system.get_time() + (seconds or 10)
 repeat local value = fn(); if value then return value end; coroutine.yield(.01) until system.get_time() >= deadline
 error(message or "Recovery probe timed out")
end
local function trace()
 local file = io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb")
 if not file then return "" end
 local text = file:read("*a"); file:close(); return text
end
local function shell_window(pid, except)
 local property = ffi.new("wchar_t[17]", {65,110,118,105,108,83,104,101,108,108,87,105,110,100,111,119,0})
 local found
 local cb = ffi.cast("int (__stdcall *)(void *, intptr_t)", function(window)
  local owner = ffi.new("unsigned long[1]"); user32.GetWindowThreadProcessId(window, owner)
  if tonumber(owner[0]) == pid and window ~= except and user32.GetPropW(window, property) ~= nil then found = window end
  return 1
 end)
 user32.EnumWindows(cb, 0); cb:free(); return found
end
local function point(x, y) return math.floor(x) % 65536 + (math.floor(y) % 65536) * 65536 end
local captures = 0
local function capture(window)
 captures = captures + 1
 user32.SendMessageW(window, 0x8052, captures, 0)
 local name = "capture-" .. captures .. ".bmp"
 wait(function() return trace():find(name, 1, true) end, 5, "No recovery capture")
 local file = assert(io.open(root .. "/" .. name, "rb"))
 local bytes = file:read("*a"); file:close(); return bytes
end
-- Compare feedback inside the button, not unrelated background or Sidebar redraws.
local function button_pixels(bytes, x, y)
 local width = bytes:byte(19) + bytes:byte(20) * 256 + bytes:byte(21) * 65536
 local rows = {}
 for row = math.floor(y - 8), math.floor(y + 8) do
  local start = 54 + (row * width + math.floor(x - 40)) * 4 + 1
  rows[#rows + 1] = bytes:sub(start, start + 80 * 4 - 1)
 end
 return table.concat(rows)
end
local function kill(pid)
 local handle = kernel.OpenProcess(0x1F0FFF, 0, pid)
 assert(handle ~= nil, "Cannot open the owned Project")
 assert(kernel.TerminateProcess(handle, 9) ~= 0); kernel.CloseHandle(handle)
end
local function quit() core.exit(function() core.quit_request = true end, true) end

if path:match("/driver$") then
 core.add_background_thread(function()
  local shell
  local ok, err = pcall(function()
   shell = assert(require("core.process").start({EXEFILE, "--shell", root .. "/Project"},
    {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
   local layout = wait(function() return load("layout") end, 30, "Project did not start")
   local window = wait(function() return shell_window(shell:pid()) end, 10)
   wait(function() return trace():find("Shell Sidebar surface Ready", 1, true) end, 30)
   local scale = user32.GetDpiForWindow(window) / 96
   local function input(step, pos)
    user32.SendMessageW(window, 0x804a, step, pos)
    coroutine.yield(.1)
   end
   local function hit(x, y)
    local p = ffi.new("RecoveryPoint", {math.floor(x), math.floor(y)})
    user32.ClientToScreen(window, p)
    return tonumber(user32.SendMessageW(window, 0x84, 0, point(p.x, p.y)))
   end
   if action == "shell-empty" or action == "shell-sidebar" then
    local x, y, target, marker
    if action == "shell-empty" then
     -- New Window takes Scratch. A second New Window takes it from Window 2, which stays open without a Project.
     user32.SendMessageW(window, 0x112, 0xe010, 0)
     wait(function()
      local scratch = trace():match("Shell selected loaded Project: id=(%d+) pid=%d+ path=[^\n]-\\user\\scratch")
      return scratch and trace():find("Shell Project runtime ready: Project=" .. scratch .. " ", 1, true)
     end, 30, "New Window did not start Scratch")
     user32.SendMessageW(window, 0x112, 0xe010, 0)
     wait(function() return trace():find("Shell keeps Window emptied by Move: id=2", 1, true) end, 10,
      "The shell did not keep an empty Window")
     local hex = assert(trace():match("Shell Window record: id=2 SDL=%d+ hwnd=(%x+)"))
     window = ffi.cast("void *", tonumber(hex, 16))
     wait(function() return trace():find("Shell Sidebar surface Ready: Window=2", 1, true) end, 15)
     local rect = ffi.new("RecoveryRect")
     assert(user32.GetClientRect(window, rect) ~= 0)
     x, y = (layout.content_x + rect.right) / 2, (layout.title_h + rect.bottom) / 2
     marker = "Shell Open Project picker started: Window=2"
     target = point(x, y)
     assert(hit(layout.content_x + 60 * scale, layout.title_h / 2) == 2, "The empty Title Bar blocks dragging")
    else
     local function sidebar_pid()
      local pid
      for value in trace():gmatch("Shell Sidebar connected: pid=(%d+)") do pid = tonumber(value) end
      return pid
     end
     for _ = 1, 8 do
      local pid, mark = assert(sidebar_pid()), #trace()
      kill(pid)
      local state = wait(function()
       local text = trace():sub(mark + 1)
       if text:find("automatic restart limit reached", 1, true) then return "stopped" end
       if sidebar_pid() ~= pid and text:find("Shell Sidebar surface Ready", 1, true) then return "ready" end
      end, 15, "Sidebar neither recovered nor offered Restart")
      if state == "stopped" then break end
     end
     assert(trace():find("automatic restart limit reached", 1, true), "Sidebar recovery did not stop")
     x, y = layout.content_x / 2, layout.title_h / 2
     target, marker = point(x, y), "Shell native control: 5"
     assert(hit(x, y) == 1, "Restart Sidebar is a window drag target")
     assert(hit(12 * scale, y) == 2, "Restart Sidebar took the surrounding Title Bar's drag space")
    end
    local away = point(layout.content_x + 60 * scale, layout.title_h + 100 * scale)
    local function pixels(bytes) return button_pixels(bytes, x, y) end
    input(0, away)
    local idle = pixels(capture(window))
    input(0, target)
    local hover = pixels(capture(window))
    assert(hover ~= idle, action .. " button has no hover feedback")
    input(1, target)
    assert(pixels(capture(window)) ~= hover, action .. " button has no press feedback")
    local mark = #trace()
    input(0, away); input(2, away)
    assert(not trace():find(marker, mark + 1, true), "A dragged-out release performed the action")
    input(0, target); input(1, target); input(2, target)
    wait(function() return trace():find(marker, mark + 1, true) end, 5, "The button did not perform its action")
    if action == "shell-empty" then
     local service = ffi.cast("void *", tonumber(assert(trace():match("Shell service notifications hwnd=(%x+)")), 16))
     user32.SendMessageW(service, 0x8050, 3, 2)
     wait(function() return trace():find("Shell Open Project picker cancelled: Window=2", 1, true) end, 5)
     input(0, target); input(1, target); input(2, target)
     user32.SendMessageW(service, 0x8050, 1, 2)
     local loaded = wait(function() return load("replacement") end, 15, "Open Project did not load the chosen folder")
     assert(loaded.window_id == 2, "Open Project used another Window")
    else
     wait(function() return trace():find("Shell Sidebar surface Ready", mark + 1, true) end, 15,
      "Restart Sidebar did not restore the Sidebar")
    end
    capture(window)
    return
   end
   local function fail(pid)
    local mark = #trace()
    kill(pid)
    wait(function() return trace():find("Shell state: Failed Project=1", mark, true) end, 10, "No recovery view")
    coroutine.yield(.2)
   end
   fail(layout.pid)
   local cx, cy = (layout.content_x + layout.width) / 2, (layout.title_h + layout.height) / 2
   local restart, unload = point(cx - 80 * scale, cy + 54 * scale), point(cx + 80 * scale, cy + 54 * scale)
   local outside = point(cx, cy + 160 * scale)
   local function restart_pixels(bytes) return button_pixels(bytes, cx - 80 * scale, cy + 54 * scale) end
   local function unload_pixels(bytes) return button_pixels(bytes, cx + 80 * scale, cy + 54 * scale) end
   input(0, outside)
   local idle = capture(window)
   input(0, restart)
   local hover = capture(window)
   assert(restart_pixels(hover) ~= restart_pixels(idle), "Restart Project has no hover feedback")
   input(0, outside)
   assert(restart_pixels(capture(window)) == restart_pixels(idle), "The recovery button was not drawn before the first hover")
   input(0, restart)
   input(1, restart)
   local pressed = capture(window)
   assert(restart_pixels(pressed) ~= restart_pixels(hover), "Restart Project has no press feedback")
   local sidebar = point(40 * scale, layout.height - 80 * scale)
   input(0, sidebar)
   input(2, sidebar)
   assert(not trace():find("Shell native control: 3", 1, true), "A dragged-out release restarted the Project")
   input(0, outside)
   idle = capture(window)
   input(0, unload)
   assert(unload_pixels(capture(window)) ~= unload_pixels(idle), "Unload Project has no hover feedback")
   for x = layout.content_x + 40 * scale, layout.controls_x - 20 * scale, 50 * scale do
    assert(hit(x, layout.title_h / 2) == 2, "The failed Project's empty Title Bar blocks window dragging")
   end
   assert(hit(layout.controls_x + 10 * scale, layout.title_h / 2) == 1, "Window controls became draggable")
   input(0, restart); input(1, restart); input(2, restart)
   local replacement = wait(function()
    local next = load("layout"); return next and next.pid ~= layout.pid and next
   end, 15, "Restart Project did not restart")
   fail(replacement.pid)
   input(0, unload); input(1, unload); input(2, unload)
   wait(function() return trace():find("Shell Project is Dormant", 1, true) end, 10, "Unload Project did not unload")
   capture(window)
  end)
  local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
  file:write("return ", common.serialize{ok=ok, error=not ok and tostring(err) or nil, action=action}); file:close()
  if shell and shell:running() then shell:terminate(); shell:wait(2) end
  quit()
 end)
elseif path == root .. "/Project" or path == root .. "/Replacement" then
 core.add_background_thread(function()
  coroutine.yield(.5)
  local width, height = core.window:get_size()
  local controls_x, _, _, title_h = system.get_window_controls()
  save(path == root .. "/Project" and "layout" or "replacement",
   {pid=tonumber(kernel.GetCurrentProcessId()), width=width, height=height,
    content_x=system.get_window_content_x(), controls_x=controls_x, title_h=title_h,
    window_id=system.get_anvil_window_id()})
 end)
end
