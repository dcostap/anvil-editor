-- mod-version:3
-- Seam: an owned shell Window with two loaded Projects and the Sidebar. The Color Theme is one saved setting:
-- the Sidebar starts with it, and a theme saved in one Project reaches the other Project and the Sidebar. The
-- software renderer keeps the Sidebar opaque, so its empty area shows the theme's exact background2 colour.
-- The shell's Window controls draw in the selected Project's Color Theme: its text colour, and its pressed colour.
-- A posted mouse move hovers only until the real cursor's leave event, so a held press shows the fill instead.
-- theme-empty: a shell Window with no Project draws its Project area and Window controls in the saved Color Theme.
-- reveal: a starting shell first shows its Window with the loaded Project, Sidebar and Color Theme, so its first
-- visible frame already looks like the settled frame.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "theme-global" and action ~= "theme-empty" and action ~= "reveal" then return end
local core, common = require "core", require "core.common"
local style = require "core.style"
local ffi = require "ffi"
ffi.cdef [[
 unsigned long __stdcall GetCurrentProcessId(void);
 int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
 unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
 void * __stdcall GetPropW(void *, const wchar_t *);
 intptr_t __stdcall SendMessageW(void *, unsigned int, uintptr_t, intptr_t);
 int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
 int __stdcall IsWindowVisible(void *);
 long __stdcall DwmGetWindowAttribute(void *, unsigned long, void *, unsigned long);
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
 -- The shell creates the log when it starts.
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
local function rgb(color) return {color[1], color[2], color[3]} end
local captures = 0
-- The shell's next composed frame, with a reader for its pixels.
local function capture(window)
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
 return {width = width, height = height, pixel = function(x, y)
  -- Top-down BGRA rows follow the 54-byte headers.
  local offset = 54 + (math.floor(y) * width + math.floor(x)) * 4
  return {data:byte(offset + 3), data:byte(offset + 2), data:byte(offset + 1)}
 end}
end
-- The colour of the Sidebar's empty bottom-left area in the shell's next composed frame.
local function sidebar_color(window)
 local frame = capture(window)
 return frame.pixel(8, frame.height - 8)
end
local function same(a, b) return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] end
local function near(a, b, tolerance)
 for i = 1, 3 do if math.abs(a[i] - b[i]) > tolerance then return false end end
 return true
end
local function show(color) return string.format("#%02x%02x%02x", color[1], color[2], color[3]) end
local function quit() core.exit(function() core.quit_request = true end, true) end
local function ready(name)
 local _, _, controls_w, controls_h = system.get_window_controls()
 save(name, {pid = tonumber(kernel.GetCurrentProcessId()), background2 = rgb(style.background2),
  text = rgb(style.text), dim = rgb(style.dim), pressed = {table.unpack(style.titlebar_control_pressed)},
  controls_w = controls_w, controls_h = controls_h})
end
-- The minimize, maximize and close buttons fill the controls rect at the frame's top-right corner.
local function control_rect(frame, state, index)
 local left, width = frame.width - state.controls_w, math.floor(state.controls_w / 3)
 return {x = left + index * width, w = index == 2 and state.controls_w - 2 * width or width, h = state.controls_h}
end
-- The selected Project uses a light Color Theme here, so its dark text colour draws the glyphs, or its dim
-- colour while the shell Window is not focused.
local function check_controls(window, state)
 pcall(wait, function() return trace():find("Shell colours: Project", 1, true) end, 5)
 local frame = capture(window)
 local close = control_rect(frame, state, 2)
 local glyph = frame.pixel(close.x + math.floor(close.w / 2), math.floor(close.h / 2))
 assert(near(glyph, state.text, 24) or near(glyph, state.dim, 24), "the close glyph drew " .. show(glyph)
  .. ", not the Color Theme's text " .. show(state.text) .. " or dim " .. show(state.dim))
 local minimize = control_rect(frame, state, 0)
 local x, y = minimize.x + 3, 3
 local before = frame.pixel(x, y)
 local point = minimize.x + math.floor(minimize.w / 2) + math.floor(minimize.h / 2) * 65536
 user32.PostMessageW(window, 0x200, 0, point)
 user32.PostMessageW(window, 0x201, 1, point)
 coroutine.yield(.3)
 local pressed = capture(window).pixel(x, y)
 -- Releasing outside the button cancels it, so the Window stays open.
 local away = math.floor(frame.width / 2) + math.floor(frame.height / 2) * 65536
 user32.PostMessageW(window, 0x200, 1, away)
 user32.PostMessageW(window, 0x202, 0, away)
 coroutine.yield(.2)
 local alpha = (state.pressed[4] or 255) / 255
 local expected = {}
 for i = 1, 3 do expected[i] = math.floor(before[i] * (1 - alpha) + state.pressed[i] * alpha + .5) end
 assert(near(pressed, expected, 3), "pressed minimize drew " .. show(pressed) .. " over " .. show(before)
  .. ", not the Color Theme's pressed " .. show(expected))
end

if path:match("/driver$") and action == "reveal" then
 core.add_background_thread(function()
  local shell
  local ok, err = pcall(function()
   local process = require "core.process"
   shell = assert(process.start({EXEFILE, "--shell", root .. "/Project"},
    {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
   local window = wait(function() return shell_window(shell:pid()) end, 10, "shell Window not found")
   -- Windows draws the Window once it is visible and DWM does not cloak it.
   local dwm, cloaked = ffi.load("dwmapi"), ffi.new("unsigned long[1]")
   wait(function()
    cloaked[0] = 1
    return user32.IsWindowVisible(window) ~= 0 and dwm.DwmGetWindowAttribute(window, 14, cloaked, 4) == 0
     and cloaked[0] == 0
   end, 15, "the shell never showed its Window")
   local first = capture(window)
   wait(function() return load("a-ready") end, 30, "Project A did not start")
   wait(function() return trace():find("Shell Sidebar surface Ready", 1, true) end, 15, "Sidebar did not become Ready")
   coroutine.yield(1.5)
   local settled = capture(window)
   local controls_w = tonumber(trace():match("Shell controls: x=%d+ y=%d+ w=(%d+)"))
   -- The Title Bar left of the Window controls, the Sidebar's empty area, and the Project area.
   local points = {{settled.width - controls_w - 24, 4, "Title Bar"}, {8, settled.height - 8, "Sidebar"},
    {math.floor(settled.width * .75), math.floor(settled.height * .75), "Project area"}}
   for _, point in ipairs(points) do
    local shown, final = first.pixel(point[1], point[2]), settled.pixel(point[1], point[2])
    -- The Project's wallpaper still settles after its first frame. The dark fallback is far from either.
    assert(near(shown, final, 24), "the first visible frame drew " .. show(shown) .. " in the " .. point[3]
     .. ", not the loaded " .. show(final))
   end
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
elseif path:match("/Project$") and action == "reveal" then
 core.add_background_thread(function()
  coroutine.yield(.5)
  ready("a-ready")
 end)
elseif path:match("/driver$") and action == "theme-empty" then
 core.add_background_thread(function()
  local shell
  local ok, err = pcall(function()
   local process = require "core.process"
   shell = assert(process.start({EXEFILE, "--shell", root .. "/Project"},
    {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
   wait(function() return load("a-ready") end, 30, "Project A did not start")
   -- Project A asks for a New Window, which has no Project.
   save("new-window", {go = true})
   -- Project A's Window was empty before A started too.
   local id = wait(function()
    local ids = {}
    for found in trace():gmatch("Shell empty Window ready: id=(%d+)") do ids[#ids + 1] = found end
    return ids[2]
   end, 10, "the shell did not open an empty Window")
   local hex = assert(trace():match("Shell Window record: id=" .. id .. " SDL=%d+ hwnd=(%x+)"))
   local window = ffi.cast("void *", tonumber(hex, 16))
   wait(function() return trace():find("Shell Sidebar surface Ready: Window=" .. id, 1, true) end, 15,
    "the empty Window's Sidebar did not become Ready")
   coroutine.yield(1)
   -- The driver loaded the same saved Color Theme.
   local frame = capture(window)
   local area = frame.pixel(frame.width - 24, frame.height - 24)
   assert(same(area, rgb(style.background)), "the empty Project area drew " .. show(area)
    .. ", not the Color Theme's background " .. show(rgb(style.background)))
   local x, y, w, h
   for cx, cy, cw, ch in trace():gmatch("Shell controls: x=(%d+) y=(%d+) w=(%d+) h=(%d+)") do
    x, y, w, h = tonumber(cx), tonumber(cy), tonumber(cw), tonumber(ch)
   end
   assert(x, "the shell did not report its Window controls")
   local state = {controls_w = w, controls_h = h, text = rgb(style.text), dim = rgb(style.dim)}
   local close = control_rect(frame, state, 2)
   local glyph = frame.pixel(close.x + math.floor(close.w / 2), math.floor(close.h / 2))
   assert(near(glyph, state.text, 24) or near(glyph, state.dim, 24), "the close glyph drew " .. show(glyph)
    .. ", not the Color Theme's text " .. show(state.text) .. " or dim " .. show(state.dim))
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
elseif path:match("/driver$") then
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
   check_controls(window, a)
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
elseif path:match("/Project$") and action == "theme-empty" then
 core.add_background_thread(function()
  coroutine.yield(.5)
  ready("a-ready")
  wait(function() return load("new-window") end, 60)
  assert(system.new_anvil_window(), "New Window request failed")
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
