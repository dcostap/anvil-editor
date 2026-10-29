-- mod-version:3
-- Seam: an owned hosted Window on a private desktop. A click on a Terminal Session's Sidebar row focuses it in the
-- Project. A right-click on the row opens the
-- Sidebar's Terminal menu, and its Snooze choices reach the Sidebar's saved Snoozes. A Snooze moves the Pane into
-- its Project's Snoozed fold, and a click there still focuses it. The probe names the choice in a file, so the shell
-- shows no native menu.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "terminal-focus" then return end
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
 local text = file:read("*a"); file:close(); return assert(loadstring(text))()
end
local function wait(fn, seconds, message)
 local deadline = system.get_time() + (seconds or 10)
 repeat local value = fn(); if value then return value end; coroutine.yield(.01) until system.get_time() >= deadline
 error(message or "Terminal Session focus probe timed out")
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

if path:match("/driver$") then
 core.add_background_thread(function()
  local shell
  local ok, err = pcall(function()
   shell = assert(require("core.process").start({EXEFILE, "--shell", root .. "/Project"},
    {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
   local ready = wait(function() return load("ready") end, 30, "The Project did not open its Terminal Session")
   local id = ready.session_id
   local window = wait(function() return shell_window(shell:pid()) end, 10, "shell Window not found")
   -- Wait until the Sidebar lists the session under the Project.
   wait(function()
    user32.PostMessageW(window, 0x804d, 0, 0)
    coroutine.yield(.2)
    local page = load("sidebar-0")
    for _, item in ipairs(page and page.items or {}) do
     if item.kind == "terminal" and item.id == id then return true end
    end
   end, 20, "The Sidebar does not list the Project's Terminal Session")
   wait(function() return trace():find("Shell Sidebar surface Ready", 1, true) end, 15, "Sidebar did not become Ready")
   coroutine.yield(1)
   -- The shell's routing probe message sends Sidebar input: posted Win32 clicks are ignored on an inactive desktop.
   -- Only the Terminal's row has the Sidebar's own menu. An empty choice in the menu file chooses nothing.
   local scale = user32.GetDpiForWindow(window) / 96
   local menu_file = root .. "/menu-choice.txt"
   local file = assert(io.open(menu_file, "wb")); file:write(""); file:close()
   -- The point of the row that opens the Terminal menu.
   local function find_point()
    file = assert(io.open(menu_file, "wb")); file:write(""); file:close()
    for y = 40, 400, 8 do
     local at, mark = math.floor(100 * scale) + math.floor(y * scale) * 65536, #trace()
     for step = 7, 8 do user32.PostMessageW(window, 0x804a, step, at) end
     local deadline = system.get_time() + .3
     repeat
      coroutine.yield(.01)
      if trace():find("Shell Sidebar menu: ", mark + 1, true) then return at end
     until system.get_time() >= deadline
    end
    error("No Sidebar row opens the Terminal menu")
   end
   local point = find_point()
   -- Waits until the Project's Pane report shows the Pane snoozed, or not.
   local function snoozed_pane(state)
    wait(function()
     user32.PostMessageW(window, 0x804d, 0, 0)
     coroutine.yield(.2)
     local page = load("sidebar-0")
     for _, item in ipairs(page and page.items or {}) do
      if item.kind == "project" and item.panes ~= "" then
       return (item.panes:find("[\"snoozed\"]=true", 1, true) ~= nil) == state
      end
     end
    end, 10, state and "The Project did not snooze the Pane" or "The Project did not wake the Pane")
   end
   local function click(at)
    for step = 0, 2 do user32.PostMessageW(window, 0x804a, step, at); coroutine.yield(.1) end
   end
   -- The Sidebar saves each Terminal Session's Snooze time.
   local function snooze()
    local file = io.open(root .. "/user/storage/sidebar/snoozes", "rb")
    if not file then return nil end
    local text = file:read("*a"); file:close()
    local chunk = loadstring(text)
    local value = chunk and chunk()
    return type(value) == "table" and value[id] or nil
   end
   local function menu(choice, items)
    file = assert(io.open(menu_file, "wb")); file:write(choice); file:close()
    local at = #trace()
    for step = 7, 8 do user32.PostMessageW(window, 0x804a, step, point); coroutine.yield(.1) end
    local found = wait(function() return trace():match("Shell Sidebar menu: Window=%d+ items=([^\r\n]*)", at) end, 5,
     "A right-click on the Terminal Session row showed no menu")
    assert(found == items, "Terminal menu items: " .. found)
    wait(function() return trace():find("Shell Sidebar menu result: [1-9]", at) end, 5, "The menu did not choose " .. choice)
   end
   local times = "Remind Me In|1 Hour|2 Hours|3 Hours|4 Hours|24 Hours|Custom\u{2026}"
   local before = os.time()
   menu("2 Hours", times)
   wait(function() local time = snooze(); return time and time >= before + 2 * 3600 end, 5,
    "The Sidebar did not save the chosen Snooze")
   -- The collapsed Snoozed fold takes the Tab's row. A click opens it.
   snoozed_pane(true)
   click(point)
   point = find_point()
   menu("Remove Snooze", times .. "|Remove Snooze")
   wait(function() return snooze() == nil end, 5, "The Sidebar did not remove the Snooze")
   snoozed_pane(false)
   -- A Snoozed Pane's row still focuses its Terminal. The capture shows the open Snoozed fold.
   point = find_point()
   menu("3 Hours", times)
   wait(snooze, 5, "The Sidebar did not save the second Snooze")
   snoozed_pane(true)
   point = find_point()
   click(point)
   wait(function() return load("focused") end, 10, "The Project did not focus the clicked Terminal Session")
   coroutine.yield(1)
   user32.SendMessageW(window, 0x8052, 1, 0)
   wait(function() return trace():find("capture%-1%.bmp") end, 5, "shell capture was not written")
  end)
  local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
  file:write("return ", common.serialize{ok=ok, error=ok and nil or tostring(err), action=action})
  file:close()
  save("finish", {go=true})
  if shell then
   local deadline = system.get_time() + 10
   while shell:running() and system.get_time() < deadline do coroutine.yield(.1) end
   if shell:running() then shell:terminate(); shell:wait(1) end
  end
  quit()
 end)
elseif path == root .. "/Project" then
 core.add_background_thread(function()
  local ok, err = pcall(function()
   local terminal_plugin = require "plugins.terminal"
   assert(require("core.command").perform("terminal:reset_quit_choice"))
   local editor = core.open_file(path .. "/edited.txt")
   local terminal = terminal_plugin.open {cwd = path, shell = "cmd.exe /D /Q", focus = true}
   wait(function()
    return terminal.session and terminal.state == "running" and terminal.session_id
   end, 15, "The Terminal Session did not start")
   wait(function() return core.active_view == terminal end, 5)
   coroutine.yield(.5)
   core.set_active_view(editor)
   save("ready", {session_id = terminal.session_id})
   wait(function()
    return core.active_view.terminal_view and core.active_view.session_id == terminal.session_id
   end, 30, "The Project did not focus the clicked Terminal Session")
   save("focused", {go = true})
  end)
  if not ok then save("project-error", {error = tostring(err)}) end
  wait(function() return load("finish") end, 60)
  -- End the Terminal Session's shell, so quitting leaves no host behind.
  local terminal_plugin = require "plugins.terminal"
  for _, view in ipairs(terminal_plugin.open_views()) do
   if view.session then pcall(view.session.write, view.session, "exit\r") end
  end
  pcall(wait, function()
   for _, view in ipairs(terminal_plugin.open_views()) do
    if view.state == "running" then return false end
   end
   return true
  end, 5)
  require("core.command").perform("core:quit")
 end)
end
