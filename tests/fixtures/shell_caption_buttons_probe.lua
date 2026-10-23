-- mod-version:3
-- Seam: an owned shell Window on a private desktop. Windows 11 shows Snap Layouts only over a button that its hit
-- test reports as Maximize. A click there still reaches the shell's own button, which maximizes and restores.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "maximize-button" then return end
local core, common = require "core", require "core.common"
local ffi = require "ffi"
ffi.cdef [[
 typedef struct { long x, y; } ProbePoint;
 unsigned long __stdcall GetCurrentProcessId(void);
 int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
 unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
 void * __stdcall GetPropW(void *, const wchar_t *);
 intptr_t __stdcall SendMessageW(void *, unsigned int, uintptr_t, intptr_t);
 int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
 int __stdcall ClientToScreen(void *, ProbePoint *);
 int __stdcall IsZoomed(void *);
 void * __stdcall OpenProcess(unsigned long, int, unsigned long);
 int __stdcall TerminateProcess(void *, unsigned int);
 int __stdcall CloseHandle(void *);
]]
local user32, kernel = ffi.load("user32"), ffi.load("kernel32")
local root = assert(os.getenv("ANVIL_PROJECT_PROBE_ROOT"))
local path = core.root_project().path:gsub("\\", "/")
local WM_NCHITTEST, WM_NCLBUTTONDOWN, WM_LBUTTONUP, HTMAXBUTTON = 0x84, 0xA1, 0x202, 9
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
 error(message or "caption button probe timed out")
end
local function trace()
 local file = io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb")
 if not file then return "" end
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
local function pack(x, y) return bit.bor(bit.band(x, 0xffff), bit.lshift(bit.band(y, 0xffff), 16)) end
local function quit() core.exit(function() core.quit_request = true end, true) end
-- The centre of the Maximize button, from the shell's latest controls record, in client coordinates.
local function maximize_center()
 local x, w, h
 for cx, cw, ch in trace():gmatch("Shell controls: x=(%d+) y=%d+ w=(%d+) h=(%d+)") do
  x, w, h = tonumber(cx), tonumber(cw), tonumber(ch)
 end
 assert(x, "the shell did not report its Window controls")
 local width = math.floor(w / 3)
 return x + width + math.floor(width / 2), math.floor(h / 2)
end
-- Windows asks the hit test where the pointer is, then sends the press as a non-client message.
local function click_maximize(window)
 local x, y = maximize_center()
 local point = ffi.new("ProbePoint", {x, y})
 user32.ClientToScreen(window, point)
 local screen = pack(tonumber(point.x), tonumber(point.y))
 local hit = tonumber(user32.SendMessageW(window, WM_NCHITTEST, 0, screen))
 assert(hit == HTMAXBUTTON, "the Maximize button hit test returned " .. hit .. ", not HTMAXBUTTON")
 user32.PostMessageW(window, WM_NCLBUTTONDOWN, HTMAXBUTTON, screen)
 user32.PostMessageW(window, WM_LBUTTONUP, 0, pack(x, y))
end

if path:match("/driver$") then
 core.add_background_thread(function()
  local shell
  local ok, err = pcall(function()
   local process = require "core.process"
   shell = assert(process.start({EXEFILE, "--shell", root .. "/Project"},
    {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
   wait(function() return load("a-ready") end, 30, "the Project did not start")
   local window = wait(function() return shell_window(shell:pid()) end, 10, "shell Window not found")
   coroutine.yield(.5)
   local zoomed = user32.IsZoomed(window) ~= 0
   click_maximize(window)
   wait(function() return (user32.IsZoomed(window) ~= 0) ~= zoomed end, 10,
    "a click on the Maximize button did not change the Window size")
   coroutine.yield(.5)
   click_maximize(window)
   wait(function() return (user32.IsZoomed(window) ~= 0) == zoomed end, 10,
    "a second click on the Maximize button did not restore the Window size")
  end)
  local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
  file:write("return ", common.serialize{ok=ok, error=ok and nil or tostring(err), action=action})
  file:close()
  if shell and shell:running() then shell:terminate(); shell:wait(1) end
  local state = load("a-ready")
  local handle = state and kernel.OpenProcess(0x1F0FFF, 0, state.pid)
  if handle ~= nil and handle then kernel.TerminateProcess(handle, 9); kernel.CloseHandle(handle) end
  quit()
 end)
elseif path:match("/Project$") then
 core.add_background_thread(function()
  coroutine.yield(.5)
  save("a-ready", {pid = tonumber(kernel.GetCurrentProcessId())})
 end)
end
