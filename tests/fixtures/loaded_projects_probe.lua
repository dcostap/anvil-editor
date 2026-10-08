-- mod-version:3
-- Seam: public Project selection, live editing, Terminal transport, and an owned Window.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if not action or not action:match("^loaded%-") then return end
local core = require "core"
local common = require "core.common"
local ffi = require "ffi"
ffi.cdef [[
  unsigned long __stdcall GetCurrentProcessId(void);
  void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
  unsigned long __stdcall WaitForSingleObject(void *handle, unsigned long timeout);
  int __stdcall CloseHandle(void *handle);
  int __stdcall TerminateProcess(void *process, unsigned int code);
  unsigned long __stdcall GetWindowThreadProcessId(void *window, unsigned long *pid);
  int __stdcall PostMessageW(void *window, unsigned int message, uintptr_t wparam, intptr_t lparam);
  int __stdcall IsIconic(void *window);
]]
local kernel, user32 = ffi.load("kernel32"), ffi.load("user32")
local root = assert(os.getenv("ANVIL_PROJECT_PROBE_ROOT"))
local function save(name, value)
  local file = assert(io.open(root .. "/" .. name .. ".lua", "wb"))
  file:write("return ", common.serialize(value)); file:close()
end
local function load(name)
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
  error(message or "owned Project probe timed out")
