-- mod-version:3
-- Seam: owned hosted Windows on a private desktop. A drag on the Project Sidebar's edge sets its width, and the
-- Project's Sidebar toggle slides it closed and open. Focus slides the hidden Sidebar open until it loses focus,
-- and the Sidebar stays hidden in the saved layout. The next shell starts with the saved layout.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "toggle-sidebar" then return end
local core, common = require "core", require "core.common"
local ffi = require "ffi"
ffi.cdef [[
 int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
 unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
 void * __stdcall GetPropW(void *, const wchar_t *);
 intptr_t __stdcall SendMessageW(void *, unsigned int, uintptr_t, intptr_t);
 int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
 unsigned int __stdcall GetDpiForWindow(void *);
]]
local user32 = ffi.load("user32")
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
 error(message or "Sidebar layout probe timed out")
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
local function quit() core.exit(function() core.quit_request = true end, true) end
local function start_shell(arguments)
 return assert(require("core.process").start(arguments,
  {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
end
local function stop_shell(shell)
 local deadline = system.get_time() + 10
 while shell:running() and system.get_time() < deadline do coroutine.yield(.1) end
 if shell:running() then shell:terminate(); shell:wait(1) end
end
local function saved_state()
 local file = assert(io.open(root .. "/user/shell-windows.state", "rb"))
 local text = file:read("*a"); file:close(); return text
end
local function saved_hidden()
 return saved_state():match("\nwindow %d+ %-?%d+ %-?%d+ %d+ %d+ [01] ([01]) ")
end

if path:match("/driver$") then
 core.add_background_thread(function()
  local shell
  local function content_x(phase) local content = load("content-" .. phase); return content and content.x end
  -- Each toggle asks the Project to perform its command, waits for the Project area to start at target, and
  -- checks that the Project saw the Sidebar between its ends.
  local function toggle(phase, step, target, full, message)
   save("toggle-" .. phase .. "-" .. step, {go = true})
   wait(function() return content_x(phase) == target end, 10, message)
   local seen = load("content-" .. phase).seen
   local between = false
   for _, x in ipairs(seen) do between = between or (x > 0 and x < full) end
   assert(between, "The Sidebar did not slide: the Project saw only " .. table.concat(seen, ","))
   save("toggled-" .. phase .. "-" .. step, {go = true})
  end
  local ok, err = pcall(function()
   shell = start_shell({EXEFILE, "--shell", root .. "/Project"})
   local window = wait(function() return shell_window(shell:pid()) end, 30, "shell Window not found")
   wait(function() return trace():find("Shell Sidebar surface Ready", 1, true) end, 30, "Sidebar did not become Ready")
   local scale = user32.GetDpiForWindow(window) / 96
   local function width(points) return math.floor(points * scale + 0.5) end
   wait(function() return content_x(1) == width(240) end, 30, "The Project area does not start after the Sidebar")
   coroutine.yield(1)
   -- Drag the Sidebar's edge 80 points to the right. The shell's routing probe message drives the pointer:
   -- posted Win32 input is ignored on an inactive desktop.
   local function post(step, x, y)
    user32.PostMessageW(window, 0x804a, step, math.floor(x) + math.floor(y) * 65536)
    coroutine.yield(.1)
   end
   local y = 300 * scale
   post(0, width(240), y)
   post(1, width(240), y)
   post(0, width(280), y)
   post(0, width(320), y)
   post(2, width(320), y)
   wait(function() return trace():find("Shell Sidebar width: Window=%d+ points=320") end, 5,
    "A drag on the Sidebar's edge did not set its width")
   wait(function() return content_x(1) == width(320) end, 5, "The Project area did not follow the Sidebar's width")
   wait(function() return trace():find("Shell Sidebar frame width: Window=%d+ width=" .. width(320) .. " ") end, 5,
    "The Sidebar did not draw at its wider width")
   -- A drag narrower than the Sidebar's starting width. The Sidebar draws at that width too, so its rows fit.
   post(0, width(320), y)
   post(1, width(320), y)
   post(0, width(200), y)
   post(0, width(170), y)
   post(2, width(170), y)
   wait(function() return content_x(1) == width(170) end, 5, "The Project area did not follow the narrower Sidebar")
   wait(function() return trace():find("Shell Sidebar frame width: Window=%d+ width=" .. width(170) .. " ") end, 5,
    "The Sidebar did not draw at its narrower width")
   post(0, width(170), y)
   post(1, width(170), y)
   post(0, width(250), y)
   post(0, width(320), y)
   post(2, width(320), y)
   wait(function() return content_x(1) == width(320) end, 5, "The Project area did not follow the Sidebar's width")
   coroutine.yield(.5)
   user32.SendMessageW(window, 0x8052, 1, 0)
   wait(function() return trace():find("capture%-1%.bmp") end, 5, "shell capture was not written")
   toggle(1, 1, 0, width(320), "The toggle did not hide the Sidebar")
   coroutine.yield(.5)
   user32.SendMessageW(window, 0x8052, 2, 0)
   wait(function() return trace():find("capture%-2%.bmp") end, 5, "shell capture was not written")
   toggle(1, 2, width(320), width(320), "The toggle did not show the Sidebar again")
   coroutine.yield(.5)
   user32.SendMessageW(window, 0x8052, 3, 0)
   wait(function() return trace():find("capture%-3%.bmp") end, 5, "shell capture was not written")
   toggle(1, 3, 0, width(320), "The toggle did not hide the Sidebar again")
   toggle(1, 4, width(320), width(320), "Focus did not show the hidden Sidebar")
   toggle(1, 5, 0, width(320), "The hidden Sidebar did not slide closed when it lost focus")
   save("finish-1", {go = true})
   stop_shell(shell)
   shell = nil
   assert(saved_state():find("\nsidebar 320\n", 1, true) and saved_hidden() == "1",
    "The shell did not save the Sidebar layout")

   -- The next shell restores the Window with its Sidebar hidden. The hidden Sidebar renders nothing, so the
   -- Window shows without it, and the Sidebar's startup deadline passes without a failure.
   local mark = #trace()
   local started = system.get_time()
   shell = start_shell({EXEFILE, "--shell"})
   window = wait(function() return shell_window(shell:pid()) end, 30, "restored shell Window not found")
   wait(function() return trace():find("Shell Window shown: id=%d+ ready", mark) end, 15,
    "The restored Window waited for its hidden Sidebar")
   wait(function() return content_x(2) == 0 end, 30, "The restored Window shows the hidden Sidebar")
   while system.get_time() - started < 33 do coroutine.yield(.5) end
   local text = trace()
   assert(not text:find("startup deadline expired", mark, true), "The hidden Sidebar failed its startup deadline")
   toggle(2, 1, width(320), width(320), "The toggle did not show the restored Window's Sidebar")
   wait(function() return trace():find("Shell Sidebar surface Ready", mark, true) end, 10,
    "The shown Sidebar did not render")
   save("finish-2", {go = true})
   stop_shell(shell)
   shell = nil
   assert(saved_hidden() == "0", "The shell did not save the shown Sidebar")
  end)
  save("finish-1", {go = true})
  save("finish-2", {go = true})
  if shell then stop_shell(shell) end
  local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
  file:write("return ", common.serialize{ok=ok, error=ok and nil or tostring(err), action=action})
  file:close()
  quit()
 end)
elseif path == root .. "/Project" then
 -- The first shell's Project toggles three times, then focuses the hidden Sidebar and takes focus back.
 -- The restored Project toggles once.
 local phase = load("finish-1") and 2 or 1
 -- Reports each Project area start the shell configures, and every value since the last toggle.
 local seen, last = {}, nil
 core.add_background_thread(function()
  while true do
   local x = system.get_window_content_x()
   if x ~= last then
    last = x
    seen[#seen + 1] = x
    save("content-" .. phase, {x = x, seen = seen})
   end
   coroutine.yield(.005)
  end
 end)
 core.add_background_thread(function()
  local command = require "core.command"
  local finish = "finish-" .. phase
  local ok, err = pcall(function()
   for step = 1, phase == 1 and 5 or 1 do
    local name = phase .. "-" .. step
    wait(function() return load("toggle-" .. name) or load(finish) end, 90)
    if load(finish) then return end
    seen = {last}
    if phase == 1 and step == 4 then
     assert(command.perform("core:focus_project_sidebar"), "The Sidebar focus command is unavailable")
    elseif phase == 1 and step == 5 then
     assert(system.focus_project_sidebar(false), "The Project did not take focus back")
    else
     assert(command.perform("core:toggle_project_sidebar"), "The Sidebar toggle command is unavailable")
    end
    wait(function() return load("toggled-" .. name) or load(finish) end, 15)
   end
  end)
  if not ok then save("project-error-" .. phase, {error = tostring(err)}) end
  wait(function() return load(finish) end, 90)
  command.perform("core:close_current_window")
 end)
end
