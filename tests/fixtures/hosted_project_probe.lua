-- mod-version:3
local action = os.getenv("ANVIL_PROJECT_PROBE")
if not action then return end
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local ffi = require "ffi"
ffi.cdef [[
  typedef struct { unsigned long size, usage, pid; uintptr_t heap; unsigned long module, threads, parent; long priority; unsigned long flags; wchar_t exe[260]; } ProbeProcessEntry;
  void * __stdcall CreateToolhelp32Snapshot(unsigned long flags, unsigned long pid);
  int __stdcall Process32FirstW(void *snapshot, ProbeProcessEntry *entry);
  int __stdcall Process32NextW(void *snapshot, ProbeProcessEntry *entry);
  unsigned long __stdcall GetCurrentProcessId(void);
  void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
  int __stdcall TerminateProcess(void *process, unsigned int code);
  unsigned long __stdcall WaitForSingleObject(void *handle, unsigned long timeout);
  int __stdcall CloseHandle(void *handle);
  long __stdcall NtQueryInformationProcess(void *process, unsigned long kind, void *buffer, unsigned long capacity, unsigned long *needed);
]]
local kernel = ffi.load("kernel32")
local ntdll = ffi.load("ntdll")
local result_path = assert(os.getenv("ANVIL_PROJECT_PROBE_RESULT"))
local root = assert(os.getenv("ANVIL_PROJECT_PROBE_ROOT"))
local function save(path, value)
  local file = assert(io.open(path, "wb")); file:write("return ", common.serialize(value)); file:close()
end
local function load(path)
  local file = io.open(path, "rb")
  if not file then return end
  local text = file:read("*a"); file:close()
  return assert(loadstring(text))()
end
local function parent_pid()
  local snapshot = kernel.CreateToolhelp32Snapshot(2, 0)
  local entry = ffi.new("ProbeProcessEntry", { size = ffi.sizeof("ProbeProcessEntry") })
  local ok = kernel.Process32FirstW(snapshot, entry)
  local parent
  while ok ~= 0 do
    if entry.pid == kernel.GetCurrentProcessId() then parent = tonumber(entry.parent); break end
    ok = kernel.Process32NextW(snapshot, entry)
  end
  kernel.CloseHandle(snapshot)
  return assert(parent)
end
local function own_handle(pid)
  local handle = kernel.OpenProcess(0x100001, 0, pid)
  assert(handle ~= nil, "cannot open an owned process")
  return handle
