-- mod-version:3
-- Seam: App State restore of Anvil Windows across shell runs, and adoption of running Projects after a shell
-- ends, on isolated owned Windows.
-- Each run records its Project runtimes, so restored, adopted, and duplicate runtimes stay visible.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if not action or not (action:match("^restore%-") or action:match("^adopt%-")) then return end
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
 unsigned long __stdcall WaitForSingleObject(void *, unsigned long);
 int __stdcall GetSystemMetrics(int);
 int __stdcall GetWindowRect(void *, ProbeRect *);
 void * __stdcall MonitorFromWindow(void *, unsigned long);
 typedef struct { unsigned long size; ProbeRect monitor, work; unsigned long flags; } ProbeMonitor;
 int __stdcall GetMonitorInfoW(void *, ProbeMonitor *);
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
 local file = io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb")
 if not file then return "" end
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
local function alive(pid)
 local handle = kernel.OpenProcess(0x100000, 0, pid) -- SYNCHRONIZE
 if handle == nil then return false end
 local running = kernel.WaitForSingleObject(handle, 0) == 258
 kernel.CloseHandle(handle); return running
end
-- Adoption records that Projects published after they lost their shell.
local function records()
 local found = {}
 for _, file in ipairs(system.list_dir(root .. "/user/adoption") or {}) do
  if file:match("%.record$") then found[#found + 1] = file end
 end
 return found
end
local names = {[root .. "/Project"] = "a", [root .. "/Replacement"] = "b", [root .. "/Other"] = "c"}
-- Cases that seed their own state file start without a first run.
local seeded = action == "restore-crash" or action == "restore-sequential" or action == "restore-argument"
 or action == "restore-loaded"
-- Writes the shell's Window state, front to back, before the first shell starts.
local function write_state(entries)
 local lines = {"anvil-shell-windows 2\n"}
 for i, item in ipairs(entries) do
  local folder = (root .. "/" .. item[5]):gsub("/", "\\")
  lines[#lines + 1] = string.format("window %d %d %d %d %d 0 %d %s\n", i, item[1], item[2], item[3], item[4], #folder,
   folder)
 end
 local file = assert(io.open(root .. "/user/shell-windows.state", "wb"))
 file:write(table.concat(lines)); file:close()
end

if path:match("/driver$") then
 core.add_background_thread(function()
  local launched = {}
  local options = {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD,
   cwd=root}
  local function launch(...)
   local item = assert(require("core.process").start({EXEFILE, "--shell", ...}, options))
   launched[#launched + 1] = item; return item
  end
  local function launch_userdir(userdir, ...)
   local item = assert(require("core.process").start({EXEFILE, "--shell", ...}, {stdin=options.stdin,
    stdout=options.stdout, stderr=options.stderr, cwd=root, env={ANVIL_USERDIR=userdir}}))
   launched[#launched + 1] = item; return item
  end
  -- Adopted records from one shell, by Project process.
  local function adopted(name, shell)
   for _, file in ipairs(system.list_dir(root) or {}) do
    local pid = file:match("^" .. name .. "%-adopted%-(%d+)%.lua$")
    local record = pid and load(name .. "-adopted-" .. pid)
    if record and record.shell_pid == shell then return record end
   end
  end
  local function controls(window, label)
   user32.PostMessageW(window, 0x112, 0xf020, 0) -- SC_MINIMIZE
   wait(function() return user32.IsIconic(window) ~= 0 end, 2, label .. ": Minimize did not respond")
   user32.PostMessageW(window, 0x112, 0xf120, 0) -- SC_RESTORE
   wait(function() return user32.IsIconic(window) == 0 end, 2, label .. ": Restore did not respond")
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
   if action == "restore-loaded" then
    local state = assert(io.open(root .. "/user/appstate.lua", "wb"))
    state:write("return ", common.serialize{recents={root .. "/Other"}}); state:close()
    local first = launch(root .. "/Project")
    local a = wait(function() return ready("a", first:pid())[1] end, 30)
    local b = wait(function() return ready("b", first:pid())[1] end, 30)
    assert(a.window_id == b.window_id, "Projects did not share one Window")
    close_shell(first, "first")
    local second = launch()
    local b2 = wait(function() return ready("b", second:pid())[1] end, 30, "Selected Project did not return")
    local a2 = wait(function() return ready("a", second:pid())[1] end, 30, "background Project did not return")
    assert(a2.window_id == b2.window_id and select(2, windows(second:pid())) == 1,
     "loaded Projects did not return to the same Window")
    assert(a2.active and a2.active:gsub("\\", "/"):match("/Project/edited%.txt$"),
     "background Project lost its Workspace")
    assert(#ready("a", second:pid()) == 1 and #ready("b", second:pid()) == 1, "restore duplicated a Project")
    local selected = wait(function() return load("loaded-selection-" .. second:pid()) end, 15)
    assert(selected.path == root .. "/Replacement", "restore changed the Selected Project")
    assert(selected.background_state == "ready", "restored background Project reports " .. tostring(selected.background_state))
    assert(selected.dormant == "dormant" and #ready("c", second:pid()) == 0, "restore loaded a Dormant Project")
    return close_shell(second, "restored")
   end
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
    -- Another Project opens in the restored Window, the Window used last.
    local third = launch("Replacement")
    local a3 = wait(function() return ready("a", third:pid())[1] end, 20, "restore did not load Project")
    local b3 = wait(function() return ready("b", third:pid())[1] end, 20, "argument did not load its Project")
    assert(a3.window_id == b3.window_id, "argument Project did not open in the restored Window")
    assert(select(2, windows(third:pid())) == 1, "restore with an argument opened another Window")
    return close_shell(third, "third")
   end
   if action == "restore-invalid" then
    -- A damaged state file opens one empty Window.
    local file = assert(io.open(root .. "/user/shell-windows.state", "wb"))
    file:write("anvil-shell-windows 1\nwindow 10 10\n"); file:close()
    local shell = launch()
    wait(function() return select(2, windows(shell:pid())) == 1 end, 20, "invalid state did not open one Window")
    assert(trace():find("Shell Window state is invalid", 1, true), "invalid state was not reported")
    return close_shell(shell, "invalid")
   end

   if action == "restore-missing" then
    -- A Window whose Project folder is gone stays open and empty, with a notice.
    write_state({{100, 100, 800, 600, "Project"}, {160, 160, 800, 600, "Gone"}})
    local shell = launch()
    local a = wait(function() return ready("a", shell:pid())[1] end, 20, "restore did not load Project")
    wait(function() return trace():find("Shell Window status: id=%d+ Project folder not found") end, 10,
     "missing Project folder showed no notice")
    local found, count = windows(shell:pid())
    assert(count == 2, "missing Project folder removed its Window")
    assert(found[a.window_id], "restored Project has no Window")
    assert(not trace():find("Shell state: Failed", 1, true), "missing Project folder showed a failed runtime")
    return close_shell(shell, "missing")
   end

   if action == "restore-offscreen" then
    -- A Window saved mostly on a monitor that is gone opens fully on a visible monitor.
    -- Windows itself only moves a Window that is completely off screen.
    local right = user32.GetSystemMetrics(76) + user32.GetSystemMetrics(78) -- virtual screen x + width
    write_state({{right - 150, 100, 900, 650, "Project"}})
    local shell = launch()
    local a = wait(function() return ready("a", shell:pid())[1] end, 20, "restore did not load Project")
    local window = assert(windows(shell:pid())[a.window_id])
    local rect, info = ffi.new("ProbeRect"), ffi.new("ProbeMonitor")
    info.size = ffi.sizeof(info)
    assert(user32.GetWindowRect(window, rect) ~= 0)
    assert(user32.GetMonitorInfoW(user32.MonitorFromWindow(window, 2), info) ~= 0)
    local w = info.work
    assert(rect.left >= w.left and rect.top >= w.top and rect.right <= w.right and rect.bottom <= w.bottom,
     string.format("restored Window is not on a visible monitor: %d,%d %d,%d work %d,%d %d,%d", rect.left, rect.top,
      rect.right, rect.bottom, w.left, w.top, w.right, w.bottom))
    return close_shell(shell, "offscreen")
   end

   if action == "restore-stagger" then
    -- Restored Projects start one at a time, frontmost first. A slow start does not hold the others for long,
    -- and native controls work in every Window meanwhile. The fault pauses Replacement's launch.
    write_state({{100, 100, 800, 600, "Project"}, {140, 140, 800, 600, "Replacement"}, {180, 180, 800, 600, "Other"}})
    local shell = launch()
    wait(function() return ready("c", shell:pid())[1] end, 20, "a slow restored Project held the next one")
    assert(#ready("b", shell:pid()) == 0, "the fault did not pause Replacement")
    for _, window in pairs(windows(shell:pid())) do
     user32.PostMessageW(window, 0x112, 0xf020, 0) -- SC_MINIMIZE
     wait(function() return user32.IsIconic(window) ~= 0 end, 2, "Minimize waited for the restore sequence")
     user32.PostMessageW(window, 0x112, 0xf120, 0) -- SC_RESTORE
     wait(function() return user32.IsIconic(window) == 0 end, 2, "Restore waited for the restore sequence")
    end
    assert(select(2, windows(shell:pid())) == 3, "restore did not return three Windows")
    wait(function() return ready("b", shell:pid())[1] end, 20, "restore did not load Replacement")
    local text = trace()
    local order = {}
    for rank in text:gmatch("Shell starts restored Project: Project=%d+ rank=(%d+)") do order[#order + 1] = rank end
    assert(table.concat(order, ",") == "0,1,2", "restored Projects did not start front to back: " ..
     table.concat(order, ","))
    local function started(name)
     return assert(text:find("Shell started Project pid=%d+ path=[^\n]*" .. name), name .. " did not start")
    end
    assert(started("Project") < started("Other") and started("Other") < started("Replacement"),
     "the slow Project did not let the next one start")
    return close_shell(shell, "stagger")
   end
   if action == "adopt-return" then
    -- A new shell takes back the running Projects in their saved Windows. Unsaved edits and Terminal Sessions
    -- stay live, because no Project restarts.
    local first = launch(root .. "/Project")
    local a = wait(function() return ready("a")[1] end, 20)
    local b = wait(function() return ready("b")[1] end, 20)
    local all = windows(first:pid())
    local aw, bw = assert(all[a.window_id]), assert(all[b.window_id])
    assert(user32.SetWindowPos(aw, nil, 120, 90, 900, 650, 0x14) ~= 0)
    assert(user32.SetWindowPos(bw, nil, 300, 200, 800, 600, 0x14) ~= 0)
    local saved_a, saved_b = placement(aw), placement(bw)
    written(2)
    kill(first:pid())
    wait(function() return not first:running() end, 5)
    wait(function() return #records() == 2 end, 10, "lost Projects did not publish adoption records")
    assert(alive(a.pid) and alive(b.pid), "a Project ended with its shell")
    local second = launch()
    local a2 = wait(function() return adopted("a", second:pid()) end, 30, "the new shell did not adopt Project")
    local b2 = wait(function() return adopted("b", second:pid()) end, 30, "the new shell did not adopt Replacement")
    assert(a2.pid == a.pid and b2.pid == b.pid, "adoption changed a Project process")
    local found, count = windows(second:pid())
    assert(count == 2, "adoption did not return both Windows")
    assert(a2.window_id ~= b2.window_id, "adopted Projects share one Window")
    assert(common.serialize(placement(assert(found[a2.window_id]))) == common.serialize(saved_a),
     "adopted Project is not in its saved Window")
    assert(common.serialize(placement(assert(found[b2.window_id]))) == common.serialize(saved_b),
     "adopted Replacement is not in its saved Window")
    assert(a2.dirty and a2.text == "unsaved on disk", "adoption lost the unsaved edit")
    local file = assert(io.open(root .. "/Project/edited.txt", "rb"))
    assert(file:read("*a") == "on disk\n", "shell loss saved the unsaved edit"); file:close()
    assert(a2.host_pid == a.host_pid and alive(a.host_pid), "adoption lost the Terminal Session")
    assert(#ready("a", second:pid()) == 0 and #ready("b", second:pid()) == 0, "adoption also started a runtime")
    wait(function() return #records() == 0 end, 5, "adopted Projects kept their records")
    -- The adopted Window works: native controls respond and the Project draws again.
    controls(found[a2.window_id], "adopted Window")
    return
   end

   if action == "adopt-timeout" then
    -- With no next shell, a lost Project waits for its period, then exits and removes its record.
    local first = launch(root .. "/Project")
    local a = wait(function() return ready("a")[1] end, 20)
    kill(first:pid())
    wait(function() return #records() == 1 end, 10, "lost Project did not publish an adoption record")
    wait(function() return not alive(a.pid) end, 20, "Project outlived its adoption period")
    assert(#records() == 0, "Project left its adoption record")
    assert(trace():find("No shell adopted this Project", 1, true), "Project did not report its period end")
    return
   end

   if action == "adopt-stale" then
    -- Stale or damaged records start nothing and do not delay startup.
    system.mkdir(root .. "/user/adoption")
    local folder = (root .. "/Project"):gsub("/", "\\")
    local function record(file, pid, created)
     local handle = assert(io.open(root .. "/user/adoption/" .. file, "wb"))
     handle:write(string.format("anvil-adoption 1\n%d %d 1 %d %s\n", pid, created, #folder, folder)); handle:close()
    end
    record("1000002-1.record", 1000002, 1) -- no such process
    record("driver-1.record", kernel.GetCurrentProcessId(), 1) -- a live process from another start time
    local junk = assert(io.open(root .. "/user/adoption/junk.record", "wb")); junk:write("junk"); junk:close()
    local started = system.get_time()
    local shell = launch(root .. "/Project")
    local a = wait(function() return ready("a", shell:pid())[1] end, 20, "stale records blocked startup")
    assert(system.get_time() - started < 15, "stale records delayed startup")
    assert(#records() == 0, "the shell kept stale records")
    local _, removed = trace():gsub("Shell removed a stale adoption record", "")
    assert(removed == 3, "the shell did not report each stale record")
    assert(select(2, windows(shell:pid())) == 1 and a.window_id, "stale records changed the Windows")
    return close_shell(shell, "stale")
   end

   if action == "adopt-hung" then
    -- A Project that does not answer ends, and the shell starts a new runtime. Its Windows respond meanwhile.
    local first = launch(root .. "/Project")
    local a = wait(function() return ready("a")[1] end, 20)
    kill(first:pid())
    wait(function() return #records() == 1 end, 10, "lost Project did not publish an adoption record")
    local second = launch()
    local window = wait(function() local found, count = windows(second:pid()); return count == 1 and next(found) and
     select(2, next(found)) end, 10, "the shell did not open the Window before adoption")
    assert(alive(a.pid), "the shell gave up on the Project too early")
    controls(window, "Window during adoption")
    local a2 = wait(function() return ready("a", second:pid())[1] end, 30, "the shell did not start a new runtime")
    assert(a2.pid ~= a.pid, "the new runtime reused the hung process")
    assert(not alive(a.pid), "the hung Project kept running beside its new runtime")
    assert(trace():find("did not accept adoption", 1, true), "the shell did not report the failed adoption")
    return close_shell(second, "hung")
   end

   if action == "adopt-userdir" then
    -- A shell for another user directory does not take this directory's Projects.
    local first = launch(root .. "/Project")
    local a = wait(function() return ready("a")[1] end, 20)
    kill(first:pid())
    wait(function() return #records() == 1 end, 10, "lost Project did not publish an adoption record")
    local other = launch_userdir(root .. "/user2", root .. "/Project")
    local a2 = wait(function() return ready("a", other:pid())[1] end, 20, "the other user directory did not start")
    assert(a2.pid ~= a.pid and not adopted("a", other:pid()), "another user directory adopted the Project")
    assert(alive(a.pid) and #records() == 1, "another user directory ended the Project")
    return close_shell(other, "other user directory")
   end
   error("unknown restore probe " .. action)
  end)
  local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
  file:write("return ", common.serialize{ok=ok, error=ok and nil or tostring(err), action=action}); file:close()
  for _, item in ipairs(launched) do if item:running() then item:terminate(); item:wait(1) end end
  for _, name in ipairs({"a", "b", "c"}) do
   for _, record in ipairs(ready(name)) do kill(record.pid); if record.host_pid then kill(record.host_pid) end end
  end
  quit()
 end)
elseif names[path] then
 local name, pid = names[path], tonumber(kernel.GetCurrentProcessId())
 core.add_background_thread(function()
  -- Let first-run Workspace setup or restore finish.
  coroutine.yield(1)
  if seeded and name == "a" and not load("a-seeded") then
   save("a-seeded", true)
   core.set_active_view(core.open_file(path .. "/edited.txt"))
   core.save_workspace()
   if action == "restore-loaded" then assert(core.open_project_in_same_window(root .. "/Replacement"))
   elseif action ~= "restore-argument" then assert(core.open_project_in_new_window(root .. "/Replacement")) end
  end
  local editor, session
  if action == "adopt-return" and name == "a" then
   local terminal = require "plugins.terminal"
   local term = terminal.open {cwd = path, shell = "cmd.exe /D /Q"}
   session = wait(function() return term.session and (term.session:stats().host_pid or 0) > 0 and term.session end,
    10, "Terminal Session did not start")
   editor = assert(core.open_file(path .. "/edited.txt"))
   editor.buffer:insert(1, 1, "unsaved ")
   assert(core.open_project_in_new_window(root .. "/Replacement"))
  end
  if action:match("^adopt%-") then
   local on_adopted = core.on_shell_adopted
   function core.on_shell_adopted(...)
    on_adopted(...)
    local lines = editor and editor.buffer.lines
    save(name .. "-adopted-" .. pid, {pid=pid, shell_pid=system.get_window_process_id(),
     window_id=system.get_anvil_window_id(), dirty=editor and editor.buffer:is_dirty(),
     text=lines and editor.buffer:get_text(1, 1, #lines, #lines[#lines]),
     host_pid=session and session:stats().host_pid})
   end
  end
  local view = core.active_view
  save(name .. "-ready-" .. pid, {pid=pid, shell_pid=system.get_window_process_id(),
   window_id=system.get_anvil_window_id(), active=view and view.buffer and view.buffer.abs_filename,
   host_pid=session and session:stats().host_pid})
  if action == "restore-loaded" and name == "a" and #ready("a") > 1 then
   wait(function() return ready("b", system.get_window_process_id())[1] end, 30)
   local previous = core.project_sidebar
   assert(core.request_project_sidebar(true))
   local model = wait(function() return core.project_sidebar ~= previous and core.project_sidebar end, 15)
   local selection = {}
   for _, project in ipairs(model) do
    local folder = project.path:gsub("\\", "/")
    if project.selected then selection.path = folder end
    if folder == root .. "/Project" then selection.background_state = project.state end
    if folder == root .. "/Other" then selection.dormant = project.state end
   end
   save("loaded-selection-" .. system.get_window_process_id(), selection)
  end
 end)
end