end
local function path() return core.root_project().path:gsub("\\", "/") end
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
if path():find("/driver$", 1) then
  core.add_background_thread(function()
    local handles, subject, host_handle = {}, nil, nil
    local ok, err = pcall(function()
      local process = require "core.process"
      subject = assert(process.start({EXEFILE, "--shell", root .. "/Project"}, {
        stdin = process.REDIRECT_DISCARD, stdout = process.REDIRECT_DISCARD, stderr = process.REDIRECT_DISCARD,
      }))
      local a = wait_for(function() return load("a-ready") end, 15)
      host_handle = kernel.OpenProcess(0x100001, 0, a.host_pid)
      assert(host_handle ~= nil, "cannot open the owned Terminal host")
      local a_handle = kernel.OpenProcess(0x100000, 0, a.pid)
      assert(a_handle ~= nil); handles[#handles + 1] = a_handle
      save("select-b", {continue = true})
      local requested = wait_for(function() return load("a-selected-b") end, 10)
      assert(requested.path == root .. "/Project", "Project selection changed A's directory")
      if action == "loaded-launch" or action == "loaded-resolve" then
        wait_for(function()
          local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
          local text = file:read("*a"); file:close()
          return text:find(action == "loaded-resolve" and "Shell paused the owned Project identity worker"
            or "Shell paused the owned Project launch worker", 1, true)
        end, 3)
        local window = assert(shell_window(a.shell_pid))
        user32.PostMessageW(window, 0x112, 0xf020, 0)
        wait_for(function() return user32.IsIconic(window) ~= 0 end, 1,
          "native Minimize waited for Project launch")
        user32.PostMessageW(window, 0x112, 0xf120, 0)
        wait_for(function() return user32.IsIconic(window) == 0 end, 1,
          "native Restore waited for Project launch")
      end
      local b = wait_for(function() return load("b-ready") end, 15)
      assert(a.shell_pid == b.shell_pid, "Project selection created another Window")
      assert(a.pid ~= b.pid, "two Projects share one process")
      assert(kernel.WaitForSingleObject(a_handle, 0) == 258, "selection ended A's process")
      local b_handle = kernel.OpenProcess(0x100000, 0, b.pid)
      assert(b_handle ~= nil); handles[#handles + 1] = b_handle
      local window = assert(shell_window(a.shell_pid))
      user32.PostMessageW(window, 0x10, 0, 0)
      wait_for(function() return load("b-close-waiting") end, 5)
      save("b-close-cancel", {continue = true})
      local cancelled = wait_for(function() return load("b-close-cancelled") end, 5)
      assert(cancelled.dirty and cancelled.text == "LIVE_B_on disk", "Cancel lost B's unsaved Buffer")
      assert(kernel.WaitForSingleObject(a_handle, 0) == 258 and kernel.WaitForSingleObject(b_handle, 0) == 258,
        "cancelled Window Close ended a loaded Project")
      save("background-go", {continue = true})
      local background = wait_for(function() return load("a-background") end, 12)
      assert(background.rendering == false, "A kept rendering after selection changed")
      assert(background.timer_progress, "A stopped its ordinary coroutine tasks")
      assert(background.worker_result == "A-worker", "A stopped worker results")
      assert(background.terminal_output, "A stopped Terminal output")
      assert(background.session_id == a.session_id and background.host_pid == a.host_pid,
        "selection replaced A's Terminal Session")
      assert(background.attach_count == a.attach_count, "selection detached A's Terminal client")
      wait_for(function() return load("b-checked") end, 5)
      if action == "loaded-restart" then
        local restarted = wait_for(function() return load("b-restarted") end, 15)
        assert(restarted.pid ~= b.pid and restarted.shell_pid == b.shell_pid, "Restart replaced the wrong process")
        assert(kernel.WaitForSingleObject(a_handle, 0) == 258, "B's Restart ended A")
        assert(kernel.WaitForSingleObject(b_handle, 5000) == 0, "B's Restart retained the old process")
        b_handle = kernel.OpenProcess(0x100000, 0, restarted.pid)
        assert(b_handle ~= nil); handles[#handles + 1] = b_handle
      end
      if action == "loaded-focus" then
        user32.PostMessageW(window, 0x112, 0xf020, 0)
        wait_for(function() return user32.IsIconic(window) ~= 0 end, 1)
      end
      save("select-a", {continue = true})
      if action == "loaded-focus" then
        local focus = wait_for(function() return load("a-focus") end, 5)
        assert(not focus.focused, "selection gave keyboard focus to a minimized Window")
        user32.PostMessageW(window, 0x112, 0xf120, 0)
      end
      local restored = wait_for(function() return load("a-restored") end, 15,
        "cancelled Window Close blocked later Project selection")
      assert(restored.pid == a.pid, "selecting A again created another process")
      assert(restored.text == "HIDDEN_A_LIVE_A_on disk", "selection lost A's live Buffer")
      assert(restored.same_editor and restored.dirty, "selection replaced or cleaned A's Editor")
      assert(restored.selection == "1,4,1,10", "selection changed A's text selection")
      assert(kernel.WaitForSingleObject(b_handle, 0) == 258, "selecting A ended B's process")
      save("finish", {continue = true})
      wait_for(function() return load("a-clean") and load("b-clean") end, 5)
      local window = wait_for(function() return shell_window(a.shell_pid) end, 3)
      if action == "loaded-quit" then save("quit-a", {continue = true})
      else user32.PostMessageW(window, 0x10, 0, 0) end
      if action == "loaded-quit" then
        wait_for(function() return load("b-quit-waiting") end, 5,
          "Quit inside A did not check B's unsaved Buffer")
        save("cancel-b-quit", {continue = true})
        wait_for(function() return load("b-quit-cancelled") end, 5)
        assert(subject:running() and kernel.WaitForSingleObject(b_handle, 0) == 258,
          "Cancel after Project Quit closed the remaining Project")
        assert(kernel.WaitForSingleObject(a_handle, 5000) == 0, "Quit kept A alive")
        save("clean-b-quit", {continue = true})
        wait_for(function() return load("b-quit-clean") end, 5)
        user32.PostMessageW(window, 0x10, 0, 0)
      end
      wait_for(function() return not subject:running() end, 15, "Window Close left loaded Projects alive")
      assert(kernel.WaitForSingleObject(a_handle, 5000) == 0, "Window Close left A alive")
      assert(kernel.WaitForSingleObject(b_handle, 5000) == 0, "Window Close left B alive")
    end)
    local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
    file:write("return ", common.serialize {ok = ok, action = action, error = ok and nil or tostring(err)})
    file:close()
    if subject and subject:running() then subject:terminate(); subject:wait(1) end
    if host_handle then
      if kernel.WaitForSingleObject(host_handle, 0) == 258 then
        kernel.TerminateProcess(host_handle, 0)
      end
      kernel.CloseHandle(host_handle)
    end
    for _, handle in ipairs(handles) do kernel.CloseHandle(handle) end
    quit()
  end)
else
  core.add_background_thread(function()
    local project = path()
    local is_a = project == root .. "/Project"
    local editor = core.open_file(project .. "/edited.txt")
    if is_a then
      local terminal = require("plugins.terminal").open {cwd = project, shell = "cmd.exe /D /Q"}
      wait_for(function() return terminal.session and terminal.state == "running" and terminal.session:stats().host_pid > 0 end, 10)
      core.set_active_view(editor)
      editor.buffer:insert(1, 1, "LIVE_A_")
      local initial = terminal.session:stats()
      local ready = state()
      ready.session_id, ready.host_pid, ready.attach_count = initial.session_id, initial.host_pid, initial.attach_count
      save("a-ready", ready)
      wait_for(function() return load("select-b") end, 10)
      assert(core.open_project_in_same_window(root .. "/Replacement"))
      save("a-selected-b", {path = path()})
      wait_for(function() return not system.window_should_render(core.window) end, 10)
      wait_for(function() return load("background-go") end, 15)
      local timer_progress, worker_result = false, nil
      core.add_thread(function() coroutine.yield(6); timer_progress = true end)
      require("core.worker_pool").named("loaded-project-probe"):submit {
        kind = "worker_pool_test", payload = {op = "echo", value = "A-worker"},
        on_result = function(message) if message.type == "result" then worker_result = message.payload.value end end,
      }
      terminal.session:write("echo LIVE_A_BACKGROUND\r")
      editor.buffer:insert(1, 1, "HIDDEN_A_")
      editor.buffer:set_selection(1, 4, 1, 10)
      -- Required owned fault packet: B must never open A's stale resource.
      system.test_surface_failure("stale")
      coroutine.yield(7)
      local stats = terminal.session:stats()
      local capture = terminal.session:text_capture()
      save("a-background", {
        rendering = system.window_should_render(core.window), timer_progress = timer_progress,
        worker_result = worker_result, terminal_output = capture and capture.text:find("LIVE_A_BACKGROUND", 1, true) ~= nil,
        session_id = stats.session_id, host_pid = stats.host_pid, attach_count = stats.attach_count,
      })
      if action == "loaded-focus" then
        wait_for(function() return load("b-selected-a") end, 20)
        coroutine.yield(1)
        save("a-focus", {focused = system.window_has_focus(core.window)})
      end
      wait_for(function() return system.window_should_render(core.window) end, 20)
      save("a-restored", {
        pid = tonumber(kernel.GetCurrentProcessId()), text = editor.buffer:get_text(1, 1, math.huge, math.huge),
        same_editor = core.active_view == editor, dirty = editor.buffer:is_dirty(),
        selection = table.concat({editor.buffer:get_selection()}, ","),
      })
      wait_for(function() return load("finish") end, 10)
      editor.buffer:clean()
      save("a-clean", {continue = true})
      if action == "loaded-quit" then
        wait_for(function() return load("quit-a") end, 5)
        assert(require("core.command").perform("core:quit"))
      end
    else
      if load("b-restarting") then
        assert(editor.buffer:get_text(1, 1, math.huge, math.huge) == "on disk", "Restart loaded another Project's file")
        editor.buffer:insert(1, 1, "RESTARTED_B_")
        save("b-restarted", state())
        wait_for(function() return load("select-a") end, 10)
        assert(core.open_project_in_same_window(root .. "/Project"))
        wait_for(function() return load("finish") end, 15)
        editor.buffer:clean()
        save("b-clean", {continue = true})
        return
      end
      editor.buffer:insert(1, 1, "LIVE_B_")
      save("b-ready", state())
      wait_for(function() return core.nag_view.visible and core.nag_view:get_title() == "Unsaved Changes" end, 5)
      save("b-close-waiting", {continue = true})
      wait_for(function() return load("b-close-cancel") end, 5)
      assert(require("core.command").perform("core:select_dialog_no"))
      save("b-close-cancelled", {dirty = editor.buffer:is_dirty(), text = editor.buffer:get_text(1, 1, math.huge, math.huge)})
      wait_for(function() return load("a-background") end, 15)
      assert(system.window_should_render(core.window), "A's background work changed B's selection")
      assert(editor.buffer:get_text(1, 1, math.huge, math.huge) == "LIVE_B_on disk", "A's input reached B")
      save("b-checked", {continue = true})
      if action == "loaded-restart" then
        editor.buffer:clean()
        save("b-restarting", {continue = true})
        assert(require("core.command").perform("core:restart"))
        return
      end
      wait_for(function() return load("select-a") end, 10)
      assert(core.open_project_in_same_window(root .. "/Project"))
      save("b-selected-a", {continue = true})
      wait_for(function() return load("finish") end, 15)
      if action == "loaded-quit" then
        save("b-clean", {ready = true})
        wait_for(function() return core.nag_view.visible and core.nag_view:get_title() == "Unsaved Changes" end, 8)
        save("b-quit-waiting", {continue = true})
        wait_for(function() return load("cancel-b-quit") end, 5)
        assert(require("core.command").perform("core:select_dialog_no"))
        assert(editor.buffer:is_dirty(), "Cancel lost B's dirty Buffer")
        save("b-quit-cancelled", {continue = true})
        wait_for(function() return load("clean-b-quit") end, 5)
        editor.buffer:clean()
        save("b-quit-clean", {continue = true})
        return
      end
      editor.buffer:clean()
      save("b-clean", {continue = true})
    end
  end)
end
