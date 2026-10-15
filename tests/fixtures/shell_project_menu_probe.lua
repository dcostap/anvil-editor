-- mod-version:3
-- Seam: owned hosted Windows on a private desktop. A right-click on a Project's Sidebar row opens the shell's
-- actions menu for it, and the chosen command acts on that Project. The probe names the command in a file, so the
-- shell shows no native menu.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "project-menu" then return end
local core, common, style = require "core", require "core.common", require "core.style"
local ffi = require "ffi"
ffi.cdef [[
 int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
 unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
 void * __stdcall GetPropW(void *, const wchar_t *);
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
 error(message or "Project menu probe timed out")
end
local function trace()
 local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
 local text = file:read("*a"); file:close(); return text
end
-- The shell's Windows, keyed by their Window id.
local function shell_windows(pid)
 local property = ffi.new("wchar_t[17]", {65,110,118,105,108,83,104,101,108,108,87,105,110,100,111,119,0})
 local found = {}
 local cb = ffi.cast("int (__stdcall *)(void *, intptr_t)", function(window)
  local owner = ffi.new("unsigned long[1]"); user32.GetWindowThreadProcessId(window, owner)
  if tonumber(owner[0]) == pid and user32.GetPropW(window, property) ~= nil then found[#found + 1] = window end
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
   local window = wait(function() return shell_windows(shell:pid())[1] end, 30, "shell Window not found")
   wait(function() return trace():find("Shell Sidebar surface Ready", 1, true) end, 30, "Sidebar did not become Ready")
   wait(function() local project = load("project"); return project and project.window ~= 0 end, 30,
    "The Project did not start")
   coroutine.yield(1)
   local scale = user32.GetDpiForWindow(window) / 96
   local font = style.font:get_height() / SCALE
   -- The first row is the Project. Row heights follow the Sidebar's font.
   local point = math.floor(100 * scale) + math.floor((40 + (font + 14) / 2) * scale) * 65536
   local menu_file = root .. "/menu-choice.txt"
   -- Right-clicks the Project's row with the shell's routing probe message: posted Win32 input is ignored on an
   -- inactive desktop. Returns the menu's items.
   local function menu(choice, items)
    local file = assert(io.open(menu_file, "wb")); file:write(choice); file:close()
    local mark = #trace()
    for step = 7, 8 do user32.PostMessageW(window, 0x804a, step, point); coroutine.yield(.1) end
    local found = wait(function()
     return trace():match("Shell Project menu: Window=%d+ row=%d+ items=([^\r\n]*)", mark)
    end, 5, "A right-click on the Project's row showed no menu")
    assert(found == items, "Project menu items: " .. found)
    if choice ~= "" then
     wait(function() return trace():find("Shell Project menu command:", mark, true) end, 5,
      "The menu did not perform " .. choice)
    end
   end
   menu("Copy Path", "Move to New Window|Unload|Copy Path|Show in File Explorer")
   local expected = (root .. "/Project"):gsub("/", "\\"):lower()
   wait(function() return (system.get_clipboard() or ""):lower() == expected end, 5,
    "Copy Path did not copy the Project's path")
   menu("Move to New Window", "Move to New Window|Unload|Copy Path|Show in File Explorer")
   wait(function() return load("project").window == 2 end, 15, "The Project did not move to a new Window")
   -- The first Window is empty now. Its Sidebar offers the Project's move back.
   menu("Unload", "Move to Window 1|Move to New Window|Unload|Copy Path|Show in File Explorer")
   wait(function() return trace():find("Shell Project is Dormant: id=", 1, true) end, 15,
    "Unload did not unload the Project")
   menu("", "Open in New Window|Copy Path|Show in File Explorer")
   -- Closing the first Window leaves the other Window's Sidebar working: a click on the Dormant Project loads it
   -- there.
   local other
   for _, candidate in ipairs(shell_windows(shell:pid())) do if candidate ~= window then other = candidate end end
   assert(other, "The second Window is missing")
   os.remove(root .. "/project.lua")
   user32.PostMessageW(window, 0x0010, 0, 0)
   wait(function() return #shell_windows(shell:pid()) == 1 end, 10, "The first Window did not close")
   coroutine.yield(.5)
   for step = 0, 2 do user32.PostMessageW(other, 0x804a, step, point); coroutine.yield(.1) end
   wait(function() local project = load("project"); return project and project.window == 2 end, 15,
    "A click on the Dormant Project did not load it after another Window closed")
  end)
  local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
  file:write("return ", common.serialize{ok=ok, error=ok and nil or tostring(err), action=action})
  file:close()
  save("finish", {go=true})
  if shell then
   coroutine.yield(1)
   shell:terminate(); shell:wait(2)
  end
  quit()
 end)
elseif path == root .. "/Project" then
 -- Reports the Window that shows this Project.
 core.add_background_thread(function()
  local last
  while not load("finish") do
   local window = system.get_anvil_window_id()
   if window ~= last then last = window; save("project", {window = window}) end
   coroutine.yield(.05)
  end
  require("core.command").perform("core:quit")
 end)
end
