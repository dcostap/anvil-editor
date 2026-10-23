-- mod-version:3
-- Seam: native Window Close and native controls on isolated owned Windows, with real Project Close choices.
-- Window A holds Project and Other; Window B holds Replacement.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if not action or not action:match("^windows%-close") then return end
local dirty = action == "windows-close-dirty" or action == "windows-close-cleanup-cancel"
local core, common = require "core", require "core.common"
local command = require "core.command"
local ffi = require "ffi"
ffi.cdef [[
 unsigned long __stdcall GetCurrentProcessId(void);
 int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
 unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
 void * __stdcall GetPropW(void *, const wchar_t *);
 int __stdcall IsWindowVisible(void *);
 int __stdcall IsIconic(void *);
 int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
 void * __stdcall GetWindow(void *, unsigned int);
 int __stdcall GetWindowTextW(void *, wchar_t *, int);
 void * __stdcall OpenProcess(unsigned long, int, unsigned long);
 unsigned long __stdcall WaitForSingleObject(void *, unsigned long);
 int __stdcall TerminateProcess(void *, unsigned int);
 int __stdcall CloseHandle(void *);
 long __stdcall NtSuspendProcess(void *);
 long __stdcall NtResumeProcess(void *);
]]
local user32, kernel, ntdll = ffi.load("user32"), ffi.load("kernel32"), ffi.load("ntdll")
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
 error(message or "Window Close probe timed out")
