-- mod-version:3
-- Seam: an owned hosted Window on a private desktop. The Project reports the Terminal Session its active view
-- shows, and a click on that session's Sidebar row focuses it in the Project.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "terminal-focus" then return end
local core, common, style = require "core", require "core.common", require "core.style"
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
   -- The Project reported the session while it had focus, and no session once the Editor took focus.
   wait(function()
    local text = trace()
    local shown = text:find("Shell Project focused Terminal Session: Project=%d+ session=" .. id)
    return shown and text:find("Shell Project focused Terminal Session: Project=%d+ session=none", shown)
   end, 10, "The Project did not report its focused Terminal Session")
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
   -- The first row is the Project; its Terminal Session follows. Row heights follow the Sidebar's font.
   local scale = user32.GetDpiForWindow(window) / 96
   local font = style.font:get_height() / SCALE
   local y = math.floor((40 + font + 14 + (font + 8) / 2) * scale)
   local point = math.floor(100 * scale) + y * 65536
   local mark = #trace()
   -- The shell's routing probe message: posted Win32 clicks are ignored on an inactive desktop.
   for step = 0, 2 do user32.PostMessageW(window, 0x804a, step, point); coroutine.yield(.1) end
   wait(function()
    return trace():find("Shell Terminal Session selection requested: Window=%d+ session=" .. id, mark)
   end, 5, "A click on the Terminal Session row did not reach the shell")
   wait(function() return load("focused") end, 10, "The Project did not focus the clicked Terminal Session")
   wait(function()
    return trace():find("Shell Project focused Terminal Session: Project=%d+ session=" .. id, mark)
   end, 5, "The Project did not report the newly focused Terminal Session")
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
