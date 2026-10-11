-- mod-version:3
-- Seam: App State restore of Anvil Windows across shell runs, on isolated owned Windows.
-- Each run records its Project runtimes, so restored and duplicate runtimes stay visible.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if not action or not action:match("^restore%-") then return end
local core, common = require "core", require "core.common"
local ffi = require "ffi"
ffi.cdef [[
 typedef struct { long left, top, right, bottom; } ProbeRect;
 typedef struct { long x, y; } ProbePoint;
 typedef struct { unsigned int length, flags, showCmd; ProbePoint min, max; ProbeRect normal; } ProbePlacement;
 unsigned long __stdcall GetCurrentProcessId(void);
 int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
 unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
 void * __stdcall GetPropW(void *, const wchar_t *);
 int __stdcall IsIconic(void *);
 int __stdcall IsZoomed(void *);
 int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
 int __stdcall GetWindowPlacement(void *, ProbePlacement *);
 int __stdcall SetWindowPos(void *, void *, int, int, int, int, unsigned int);
 void * __stdcall GetWindow(void *, unsigned int);
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
 error(message or "restore probe timed out")
end
local function trace()
 local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
 local text = file:read("*a"); file:close(); return text
end
-- Ready records of one Project, optionally only those from one shell.
local function ready(name, shell)
 local found = {}
 for _, file in ipairs(system.list_dir(root) or {}) do
  local pid = file:match("^" .. name .. "%-ready%-(%d+)%.lua$")
  local record = pid and load(name .. "-ready-" .. pid)
  if record and (not shell or record.shell_pid == shell) then found[#found + 1] = record end
 end
 return found
end
local function windows(pid)
 local found, count = {}, 0
 local property = ffi.new("wchar_t[17]", {65,110,118,105,108,83,104,101,108,108,87,105,110,100,111,119,0})
 local text = trace()
 local cb = ffi.cast("int (__stdcall *)(void *, intptr_t)", function(window)
  local owner = ffi.new("unsigned long[1]"); user32.GetWindowThreadProcessId(window, owner)
  if tonumber(owner[0]) == pid and user32.GetPropW(window, property) ~= nil then
   for id, hex in text:gmatch("Shell Window record: id=(%d+) SDL=%d+ hwnd=(%x+)") do
    if ffi.cast("void *", tonumber(hex, 16)) == window then found[tonumber(id)] = window; count = count + 1 end
   end
  end
  return 1
 end)
 user32.EnumWindows(cb, 0); cb:free(); return found, count
end
local function placement(window)
 local value = ffi.new("ProbePlacement"); value.length = ffi.sizeof(value)
 assert(user32.GetWindowPlacement(window, value) ~= 0)
 local r = value.normal
 return {tonumber(r.left), tonumber(r.top), tonumber(r.right - r.left), tonumber(r.bottom - r.top)}
end
-- True when `upper` is above `lower` in z-order.
local function above(upper, lower)
 local item = user32.GetWindow(upper, 2) -- GW_HWNDNEXT
 while item ~= nil do
  if item == lower then return true end
  item = user32.GetWindow(item, 2)
 end
 return false
end
local function quit() core.exit(function() core.quit_request = true end, true) end
local names = {[root .. "/Project"] = "a", [root .. "/Replacement"] = "b"}

if path:match("/driver$") then
 core.add_background_thread(function()
  local launched = {}
  local options = {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD,
   cwd=root}
  local function launch(...)
   local item = assert(require("core.process").start({EXEFILE, "--shell", ...}, options))
   launched[#launched + 1] = item; return item
  end
  local function kill(pid)
   local handle = kernel.OpenProcess(0x1F0FFF, 0, pid)
   if handle ~= nil then kernel.TerminateProcess(handle, 9); kernel.CloseHandle(handle) end
  end
  local function close_window(window) user32.PostMessageW(window, 0x10, 0, 0) end
  local function close_shell(item, label)
   for _, window in pairs(windows(item:pid())) do close_window(window) end
   wait(function() return not item:running() end, 15, label .. " Close did not end the shell")
   assert(item:returncode() == 0, label .. " shell ended with a failure")
  end
  -- The shell writes App State after placement settles.
  local function written(count)
   local _, before = trace():gsub("Shell Window state written", "")
   coroutine.yield(1)
   wait(function() local _, now = trace():gsub("Shell Window state written", ""); return now > before end, 5,
    "shell did not write its Window state")
   assert(trace():find("Shell Window state queued: Windows=" .. count, 1, true))
  end
  local ok, err = pcall(function()
   if action == "restore-crash" then
    -- A crash or reboot keeps every Window from the last write.
    local first = launch(root .. "/Project")
    local a = wait(function() return ready("a")[1] end, 20)
    local b = wait(function() return ready("b")[1] end, 20)
    local all = windows(first:pid())
    local aw, bw = assert(all[a.window_id]), assert(all[b.window_id])
    assert(user32.SetWindowPos(aw, nil, 120, 90, 900, 650, 0x14) ~= 0)
    user32.PostMessageW(bw, 0x112, 0xf030, 0)
    wait(function() return user32.IsZoomed(bw) ~= 0 end, 5)
    local saved_a, saved_b = placement(aw), placement(bw)
    written(2)
    for _, pid in ipairs({first:pid(), a.pid, b.pid}) do kill(pid) end
    wait(function() return not first:running() end, 5)
    local second = launch()
    local a2 = wait(function() return ready("a", second:pid())[1] end, 20, "restore did not load Project")
    local b2 = wait(function() return ready("b", second:pid())[1] end, 20, "restore did not load Replacement")
    local found, count = windows(second:pid())
    assert(count == 2, "restore did not return both Windows")
    local aw2, bw2 = assert(found[a2.window_id]), assert(found[b2.window_id])
    assert(a2.window_id ~= b2.window_id, "restored Projects share one Window")
    assert(common.serialize(placement(aw2)) == common.serialize(saved_a), "restored Window lost its bounds: " ..
     common.serialize(placement(aw2)) .. " saved " .. common.serialize(saved_a))
    assert(user32.IsZoomed(aw2) == 0 and user32.IsZoomed(bw2) ~= 0, "restored Windows lost their modes")
    assert(common.serialize(placement(bw2)) == common.serialize(saved_b), "maximized Window lost its normal bounds")
    assert(above(bw2, aw2), "frontmost Window did not restore in front")
    assert(a2.active and a2.active:gsub("\\", "/"):match("/Project/edited%.txt$"),
     "restored Project did not restore its Workspace")
    return close_shell(second, "restored")
   end

   if action == "restore-sequential" then
    -- Close is per Window. After separate Closes, only the last Window returns.
    local first = launch(root .. "/Project")
    local a = wait(function() return ready("a")[1] end, 20)
    local b = wait(function() return ready("b")[1] end, 20)
    local all = windows(first:pid())
    local aw, bw = assert(all[a.window_id]), assert(all[b.window_id])
    assert(user32.SetWindowPos(bw, nil, 200, 150, 800, 600, 0x14) ~= 0)
    local saved_b = placement(bw)
    close_window(aw)
    wait(function() return select(2, windows(first:pid())) == 1 end, 10, "Window A did not close")
    close_window(bw)
    wait(function() return not first:running() end, 15, "last Window Close did not end the shell")
    local second = launch()
    local b2 = wait(function() return ready("b", second:pid())[1] end, 20, "restore did not load the last Window's Project")
    coroutine.yield(1.5)
    local found, count = windows(second:pid())
    assert(count == 1, "restore returned a Window the user closed earlier")
    assert(#ready("a", second:pid()) == 0, "restore loaded the earlier Window's Project")
    assert(common.serialize(placement(assert(found[b2.window_id]))) == common.serialize(saved_b),
     "last Window lost its bounds")
    return close_shell(second, "restored")
   end

   if action == "restore-argument" then
    local first = launch(root .. "/Project")
    wait(function() return ready("a")[1] end, 20)
    close_shell(first, "first")
    -- An argument that names a restored Project selects it. No second runtime starts.
    local second = launch("PROJECT")
    local a2 = wait(function() return ready("a", second:pid())[1] end, 20, "restore did not load Project")
    coroutine.yield(1.5)
    assert(#ready("a", second:pid()) == 1, "argument duplicated the restored Project")
    assert(select(2, windows(second:pid())) == 1, "argument for a restored Project opened another Window")
    assert(a2.window_id, "restored Project has no Window")
    close_shell(second, "second")
    -- Another Project opens in a new Window beside the restored Window.
    local third = launch("Replacement")
    local a3 = wait(function() return ready("a", third:pid())[1] end, 20, "restore did not load Project")
    local b3 = wait(function() return ready("b", third:pid())[1] end, 20, "argument did not load its Project")
    assert(a3.window_id ~= b3.window_id, "argument Project did not open a new Window")
    assert(select(2, windows(third:pid())) == 2, "restore with an argument did not keep both Windows")
    return close_shell(third, "third")
   end
   error("unknown restore probe " .. action)
  end)
  local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
  file:write("return ", common.serialize{ok=ok, error=ok and nil or tostring(err), action=action}); file:close()
  for _, item in ipairs(launched) do if item:running() then item:terminate(); item:wait(1) end end
  for _, name in ipairs({"a", "b"}) do for _, record in ipairs(ready(name)) do kill(record.pid) end end
  quit()
 end)
elseif names[path] then
 local name, pid = names[path], tonumber(kernel.GetCurrentProcessId())
 core.add_background_thread(function()
  -- Let first-run Workspace setup or restore finish.
  coroutine.yield(1)
  if name == "a" and not load("a-seeded") then
   save("a-seeded", true)
   core.set_active_view(core.open_file(path .. "/edited.txt"))
   core.save_workspace()
   if action ~= "restore-argument" then assert(core.open_project_in_new_window(root .. "/Replacement")) end
  end
  local view = core.active_view
  save(name .. "-ready-" .. pid, {pid=pid, shell_pid=system.get_window_process_id(),
   window_id=system.get_anvil_window_id(), active=view and view.buffer and view.buffer.abs_filename})
 end)
end
