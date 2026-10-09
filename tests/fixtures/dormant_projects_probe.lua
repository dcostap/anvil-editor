-- mod-version:3
-- Seam: explicit Project unload/load, Workspace restoration, and an owned Window.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if not action or not action:match("^dormant%-") then return end
local with_terminal = action:find("^dormant%-terminal") ~= nil
local crash_unload = action == "dormant-unload-crash" or action == "dormant-unload-restart"
local core = require "core"
local common = require "core.common"
local ffi = require "ffi"
ffi.cdef [[
  unsigned long __stdcall GetCurrentProcessId(void);
  void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
  unsigned long __stdcall WaitForSingleObject(void *process, unsigned long timeout);
  int __stdcall CloseHandle(void *handle);
  int __stdcall TerminateProcess(void *process, unsigned int code);
  long __stdcall NtSuspendProcess(void *process);
  long __stdcall NtResumeProcess(void *process);
  unsigned long __stdcall GetWindowThreadProcessId(void *window, unsigned long *pid);
  int __stdcall PostMessageW(void *window, unsigned int message, uintptr_t wparam, intptr_t lparam);
  int __stdcall IsIconic(void *window);
  int __stdcall EnumWindows(int (__stdcall *callback)(void *, intptr_t), intptr_t parameter);
  int __stdcall IsWindowVisible(void *window);
  int __stdcall GetWindowTextW(void *window, wchar_t *text, int size);
]]
local kernel, user32, ntdll = ffi.load("kernel32"), ffi.load("user32"), ffi.load("ntdll")
local root = assert(os.getenv("ANVIL_PROJECT_PROBE_ROOT"))
local function save(name, value)
  local file = assert(io.open(root .. "/" .. name .. ".lua", "wb"))
  file:write("return ", common.serialize(value)); file:close()
end
local function read(name)
  local file = io.open(root .. "/" .. name .. ".lua", "rb")
  if not file then return end
  local text = file:read("*a"); file:close()
  return assert(loadstring(text))()
end
local function wait_for(fn, seconds, message)
  local deadline = system.get_time() + seconds
  repeat
    local value = fn()
    if value then return value end
    coroutine.yield(.01)
  until system.get_time() > deadline
  error(message or "Dormant Project probe timed out")
end
local function quit() core.exit(function() core.quit_request = true end, true) end
local function state() return {pid = tonumber(kernel.GetCurrentProcessId()), shell_pid = system.get_window_process_id()} end
local function shell_window(pid)
  local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
  local text = file:read("*a"); file:close()
  local hex = text:match("shell%[" .. pid .. "%] Shell window hwnd=(%x+)")
  if not hex then return end
  local window = ffi.cast("void *", tonumber(hex, 16))
  local owner = ffi.new("unsigned long[1]")
  user32.GetWindowThreadProcessId(window, owner)
  assert(tonumber(owner[0]) == pid, "Window has the wrong owner")
  return window
