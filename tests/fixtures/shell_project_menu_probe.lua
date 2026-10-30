-- mod-version:3
-- Seam: owned hosted Windows on a private desktop. A right-click on a Project's Sidebar row opens its Context
-- Menu, which the shell shows above the Project. Keys choose an item, and its command acts on that Project.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "project-menu" and action ~= "project-menu-background" then return end
local background = action == "project-menu-background"
local core, common = require "core", require "core.common"
local ffi = require "ffi"
ffi.cdef [[
 int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
 unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
 void * __stdcall GetPropW(void *, const wchar_t *);
 int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
 unsigned int __stdcall GetDpiForWindow(void *);
 typedef struct { long left, top, right, bottom; } MenuProbeRect;
 int __stdcall GetClientRect(void *, MenuProbeRect *);
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
local menus = dofile(DATADIR .. "/shell_sidebar_menu.lua"){trace = trace, logs = root .. "/user/logs",
 post = function(window, action, value) user32.PostMessageW(window, 0x804a, action, value) end}

if path:match("/driver$") then
 core.add_background_thread(function()
  local shell
  local ok, err = pcall(function()
   if background then
    local selected, loaded = root .. "/Replacement", root .. "/Project"
    local state = assert(io.open(root .. "/user/shell-windows.state", "wb"))
    state:write(string.format("anvil-shell-windows 5\nwindow 1 40 40 1000 700 0 %d %s\nloaded 1 %d %s\n",
     #selected, selected, #loaded, loaded)); state:close()
   end
   shell = assert(require("core.process").start({EXEFILE, "--shell", background and root .. "/Replacement" or root .. "/Project"},
    {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
   local window = wait(function() return shell_windows(shell:pid())[1] end, 30, "shell Window not found")
   wait(function() return trace():find("Shell Sidebar surface Ready", 1, true) end, 30, "Sidebar did not become Ready")
   wait(function() local project = load("project"); return project and project.window ~= 0 end, 30,
    "The Project did not start")
   coroutine.yield(1)
   local scale = user32.GetDpiForWindow(window) / 96
   local function model()
    os.remove(root .. "/sidebar-0.lua"); user32.PostMessageW(window, 0x804d, 0, 0)
    return wait(function() return load("sidebar-0") end, 10, "Sidebar model did not arrive")
   end
   -- Finds a Project's row in `target`'s Sidebar through Sidebar input, without selecting it. A right-click on a
   -- Project row opens its menu, and Escape closes it. The Scratch Project's row is first.
   local function find_row(target, row_id, message)
    local client = ffi.new("MenuProbeRect")
    assert(user32.GetClientRect(target, client) ~= 0)
    return (menus.find_row(target, row_id, scale, client.bottom / scale, message))
   end
   if background then
    wait(function() return trace():match("Shell Project runtime ready: Project=%d+ background=1") end, 30,
     "The background Project did not become ready")
   end
   local original = wait(function()
    for _, item in ipairs(model().items) do
     if item.kind == "project" and item.path:gsub("\\", "/") == root .. "/Project" and item.state == "ready" then
      return item
     end
    end
   end, 30, "The Project is not ready in the Sidebar")
   local point = find_row(window, original.row_id, "The Project has no Sidebar row")
   -- Right-clicks the Project's row with the shell's routing probe message: posted Win32 input is ignored on an
   -- inactive desktop. Checks the menu's items and chooses `choice`, or nothing for "".
   local function menu(choice, items)
    local found = menus.open(window, point)
    assert(found, "A right-click on the Project's row showed no menu")
    assert(found.labels == items, "Project menu items: " .. found.labels)
    if choice ~= "" then menus.choose(window, choice) else menus.choose(window) end
   end
   menu("Copy Path", "Move to New Window|Unload|-|Copy Path|Show in File Explorer")
   local expected = (root .. "/Project"):gsub("/", "\\"):lower()
   wait(function() return (system.get_clipboard() or ""):lower() == expected end, 5,
    "Copy Path did not copy the Project's path")
   menu("Move to New Window", "Move to New Window|Unload|-|Copy Path|Show in File Explorer")
   wait(function() return load("project").window == 2 end, 15, "The Project did not move to a new Window")
   if background then
    assert(#shell_windows(shell:pid()) == 2, "Move closed the Window with the other Project")
    local page, moved = model()
    for _, item in ipairs(page.items) do if item.id == original.id then moved = item end end
    assert(moved and moved.window_id == 2 and moved.pid == original.pid, "Move replaced or lost the live Project")
    local selected = {}
    for _, item in ipairs(page.windows) do selected[item.id] = item.selected_project end
    assert(selected[2] == original.id, "The new Window did not select the moved Project")
    assert(selected[1] and selected[1] ~= original.id, "Move changed the first Window's Selected Project")
    return
   end
   -- The Move took the first Window's only Project, so that Window closes.
   wait(function() return #shell_windows(shell:pid()) == 1 end, 10, "The first Window stayed open without a Project")
   local other = shell_windows(shell:pid())[1]
   assert(other ~= window, "The Project's new Window closed")
   window = other
   -- A Window that opens for one Project starts with its Sidebar hidden. The Project shows it, and it slides open.
   local mark = #trace()
   save("toggle-sidebar", {go = true})
   wait(function() return trace():find("Shell Sidebar shown: Window=", mark + 1, true) end, 10,
    "The new Window did not show its Sidebar")
   coroutine.yield(.5)
   point = find_row(window, original.row_id, "The moved Project has no Sidebar row")
   menu("Unload", "Move to New Window|Unload|-|Copy Path|Show in File Explorer")
   wait(function() return trace():find("Shell Project is Dormant: id=", 1, true) end, 15,
    "Unload did not unload the Project")
   -- The Dormant Project is in a group in the Sidebar's bottom area. Groups start collapsed. The only group is at the
   -- bottom, above the Sidebar's padding, and a click opens it.
   local client = ffi.new("MenuProbeRect")
   assert(user32.GetClientRect(window, client) ~= 0)
   local header = math.floor(100 * scale) + (client.bottom - math.floor(20 * scale)) * 65536
   for step = 1, 2 do user32.PostMessageW(window, 0x804a, step, header) end
   coroutine.yield(.3)
   point = find_row(window, original.row_id, "The Dormant Project has no row in the Sidebar")
   menu("", "Open in New Window|-|Copy Path|Show in File Explorer")
   -- After the first Window closed, a click on the Dormant Project in the other Window's Sidebar loads it there.
   os.remove(root .. "/project.lua")
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
 -- Reports the Window that shows this Project, and toggles its Sidebar when the driver asks.
 core.add_background_thread(function()
  local last
  while not load("finish") do
   local window = system.get_anvil_window_id()
   if window ~= last then last = window; save("project", {window = window}) end
   if load("toggle-sidebar") then
    os.remove(root .. "/toggle-sidebar.lua")
    require("core.command").perform("core:toggle_project_sidebar")
   end
   coroutine.yield(.05)
  end
  require("core.command").perform("core:quit")
 end)
end
