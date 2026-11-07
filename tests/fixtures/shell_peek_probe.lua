-- mod-version:3
-- Seam: an owned shell Window with two loaded Projects. While the Sidebar has the keyboard, its cursor row's
-- content shows in the Project area (Peek). A Peek selects nothing, keeps the keyboard in the Sidebar, and adds no
-- Pane History visit or focus stamp in the peeked Project. Escape shows the Selected Project again. Enter on the
-- peeked row selects it without showing the previous Project in between.
if os.getenv("ANVIL_PROJECT_PROBE") ~= "peek" then return end
local core, common = require "core", require "core.common"
local ffi = require "ffi"
ffi.cdef [[
 unsigned long __stdcall GetCurrentProcessId(void);
 int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
 unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
 void * __stdcall GetPropW(void *, const wchar_t *);
 intptr_t __stdcall SendMessageW(void *, unsigned int, uintptr_t, intptr_t);
 int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
 void * __stdcall OpenProcess(unsigned long, int, unsigned long);
 int __stdcall TerminateProcess(void *, unsigned int);
 int __stdcall CloseHandle(void *);
]]
local user32, kernel = ffi.load("user32"), ffi.load("kernel32")
local root = assert(os.getenv("ANVIL_PROJECT_PROBE_ROOT"))
local path = core.root_project().path:gsub("\\", "/")
local RED, GREEN = {192, 48, 32, 255}, {32, 160, 64, 255}
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
 error(message or "peek probe timed out")
end
local function trace()
 local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
 local text = file:read("*a"); file:close(); return text
end
local function count(text, pattern)
 local n = 0
 for _ in text:gmatch(pattern) do n = n + 1 end
 return n
end
local function quit() core.exit(function() core.quit_request = true end, true) end
-- A Pane that fills itself with one colour, so a pixel tells which Project the shell shows.
local function color_pane(color)
 local panes, View = require "core.panes", require "core.view"
 local ColorView = View:extend()
 function ColorView:get_name() return "Peek probe" end
 function ColorView:draw()
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, self.size.y, color)
 end
 local pane = assert(panes.create {factory = function() return ColorView() end})
 panes.focus(pane)
 return pane
end