end
local function owned_dialog(pid, title)
  local found
  local callback = ffi.cast("int (__stdcall *)(void *, intptr_t)", function(window)
    local owner = ffi.new("unsigned long[1]")
    user32.GetWindowThreadProcessId(window, owner)
    if tonumber(owner[0]) == pid and user32.IsWindowVisible(window) ~= 0 then
      local text = ffi.new("wchar_t[256]")
      local length = user32.GetWindowTextW(window, text, 256)
      local name = {}
      for i = 0, length - 1 do name[#name + 1] = string.char(tonumber(text[i]) < 128 and tonumber(text[i]) or 63) end
      if table.concat(name) == title then found = window; return 0 end
    end
    return 1
  end)
  user32.EnumWindows(callback, 0); callback:free()
  return found
end
local directory = core.root_project().path:gsub("\\", "/")
if directory:match("/driver$") then
  core.add_background_thread(function()
    local handles, subject, host_handle, suspended_handle = {}, nil, nil, nil
    local ok, err = pcall(function()
      local process = require "core.process"
      subject = assert(process.start({EXEFILE, "--shell", root .. "/Project"}, {
        stdin = process.REDIRECT_DISCARD, stdout = process.REDIRECT_DISCARD, stderr = process.REDIRECT_DISCARD}))
      local a = wait_for(function() return read("a-ready") end, 15)
      local ah = kernel.OpenProcess(0x100000, 0, a.pid); assert(ah ~= nil); handles[#handles + 1] = ah
      if action == "dormant-last" or action == "dormant-last-close" then
        save("unload-a", {continue = true})
        wait_for(function() return kernel.WaitForSingleObject(ah, 0) == 0 end, 12)
        assert(subject:running(), "Unloading the last Project closed the Window")
        local window = assert(shell_window(a.shell_pid))
        user32.PostMessageW(window, 0x112, 0xF020, 0)
        wait_for(function() return user32.IsIconic(window) ~= 0 end, 1)
        user32.PostMessageW(window, 0x112, 0xF120, 0)
        wait_for(function() return user32.IsIconic(window) == 0 end, 1)
        if action == "dormant-last-close" then
          user32.PostMessageW(window, 0x10, 0, 0)
          wait_for(function() return not subject:running() end, 5, "Native Close retained a Window with no loaded Project")
          return
        end
        user32.PostMessageW(window, 0x804c, 3, 0)
        local restored = wait_for(function() return read("a-restored") end, 15)
        assert(restored.pid ~= a.pid and restored.shell_pid == a.shell_pid, "Load replaced the Window or reused the unloaded process")
        assert(restored.text == "PERSIST_A_on disk" and restored.selection == "1,3,1,8", "Last Project load lost Workspace state")
        save("finish", {continue = true})
        wait_for(function() return not subject:running() end, 15)
        return
      end
      save("select-b", {continue = true})
      if action == "dormant-launch" then
        wait_for(function() return read("a-unload-requested") end, 5)
        local log = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
        local text = log:read("*a"); log:close()
        assert(text:find("Shell paused the owned Project launch worker", 1, true), "Launch delay was not armed")
        assert(not read("b-started"), "Unload did not run during pending launch")
        local window = wait_for(function() return shell_window(a.shell_pid) end, 5)
        user32.PostMessageW(window, 0x112, 0xF020, 0)
        wait_for(function() return user32.IsIconic(window) ~= 0 end, 1, "Minimize waited for pending unload launch")
        user32.PostMessageW(window, 0x112, 0xF120, 0)
        wait_for(function() return user32.IsIconic(window) == 0 end, 1, "Restore waited for pending unload launch")
      end
      local b = wait_for(function() return read(action == "dormant-launch" and "b-started" or "b-ready") or read("b-error") end, 15)
      assert(not read("b-error"), b.error)
      local bh = kernel.OpenProcess(action == "dormant-hang" and 0x100801 or (action == "dormant-crash" or crash_unload) and 0x100001 or 0x100000, 0, b.pid); assert(bh ~= nil); handles[#handles + 1] = bh
      if crash_unload then
        save("unload-b", {continue = true})
        wait_for(function() return read("b-close-held") end, 8)
        wait_for(function()
          local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
          local text = file:read("*a"); file:close()
          return text:find("Shell close decision: accepted", 1, true)
        end, 5, "B's Close was not accepted")
        assert(kernel.TerminateProcess(bh, 126) ~= 0)
        wait_for(function() return kernel.WaitForSingleObject(bh, 0) == 0 end, 5)
        wait_for(function()
          local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
          local text = file:read("*a"); file:close()
          return text:find("Project failed unexpectedly", 1, true)
        end, 5, "Crash after accepted unload did not leave B Failed")
        save("switch-a-after-crash", {continue = true})
        local resumed = wait_for(function() return read("a-resumed") end, 10)
        assert(resumed.pid == a.pid and kernel.WaitForSingleObject(ah, 0) == 258 and subject:running(),
          "Crash during unload changed A or the Window")
        if action == "dormant-unload-crash" then
          save("unload-failed-b", {continue = true})
          wait_for(function()
            local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
            local text = file:read("*a"); file:close()
            return text:find("Shell Project is Dormant: id=2", 1, true)
          end, 5, "Unload did not make Failed B Dormant")
          assert(kernel.WaitForSingleObject(ah, 0) == 258 and subject:running(), "Unloading Failed B ended A")
          save("finish", {continue = true})
          user32.PostMessageW(assert(shell_window(a.shell_pid)), 0x10, 0, 0)
        else
          save("load-b", {continue = true})
          wait_for(function() return read("a-selected-b-failure") end, 10)
          user32.PostMessageW(assert(shell_window(a.shell_pid)), 0x804c, 3, 0)
          local restored = wait_for(function() return read("b-restored") end, 15)
          assert(restored.pid ~= b.pid and restored.shell_pid == a.shell_pid, "Restart changed the Window")
          save("finish", {continue = true})
        end
        wait_for(function() return not subject:running() end, 15, "Restart then Quit did not close the Window")
        wait_for(function() return kernel.WaitForSingleObject(ah, 0) == 0 end, 5, "Window Quit retained A")
        return
      end
      if action == "dormant-background-quit" then
        save("quit-a", {continue = true})
        wait_for(function() return kernel.WaitForSingleObject(ah, 0) == 0 end, 8)
        local cancelled = wait_for(function() return read("b-window-cancelled") end, 8,
          "Background Project Quit did not check B")
        assert(cancelled.pid == b.pid and cancelled.dirty and cancelled.text == "UNSAVED_B_PERSIST_B_on disk",
          "Window Close Cancel changed B or its unsaved Buffer")
        assert(subject:running() and kernel.WaitForSingleObject(bh, 0) == 258, "Window Close Cancel ended B or the Window")
        save("finish", {continue = true})
        wait_for(function() return not subject:running() end, 15)
        return
      end
      if action == "dormant-hang" then
        assert(ntdll.NtSuspendProcess(bh) == 0)
        suspended_handle = bh
        save("switch-a-after-crash", {continue = true})
        local resumed = wait_for(function() return read("a-resumed") end, 10)
        assert(resumed.pid == a.pid and subject:running(), "B's hang replaced A or the Window")
        save("unload-hung-b", {continue = true})
        local warning = wait_for(function() return owned_dialog(a.shell_pid, "Anvil - Project not responding") end, 8)
        user32.PostMessageW(warning, 0x466, 7, 0); user32.PostMessageW(warning, 0x111, 7, 0)
        wait_for(function() return not owned_dialog(a.shell_pid, "Anvil - Project not responding") end, 3)
        assert(kernel.WaitForSingleObject(ah, 0) == 258 and kernel.WaitForSingleObject(bh, 0) == 258,
          "Wait ended a Project")
        local window = assert(shell_window(a.shell_pid))
        user32.PostMessageW(window, 0x112, 0xF020, 0)
        wait_for(function() return user32.IsIconic(window) ~= 0 end, 1, "A's native Minimize waited for hung B")
        user32.PostMessageW(window, 0x112, 0xF120, 0)
        wait_for(function() return user32.IsIconic(window) == 0 end, 1)
        warning = wait_for(function() return owned_dialog(a.shell_pid, "Anvil - Project not responding") end, 8)
        user32.PostMessageW(warning, 0x466, 6, 0); user32.PostMessageW(warning, 0x111, 6, 0)
        wait_for(function() return kernel.WaitForSingleObject(bh, 0) == 0 end, 5)
        assert(kernel.WaitForSingleObject(ah, 0) == 258 and subject:running(), "Force close ended A or the Window")
        save("b-crashed", {continue = true})
        save("load-b", {continue = true})
        local restored = wait_for(function() return read("b-restored") end, 15)
        assert(restored.pid ~= b.pid and restored.shell_pid == a.shell_pid and restored.text == "PERSIST_B_on disk",
          "Explicit load after Force close did not recover B locally")
        save("finish", {continue = true})
        wait_for(function() return not subject:running() end, 15)
        return
      end
      if action == "dormant-crash" then
        save("b-crashed", {continue = true})
        assert(kernel.TerminateProcess(bh, 126) ~= 0)
        wait_for(function() return kernel.WaitForSingleObject(bh, 0) == 0 end, 5)
        assert(subject:running() and kernel.WaitForSingleObject(ah, 0) == 258, "B's crash ended the Window or A")
        save("switch-a-after-crash", {continue = true})
        local resumed = wait_for(function() return read("a-resumed") end, 10)
        assert(resumed.pid == a.pid and resumed.shell_pid == a.shell_pid, "B's crash replaced A or the Window")
        save("load-b", {continue = true})
        wait_for(function() return read("a-selected-b-failure") end, 10)
        local window = assert(shell_window(a.shell_pid))
        user32.PostMessageW(window, 0x804c, 0, 0)
        wait_for(function() return user32.IsIconic(window) ~= 0 end, 1, "B's failure blocked native Minimize")
        user32.PostMessageW(window, 0x112, 0xF120, 0)
        wait_for(function() return user32.IsIconic(window) == 0 end, 1)
        user32.PostMessageW(window, 0x804c, 3, 0)
        local restored = wait_for(function() return read("b-restored") end, 15)
        assert(restored.pid ~= b.pid and restored.shell_pid == a.shell_pid, "Restart replaced A's Window or reused B's process")
        assert(restored.text == "PERSIST_B_on disk", "Restart did not use B's saved file")
        assert(kernel.WaitForSingleObject(ah, 0) == 258, "Restart ended A")
        save("finish", {continue = true})
        wait_for(function() return not subject:running() end, 15)
        return
      end
      if b.host_pid then host_handle = kernel.OpenProcess(0x100001, 0, b.host_pid); assert(host_handle ~= nil) end
      local dialog
      if action == "dormant-dialog" then
        dialog = wait_for(function() return owned_dialog(a.shell_pid, "Anvil pending unload dialog") end, 8)
      end
      save("unload-b", {continue = true})
      if action == "dormant-terminal-cancel" then
        local cancelled = wait_for(function() return read("b-terminal-cancelled") end, 8)
        assert(cancelled.pid == b.pid and cancelled.session_id == b.session_id and cancelled.attach_count == 1,
          "Terminal Cancel changed B or its attachment")
        assert(kernel.WaitForSingleObject(bh, 0) == 258 and kernel.WaitForSingleObject(host_handle, 0) == 258,
          "Terminal Cancel ended B or its shell")
        save("continue-after-cancel", {continue = true})
      end
      if action == "dormant-cancel" then
        local cancelled = wait_for(function() return read("b-cancelled") end, 8)
        assert(cancelled.pid == b.pid and cancelled.dirty and cancelled.text == "DIRTY_PERSIST_B_on disk",
          "Cancel replaced B or lost its unsaved Buffer")
        assert(kernel.WaitForSingleObject(bh, 0) == 258 and subject:running(), "Cancel ended B or the Window")
        save("continue-after-cancel", {continue = true})
      end
      if action ~= "dormant-launch" then
        wait_for(function() return read("b-unload-requested") or read("b-error") end, 8)
      end
      assert(not read("b-error"), (read("b-error") or {}).error)
      wait_for(function() return kernel.WaitForSingleObject(bh, 0) == 0 end, 12, "Unload retained B's process")
      assert(subject:running() and kernel.WaitForSingleObject(ah, 0) == 258, "Unload closed the Window or A")
      if host_handle then
        if action == "dormant-terminal-end" then
          wait_for(function() return kernel.WaitForSingleObject(host_handle, 0) == 0 end, 5, "Terminal End retained its shell")
        else assert(kernel.WaitForSingleObject(host_handle, 0) == 258, "Unload ended the kept Terminal Session") end
      end
      local resumed = wait_for(function() return read("a-resumed") end, 8, "Unload did not resume the remaining Project")
      assert(resumed.pid == a.pid, "Unload replaced A")
      if action == "dormant-terminal-sidebar" then
        wait_for(function() return read("a-sidebar-kept") end, 12,
          "Dormant B's busy detached Terminal is missing from the Sidebar model")
      end
      if action == "dormant-launch" then
        local window = assert(shell_window(a.shell_pid))
        user32.PostMessageW(window, 0x10, 0, 0)
        wait_for(function() return not subject:running() end, 15)
        return
      end
      save("load-b", {continue = true})
      local restored = wait_for(function() return read("b-restored") end, 15)
      assert(restored.pid ~= b.pid and restored.shell_pid == a.shell_pid, "Load reused the old process or replaced the Window")
      assert(restored.text == "PERSIST_B_on disk", "Load lost the saved Buffer")
      assert(restored.selection == "1,3,1,8", "Load lost Workspace selection")
      if host_handle and action ~= "dormant-terminal-end" then
        assert(restored.session_id == b.session_id and restored.host_pid == b.host_pid and restored.attach_count == 1,
          "Load replaced or duplicated the kept Terminal Session")
        local marker = assert(io.open(root .. "/terminal-command-count.txt", "rb"))
        local calls = marker:read("*a"); marker:close()
        assert(calls == "one\r\n" or calls == "one\n", "Load replayed a Terminal command")
      end
      if dialog then
        assert(owned_dialog(a.shell_pid, "Anvil pending unload dialog") == dialog, "Unload disposed the pending callback fixture")
        user32.PostMessageW(dialog, 0x10, 0, 0)
        wait_for(function() return not owned_dialog(a.shell_pid, "Anvil pending unload dialog") end, 5)
        assert(not read("b-old-dialog-result"), "Old dialog result reached the loaded Workspace")
        local window = assert(shell_window(a.shell_pid))
        user32.PostMessageW(window, 0x112, 0xF020, 0)
        wait_for(function() return user32.IsIconic(window) ~= 0 end, 1, "Old dialog blocked native Minimize")
        user32.PostMessageW(window, 0x112, 0xF120, 0)
        wait_for(function() return user32.IsIconic(window) == 0 end, 1)
        assert(subject:running() and kernel.WaitForSingleObject(ah, 0) == 258, "Late dialog ended the Window or A")
      end
      save("finish", {continue = true})
      wait_for(function() return not subject:running() end, 15)
    end)
    save("result", {ok = ok, action = action, error = ok and nil or tostring(err)})
    if suspended_handle and kernel.WaitForSingleObject(suspended_handle, 0) == 258 then
      ntdll.NtResumeProcess(suspended_handle)
    end
    if subject and subject:running() then subject:terminate(); subject:wait(1) end
    if host_handle then
      if kernel.WaitForSingleObject(host_handle, 0) == 258 then kernel.TerminateProcess(host_handle, 0) end
      kernel.CloseHandle(host_handle)
    end
    for _, handle in ipairs(handles) do kernel.CloseHandle(handle) end
    quit()
  end)
else
  if directory == root .. "/Replacement" then save("b-started", state()) end
  core.add_background_thread(function()
    if directory == root .. "/Project" then
      if action == "dormant-last" or action == "dormant-last-close" then
        if read("a-unload-requested") then
          local editor = wait_for(function() return core.active_view and core.active_view.buffer and core.active_view.buffer.filename and core.active_view.buffer.filename:match("edited%.txt$") and core.active_view end, 10)
          local restored = state()
          restored.text = editor.buffer:get_text(1, 1, math.huge, math.huge)
          restored.selection = table.concat({editor.buffer:get_selection()}, ",")
          save("a-restored", restored)
          wait_for(function() return read("finish") end, 10)
          quit()
        else
          local editor = core.open_file(directory .. "/edited.txt")
          editor.buffer:insert(1, 1, "PERSIST_A_"); editor.buffer:save()
          editor.buffer:set_selection(1, 3, 1, 8)
          save("a-ready", state())
          wait_for(function() return read("unload-a") end, 10)
          assert(require("core.command").perform("core:unload_project"))
          save("a-unload-requested", {continue = true})
        end
        return
      end
      save("a-ready", state())
      wait_for(function() return read("select-b") end, 10)
      assert(core.open_project_in_same_window(root .. "/Replacement"))
      wait_for(function() return not system.window_should_render(core.window) end, 10)
      if action == "dormant-background-quit" then
        wait_for(function() return read("quit-a") end, 15)
        assert(require("core.command").perform("core:quit"))
        return
      end
      if action == "dormant-launch" then
        assert(core.unload_project(root .. "/Replacement"))
        save("a-unload-requested", {continue = true})
      end
      if action == "dormant-crash" or action == "dormant-hang" or crash_unload then
        wait_for(function() return read("switch-a-after-crash") end, 20)
        assert(core.open_project_in_same_window(directory))
      end
      wait_for(function() return system.window_should_render(core.window) end, 20)
      save("a-resumed", state())
      if action == "dormant-terminal-sidebar" then
        local b = assert(read("b-ready"))
        wait_for(function()
          if core.project_sidebar_request then return end
          assert(core.request_project_sidebar())
          wait_for(function() return not core.project_sidebar_request end, 5)
          save("a-sidebar-status", core.project_sidebar)
          for _, project in ipairs(core.project_sidebar or {}) do
            if project.path:gsub("\\", "/") == root .. "/Replacement" and project.state == "dormant" then
              for _, terminal in ipairs(project.terminals) do
                if terminal.id == b.session_id and terminal.host_pid == b.host_pid and terminal.state == "running" and
                    terminal.busy == 1 and not terminal.attached and terminal.cwd:gsub("\\", "/") == root .. "/Replacement" then
                  save("a-sidebar-kept", {continue = true}); return true
                end
              end
            end
          end
        end, 10, "Dormant B's busy detached Terminal is missing from the Sidebar model")
      end
      if action == "dormant-unload-crash" then
        wait_for(function() return read("unload-failed-b") end, 10)
        assert(core.unload_project(root .. "/Replacement"))
        return
      end
      if action == "dormant-hang" then
        wait_for(function() return read("unload-hung-b") end, 10)
        assert(core.unload_project(root .. "/Replacement"))
      end
      wait_for(function() return read("load-b") end, action == "dormant-hang" and 20 or 10)
      assert(core.open_project_in_same_window(root .. "/Replacement"))
      if action == "dormant-crash" or action == "dormant-unload-restart" then
        wait_for(function() return not system.window_should_render(core.window) end, 10)
        save("a-selected-b-failure", {continue = true})
      end
    elseif action == "dormant-unload-restart" and read("b-close-held") then
      local restored = state()
      save("b-restored", restored)
      wait_for(function() return read("finish") end, 10)
      assert(require("core.command").perform("core:quit"))
    elseif (action == "dormant-crash" or action == "dormant-hang") and read("b-crashed") then
      local editor = core.open_file(directory .. "/edited.txt")
      local restored = state()
      restored.text = editor.buffer:get_text(1, 1, math.huge, math.huge)
      save("b-restored", restored)
      wait_for(function() return read("finish") end, 10)
      quit()
    elseif read("b-unload-requested") then
      local editor = wait_for(function()
        local panes = require "core.panes"
        for _, pane in ipairs(panes.ordered()) do
          for _, view in ipairs(panes.views(pane)) do
            if view.buffer and view.buffer.filename and view.buffer.filename:match("edited%.txt$") then return view end
          end
        end
      end, 10, "Load did not restore B's Editor")
      local restored = state()
      restored.text = editor.buffer:get_text(1, 1, math.huge, math.huge)
      restored.selection = table.concat({editor.buffer:get_selection()}, ",")
      if with_terminal and action ~= "dormant-terminal-end" then
        local terminal = wait_for(function()
          for _, view in ipairs(require("plugins.terminal").open_views()) do
            if view.session and view.state == "running" then return view end
          end
        end, 15, "Load did not reattach the Terminal View")
        local stats = terminal.session:stats()
        restored.session_id, restored.host_pid, restored.attach_count = stats.session_id, stats.host_pid, stats.attach_count
      end
      save("b-restored", restored)
      wait_for(function() return read("finish") end, 10)
      quit()
    else
      if action == "dormant-launch" then return end
      local ok, err = pcall(function()
        local editor = core.open_file(directory .. "/edited.txt")
        editor.buffer:insert(1, 1, "PERSIST_B_")
        editor.buffer:save()
        editor.buffer:set_selection(1, 3, 1, 8)
        local ready = state()
        local terminal
        if with_terminal then
          local command = require "core.command"
          assert(command.perform("terminal:reset_quit_choice"))
          terminal = require("plugins.terminal").open {cwd = directory, shell = "cmd.exe /D /Q"}
          wait_for(function() return terminal.session and terminal.state == "running" and terminal.session:stats().host_pid > 0 end, 10)
          terminal.session:write(string.format([[powershell.exe -NoProfile -Command "Add-Content -LiteralPath '%s/terminal-command-count.txt' -Value one; Write-Output ('KEEP_'+'B_READY'); Start-Sleep -Seconds 180"]], root) .. "\r")
          wait_for(function()
            local _, status = terminal.session:update()
            local capture = terminal.session:text_capture()
            return status.busy == true and capture and capture.text:find("KEEP_B_READY", 1, true)
          end, 10, "The Terminal command did not start")
          local stats = terminal.session:stats()
          ready.session_id, ready.host_pid = stats.session_id, stats.host_pid
          core.set_active_view(editor)
        end
        if action == "dormant-dialog" then
          core.open_file_dialog(core.window, function(status) save("b-old-dialog-result", {status = status}) end,
            {title = "Anvil pending unload dialog", default_location = (directory .. "/"):gsub("/", "\\")})
        end
        if action == "dormant-cancel" then editor.buffer:insert(1, 1, "DIRTY_") end
        if action == "dormant-background-quit" then editor.buffer:insert(1, 1, "UNSAVED_B_") end
        save("b-ready", ready)
        if action == "dormant-background-quit" then
          wait_for(function() return core.nag_view.visible and core.nag_view:get_title() == "Unsaved Changes" end, 10)
          assert(require("core.command").perform("core:select_dialog_no"))
          wait_for(function() return not core.nag_view.visible and not core.quit_pending end, 3)
          local cancelled = state()
          cancelled.dirty = editor.buffer:is_dirty()
          cancelled.text = editor.buffer:get_text(1, 1, math.huge, math.huge)
          save("b-window-cancelled", cancelled)
          wait_for(function() return read("finish") end, 8)
          quit()
          return
        end
        wait_for(function() return read("unload-b") end, 10)
        if crash_unload then
          -- Hold the accepted exit callback at the process boundary. The driver
          -- crashes this owned process after the shell receives acceptance.
          local exit = core.exit
          core.exit = function(callback, force)
            return exit(function() save("b-close-held", {continue = true}) end, force)
          end
        end
        assert(require("core.command").perform("core:unload_project"), "Project unload command is unavailable")
        save("b-unload-requested", {continue = true})
        if action == "dormant-cancel" then
          wait_for(function() return core.nag_view.visible and core.nag_view:get_title() == "Unsaved Changes" end, 8)
          assert(require("core.command").perform("core:select_dialog_no"))
          wait_for(function() return not core.nag_view.visible and not core.quit_pending end, 3)
          local cancelled = state()
          cancelled.dirty = editor.buffer:is_dirty()
          cancelled.text = editor.buffer:get_text(1, 1, math.huge, math.huge)
          save("b-cancelled", cancelled)
          wait_for(function() return read("continue-after-cancel") end, 8)
          editor.buffer:remove(1, 1, 1, 7); editor.buffer:save()
          editor.buffer:set_selection(1, 3, 1, 8)
          assert(require("core.command").perform("core:unload_project"))
        end
        if with_terminal then
          wait_for(function() return core.nag_view.visible and core.nag_view:get_title() == "Running Terminals" end, 8)
          if action == "dormant-terminal-cancel" then
            local cancelled = false
            for i, option in ipairs(core.nag_view.options) do
              if option.text == "Cancel" then
                core.nag_view:change_hovered(i)
                assert(require("core.command").perform("core:select_dialog_entry"))
                cancelled = true; break
              end
            end
            assert(cancelled, "Unload did not offer Terminal Cancel")
            wait_for(function() return not core.nag_view.visible and not core.quit_pending end, 3)
            local result = state()
            local stats = terminal.session:stats()
            result.session_id, result.attach_count = stats.session_id, stats.attach_count
            save("b-terminal-cancelled", result)
            wait_for(function() return read("continue-after-cancel") end, 8)
            assert(require("core.command").perform("core:unload_project"))
            wait_for(function() return core.nag_view.visible and core.nag_view:get_title() == "Running Terminals" end, 8)
          end
          local chosen = false
          for i, option in ipairs(core.nag_view.options) do
            if option.text == (action == "dormant-terminal-end" and "End" or "Keep") then
              core.nag_view:change_hovered(i)
              assert(require("core.command").perform("core:select_dialog_entry"))
              chosen = true; break
            end
          end
          assert(chosen, "Unload did not offer the requested Terminal choice")
        end
      end)
      if not ok then save("b-error", {error = tostring(err)}) end
    end
  end)
end
