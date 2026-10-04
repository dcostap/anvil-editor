local core = require "core"
local common = require "core.common"
local panes = require "core.panes"
local test = require "core.test"
local terminal = require "plugins.terminal"

local function wait_for(view, predicate)
  local deadline = system.get_time() + 10
  while true do
    view:service_session(true)
    if predicate() then return true end
    if system.get_time() >= deadline then return false end
    coroutine.yield(0.01)
  end
end

local function printed(view, marker)
  return ("\n" .. view.session:text_capture().text .. "\n"):find("\n" .. marker .. "\n", 1, true) ~= nil
end

local function mark(view, marker)
  test.ok(view.session:write("echo " .. marker .. "\r"))
  test.ok(wait_for(view, function() return printed(view, marker) end))
end

test.describe("Terminal Session lifecycle", function()
  test.before_each(function(context)
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    context.project = core.root_project().path
    context.views = {}
    context.processes = {}
    context.restart_request = core.restart_request
  end)

  test.after_each(function(context)
    core.restart_request = context.restart_request
    if context.project and not common.path_equals(core.root_project().path, context.project) then
      core.set_project(context.project)
    end
    for _, view in ipairs(context.views or {}) do view:on_close() end
    for _, view in ipairs(terminal.open_views()) do view:on_close() end
    for _, handles in ipairs(context.processes or {}) do
      if handles[1] ~= nil then
        if context.kernel.WaitForSingleObject(handles[1], 100) == 258 then
          context.kernel.TerminateProcess(handles[1], 99)
        end
        context.kernel.WaitForSingleObject(handles[1], 5000)
        context.kernel.CloseHandle(handles[1])
      end
      if handles[2] ~= nil then
        context.kernel.WaitForSingleObject(handles[2], 5000)
        context.kernel.CloseHandle(handles[2])
      end
    end
    if context.directory then common.rm(context.directory, true) end
  end)

  local function open(context, state)
    local view = state and terminal.from_state(state)
      or terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    if state then panes.place(function() return view end, { placement = "current", focus = true }) end
    context.views[#context.views + 1] = view
    test.ok(wait_for(view, function() return view.state == "running" or view.state == "failed" end))
    test.equal(view.state, "running", view.launch_error)
    local ffi = require "ffi"
    ffi.cdef [[
      void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
      int __stdcall TerminateProcess(void *process, unsigned int code);
      unsigned long __stdcall WaitForSingleObject(void *handle, unsigned long timeout);
      int __stdcall CloseHandle(void *handle);
    ]]
    context.kernel = ffi.load("kernel32")
    local stats = view.session:stats()
    context.processes[#context.processes + 1] = {
      context.kernel.OpenProcess(0x100001, 0, stats.host_pid),
      context.kernel.OpenProcess(0x100000, 0, stats.shell_pid),
    }
    return view
  end

  test.it("recovers a broken pipe with the same host and working input", function(context)
    local view = open(context)
    mark(view, "before_pipe_break_marker")
    local stats = view.session:stats()
    require("terminal_native")._break_transport_for_tests(view.session)
    test.ok(wait_for(view, function() return view.session:stats().attach_count > stats.attach_count end))
    test.equal(view.state, "running")
    test.equal(view.session:stats().host_pid, stats.host_pid)
    test.equal(view.session:stats().shell_pid, stats.shell_pid)
    test.ok(wait_for(view, function() return printed(view, "before_pipe_break_marker") end))
    mark(view, "after_pipe_break_marker")
  end)

  test.it("starts a new shell in the saved cwd when its recorded host is dead", function(context)
    local view = open(context)
    mark(view, "dead_host_marker")
    local state, stats = view:get_state(), view.session:stats()
    local ffi = require "ffi"
    ffi.cdef [[
      void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
      int __stdcall TerminateProcess(void *process, unsigned int code);
      unsigned long __stdcall WaitForSingleObject(void *handle, unsigned long timeout);
      int __stdcall CloseHandle(void *handle);
    ]]
    local kernel = ffi.load("kernel32")
    local process = kernel.OpenProcess(0x100001, 0, stats.host_pid)
    test.ok(process ~= nil)
    test.ok(kernel.TerminateProcess(process, 99) ~= 0)
    local deadline = system.get_time() + 5
    while kernel.WaitForSingleObject(process, 0) == 258 and system.get_time() < deadline do
      coroutine.yield(0.01)
    end
    local ended = kernel.WaitForSingleObject(process, 0)
    kernel.CloseHandle(process)
    test.equal(ended, 0)
    local restored = open(context, state)
    test.not_equal(restored:get_state().session_id, state.session_id)
    test.ok(common.path_equals(restored:get_cwd(), state.cwd))
    mark(restored, "new_shell_marker")
    test.ok(not printed(restored, "dead_host_marker"))
  end)

  test.it("keeps a Terminal Session through an accepted Workspace exit", function(context)
    local view = open(context)
    mark(view, "workspace_exit_marker")
    local state, stats = view:get_state(), view.session:stats()
    local accepted = false
    core.exit(function() accepted = true end, true)
    test.ok(accepted)
    test.equal(view.session, nil)
    local restored = open(context, state)
    test.equal(restored.session:stats().host_pid, stats.host_pid)
    test.ok(wait_for(restored, function() return printed(restored, "workspace_exit_marker") end))
    mark(restored, "workspace_exit_reattach_marker")
  end)

  test.it("does not restore text removed by clearing the terminal", function(context)
    local view = open(context)
    mark(view, "removed_by_clear_marker")
    test.ok(view.session:clear())
    mark(view, "kept_after_clear_marker")
    test.ok(not printed(view, "removed_by_clear_marker"))
    local state = view:get_state()
    view:detach_session()
    local restored = open(context, state)
    test.ok(wait_for(restored, function() return printed(restored, "kept_after_clear_marker") end))
    test.ok(not printed(restored, "removed_by_clear_marker"), "replay restored cleared text")
  end)

  test.it("detaches a Terminal Session before an accepted editor restart", function(context)
    local view = open(context)
    mark(view, "restart_marker")
    local state, stats = view:get_state(), view.session:stats()
    core.restart()
    local requested = core.restart_request
    core.restart_request = context.restart_request -- Keep the isolated test app running.
    test.ok(requested)
    test.equal(view.session, nil)
    local restored = open(context, state)
    test.equal(restored.session:stats().host_pid, stats.host_pid)
    test.ok(wait_for(restored, function() return printed(restored, "restart_marker") end))
    mark(restored, "restart_reattach_marker")
  end)

  test.it("reattaches the saved Terminal Session after switching Projects", function(context)
    local view = open(context)
    mark(view, "project_switch_marker")
    local state, stats = view:get_state(), view.session:stats()
    context.directory = USERDIR .. "/terminal-session-project"
    test.ok(common.mkdirp(context.directory))
    test.ok(core.open_project_in_same_window(context.directory))
    core.restart_request = context.restart_request
    test.equal(view.session, nil)
    coroutine.yield(0.01) -- Let the new Project's Workspace load before switching back.
    test.ok(core.set_project(context.project))
    local restored
    test.ok(wait_for(view, function()
      for _, candidate in ipairs(terminal.open_views()) do
        if candidate.session and candidate:get_state().session_id == state.session_id then restored = candidate end
      end
      return restored ~= nil
    end))
    test.ok(restored, "Workspace did not restore its Terminal Session")
    test.equal(restored.session:stats().host_pid, stats.host_pid)
    test.ok(wait_for(restored, function() return printed(restored, "project_switch_marker") end))
    mark(restored, "project_switch_reattach_marker")
  end)
end)
