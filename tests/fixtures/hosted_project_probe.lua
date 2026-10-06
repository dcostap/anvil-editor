-- mod-version:3
local action = os.getenv("ANVIL_PROJECT_PROBE")
if not action then return end
if action == "option-arguments" then
  table.insert(require("core.cli").commands.default.flags, {name = "probe-project", type = "string", description = "Owned probe value"})
end
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
  void * __stdcall GetForegroundWindow(void);
  int __stdcall SetForegroundWindow(void *window);
  unsigned long __stdcall GetWindowThreadProcessId(void *window, unsigned long *pid);
  int __stdcall ShowWindow(void *window, int how);
  int __stdcall IsIconic(void *window);
  int __stdcall IsZoomed(void *window);
  int __stdcall PostMessageW(void *window, unsigned int message, uintptr_t wparam, intptr_t lparam);
  struct RECT { long left, top, right, bottom; };
  int __stdcall GetClientRect(void *window, struct RECT *rect);
  int __stdcall GetWindowRect(void *window, struct RECT *rect);
  int __stdcall GetClientRect(void *window, struct RECT *rect);
  typedef struct { unsigned long size, flags; void *active, *focus, *capture, *menu, *moving, *caret; struct RECT rect; } ProbeGuiThreadInfo;
  int __stdcall GetGUIThreadInfo(unsigned long thread, ProbeGuiThreadInfo *info);
  int __stdcall SetWindowPos(void *window, void *after, int x, int y, int w, int h, unsigned int flags);
  intptr_t __stdcall SendMessageW(void *window, unsigned int message, uintptr_t wparam, intptr_t lparam);
  long __stdcall NtSuspendProcess(void *process);
  long __stdcall NtResumeProcess(void *process);
  long __stdcall NtQueryInformationProcess(void *process, unsigned long kind, void *buffer, unsigned long capacity, unsigned long *needed);
]]
local kernel = ffi.load("kernel32")
local ntdll = ffi.load("ntdll")
local user32 = ffi.load("user32")
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
local function own_handle(pid, access)
  local handle = kernel.OpenProcess(access or 0x100001, 0, pid)
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
local function shell_window(pid)
  local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
  local text = file:read("*a"); file:close()
  local hex = text:match("shell%[" .. pid .. "%] Shell window hwnd=(%x+)")
  if not hex then return end
  local window = ffi.cast("void *", tonumber(hex, 16))
  local owner = ffi.new("unsigned long[1]"); user32.GetWindowThreadProcessId(window, owner)
  assert(tonumber(owner[0]) == pid, "test window has the wrong owner")
  return window
