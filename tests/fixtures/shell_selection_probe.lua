-- mod-version:3
-- Seam: an owned shell Window with two Projects. Selecting a Project that has not presented yet keeps the
-- previous Project's frame on screen, so the switch shows no empty Project area. This holds for a Project that
-- starts on selection and for a loaded Project that is slow to present.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "select-hold" then return end
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
 error(message or "selection probe timed out")
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
local function same(a, b) return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] end
local function show(color) return string.format("#%02x%02x%02x", color[1], color[2], color[3]) end
local function quit() core.exit(function() core.quit_request = true end, true) end
local function ready(name, pane)
 local _, _, controls_w = system.get_window_controls()
 save(name, {pid = tonumber(kernel.GetCurrentProcessId()), controls_w = controls_w, pane = pane,
  background = {style.background[1], style.background[2], style.background[3]}})
end

if path:match("/driver$") then
 core.add_background_thread(function()
  local shell
  local ok, err = pcall(function()
   local process = require "core.process"
   shell = assert(process.start({EXEFILE, "--shell", root .. "/Project"},
    {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
   local a = wait(function() return load("a-ready") end, 30, "Project A did not start")
   local window = wait(function() return shell_window(shell:pid()) end, 10, "shell Window not found")
   coroutine.yield(.5)
   -- An empty stretch of the Title Bar, left of the Window controls.
   local first = capture(window)
   local x, y = first.width - a.controls_w - 24, 4
   local a_shown = first.pixel(x, y)
   assert(not same(a_shown, a.background), "the probe pixel shows A's background " .. show(a_shown))
   -- B starts on selection. Until its first frame, every composed frame still shows A.
   local presented = count(trace(), "showing its first")
   save("select-b", {go = true})
   wait(function() return trace():find("path=[^\n]*Replacement") end, 10, "the shell did not select Project B")
   local frames = 0
   while count(trace(), "showing its first") == presented do
    local starting = capture(window).pixel(x, y)
    frames = frames + 1
    assert(same(starting, a_shown), "starting Project B showed " .. show(starting) .. " in frame " .. frames
     .. ", not A's " .. show(a_shown))
   end
   assert(frames > 0, "Project B presented before the probe saw the switch")
   local b = wait(function() return load("b-ready") end, 30, "Project B did not start")
   coroutine.yield(.5)
   local shown = capture(window).pixel(x, y)
   assert(not same(shown, b.background), "the probe pixel shows B's background " .. show(shown))
   -- A cannot present while its UI thread sleeps, so its selection waits for its first frame.
   save("a-block", {go = true})
   wait(function() return load("a-blocking") end, 10, "Project A did not block")
   local selected = count(trace(), "Shell selected loaded Project")
   save("select-a", {go = true})
   wait(function() return count(trace(), "Shell selected loaded Project") > selected end, 5,
    "the shell did not select Project A")
   local switching = capture(window).pixel(x, y)
   assert(same(switching, shown), "the switch showed " .. show(switching) .. " before Project A presented, not B's "
    .. show(shown))
   -- A Pane request must never show the previously focused Pane during the switch.
   local px, py = math.floor(first.width * .75), math.floor(first.height * .5)
   local target = {32, 160, 64}
   local old = {192, 48, 32}
   wait(function()
    local color = capture(window).pixel(px, py)
    assert(not same(color, old), "Project selection showed the previously focused Pane before the requested Pane")
    return same(color, target)
   end, 15, "the requested Pane did not appear")
   local sidebar = wait(function() return load("sidebar-selection") end, 15, "Sidebar selection check did not finish")
   assert(sidebar.ok, sidebar.error)
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
  local panes, View = require "core.panes", require "core.view"
  local ColorView = View:extend()
  function ColorView:new(color) ColorView.super.new(self); self.color = color end
  function ColorView:get_name() return "Selection probe" end
  function ColorView:draw()
   renderer.draw_rect(self.position.x, self.position.y, self.size.x, self.size.y, self.color)
  end
  local old = assert(panes.create {factory = function() return ColorView({192, 48, 32, 255}) end})
  local target = assert(panes.create {factory = function() return ColorView({32, 160, 64, 255}) end})
  panes.focus(old)
  coroutine.yield(.5)
  ready("a-ready", target.id)
  wait(function() return load("select-b") end, 60)
  assert(system.pane_request("select", root .. "/Replacement",
   common.serialize({action = "new_group"}, {escape = true})))
  wait(function() return load("a-block") end, 60)
  save("a-blocking", {go = true})
  system.sleep(1.5)
 end)
elseif path:match("/Replacement$") then
 core.add_background_thread(function()
  coroutine.yield(.5)
  ready("b-ready")
  wait(function() return load("select-a") end, 60)
  local target = assert(load("a-ready")).pane
  assert(system.pane_request("select", root .. "/Project",
   common.serialize({action = "focus", pane = target}, {escape = true})))
  local ok, err = pcall(function()
   wait(function()
    local previous = core.project_sidebar
    if not core.request_project_sidebar() then return end
    local model = wait(function() return core.project_sidebar ~= previous and core.project_sidebar end, 10)
    for _, project in ipairs(model) do
     if project.path:gsub("\\", "/") == root .. "/Project" and project.selected then
      local active = project.panes[project.panes.active]
      assert(active and active.id == target, "Sidebar selected the Project with its previously focused Pane")
      return true
     end
    end
   end, 15, "Sidebar did not select the requested Pane")
  end)
  save("sidebar-selection", {ok = ok, error = ok and nil or tostring(err)})
 end)
end