end
local function trace()
 local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
 local text = file:read("*a"); file:close(); return text
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
local function dialog(pid, title)
 local found
 local cb = ffi.cast("int (__stdcall *)(void *, intptr_t)", function(window)
  local owner = ffi.new("unsigned long[1]"); user32.GetWindowThreadProcessId(window, owner)
  if tonumber(owner[0]) == pid and user32.IsWindowVisible(window) ~= 0 then
   local text = ffi.new("wchar_t[128]"); local length = user32.GetWindowTextW(window, text, 128)
   local label = {}; for i=0,length-1 do label[#label+1] = string.char(text[i] < 128 and text[i] or 63) end
   if table.concat(label) == title then found = window; return 0 end
  end
  return 1
 end)
 user32.EnumWindows(cb, 0); cb:free(); return found
end
local function quit() core.exit(function() core.quit_request = true end, true) end
local names = {[root .. "/Project"] = "a", [root .. "/Replacement"] = "b", [root .. "/Other"] = "c"}

if path:match("/driver$") then
 core.add_background_thread(function()
  local subject
  local handles = {}
  local ok, err = pcall(function()
   subject = assert(require("core.process").start({EXEFILE,"--shell",root .. "/Project"}, {
    stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
   local a = wait(function() return load("a-ready") end, 20)
   local b = wait(function() return load("b-ready") end, 20)
   local shell = a.shell_pid
   local function open(pid)
    local handle = assert(kernel.OpenProcess(0x1F0FFF, 0, pid)); handles[#handles+1] = handle; return handle
   end
   local function running(handle) return kernel.WaitForSingleObject(handle, 0) == 258 end
   local function count() local _, n = windows(shell); return n end
   local all = windows(shell); local aw, bw = assert(all[a.window_id]), assert(all[b.window_id])
   local pa, pb = open(a.pid), open(b.pid)
   -- Native controls of a Window must not wait for any Project.
   local function controls(window, label)
    user32.PostMessageW(window, 0x112, 0xf020, 0)
    wait(function() return user32.IsIconic(window) ~= 0 end, 3, label .. " native Minimize was blocked")
    user32.PostMessageW(window, 0x112, 0xf120, 0)
    wait(function() return user32.IsIconic(window) == 0 end, 3, label .. " native Restore was blocked")
   end
   local function new_window(window, label)
    local before = count()
    user32.PostMessageW(window, 0x112, 0xe010, 0)
    wait(function() return count() == before + 1 end, 5, label .. " native New Window was blocked")
    for id, item in pairs(windows(shell)) do
     if id ~= a.window_id and id ~= b.window_id then user32.PostMessageW(item, 0x10, 0, 0) end
    end
    wait(function() return count() == before end, 5, "empty Window Close was blocked")
   end
   local function finish_b()
    assert(not load("nag-b-1"), "Window A Close asked Window B's Project")
    assert(running(pb) and subject:running(), "Window A Close ended Window B's Project or the shell")
    assert(count() == 1 and windows(shell)[b.window_id], "Window A Close removed the wrong Window")
    controls(bw, "Window B")
    -- The last Window Close ends the shell through the normal shutdown.
    user32.PostMessageW(bw, 0x10, 0, 0)
    if dirty then
     wait(function() return load("nag-b-1") end, 8, "last Window Close did not ask its dirty Project")
     save("answer-b-1", "discard")
    end
    wait(function() return not subject:running() end, 15, "last Window Close did not end the shell")
    assert(subject:returncode() == 0, "last Window Close ended the shell with a failure")
   end

   if action == "windows-close-launch" then
    -- Other's launch worker is paused. Window A Close must wait for it, then close Other and Project.
    wait(function() return trace():find("Shell paused the owned Project launch worker", 1, true) end, 10)
    controls(aw, "Window A")
    user32.PostMessageW(aw, 0x10, 0, 0)
    wait(function() return not running(pa) end, 20, "Window A Close did not close Project after a pending launch")
    wait(function() return count() == 1 end, 20, "Window A Close did not finish after a pending launch")
    for pid in trace():gsub("\\", "/"):gmatch("Shell started Project pid=(%d+) path=[^\r\n]+/Other[\r\n]") do
     assert(not running(open(tonumber(pid))), "Window A Close left the launched Project running")
    end
    return finish_b()
   end

   local c = wait(function() return load("c-ready") end, 20)
   assert(c.window_id == a.window_id, "Other did not load into Window A")
   local pc = open(c.pid)

   if action == "windows-close-update-disconnect" then
    -- Hold the selected Project alive while its transport fails. Its later exit
    -- must still complete the update, even without a final exit notification.
    assert(ntdll.NtSuspendProcess(pc) >= 0)
    local function request_update()
     local request = assert(require("core.process").start({EXEFILE, "--prepare-update"}, {
      stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
     wait(function() return not request:running() end, 10, "update request did not return")
     assert(request:returncode() == 0, "shell rejected the update request")
    end
    request_update()
    user32.PostMessageW(aw, 0x804b, 8, 0) -- Break only this owned Project's pipe.
    wait(function() return trace():find("Shell connection failed: pipe connection ended", 1, true) end,
     10, "Project transport did not fail")
    request_update()
    assert(running(pc), "update retry killed a Project that had not finished")
    local warning = wait(function() return dialog(shell, "Anvil - Project not responding") end,
     15, "connection loss removed the pending Close's Wait choice")
    assert(user32.GetWindow(warning, 4) == aw, "Close warning used the wrong Window")
    user32.PostMessageW(warning, 0x466, 7, 0) -- TaskDialog Wait
    user32.PostMessageW(warning, 0x111, 7, 0) -- MessageBox fallback
    wait(function() return trace():find("Shell close timeout: Wait selected", 1, true) end, 5)
    assert(running(pc), "Wait ended the disconnected Project")
    assert(ntdll.NtResumeProcess(pc) >= 0)
    wait(function() return not running(pc) end, 30, "disconnected Project did not finish shutdown")
    wait(function() return not subject:running() end, 30, "update stopped after the disconnected Project exited")
    assert(not running(pa) and not running(pb), "update left another Project running")
    assert(subject:returncode() == 0, "update ended the shell with a failure")
    return
   end

   if action == "windows-close-cleanup-unload" then
    save("unload-c", true)
    wait(function() return load("cleanup-c") end, 10, "Other did not reach cleanup")
    wait(function()
     local text = ffi.new("wchar_t[128]")
     local length = user32.GetWindowTextW(aw, text, 128)
     local label = {}; for i=0,length-1 do label[#label+1] = string.char(text[i] < 128 and text[i] or 63) end
     return table.concat(label) == "Project"
    end, 5, "Unload kept the closing Project selected during cleanup")
    assert(running(pc) and running(pa), "Unload ended a Project before the cleanup check")
    assert(user32.IsWindowVisible(aw) ~= 0, "Project unload hid its Window")
    save("release-cleanup", true)
    wait(function() return not running(pc) end, 10)
    user32.PostMessageW(aw, 0x10, 0, 0)
    wait(function() return count() == 1 end, 10)
    return finish_b()
   end

   if action == "windows-close-cleanup" then
    user32.PostMessageW(aw, 0x10, 0, 0)
    wait(function() return load("cleanup-c") end, 10, "Other did not reach cleanup")
    wait(function() return load("cleanup-a") end, 5, "Window Close waited for Other's cleanup before closing Project")
    wait(function() return user32.IsWindowVisible(aw) == 0 end, 5, "Window stayed visible during cleanup")
    assert(running(pa) and running(pc), "cleanup fixture did not keep both Projects alive")
    assert(user32.IsWindowVisible(bw) ~= 0 and running(pb), "Close hid or ended the other Window")
    save("release-cleanup", true)
    wait(function() return count() == 1 end, 10, "Window cleanup did not finish")
    return finish_b()
   end

   if dirty then
    -- Window A selects Other. Close asks it first, then Project. Cancel stops the remaining Close requests.
    user32.PostMessageW(aw, 0x10, 0, 0)
    wait(function() return load("nag-c-1") end, 8, "Window A Close did not ask its selected dirty Project")
    assert(not load("nag-a-1"), "Window A Close asked two Projects at once")
    save("answer-c-1", "discard")
    if action == "windows-close-cleanup-cancel" then
     wait(function() return load("cleanup-c") end, 8, "Other did not reach cleanup")
    else
     wait(function() return not running(pc) end, 8, "accepted Close did not end Other")
    end
    wait(function() return load("nag-a-1") end, 8, "Window A Close did not ask its next dirty Project")
    save("answer-a-1", "cancel")
    wait(function() return load("cancelled-a-1") end, 5)
    coroutine.yield(1)
    assert(not load("nag-a-2"), "Cancel did not stop Window A's later Close requests")
    assert(running(pa) and count() == 2, "Cancel ended Project or removed Window A")
    if action == "windows-close-cleanup-cancel" then
     assert(running(pc), "cleanup fixture ended before cancellation")
     assert(user32.IsWindowVisible(aw) ~= 0, "Close hid a Window with a cancelled Project")
     save("release-cleanup", true)
     wait(function() return not running(pc) end, 8)
     coroutine.yield(.5)
     assert(not load("nag-a-2") and running(pa), "completed cleanup restarted the cancelled Window Close")
    end
    assert(not running(pc), "Cancel revived an accepted Close")
    assert(not load("nag-b-1") and running(pb), "Window A Close reached Window B")
    controls(aw, "Window A")
    user32.PostMessageW(aw, 0x10, 0, 0)
    wait(function() return load("nag-a-2") end, 8, "second Window A Close did not ask its dirty Project")
    save("answer-a-2", "discard")
    wait(function() return not running(pa) end, 8, "accepted Close did not end Project")
    wait(function() return count() == 1 end, 8, "Window A did not close after its last Project")
    return finish_b()
   end

   if action == "windows-close-hang" then
    assert(ntdll.NtSuspendProcess(pc) >= 0)
    controls(aw, "Window A with a hung Project")
    new_window(bw, "Window B with a hung Project in Window A")
    user32.PostMessageW(aw, 0x10, 0, 0)
    local warning = wait(function() return dialog(shell, "Anvil - Project not responding") end, 10,
     "Window A Close did not offer Wait or Force close for its hung Project")
    assert(user32.GetWindow(warning, 4) == aw, "hung Project warning used the wrong Window")
    controls(bw, "Window B during Window A's close warning")
    new_window(bw, "Window B during Window A's close warning")
    user32.PostMessageW(warning, 0x466, 6, 0) -- TaskDialog Force close
    user32.PostMessageW(warning, 0x111, 6, 0) -- MessageBox fallback
    wait(function() return not running(pc) end, 8, "Force close did not end the hung Project")
    wait(function() return not running(pa) end, 8, "Window A Close did not continue with Project")
    wait(function() return count() == 1 end, 8, "Window A did not close after Force close")
    return finish_b()
   end

   if action == "windows-close-crash" then
    assert(kernel.TerminateProcess(pc, 3) ~= 0)
    wait(function() return trace():find("Shell state: Failed Project=[1-9]") end, 10, "shell did not mark the crashed Project Failed")
    controls(aw, "Window A with a crashed Project")
    new_window(bw, "Window B with a crashed Project in Window A")
    user32.PostMessageW(aw, 0x10, 0, 0)
    wait(function() return not running(pa) end, 10, "Window A Close did not close Project after a crash")
    wait(function() return count() == 1 end, 10, "Window A did not close after a crashed Project")
    return finish_b()
   end

   if action == "windows-close-gpu" then
    -- Each Window owns its D3D11 device. A present failure in A must not reach B.
    user32.PostMessageW(aw, 0x804b, 5, 0)
    wait(function() return trace():find("Shell GPU failure", 1, true) end, 5, "present fault did not fail Window A")
    wait(function() return trace():find("Shell state: Failed Project=[1-9]") end, 5)
    controls(aw, "Window A after its GPU failure")
    new_window(bw, "Window B after Window A's GPU failure")
    local _, failures = trace():gsub("Shell GPU failure", "")
    local _, failed = trace():gsub("Shell state: Failed Project=[1-9]", "")
    assert(failures == 1 and failed == 1, "Window A's GPU failure reached another Window or Project")
    -- The failed connection belongs to A's selected Project only. That Project detaches through shell-loss handling.
    assert(running(pb) and running(pa), "GPU failure ended a Project outside its failed connection")
    user32.PostMessageW(aw, 0x10, 0, 0)
    wait(function() return not running(pa) and not running(pc) end, 10, "Window A Close did not close its Projects after a GPU failure")
    wait(function() return count() == 1 end, 10, "Window A did not close after its GPU failure")
    return finish_b()
   end

   if action == "windows-close-quit" then
    -- Quit inside a Project closes its assigned Window, including the Window's other Project.
    save("quit-c", true)
    wait(function() return not running(pc) end, 8, "Quit did not end its Project")
    wait(function() return not running(pa) end, 8, "Quit did not close the other Project in its Window")
    wait(function() return count() == 1 end, 8, "Quit did not close its assigned Window")
    return finish_b()
   end
   error("unknown Window Close probe " .. action)
  end)
  save("release-cleanup", true)
  local file=assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"),"wb"))
  file:write("return ",common.serialize{ok=ok,error=ok and nil or tostring(err),action=action}); file:close()
  for _, handle in ipairs(handles) do ntdll.NtResumeProcess(handle); kernel.CloseHandle(handle) end
  if subject and subject:running() then subject:terminate(); subject:wait(1) end
  quit()
 end)
elseif names[path] then
 local name = names[path]
 if (action == "windows-close-cleanup" and name ~= "b")
   or ((action == "windows-close-cleanup-cancel" or action == "windows-close-cleanup-unload") and name == "c") then
  -- Hold final destruction at the process boundary, after normal saves and exit intent.
  local guard = newproxy(true)
  getmetatable(guard).__gc = function()
   save("cleanup-" .. name, true)
   local deadline = system.get_time() + 20
   while not load("release-cleanup") and system.get_time() < deadline do system.sleep(.01) end
  end
  core.close_probe_guard = guard
 end
 core.add_background_thread(function()
  -- Let first-run Workspace setup finish before editing.
  coroutine.yield(.2)
  local editor
  if dirty then
   editor = core.open_file(path .. "/edited.txt"); core.set_active_view(editor)
   editor.buffer:insert(1, 1, "DIRTY_" .. name .. "_")
  end
  save(name .. "-ready", {pid=tonumber(kernel.GetCurrentProcessId()), shell_pid=system.get_window_process_id(),
   window_id=system.get_anvil_window_id()})
  if name == "a" then
   -- The paused launch worker serves the second Project, so select Other before opening Window B.
   assert(system.select_project(root .. "/Other"))
   assert(core.open_project_in_new_window(root .. "/Replacement"))
  end
  -- Answer each Close choice as the driver asks. Each choice is numbered per Project.
  local asked, pending = 0, false
  while true do
   if load("unload-" .. name) then command.perform("core:unload_project"); return end
   if load("quit-" .. name) then quit(); return end
   local visible = core.nag_view.visible and core.nag_view:get_title() == "Unsaved Changes"
   if visible and not pending then asked = asked + 1; pending = true; save("nag-" .. name .. "-" .. asked, true) end
   local answer = pending and load("answer-" .. name .. "-" .. asked)
   if answer then
    pending = false
    if answer == "discard" then
     command.perform("core:select_dialog_yes")
    else
     command.perform("core:select_dialog_no")
     wait(function() return not core.nag_view.visible end, 5)
     assert(editor.buffer:is_dirty(), "cancelled Close lost the unsaved edit")
     save("cancelled-" .. name .. "-" .. asked, true)
    end
   end
   coroutine.yield(.01)
  end
 end)
end
