-- mod-version:3
-- Seam: an owned shell Window with two loaded Projects and the Sidebar. The Color Theme is one saved setting:
-- the Sidebar starts with it, and a theme saved in one Project reaches the other Project and the Sidebar. The
-- software renderer keeps the Sidebar opaque, so its empty area shows the theme's exact background2 colour.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "theme-global" then return end
local core, common = require "core", require "core.common"
local style = require "core.style"
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
 error(message or "Color Theme probe timed out")
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
local function rgb(color) return {color[1], color[2], color[3]} end
local captures = 0
-- The colour of the Sidebar's empty bottom-left area in the shell's next composed frame.
local function sidebar_color(window)
 captures = captures + 1
 user32.SendMessageW(window, 0x8052, captures, 0)
 local name = "capture-" .. captures .. ".bmp"
 wait(function() return trace():find(name, 1, true) end, 5, "shell capture " .. captures .. " was not written")
 local file = assert(io.open(root .. "/" .. name, "rb"))
 local data = file:read("*a"); file:close()
 local function int32(offset)
  local value = data:byte(offset + 1) + data:byte(offset + 2) * 256 + data:byte(offset + 3) * 65536
   + data:byte(offset + 4) * 16777216
  return value >= 2147483648 and value - 4294967296 or value
 end
 local width, height = int32(18), math.abs(int32(22))
 -- Top-down BGRA rows follow the 54-byte headers.
 local offset = 54 + ((height - 8) * width + 8) * 4
 return {data:byte(offset + 3), data:byte(offset + 2), data:byte(offset + 1)}
end
local function same(a, b) return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] end
local function show(color) return string.format("#%02x%02x%02x", color[1], color[2], color[3]) end
local function quit() core.exit(function() core.quit_request = true end, true) end
local function ready(name)
 save(name, {pid = tonumber(kernel.GetCurrentProcessId()), background2 = rgb(style.background2)})
end

if path:match("/driver$") then
 core.add_background_thread(function()
  local shell
  local ok, err = pcall(function()
   local process = require "core.process"
   shell = assert(process.start({EXEFILE, "--shell", root .. "/Project"},
    {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
   local a = wait(function() return load("a-ready") end, 30, "Project A did not start")
   wait(function() return trace():find("Shell Sidebar surface Ready", 1, true) end, 15, "Sidebar did not become Ready")
   local window = wait(function() return shell_window(shell:pid()) end, 10, "shell Window not found")
   coroutine.yield(1)
   local started = sidebar_color(window)
   assert(same(started, a.background2), "the Sidebar started with " .. show(started)
    .. ", not the saved Color Theme's " .. show(a.background2))
   save("select-b", {go = true})
   wait(function() return load("b-ready") end, 30, "Project B did not start")
   save("b-theme", {go = true})
   local applied = wait(function() return load("b-applied") end, 10, "Project B did not apply the Color Theme")
   assert(not same(applied.background2, a.background2), "the probe's two Color Themes share background2")
   local other = wait(function() return load("a-theme") end, 10, "Project A kept the old Color Theme")
   assert(other.theme == "dark", "Project A's settings kept " .. tostring(other.theme))
   assert(same(other.background2, applied.background2), "Project A drew another Color Theme")
   local color
   wait(function()
    color = sidebar_color(window)
    return same(color, applied.background2)
   end, 5, "the Sidebar kept the old Color Theme")
  end)
  local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
  file:write("return ", common.serialize{ok=ok, error=ok and nil or tostring(err), action=action})
  file:close()
  if shell and shell:running() then shell:terminate(); shell:wait(1) end
  for _, name in ipairs {"a-ready", "b-ready"} do
   local state = load(name)
   local handle = state and kernel.OpenProcess(0x1F0FFF, 0, state.pid)
   if handle ~= nil and handle then kernel.TerminateProcess(handle, 9); kernel.CloseHandle(handle) end
  end
  quit()
 end)
elseif path:match("/Project$") then
 core.add_background_thread(function()
  coroutine.yield(.5)
  ready("a-ready")
  wait(function() return load("select-b") end, 60)
  assert(core.open_project_in_same_window(root .. "/Replacement"))
  wait(function() return core.color_theme_module == "colors.default" end, 60)
  save("a-theme", {theme = require("plugins.settings").config.theme, background2 = rgb(style.background2)})
 end)
elseif path:match("/Replacement$") then
 core.add_background_thread(function()
  coroutine.yield(.5)
  ready("b-ready")
  wait(function() return load("b-theme") end, 60)
  require("plugins.settings").apply_color_theme("dark")
  save("b-applied", {background2 = rgb(style.background2)})
 end)
end