end
local function command_line(pid)
  local handle = kernel.OpenProcess(0x1000, 0, pid)
  local needed = ffi.new("unsigned long[1]")
  ntdll.NtQueryInformationProcess(handle, 60, nil, 0, needed)
  local buffer = ffi.new("uint8_t[?]", tonumber(needed[0]))
  assert(ntdll.NtQueryInformationProcess(handle, 60, buffer, needed[0], needed) >= 0)
  -- UNICODE_STRING has an aligned pointer after the two USHORT fields.
  local length = tonumber(ffi.cast("uint16_t *", buffer)[0]) / 2
  local ptr = ffi.cast("wchar_t **", buffer + 8)[0]
  local text = {}
  for index = 0, length - 1 do text[#text + 1] = string.char(tonumber(ptr[index]) < 128 and tonumber(ptr[index]) or 63) end
  kernel.CloseHandle(handle)
  return table.concat(text)
end
local function wait_for(predicate, seconds)
  local until_time = system.get_time() + seconds
  repeat
    if predicate() then return true end
    coroutine.yield(.01)
  until system.get_time() >= until_time
  return false
end
local function quit()
  core.exit(function() core.quit_request = true end, true)
end
local function workspace_text()
  local storage = require "core.storage"
  for _, key in ipairs(storage.keys("ws")) do
    local workspace = storage.load("ws", key)
    if workspace and workspace.path:gsub("\\", "/") == root .. "/Project" then return common.serialize(workspace) end
  end
  return ""
end
local project = core.root_project().path:gsub("\\", "/")
if project:find("/driver$", 1) then
  core.add_background_thread(function()
    local handles, processes = {}, {}
    local ok, err = pcall(function()
      local process = require "core.process"
      local function start(mode, directory)
        local args = { EXEFILE }
        if mode == "shell" then args[#args + 1] = "--shell" end
        args[#args + 1] = directory
        local proc = assert(process.start(args, { stdin = process.REDIRECT_DISCARD, stdout = process.REDIRECT_DISCARD, stderr = process.REDIRECT_DISCARD }))
        processes[#processes + 1] = proc
        return proc
      end
      local mode = os.getenv("ANVIL_PROJECT_PROBE_MODE") or "shell"
      if action == "invalid" then
        for _, args in ipairs {
          { EXEFILE, "--project" },
          { EXEFILE, "--project", root .. "/missing", "--anvil-surface-pipe=anvil-surface-1-x" },
          { EXEFILE, "--project", root .. "/Project" },
          { EXEFILE, root .. "/Project", "--anvil-surface-pipe=anvil-surface-1-x" },
        } do
          local child = assert(process.start(args)); processes[#processes + 1] = child
          assert(wait_for(function() return not child:running() end, 5), "invalid Project launch did not exit")
          assert(child:returncode() ~= 0, "invalid Project launch succeeded")
        end
        save(result_path, { ok = true, action = action, mode = mode }); return
      end
      local subject = start(mode, root .. "/Project")
      assert(wait_for(function() return load(root .. "/subject.lua") end, 20), "subject did not start")
      local state = load(root .. "/subject.lua")
      core.log_quiet("Hosted Project probe: subject ready action=%s pid=%d", action, state.pid)
      local handle = own_handle(state.pid); handles[#handles + 1] = handle
      if action == "launch" then
        assert(state.hosted, "Project did not use a hosted backend")
        assert(state.command_line:find("--project", 1, true), "shell did not launch explicit Project mode")
        assert(state.hidden, "Project window became visible")
        assert(state.bounds and state.scale > 0, "backend did not return window configuration")
        save(root .. "/continue.lua", { continue = true })
      elseif action == "duplicate" then
        -- Wait until IPC advertises the first instance. The same wait applies to direct mode.
        coroutine.yield(1.5)
        local duplicate = start(mode, root .. "/Project")
        assert(wait_for(function() return not duplicate:running() end, 10), "duplicate Project did not forward and exit")
        assert(subject:running(), "duplicate launch ended the first instance")
        assert(not load(root .. "/duplicate.lua"), "duplicate launch restored the Workspace")
        local terminal_handle = own_handle(state.host_pid); handles[#handles + 1] = terminal_handle
        assert(kernel.WaitForSingleObject(terminal_handle, 0) == 258, "duplicate launch ended the original Terminal Session")
        save(root .. "/continue.lua", { continue = true })
      elseif action == "conflict" then
        local second = start(mode, root .. "/Project")
        assert(wait_for(function() return load(root .. "/duplicate.lua") end, 15), "second Project did not restore its Workspace")
        local duplicate = load(root .. "/duplicate.lua")
        core.log_quiet("Hosted Project probe: conflict reported pid=%d", duplicate.pid)
        assert(duplicate.session_id == state.session_id, "second Project changed the persisted Terminal identity")
        assert(duplicate.host_pid == state.host_pid, "second Project started a duplicate shell")
        local terminal_handle = own_handle(state.host_pid); handles[#handles + 1] = terminal_handle
        assert(kernel.WaitForSingleObject(terminal_handle, 0) == 258, "failed second attach closed the original Terminal Session")
        save(root .. "/continue.lua", { continue = true })
        assert(wait_for(function() return not second:running() end, 15), "second Project did not close")
        assert(kernel.WaitForSingleObject(terminal_handle, 0) == 258, "second Project close ended the original Terminal Session")
        assert(workspace_text():find("second.txt", 1, true), "last completed second-Project Workspace save did not win")
        save(root .. "/finish.lua", { finish = true })
      elseif action == "restart" or action == "switch" or action == "new-window" then
        assert(wait_for(function() return load(root .. "/replacement.lua") end, 15), "Project replacement did not start")
        local replacement = load(root .. "/replacement.lua")
        assert(replacement.pid ~= state.pid, "hosted restart reused the old Project process")
        if action == "new-window" then
          assert(replacement.shell_pid ~= state.shell_pid, "New Window reused the original shell")
        else
          assert(replacement.shell_pid == state.shell_pid, "restart replaced the shell window process")
        end
        save(root .. "/continue.lua", { continue = true })
      elseif action == "shell-loss" or action == "stalled-loss" then
        assert(wait_for(function() return kernel.WaitForSingleObject(handle, 0) == 0 end, 8), "Project exceeded its shell-loss deadline")
        core.log_quiet("Hosted Project probe: Project exited after shell loss")
        local terminal_handle = own_handle(state.host_pid); handles[#handles + 1] = terminal_handle
        assert(kernel.WaitForSingleObject(terminal_handle, 0) == 258, "shell loss ended the Terminal Session")
        assert(wait_for(function()
          local text = require("terminal_native").read_session_record(state.session_id)
          local record = text and assert(loadstring(text))()
          return record and record.host_pid == state.host_pid and record.attached == false
        end, 2), "shell loss did not detach the original Terminal Session")
        if action == "shell-loss" then
          local storage = require "core.storage"
          local found = false
          for _, key in ipairs(storage.keys("ws")) do
            local workspace = storage.load("ws", key)
            if workspace and workspace.path:gsub("\\", "/") == root .. "/Project" then
              found = common.serialize(workspace):find("edited.txt", 1, true) ~= nil
            end
          end
          assert(found, "shell loss did not save the latest Workspace")
          local file = assert(io.open(root .. "/Project/edited.txt", "rb"))
          assert(file:read("*a") == "on disk\n", "shell loss silently saved dirty named contents"); file:close()
        else
          local exit_time = system.get_time() - state.started
          assert(exit_time >= 4 and exit_time < 8, "native deadline did not protect a stalled Lua loop")
        end
        kernel.TerminateProcess(terminal_handle, 0)
      end
      assert(wait_for(function() return not subject:running() end, 15), "shell did not close after an intentional Project quit")
      if action == "quit" or action == "quit-error" then assert(subject:returncode() == 0, "intentional Project quit became a shell failure") end
      if action == "conflict" then
        assert(not workspace_text():find("second.txt", 1, true), "last completed first-Project Workspace save did not win")
      end
      core.log_quiet("Hosted Project probe: original shell exited")
      save(result_path, { ok = true, action = action, mode = mode })
    end)
    for _, handle in ipairs(handles) do kernel.CloseHandle(handle) end
    for _, process in ipairs(processes) do if process:running() then process:terminate() end end
    if not ok then save(result_path, { ok = false, error = tostring(err), action = action }) end
    quit()
  end)
else
  core.add_background_thread(function()
    -- Let startup finish and the Workspace restore before driving public APIs.
    coroutine.yield(.4)
    local pid, shell_pid = tonumber(kernel.GetCurrentProcessId()), parent_pid()
    local old = load(root .. "/subject.lua")
    if old and (action == "restart" or action == "switch" or action == "new-window") then
      save(root .. "/replacement.lua", { pid = pid, shell_pid = shell_pid })
      assert(wait_for(function() return load(root .. "/continue.lua") end, 15))
      quit(); return
    end
    if old and action == "conflict" then
      local text = assert(require("terminal_native").read_session_record(old.session_id))
      local record = assert(loadstring(text))()
      local restored
      for _, view in ipairs(require("plugins.terminal").open_views()) do
        if view.session_id == old.session_id then restored = view end
      end
      assert(restored, "Workspace did not restore its Terminal View")
      assert(wait_for(function() return restored.state == "failed" end, 10), "second attach did not report a conflict")
      assert(core.open_file(project .. "/second.txt")); core.save_workspace()
      save(root .. "/duplicate.lua", { pid = pid, session_id = restored.session_id, host_pid = record.host_pid })
      assert(wait_for(function() return load(root .. "/continue.lua") end, 15))
      quit(); return
    end
    if old then
      save(root .. "/duplicate.lua", { pid = pid })
      quit(); return
    end
    local state = { pid = pid, shell_pid = shell_pid, started = system.get_time(), hosted = system.is_hosted_surface() }
    if action == "launch" then
      state.command_line = command_line(pid)
      system.set_window_visible(core.window, true)
      state.hidden = system.window_focus_diagnostics(core.window):find("hidden=true", 1, true) ~= nil
      local w, h, x, y = system.get_window_size(core.window)
      state.bounds = w > 0 and h > 0 and x ~= nil and y ~= nil
      state.scale = system.get_scale(core.window)
    elseif action == "shell-loss" or action == "stalled-loss" or action == "duplicate" or action == "conflict" then
      local terminal = require "plugins.terminal"
      local view = terminal.open { cwd = project, shell = "cmd.exe /D /Q" }
      assert(wait_for(function() return view.session and (view.session:stats().host_pid or 0) > 0 end, 10), "Terminal Session did not start")
      core.save_workspace()
      if action == "shell-loss" or action == "stalled-loss" then
        local editor = assert(core.open_file(project .. "/edited.txt"))
        editor.buffer:insert(1, 1, "unsaved ")
      end
      state.host_pid = view.session:stats().host_pid
      state.session_id = view.session_id
    end
    save(root .. "/subject.lua", state)
    if action == "shell-loss" or action == "stalled-loss" then
      local handle = own_handle(shell_pid)
      kernel.TerminateProcess(handle, 99); kernel.CloseHandle(handle)
      if action == "stalled-loss" then while true do end end
    elseif action == "restart" then command.perform("core:restart")
    elseif action == "switch" then core.open_project_in_same_window(root .. "/Replacement")
    elseif action == "new-window" then
      core.open_project_in_new_window(root .. "/Replacement")
      assert(wait_for(function() return load(root .. "/continue.lua") end, 20)); quit()
    elseif action == "quit" then command.perform("core:quit")
    elseif action == "quit-error" then core.quit(true, 7)
    else
      assert(wait_for(function() return load(root .. "/continue.lua") end, 20))
      if action == "conflict" then assert(wait_for(function() return load(root .. "/finish.lua") end, 20)) end
      quit()
    end
  end)
end