if path:match("/driver$") then
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
 core.add_background_thread(function()
  local shell
  local ok, err = pcall(function()
   local process = require "core.process"
   shell = assert(process.start({EXEFILE, "--shell", root .. "/Project"},
    {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD,
     env={ANVIL_INPUT_LATENCY_PROBE="1", ANVIL_INPUT_LATENCY_WARMUP_MS="600000"}}))
   wait(function() return load("a-ready") end, 30, "Project A did not start")
   wait(function() return load("b-ready") end, 30, "Project B did not start")
   local window = wait(function() return shell_window(shell:pid()) end, 10, "shell Window not found")
   local captures = 0
   local function capture()
    captures = captures + 1
    user32.SendMessageW(window, 0x8052, captures, 0)
    local name = "capture-" .. captures .. ".bmp"
    wait(function() return trace():find(name, 1, true) end, 5, "shell capture " .. captures .. " was not written")
    local file = assert(io.open(root .. "/" .. name, "rb"))
    local data = file:read("*a"); file:close()
    os.remove(root .. "/" .. name)
    local function int32(offset)
     local value = data:byte(offset + 1) + data:byte(offset + 2) * 256 + data:byte(offset + 3) * 65536
      + data:byte(offset + 4) * 16777216
     return value >= 2147483648 and value - 4294967296 or value
    end
    local width, height = int32(18), math.abs(int32(22))
    return {width = width, height = height, pixel = function(x, y)
     local offset = 54 + (math.floor(y) * width + math.floor(x)) * 4
     return {data:byte(offset + 3), data:byte(offset + 2), data:byte(offset + 1)}
    end}
   end
   -- Which Project's Pane the middle of the Project area shows.
   local function shown()
    local frame = capture()
    local color = frame.pixel(frame.width * .75, frame.height * .5)
    if color[1] > 150 and color[2] < 90 then return "A", frame end
    if color[2] > 130 and color[1] < 70 then return "B", frame end
    return string.format("#%02x%02x%02x", color[1], color[2], color[3]), frame
   end
   local function press(key)
    user32.PostMessageW(window, 0x804a, 9, key)
    user32.PostMessageW(window, 0x804a, 10, key)
   end
   local DOWN, UP, ESCAPE, ENTER = 0x40000051, 0x40000052, 27, 13
   wait(function() return shown() == "A" end, 10, "the Window did not show Project A")
   local function focus(step)
    local mark = #trace() + 1
    save("focus-" .. step, true)
    wait(function() return trace():find("Shell Sidebar focus: Window=%d+ focused=1", mark) end, 10,
     "the Sidebar did not take the keyboard")
   end
   -- Moves the cursor until the shell shows B's Peek. B's rows can be above or below A's rows.
   local function peek_b()
    for _, key in ipairs {DOWN, DOWN, DOWN, DOWN, DOWN, DOWN, UP, UP, UP, UP, UP, UP, UP, UP, UP, UP, UP, UP} do
     local mark = #trace() + 1
     press(key)
     local found = pcall(wait, function()
      return trace():find("Shell Peek shown: Window=%d+ Project=%d+", mark)
     end, .6)
     if found then return end
    end
    error("no cursor row showed Project B's Peek")
   end
   local selected = count(trace(), "Shell selected loaded Project")
   focus(1)
   peek_b()
   local frame = wait(function()
    local name, frame = shown()
    return name == "B" and frame
   end, 3, "the Peek did not show Project B")
   -- The lens frames the Project area at its edges.
   local edge = frame.pixel(frame.width - 1, frame.height * .5)
   assert(not (edge[2] > 130 and edge[1] < 70), "the Peek showed no lens at the Project area's edge")
   assert(count(trace(), "Shell selected loaded Project") == selected, "the Peek selected Project B")
   assert(not trace():find("Shell Sidebar focus: Window=%d+ focused=0"), "the Peek took the keyboard from the Sidebar")
   save("peeked", true)
   local effects = wait(function() return load("b-effects") end, 10, "Project B did not report its state")
   assert(effects.ok, effects.error)
   -- Escape gives the keyboard back to A and ends the Peek.
   local mark = #trace() + 1
   press(ESCAPE)
   wait(function() return trace():find("Shell Peek ended: Window=%d+ reason=", mark) end, 5, "Escape did not end the Peek")
   wait(function() return shown() == "A" end, 3, "the Project area did not show Project A again")
   -- Enter on the peeked row selects B. No frame shows A between the Peek and B's own frames.
   focus(2)
   peek_b()
   wait(function() return shown() == "B" end, 3, "the second Peek did not show Project B")
   mark = #trace() + 1
   press(ENTER)
   local frames, settled = 0, nil
   repeat
    local name = shown()
    frames = frames + 1
    assert(name == "B", "frame " .. frames .. " after Enter showed " .. name .. ", not Project B")
    local text = trace()
    if not settled and text:find("Shell Peek committed: Window=%d+ Project=%d+", mark)
      and text:find("Shell replaced the previous Project's frame", mark, true) then settled = system.get_time() end
   until settled and system.get_time() - settled > .3 or frames > 400
   assert(settled, "the selection did not keep the Peek's frame")
   assert(count(trace(), "Shell selected loaded Project") > selected, "Enter did not select Project B")
   wait(function() return load("b-focused") end, 10, "Project B did not get the keyboard")
  end)
  local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
  file:write("return ", common.serialize{ok=ok, error=ok and nil or tostring(err)})
  file:close()
  save("finish", true)
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
  local command = require "core.command"
  color_pane(RED)
  assert(system.load_project(root .. "/Replacement"))
  coroutine.yield(.5)
  save("a-ready", {pid = tonumber(kernel.GetCurrentProcessId())})
  wait(function() return load("focus-1") end, 60)
  assert(command.perform("core:focus_project_sidebar"))
  wait(function() return load("focus-2") end, 60)
  assert(command.perform("core:focus_project_sidebar"))
  wait(function() return load("finish") end, 120)
  quit()
 end)
elseif path:match("/Replacement$") then
 core.add_background_thread(function()
  local pane_history, recent_panes = require "core.pane_history", require "core.recent_panes"
  local pane = color_pane(GREEN)
  local visits, stamp = #pane_history.entries(), recent_panes.focused_at(pane)
  save("b-ready", {pid = tonumber(kernel.GetCurrentProcessId())})
  wait(function() return load("peeked") end, 60)
  local ok, err = pcall(function()
   assert(not system.window_has_focus(core.window), "the Peek gave Project B the keyboard")
   assert(#pane_history.entries() == visits, "the Peek added a Pane History visit")
   assert(recent_panes.focused_at(pane) == stamp, "the Peek stamped the Pane's focus time")
  end)
  save("b-effects", {ok = ok, error = not ok and tostring(err) or nil})
  wait(function() return system.window_has_focus(core.window) end, 30)
  save("b-focused", true)
  wait(function() return load("finish") end, 120)
  quit()
 end)
end