end
local project = core.root_project().path:gsub("\\", "/")
if project:find("/driver$", 1) then
  core.add_background_thread(function()
    local handles, processes = {}, {}
    local foreground_gate
    local ok, err = pcall(function()
      local process = require "core.process"
      local function start(mode, directory)
        local args = { EXEFILE }
        if mode == "shell" then args[#args + 1] = "--shell" end
        if type(directory) == "table" then for _, arg in ipairs(directory) do args[#args + 1] = arg end
        else args[#args + 1] = directory end
        local proc = assert(process.start(args, { stdin = process.REDIRECT_DISCARD, stdout = process.REDIRECT_DISCARD, stderr = process.REDIRECT_DISCARD }))
        processes[#processes + 1] = proc
        return proc
      end
      local mode = os.getenv("ANVIL_PROJECT_PROBE_MODE") or "shell"
      if action == "arguments" or action == "option-arguments" then
        local args = {root .. "/Project/new-file.txt"}
        if action == "option-arguments" then args[#args+1] = "--probe-project"; args[#args+1] = root .. "/Replacement" end
        local child = start(mode, args)
        assert(wait_for(function() return load(root .. "/subject.lua") end, 15), "nonexistent file prevented Project launch")
        local state = load(root .. "/subject.lua")
        assert(state.path == root .. "/Project", "file argument selected the wrong Project")
        save(root .. "/continue.lua", {continue = true})
        assert(wait_for(function() return not child:running() end, 10))
        save(result_path, {ok = true, action = action}); return
      end
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
      elseif action == "routing" then
        local window = assert(shell_window(state.shell_pid))
        local client = ffi.new("struct RECT")
        assert(user32.GetClientRect(window, client) ~= 0)
        local origin_x = tonumber(client.right - client.left) - state.surface_w
        local owner = ffi.new("unsigned long[1]")
        local thread = user32.GetWindowThreadProcessId(window, owner)
        assert(tonumber(owner[0]) == state.shell_pid)
        local function captured()
          local info = ffi.new("ProbeGuiThreadInfo", {size = ffi.sizeof("ProbeGuiThreadInfo")})
          assert(user32.GetGUIThreadInfo(thread, info) ~= 0)
          return info.capture == window
        end
        local function point(x, y) return math.floor(x) % 65536 + (math.floor(y) % 65536) * 65536 end
        local function post(message, buttons, x, y)
          local probe_action = ({[0x200] = 0, [0x201] = 1, [0x202] = 2, [0x20a] = 3})[message]
          -- SDL checks real asynchronous button state for posted Win32 input.
          -- Use the existing native probe for held input on an inactive desktop.
          assert(user32.PostMessageW(window, probe_action and 0x804a or message,
            probe_action or buttons, point(x, y)) ~= 0)
          coroutine.yield(.1)
        end
        local x, y = state.x + origin_x, state.y
        post(0x200, 0, x, y)
        post(0x201, 1, x, y)
        assert(captured(), "Project drag did not capture the native window")
        post(0x200, 1, x + 20, y)
        post(0x200, 1, -5, y)
        assert(captured(), "Project drag lost capture over the Sidebar")
        post(0x200, 1, x + 20, y)
        post(0x200, 1, -5, y)
        post(0x202, 0, -5, y)
        assert(not captured(), "Project release retained native capture")
        save(root .. "/selection-check.lua", {continue = true})
        assert(wait_for(function() return load(root .. "/selection.lua") end, 5), "selection did not cross the Sidebar boundary")
        local selection = load(root .. "/selection.lua")
        assert(selection.text == "0", "captured selection used the wrong surface origin")
        assert(selection.left and selection.entered, "captured pointer did not clear and restore Project hover")
        post(0x200, 0, x, y)
        post(0x20a, 0xff880000, x, y)
        save(root .. "/wheel-check.lua", {continue = true})
        assert(wait_for(function() return load(root .. "/wheel.lua") end, 5), "wheel did not reach the Project")
        assert(load(root .. "/wheel.lua").scrolled, "wheel did not scroll the Editor")
        post(0x201, 1, x, y)
        assert(captured())
        post(0x8, 0, 0, 0)
        assert(not captured(), "native focus loss retained Project capture")
        save(root .. "/compose.lua", {continue = true})
        assert(wait_for(function() return load(root .. "/composing.lua") end, 5), "composition did not start")
        post(0x8, 0, 0, 0)
        assert(wait_for(function() return load(root .. "/focus.lua") end, 5), "native focus loss did not cancel composition")
        assert(load(root .. "/focus.lua").unchanged, "focus loss committed composition")
        for probe_action = 4, 6 do
          assert(user32.PostMessageW(window, 0x804a, probe_action, point(origin_x + 10, 16)) ~= 0)
          coroutine.yield(.1)
        end
        assert(wait_for(function() return load(root .. "/drop.lua") end, 10), "complete text drop did not open an Editor")
        local drop = load(root .. "/drop.lua")
        assert(drop.bytes == 40000 and drop.prefix and drop.tail, "hosted text drop lost complete UTF-8 or trailing lines")
        assert(drop.new_pane, "Title Bar text drop replaced the existing Pane")
        save(root .. "/continue.lua", {continue = true})
      elseif action == "move" then
        local window = assert(shell_window(state.shell_pid))
        local rect = ffi.new("struct RECT")
        assert(user32.GetWindowRect(window, rect) ~= 0)
        local client = ffi.new("struct RECT")
        assert(user32.GetClientRect(window, client) ~= 0)
        local origin_x = tonumber(client.right) - state.surface_w
        local function discarded()
          local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
          local text = file:read("*a"); file:close()
          local _, count = text:gsub("Shell discarded stale frame", "")
          return count
        end
        local function hit()
          assert(user32.GetWindowRect(window, rect) ~= 0)
          local x = tonumber(rect.left) + origin_x + state.hit_x
          local y = tonumber(rect.top) + state.hit_y
          return tonumber(user32.SendMessageW(window, 0x84, 0, x % 65536 + (y % 65536) * 65536))
        end
        assert(hit() == 1, "Title Bar client region was not installed")
        local previous_discarded = discarded()
        assert(user32.SetWindowPos(window, nil, rect.left + 10, rect.top + 10, 0, 0, 0x15) ~= 0)
        coroutine.yield(.25)
        assert(hit() == 1, "window move cleared Title Bar client regions")
        save(root .. "/move-check.lua", {continue = true})
        assert(wait_for(function() return load(root .. "/move.lua") end, 5))
        assert(load(root .. "/move.lua").composing, "window move cancelled composition")
        assert(discarded() == previous_discarded, "window move discarded matching frames")
        save(root .. "/continue.lua", {continue = true})
      elseif action == "controls" then
        local window = assert(shell_window(state.shell_pid))
        local process_handle = own_handle(state.pid, 0x101801); handles[#handles + 1] = process_handle
        local function click(x,y)
          local point = math.floor(x) + math.floor(y)*65536
          assert(user32.PostMessageW(window,0x200,0,point) ~= 0)
          assert(user32.PostMessageW(window,0x201,1,point) ~= 0)
          -- Keep press and release in separate event drains, like a physical click.
          coroutine.yield(.1)
          assert(user32.PostMessageW(window,0x200,1,point) ~= 0)
          coroutine.yield(.05)
          assert(user32.PostMessageW(window,0x202,0,point) ~= 0)
        end
        local function caption(index)
          local rect = ffi.new("struct RECT[1]"); assert(user32.GetClientRect(window,rect) ~= 0)
          local width = state.controls_w / 3
          click(tonumber(rect[0].right) - state.controls_w + (index+0.5)*width, state.controls_h/2)
        end
        assert(ntdll.NtSuspendProcess(process_handle) == 0, "could not suspend the owned Project")
        caption(0)
        assert(wait_for(function() return user32.IsIconic(window) ~= 0 end, 3), "native Minimize waited for the suspended Project")
        user32.ShowWindow(window,9)
        caption(1)
        assert(wait_for(function() return user32.IsZoomed(window) ~= 0 end, 3), "native Maximize waited for the suspended Project")
        caption(1)
        assert(wait_for(function() return user32.IsZoomed(window) == 0 end, 3), "native Restore waited for the suspended Project")
        local bounds = ffi.new("struct RECT[1]"); assert(user32.GetWindowRect(window,bounds) ~= 0)
        local point = (tonumber(bounds[0].left)+24) + (tonumber(bounds[0].top)+state.controls_h/2)*65536
        assert(user32.SendMessageW(window,0x84,0,point) == 2, "native header did not offer window drag")
        point = tonumber(bounds[0].right)-1 + (tonumber(bounds[0].bottom)-1)*65536
        assert(user32.SendMessageW(window,0x84,0,point) == 17, "native border did not offer window resize")
        local x, y = tonumber(bounds[0].left)+20, tonumber(bounds[0].top)+20
        local w, h = tonumber(bounds[0].right-bounds[0].left)+70, tonumber(bounds[0].bottom-bounds[0].top)+45
        assert(user32.SetWindowPos(window,nil,x,y,w,h,0x14) ~= 0)
        assert(user32.GetWindowRect(window,bounds) ~= 0)
        assert(tonumber(bounds[0].left) == x and tonumber(bounds[0].right-bounds[0].left) == w, "native movement or resize did not complete")
        assert(ntdll.NtResumeProcess(process_handle) == 0)
        save(root .. "/edit.lua", {continue = true})
        assert(wait_for(function() return load(root .. "/resumed.lua") end, 10), "Tabs and editing did not resume")
        local resumed = load(root .. "/resumed.lua")
        assert(resumed.text == "resumedon disk" and resumed.panes >= 2, "resumed Project lost edits or Tabs")
        assert(ntdll.NtSuspendProcess(process_handle) == 0)
        caption(2); caption(2)
        coroutine.yield(0.3)
        assert(kernel.WaitForSingleObject(process_handle,0) == 258, "repeated Close killed the suspended Project")
        assert(ntdll.NtResumeProcess(process_handle) == 0)
        assert(kernel.TerminateProcess(process_handle,92) ~= 0)
        assert(wait_for(function()
          local f = io.open(os.getenv("ANVIL_SURFACE_LOG"),"rb"); if not f then return end
          local text = f:read("*a"); f:close(); return text:find("Shell state: Failed",1,true)
        end, 5), "Project exit did not enter Failed")
        local rect = ffi.new("struct RECT[1]"); user32.GetClientRect(window,rect)
        local scale = state.controls_w/138
        local x = (48*scale + tonumber(rect[0].right))/2
        local y = (state.controls_h + tonumber(rect[0].bottom))/2 + 46*scale
        click(x-78*scale,y)
        assert(wait_for(function() return load(root .. "/replacement.lua") end, 15), "Failed Restart did not launch a replacement")
        local replacement = load(root .. "/replacement.lua")
        assert(replacement.pid ~= state.pid and replacement.shell_pid == state.shell_pid, "Failed Restart replaced the shell")
        caption(2)
        assert(wait_for(function() return not subject:running() end, 10), "native Close did not close the replacement Project")
      elseif action == "duplicate" or action == "foreground" then
        -- Wait until IPC advertises the first instance. The same wait applies to direct mode.
        coroutine.yield(1.5)
        local window
        if action == "foreground" then
          window = assert(shell_window(state.shell_pid))
          user32.ShowWindow(window, 6)
          local mine = system.window_focus_diagnostics(core.window):match("hwnd=(%x+)")
          user32.SetForegroundWindow(ffi.cast("void *", tonumber(mine, 16)))
        end
        local duplicate = start(mode, root .. "/Project")
        assert(wait_for(function() return not duplicate:running() end, 10), "duplicate Project did not forward and exit")
        assert(subject:running(), "duplicate launch ended the first instance")
        assert(not load(root .. "/duplicate.lua"), "duplicate launch restored the Workspace")
        if action == "foreground" then
          local foreground = user32.GetForegroundWindow()
          save(root .. "/foreground.lua", { foreground = tostring(foreground), target = tostring(window), front = foreground == window })
          assert(user32.IsIconic(window) == 0, "forwarding did not restore the hosted window")
          if foreground == nil then
            foreground_gate = "unavailable"
            core.log_quiet("Foreground gate: inactive private desktop has no foreground window; interactive verification remains required")
          else assert(foreground == window, "Windows did not grant foreground to the hosted window") end
        else
          local terminal_handle = own_handle(state.host_pid); handles[#handles + 1] = terminal_handle
          assert(kernel.WaitForSingleObject(terminal_handle, 0) == 258, "duplicate launch ended the original Terminal Session")
        end
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
      elseif action == "shell-loss" or action == "stalled-loss" or action == "end-loss" then
        assert(wait_for(function() return kernel.WaitForSingleObject(handle, 0) == 0 end, 8), "Project exceeded its shell-loss deadline")
        core.log_quiet("Hosted Project probe: Project exited after shell loss")
        local terminal_handle = own_handle(state.host_pid); handles[#handles + 1] = terminal_handle
        assert(kernel.WaitForSingleObject(terminal_handle, 0) == 258, "shell loss ended the Terminal Session")
        assert(wait_for(function()
          local text = require("terminal_native").read_session_record(state.session_id)
          local record = text and assert(loadstring(text))()
          return record and record.host_pid == state.host_pid and record.attached == false
        end, 2), "shell loss did not detach the original Terminal Session")
        if action == "end-loss" then
          assert(wait_for(function() return not subject:running() end, 10))
          local next_launch = start(mode, root .. "/Project")
          assert(wait_for(function() return load(root .. "/reattached.lua") end, 15), "Terminal Session did not reattach on the next launch")
          local attached = load(root .. "/reattached.lua")
          assert(attached.session_id == state.session_id and attached.host_pid == state.host_pid, "next launch replaced the live Terminal Session")
          save(root .. "/continue.lua", {continue = true})
          assert(wait_for(function() return not next_launch:running() end, 10))
        elseif action == "shell-loss" then
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
      save(result_path, { ok = true, action = action, mode = mode, foreground_gate = foreground_gate })
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
    if old and action == "controls" then
      save(root .. "/replacement.lua", {pid = pid, shell_pid = shell_pid})
      assert(wait_for(function() return load(root .. "/continue.lua") end, 15)); quit(); return
    end
    if old and action == "end-loss" then
      local terminal = require "plugins.terminal"
      assert(wait_for(function()
        for _, view in ipairs(terminal.open_views()) do
          if view.session_id == old.session_id and view.session and view.state == "running" then
            save(root .. "/reattached.lua", {session_id = view.session_id, host_pid = view.session:stats().host_pid}); return true
          end
        end
      end, 12), "saved live Terminal did not attach")
      assert(wait_for(function() return load(root .. "/continue.lua") end, 15)); quit(); return
    end
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
    local state = { pid = pid, shell_pid = shell_pid, started = system.get_time(), hosted = system.is_hosted_surface(), path = project }
    local routing_view, drag_events
    if action == "move" then
      routing_view = core.open_file(project .. "/edited.txt")
      core.set_active_view(routing_view)
      coroutine.yield(.3)
      local entry = assert(core.title_bar.entries[1])
      state.hit_x = math.floor(entry.x + entry.w / 2)
      state.hit_y = math.floor(entry.y + entry.h / 2)
      state.surface_w = core.root_panel.size.x
      routing_view.buffer:set_selection(1, 1)
      core.on_event("textediting", "λ中", 0, 2)
      coroutine.yield(.1)
    end
    if action == "routing" then
      local on_event = core.on_event
      local dragging, left, entered = false, false, false
      core.on_event = function(kind, ...)
        if kind == "mousepressed" and (...) == "left" then dragging = true end
        if kind == "mousereleased" and (...) == "left" then dragging = false end
        if kind == "mouseleft" and dragging then left = true end
        if kind == "mouseentered" and dragging and left then entered = true end
        return on_event(kind, ...)
      end
      routing_view = core.open_file(project .. "/edited.txt")
      core.set_active_view(routing_view)
      assert(wait_for(function() return routing_view.size.x > 0 and routing_view.size.y > 0 end, 5))
      coroutine.yield(.2)
      state.x, state.y = routing_view:get_line_screen_position(1, 2)
      state.y = state.y + routing_view:get_line_height() / 2
      state.surface_w = core.root_panel.size.x
      drag_events = function() return left, entered end
    end
    if action == "controls" then
      local _, _, w, h = system.get_window_controls()
      state.controls_w, state.controls_h = w,h
    end
    if action == "launch" then
      state.command_line = command_line(pid)
      system.set_window_visible(core.window, true)
      state.hidden = system.window_focus_diagnostics(core.window):find("hidden=true", 1, true) ~= nil
      local w, h, x, y = system.get_window_size(core.window)
      state.bounds = w > 0 and h > 0 and x ~= nil and y ~= nil
      state.scale = system.get_scale(core.window)
    elseif action == "shell-loss" or action == "stalled-loss" or action == "end-loss" or action == "duplicate" or action == "foreground" or action == "conflict" then
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
      if action == "end-loss" then
        require("core.storage").save("plugins.terminal", "quit_choice", "end")
        view.session:write("ping -t 127.0.0.1\r")
        assert(wait_for(function() local _, status = view.session:update(); return status.busy == true end, 5), "Terminal command did not become busy")
      end
    end
    save(root .. "/subject.lua", state)
    if action == "move" then
      assert(wait_for(function() return load(root .. "/move-check.lua") end, 5))
      save(root .. "/move.lua", {composing = require("core.ime").editing})
    end
    if action == "routing" then
      assert(wait_for(function() return load(root .. "/selection-check.lua") end, 10))
      local l1, c1, l2, c2 = routing_view.buffer:get_selection(true)
      local left, entered = drag_events()
      save(root .. "/selection.lua", {text = routing_view.buffer:get_text(l1, c1, l2, c2), left = left, entered = entered})
      assert(wait_for(function() return load(root .. "/wheel-check.lua") end, 10))
      save(root .. "/wheel.lua", {scrolled = routing_view.scroll.to.y > 0})
      assert(wait_for(function() return load(root .. "/compose.lua") end, 10))
      routing_view.buffer:set_selection(1, 2)
      core.on_event("textediting", "λ中", 0, 2)
      save(root .. "/composing.lua", {continue = true})
      assert(wait_for(function() return not require("core.ime").editing end, 10))
      save(root .. "/focus.lua", {unchanged = routing_view.buffer.lines[1] == "0123456789\n"})
      local pane_count = require("core.panes").count()
      assert(wait_for(function() return core.active_view.buffer and core.active_view.buffer ~= routing_view.buffer end, 10))
      local text = core.active_view.buffer:get_text(1, 1, math.huge, math.huge)
      save(root .. "/drop.lua", {bytes = #text, prefix = text:sub(1, #"DROP_λ中\n\n") == "DROP_λ中\n\n",
        tail = text:sub(-2) == "\n\n", new_pane = require("core.panes").count() == pane_count + 1})
    end
    if action == "controls" then
      assert(wait_for(function() return load(root .. "/edit.lua") end, 15))
      local panes = require "core.panes"
      local original = panes.active()
      local second = core.open_file(root .. "/Project/second.txt").buffer
      local added = panes.create {factory = function() return require("core.editor")(second) end}
      panes.focus(original)
      local view = core.open_file(root .. "/Project/edited.txt")
      core.set_active_view(view); core.on_event("textinput", "resumed")
      local text = view.buffer:get_text(1,1,#view.buffer.lines,#view.buffer.lines[#view.buffer.lines])
      panes.focus(added); assert(core.active_view.buffer == second, "Tab focus did not resume")
      save(root .. "/resumed.lua", {text = text, panes = #panes.ordered()})
    end
    if action == "shell-loss" or action == "stalled-loss" or action == "end-loss" then
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
