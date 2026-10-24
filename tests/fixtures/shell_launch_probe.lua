-- mod-version:3
-- Seam: external `anvil --shell` launches on isolated owned Windows. A launch reaches the running shell for its
-- executable and user directory, and never starts a duplicate Project runtime.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if not action or not action:match("^launch%-") then return end
local core, common = require "core", require "core.common"
local ffi = require "ffi"
ffi.cdef [[
 unsigned long __stdcall GetCurrentProcessId(void);
 int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
 unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
 void * __stdcall GetPropW(void *, const wchar_t *);
 int __stdcall IsIconic(void *);
 int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
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
 error(message or "shell launch probe timed out")
end
local function trace()
 local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
 local text = file:read("*a"); file:close(); return text
end
-- Each Project runtime writes its own ready record, so duplicate runtimes stay visible.
local function ready(name)
 local found = {}
 for _, file in ipairs(system.list_dir(root) or {}) do
  local pid = file:match("^" .. name .. "%-ready%-(%d+)%.lua$")
  if pid then found[#found + 1] = load(name .. "-ready-" .. pid) end
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
local function quit() core.exit(function() core.quit_request = true end, true) end
local names = {[root .. "/Project"] = "a", [root .. "/Replacement"] = "b", [root .. "/user/scratch"] = "s"}

if path:match("/driver$") then
 core.add_background_thread(function()
  local launched, handles = {}, {}
  local options = {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}
  local function launch(target, extra)
   local item = assert(require("core.process").start({EXEFILE, "--shell", target},
    common.merge(options, extra or {})))
   launched[#launched + 1] = item; return item
  end
  local function open(pid)
   local handle = assert(kernel.OpenProcess(0x1F0FFF, 0, pid)); handles[#handles + 1] = handle; return handle
  end
  local function running(handle) return kernel.WaitForSingleObject(handle, 0) == 258 end
  local function exits(item, seconds, label)
   wait(function() return not item:running() end, seconds, label .. " launcher did not exit")
   return item:returncode()
  end
  local function controls(window, label)
   user32.PostMessageW(window, 0x112, 0xf020, 0)
   wait(function() return user32.IsIconic(window) ~= 0 end, 3, label .. " native Minimize was blocked")
   user32.PostMessageW(window, 0x112, 0xf120, 0)
   wait(function() return user32.IsIconic(window) == 0 end, 3, label .. " native Restore was blocked")
  end
  -- Closes every Window of `item`. The last Window Close ends that shell through the normal shutdown.
  local function close_shell(item, label)
   for _, window in pairs(windows(item:pid())) do user32.PostMessageW(window, 0x10, 0, 0) end
   wait(function() return not item:running() end, 15, label .. " Close did not end the shell")
   assert(item:returncode() == 0, label .. " shell ended with a failure")
  end
  local ok, err = pcall(function()
   if action == "launch-terminal-editor" then
    local shell = launch(root .. "/Project")
    wait(function() return ready("a")[1] end, 30)
    local result = wait(function() return load("terminal-editor") end, 45,
     "the Terminal launch did not complete")
    assert(result.ok, result.error)
    assert(#ready("a") == 1 and #ready("b") == 0, "Terminal launch loaded another Project")
    assert(select(2, windows(shell:pid())) == 1, "Terminal launch opened another Window")
    return close_shell(shell, "Terminal editor")
   end

   if action == "launch-terminal-move" then
    -- Project moves its Terminal to Replacement. An `anvil` file launch in it then opens in Replacement.
    local shell = launch(root .. "/Project")
    local a = wait(function() return ready("a")[1] end, 30)
    assert(exits(launch(root .. "/Replacement"), 20, "second Project") == 0, "second Project launch failed")
    local b = wait(function() return ready("b")[1] end, 30, "second Project did not load")
    assert(a.window_id == b.window_id, "second Project opened in another Window")
    local result = wait(function() return load("terminal-move") end, 90, "the Terminal move did not complete")
    assert(result.ok, result.error)
    assert(#ready("a") == 1 and #ready("b") == 1, "the Terminal move started a duplicate Project runtime")
    return close_shell(shell, "Terminal move")
   end

   if action == "launch-forward" then
    local shell = launch(root .. "/Project")
    local a = wait(function() return ready("a")[1] end, 20)
    local aw = assert(windows(shell:pid())[a.window_id])
    user32.PostMessageW(aw, 0x112, 0xf020, 0)
    wait(function() return user32.IsIconic(aw) ~= 0 end, 3)
    -- A junction alias with a trailing separator names the loaded Project. It raises the owning Window.
    local alias = launch(root .. "/alias/")
    assert(exits(alias, 20, "aliased") == 0, "aliased launch failed")
    wait(function() return user32.IsIconic(aw) == 0 end, 5, "aliased launch did not raise the minimized owner")
    assert(trace():find("Shell launch foreground grant to pid=" .. shell:pid(), 1, true),
     "launcher did not grant foreground permission before its raise request")
    assert(#ready("a") == 1, "aliased launch started a duplicate Project runtime")
    controls(aw, "Window A after a forwarded launch")
    -- A new Project opens in the Window that the user used last. A relative path uses the launcher's directory.
    local other = launch("Replacement", {cwd=root})
    assert(exits(other, 20, "new Project") == 0, "new Project launch failed")
    local b = wait(function() return ready("b")[1] end, 20, "forwarded launch did not load its Project")
    assert(b.shell_pid == shell:pid(), "new Project did not load in the running shell")
    assert(b.window_id == a.window_id, "new Project did not open in the Window used last")
    local _, count = windows(shell:pid()); assert(count == 1, "new Project opened another Window")
    -- A repeated launch of the second Project selects it again without a second runtime.
    assert(exits(launch(root .. "/REPLACEMENT"), 20, "repeated") == 0, "repeated launch failed")
    assert(#ready("b") == 1 and select(2, windows(shell:pid())) == 1, "repeated launch duplicated its Project")
    return close_shell(shell, "forwarded")
   end

   if action == "launch-files" then
    -- Files open in new Panes of the deepest known Project that contains them, in the Window used last.
    -- The runner lists Project and Replacement as recent Projects.
    assert(common.mkdirp(root .. "/Project/sub") and common.mkdirp(root .. "/Replacement/deep")
     and common.mkdirp(root .. "/Loose"))
    local inner, new, deep = root .. "/Project/sub/inner.txt", root .. "/Project/sub/new.txt",
     root .. "/Replacement/deep/deep.txt"
    local loose = root .. "/Loose/loose.txt"
    for _, name in ipairs {inner, deep, loose} do
     local file = assert(io.open(name, "wb")); file:write("on disk\n"); file:close()
    end
    local function opened(name, path)
     wait(function() local files = load(name .. "-files"); return files and files[path:lower()] end, 20,
      "Project " .. name .. " did not open " .. path)
    end
    local shell = launch(root .. "/Project")
    local a = wait(function() return ready("a")[1] end, 30)
    -- A loaded Project opens a file from its subfolder, and a new file there. No Project starts at the subfolder.
    assert(exits(launch(inner), 20, "subfolder file") == 0, "subfolder file launch failed")
    opened("a", inner)
    assert(exits(launch(new), 20, "new file") == 0, "new file launch failed")
    opened("a", new)
    -- A known Project that is not loaded starts at its root, in the same Window.
    assert(exits(launch(deep), 20, "known Project file") == 0, "known Project file launch failed")
    local b = wait(function() return ready("b")[1] end, 30, "file launch did not start its known Project")
    opened("b", deep)
    assert(b.window_id == a.window_id, "known Project did not open in the Window used last")
    -- A file that no known Project contains opens in the Scratch Project, in the same Window.
    assert(exits(launch(loose), 20, "loose file") == 0, "loose file launch failed")
    local s = wait(function() return ready("s")[1] end, 30, "loose file did not open the Scratch Project")
    opened("s", loose)
    assert(s.window_id == a.window_id, "Scratch Project did not open in the Window used last")
    assert(#ready("a") == 1 and #ready("b") == 1 and #ready("s") == 1,
     "file launches started duplicate Project runtimes")
    assert(select(2, windows(shell:pid())) == 1, "file launches opened another Window")
    return close_shell(shell, "file launches")
   end

   if action == "launch-concurrent" then
    -- No shell runs yet. Concurrent launchers end with one shell and one runtime per Project.
    local items = {}
    for i = 1, 4 do items[i] = launch(root .. "/Project") end
    local a = wait(function() return ready("a")[1] end, 20)
    wait(function()
     local alive = 0; for _, item in ipairs(items) do if item:running() then alive = alive + 1 end end
     return alive == 1
    end, 20, "concurrent launchers did not leave exactly one shell")
    local shell
    for _, item in ipairs(items) do
     if item:running() then shell = item else assert(item:returncode() == 0, "a concurrent launch failed") end
    end
    assert(a.shell_pid == shell:pid(), "Project loaded outside the remaining shell")
    coroutine.yield(1)
    assert(#ready("a") == 1, "concurrent launches started duplicate Project runtimes")
    assert(select(2, windows(shell:pid())) == 1, "concurrent launches opened duplicate Windows")
    return close_shell(shell, "concurrent")
   end

   if action == "launch-stale" then
    -- An ended shell leaves an abandoned record. The next launch becomes the shell.
    local first = launch(root .. "/Project")
    local a = wait(function() return ready("a")[1] end, 20)
    local child = open(a.pid)
    assert(kernel.TerminateProcess(open(first:pid()), 9) ~= 0)
    wait(function() return not first:running() end, 5)
    kernel.TerminateProcess(child, 9)
    local second = launch(root .. "/Replacement")
    local b = wait(function() return ready("b")[1] end, 20, "launch after a stale shell did not load its Project")
    assert(second:running() and b.shell_pid == second:pid(), "launch after a stale shell did not become the shell")
    return close_shell(second, "replacement")
   end

   if action == "launch-hung" then
    -- A shell that cannot answer fails the launch within its bound. No second shell starts.
    local shell = launch(root .. "/Project")
    local a = wait(function() return ready("a")[1] end, 20)
    local handle = open(shell:pid())
    assert(ntdll.NtSuspendProcess(handle) >= 0)
    local started = system.get_time()
    local late = launch(root .. "/Replacement")
    local code = exits(late, 25, "hung shell")
    ntdll.NtResumeProcess(handle)
    assert(code ~= 0, "launch reported success from a hung shell")
    assert(system.get_time() - started < 20, "launch to a hung shell exceeded its bound")
    assert(#ready("b") == 0, "launch to a hung shell started its Project elsewhere")
    controls(assert(windows(shell:pid())[a.window_id]), "Window A after a resumed shell")
    return close_shell(shell, "resumed")
   end

   if action == "launch-link" then
    -- C:\Projects can be a link to D:\Projects. A launch through a link to the app reaches the running shell.
    local shell = launch(root .. "/Project")
    wait(function() return ready("a")[1] end, 20)
    local linked = assert(require("core.process").start(
     {os.getenv("ANVIL_PROBE_LINKED_EXE"), "--shell", root .. "/Replacement"}, options))
    launched[#launched + 1] = linked
    assert(exits(linked, 20, "linked") == 0, "linked launch failed")
    local b = wait(function() return ready("b")[1] end, 20, "linked launch did not load its Project")
    assert(b.shell_pid == shell:pid(), "linked launch started a second shell")
    return close_shell(shell, "linked")
   end

   if action == "launch-handoff" then
    -- An instance outside this shell shows Project. Selecting Project in a shell Window raises that
    -- instance. The Window keeps its other Project.
    local direct = assert(require("core.process").start({EXEFILE, "--direct", root .. "/Project"}, options))
    launched[#launched + 1] = direct
    wait(function() return ready("a")[1] end, 20, "direct instance did not load Project")
    local shell = launch(root .. "/Replacement")
    local b = wait(function() return ready("b")[1] end, 20)
    local exits_before = select(2, trace():gsub("Anvil shell surface process exited", ""))
    save("select", {path = root .. "/Project"})
    wait(function() return select(2, trace():gsub("Anvil shell surface process exited", "")) > exits_before end,
     20, "hand-off Project did not exit")
    coroutine.yield(2)
    assert(shell:running(), "hand-off ended the shell")
    assert(kernel.WaitForSingleObject(open(b.pid), 0) == 258, "hand-off closed the Window's other Project")
    assert(select(2, windows(shell:pid())) == 1, "hand-off closed the Window")
    assert(direct:running(), "hand-off ended the instance that shows Project")
    assert(#ready("a") == 1, "hand-off started a duplicate Project runtime")
    return close_shell(shell, "hand-off")
   end

   if action == "launch-userdir" then
    -- Another user directory has its own shell, even for the same Project.
    local shell = launch(root .. "/Project")
    wait(function() return ready("a")[1] end, 20)
    local other = launch(root .. "/Project", {env={ANVIL_USERDIR=root .. "/user2"}})
    wait(function() return #ready("a") == 2 end, 20, "another user directory did not get its own shell")
    assert(shell:running() and other:running(), "user directories shared one shell")
    close_shell(other, "second user directory")
    return close_shell(shell, "first user directory")
   end
   error("unknown shell launch probe " .. action)
  end)
  local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
  file:write("return ", common.serialize{ok=ok, error=ok and nil or tostring(err), action=action}); file:close()
  for _, handle in ipairs(handles) do ntdll.NtResumeProcess(handle) end
  for _, item in ipairs(launched) do
   if item:running() then item:terminate(); item:wait(1) end
  end
  for _, name in ipairs({"a", "b", "s"}) do
   for _, record in ipairs(ready(name)) do
    local handle = kernel.OpenProcess(0x1F0FFF, 0, record.pid)
    if handle ~= nil then kernel.TerminateProcess(handle, 9); kernel.CloseHandle(handle) end
   end
  end
  for _, handle in ipairs(handles) do kernel.CloseHandle(handle) end
  quit()
 end)
elseif names[path] then
 local pid = tonumber(kernel.GetCurrentProcessId())
 core.add_background_thread(function()
  coroutine.yield(.2)
  save(names[path] .. "-ready-" .. pid, {pid=pid, shell_pid=system.get_window_process_id(),
   window_id=system.get_anvil_window_id()})
  if action == "launch-terminal-editor" and names[path] == "a" then
   local terminal, panes = require "plugins.terminal", require "core.panes"
   local Editor = require "core.editor"
   local view
   local ok, err = pcall(function()
    wait(function() return trace():find("Shell Project runtime ready:", 1, true) end, 20)
    view = terminal.open {cwd=path, shell="powershell.exe -NoLogo -NoProfile", focus=true}
    wait(function() return view.state == "running" and view.busy == false end, 20)
    local pane, session = panes.active(), view.session
    local function quote(text) return "'" .. text:gsub("'", "''") .. "'" end
    local function output(marker)
     return ("\n" .. view.session:text_capture().text:gsub("\r", "") .. "\n"):find("\n" .. marker .. "\n", 1, true)
    end
    -- Match the user's PowerShell function. Change directory outside the Project before the bare launch.
    assert(view:write_input("function anvil { & " .. quote(EXEFILE) .. " @args }; Set-Location " ..
     quote(root .. "/Replacement") .. "; Write-Output 'ANVIL_SETUP_DONE'\r"))
    wait(function() return output("ANVIL_SETUP_DONE") end, 10)
    for attempt = 1, 2 do
     assert(view:write_input("anvil\r"))
     wait(function()
      return core.active_view ~= view
     end, 20, "bare anvil did not open an Editor: " .. view.session:text_capture().text)
     assert(core.active_view:is(Editor) and not core.active_view.buffer.abs_filename,
      "launch did not focus an Untitled Editor")
     assert(view.busy == false, "launch opened an Editor before the command ended")
     assert(view.session == session and view.state == "running", "launch closed the Terminal Session")
     assert(panes.close(panes.active()))
     assert(panes.focus(pane))
     assert(pane.current_view == view, "launch did not retain the Terminal")
    end
    -- File arguments use the Terminal's Project, but resolve from its changed directory.
    local filename = root .. "/Replacement/terminal file.txt"
    local file = assert(io.open(filename, "wb")); file:write("from the Terminal\n"); file:close()
    assert(view:write_input("anvil './terminal file.txt' './new file.txt'\r"))
    wait(function() return core.active_view ~= view end, 20,
     "file arguments did not open an Editor in the originating Project")
    assert(core.active_view:is(Editor), "file launch did not focus an Editor")
    assert(core.active_view.buffer.abs_filename:gsub("\\", "/") == root .. "/Replacement/new file.txt",
     "file launch did not resolve the new file from the Terminal directory")
    assert(core.buffer_registry:find(filename), "file launch did not open the existing file")
    assert(view.busy == false, "file launch opened an Editor before the command ended")
    assert(view.session == session and view.state == "running", "file launch closed the Terminal Session")
    assert(core.root_project().path:gsub("\\", "/") == path, "file launch changed the Project")
    -- Save the new file so the isolated shell can close without a save prompt.
    core.active_view.buffer:save()
    assert(panes.focus(pane))
    assert(pane.current_view == view, "file launch did not retain the Terminal")
    -- An explicit CLI argument must keep its normal behavior.
    assert(view:write_input("anvil --version; Write-Output 'ANVIL_ARGS_DONE'\r"))
    wait(function() return output("ANVIL_ARGS_DONE") end, 15)
    assert(pane.current_view == view, "a CLI argument opened an Untitled Editor")
   end)
   if view then view:on_close() end
   save("terminal-editor", {ok=ok, error=ok and nil or tostring(err)})
  end
  if action == "launch-terminal-move" then
   local terminal, panes = require "plugins.terminal", require "core.panes"
   local function record(id)
    local text = require("terminal_native").read_session_record(id)
    return text and assert(loadstring(text))()
   end
   local function output(view, marker)
    return ("\n" .. view.session:text_capture().text:gsub("\r", "") .. "\n"):find("\n" .. marker .. "\n", 1, true)
   end
   local function scans() return select(2, trace():gsub("Shell Sidebar status scan started", "")) end
   local view
   local ok, err = pcall(function()
    wait(function() return trace():find("Shell Project runtime ready:", 1, true) end, 20)
    if names[path] == "a" then
     view = terminal.open {cwd=path, shell="powershell.exe -NoLogo -NoProfile", focus=true}
     wait(function() return view.state == "running" and view.busy == false end, 20, "the Terminal did not start")
     local function quote(text) return "'" .. text:gsub("'", "''") .. "'" end
     assert(view:write_input("function anvil { & " .. quote(EXEFILE) .. " @args }; Write-Output 'ANVIL_SETUP_DONE'\r"))
     wait(function() return output(view, "ANVIL_SETUP_DONE") end, 10)
     wait(function() local r = record(view.session_id); return r and r.movable end, 10, "the host is not movable")
     wait(function() return ready("b")[1] end, 30)
     local pane, id = panes.pane_for_view(view), view.session_id
     save("terminal-move-id", {id=id})
     assert(require("core.pane_transfer").perform {action="export", pane=pane.id, to=root .. "/Replacement",
      transfer="probe-terminal-move", target={mode="group"}})
     wait(function() return not panes.find(pane.id) end, 30, "the source kept the moved Pane")
     view = nil
     return
    end
    local id = wait(function() local moved = load("terminal-move-id"); return moved and moved.id end, 60)
    view = wait(function()
     for _, pane in ipairs(panes.ordered()) do
      for _, candidate in ipairs(panes.views(pane)) do
       if candidate.session_id == id then return candidate end
      end
     end
    end, 30, "Replacement did not receive the Terminal")
    wait(function() return view.state == "running" end, 20, "the moved Terminal did not attach")
    wait(function() return common.path_equals(record(id).project_path, path) end, 20,
     "the host did not record Replacement")
    -- The shell routes by the Sidebar's Terminal list. Each command start and end rewrites the record, and a
    -- scan starts only after the last one ends, so the second new scan follows a complete one.
    local before = scans()
    assert(view:write_input("Write-Output 'ANVIL_MOVE_SYNC'\r"))
    wait(function() return output(view, "ANVIL_MOVE_SYNC") and scans() >= before + 2 end, 20,
     "the Sidebar did not scan the moved record")
    assert(view:write_input("anvil './moved file.txt'\r"))
    wait(function() return core.active_view ~= view end, 20, "the file launch did not open in Replacement")
    local Editor = require "core.editor"
    assert(core.active_view:is(Editor), "the file launch did not focus an Editor")
    assert(core.active_view.buffer.abs_filename:gsub("\\", "/") == root .. "/Project/moved file.txt",
     "the file launch did not resolve from the Terminal directory")
    core.active_view.buffer:save()
    assert(view.state == "running", "the file launch closed the moved Terminal Session")
   end)
   if view then view:on_close() end
   if names[path] == "b" or not ok then save("terminal-move", {ok=ok, error=ok and nil or tostring(err)}) end
  end
  if action == "launch-files" then
   -- Report each opened file. Save new files so the isolated shell can close without a save prompt.
   local reported = -1
   while true do
    local files, count = {}, 0
    for _, buffer in ipairs(core.buffers) do
     if buffer.abs_filename then
      if not system.get_file_info(buffer.abs_filename) then buffer:save() end
      files[buffer.abs_filename:gsub("\\", "/"):lower()] = true
      count = count + 1
     end
    end
    if count ~= reported then save(names[path] .. "-files", files); reported = count end
    coroutine.yield(.1)
   end
  end
  if action == "launch-handoff" and names[path] == "b" then
   local request = wait(function() return load("select") end, 30)
   assert(system.select_project(request.path), "Replacement could not select Project")
  end
 end)
end
