local core = require "core"
local test = require "core.test"
local terminal = require "plugins.terminal"
local panes = require "core.panes"

local function retain_processes(context, session)
  local ffi = require "ffi"
  ffi.cdef [[
    void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
    int __stdcall TerminateProcess(void *process, unsigned int code);
    unsigned long __stdcall WaitForSingleObject(void *handle, unsigned long timeout);
    int __stdcall CloseHandle(void *handle);
  ]]
  context.kernel = ffi.load("kernel32")
  local stats = session:stats()
  context.processes[#context.processes + 1] = {
    context.kernel.OpenProcess(0x100001, 0, stats.host_pid),
    context.kernel.OpenProcess(0x100000, 0, stats.shell_pid),
  }
end

local function wait_for(view, predicate, seconds)
  -- Shells start slowly on a loaded machine. The wait ends as soon as the predicate holds.
  local deadline = system.get_time() + (seconds or 30)
  while true do
    view:service_session(true)
    if predicate() then return true end
    if system.get_time() >= deadline then return false end
    coroutine.yield(0.01)
  end
end

local function printed(view, marker)
  local capture = view.session:text_capture()
  return capture and ("\n" .. capture.text .. "\n"):find("\n" .. marker .. "\n", 1, true) ~= nil
end

local function mark(view, marker)
  test.ok(view.session:write("echo " .. marker .. "\r"))
  test.ok(wait_for(view, function() return printed(view, marker) end), "shell did not print " .. marker)
end

local function restrict_process(context, pid, denied)
  local ffi = require "ffi"
  ffi.cdef [[
    int __stdcall GetKernelObjectSecurity(void *, unsigned long, void *, unsigned long, unsigned long *);
    int __stdcall SetKernelObjectSecurity(void *, unsigned long, void *);
    int __stdcall ConvertStringSecurityDescriptorToSecurityDescriptorA(const char *, unsigned long, void **, unsigned long *);
    void * __stdcall LocalFree(void *);
  ]]
  local advapi = ffi.load("advapi32")
  local handle = context.kernel.OpenProcess(0x60000, 0, pid) -- READ_CONTROL | WRITE_DAC
  test.ok(handle ~= nil, "could not change the private test process permissions")
  local saved = { handle = handle, advapi = advapi }
  context.protections[#context.protections + 1] = saved
  local needed = ffi.new("unsigned long[1]")
  advapi.GetKernelObjectSecurity(handle, 4, nil, 0, needed)
  test.ok(needed[0] > 0)
  local original = ffi.new("char[?]", needed[0])
  test.ok(advapi.GetKernelObjectSecurity(handle, 4, original, needed[0], needed) ~= 0)
  saved.original = original
  local descriptor = ffi.new("void *[1]")
  test.ok(advapi.ConvertStringSecurityDescriptorToSecurityDescriptorA(
    string.format("D:(D;;0x%x;;;WD)(A;;GA;;;OW)(A;;GA;;;SY)", denied), 1, descriptor, nil) ~= 0)
  local changed = advapi.SetKernelObjectSecurity(handle, 4, descriptor[0])
  context.kernel.LocalFree(descriptor[0])
  test.ok(changed ~= 0)
  local refused = context.kernel.OpenProcess(denied, 0, pid)
  if refused ~= nil then context.kernel.CloseHandle(refused) end
  test.ok(refused == nil, "the test process did not deny the requested rights")
end

test.describe("Terminal Session restoration", function()
  test.before_each(function(context)
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    context.views = {}
    context.processes = {}
    context.protections = {}
  end)

  test.after_each(function(context)
    for _, saved in ipairs(context.protections or {}) do
      if saved.original then saved.advapi.SetKernelObjectSecurity(saved.handle, 4, saved.original) end
      context.kernel.CloseHandle(saved.handle)
    end
    if context.private_process then context.private_process:kill() end
    for _, view in ipairs(context.views or {}) do view:on_close() end
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
    if context.file then os.remove(context.file) end
    if context.other then context.other:detach() end
  end)

  local function open(context, state)
    local view = state and terminal.from_state(state)
      or terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    if state then
      test.equal(view.state, "reconnecting", "restore did not return a pending client")
      panes.place(function() return view end, { placement = "current", focus = true })
    end
    context.views[#context.views + 1] = view
    test.ok(wait_for(view, function() return view.state == "running" or view.state == "failed" end))
    test.equal(view.state, "running", view.launch_error)
    retain_processes(context, view.session)
    return view
  end

  test.it("reattaches the same shell with its screen and working input", function(context)
    local view = open(context)
    mark(view, "before_detach_marker")
    local state = view:get_state()
    test.ok(type(state.session_id) == "string", "Workspace state has no Terminal Session ID")
    local stats = view.session:stats()
    view:detach_session()
    local restored = open(context, state)
    test.equal(restored.session:stats().host_pid, stats.host_pid)
    test.equal(restored.session:stats().shell_pid, stats.shell_pid)
    test.ok(wait_for(restored, function() return printed(restored, "before_detach_marker") end))
    mark(restored, "after_reattach_marker")
  end)

  test.it("reattaches a session that another spelling of the user folder started", function(context)
    -- A launch through C:\Projects, a link to D:\Projects, spells the same user folder differently.
    local userdir = USERDIR
    USERDIR = userdir:gsub("^%a", function(drive)
      return drive == drive:upper() and drive:lower() or drive:upper()
    end)
    local ok, view = pcall(open, context)
    USERDIR = userdir
    assert(ok, view)
    mark(view, "other_spelling_marker")
    local state = view:get_state()
    local stats = view.session:stats()
    view:detach_session()
    local restored = open(context, state)
    test.equal(restored.session:stats().host_pid, stats.host_pid)
    test.equal(restored:get_state().session_id, state.session_id)
    test.ok(wait_for(restored, function() return printed(restored, "other_spelling_marker") end))
  end)

  test.it("opens no new shell for a listed session that cannot reattach", function(context)
    local before = #terminal.open_views()
    local view, err = terminal.open_session(string.rep("0", 32))
    if view then context.views[#context.views + 1] = view end
    test.equal(view, nil)
    test.ok(err, "no reason for the failed open")
    test.equal(#terminal.open_views(), before)
  end)

  test.it("shares the shell with a second client, and typing takes control", function(context)
    local view = open(context)
    mark(view, "before_share_marker")
    local native = require "terminal_native"
    local record = assert(loadfile(USERDIR .. "/terminal-sessions/" .. view:get_state().session_id .. ".lua"))()
    test.equal(record.shared, true)
    local other, err = native.new {
      session_id = record.session_id, host_pid = record.host_pid,
      host_creation_time = record.host_creation_time, pipe_name = record.pipe_name,
      cols = 50, rows = 12,
    }
    test.ok(other, err)
    context.other = other
    local status
    local function other_printed(marker)
      local _, current = other:update()
      status = current
      local capture = other:text_capture()
      return capture and ("\n" .. capture.text .. "\n"):find("\n" .. marker .. "\n", 1, true) ~= nil
    end
    local function own_status()
      local _, current = view.session:update()
      return current
    end
    -- The second client on this PC takes control. The first shows the shell at the second's size.
    test.ok(wait_for(view, function()
      return other_printed("before_share_marker") and own_status().viewer and view.session:snapshot(nil, false).cols == 50
    end), "the first client did not become a Viewer at the Controller's size")
    -- The Viewer names the Controller's device. A local Controller is this PC.
    local controller = own_status().controller
    test.ok(type(controller) == "string" and controller ~= "", "the Viewer does not name the Controller")
    test.ok(other:write("echo from_controller_marker\r"))
    test.ok(wait_for(view, function()
      other_printed("")
      return printed(view, "from_controller_marker")
    end), "the Viewer did not show the Controller's output")
    -- Typing in the Viewer takes control. Its input reaches the shell, and the other client becomes a Viewer.
    mark(view, "from_viewer_marker")
    test.ok(wait_for(view, function() return other_printed("from_viewer_marker") and status.viewer end),
      "typing did not take control")
    test.not_equal(own_status().viewer, true)
    test.ok(wait_for(view, function() return view.session:snapshot(nil, false).cols ~= 50 end),
      "the new Controller did not set its own size")
    -- Both Clients belong to this process. Closing one must not close the other's shell.
    other:close()
    test.ok(wait_for(view, function() return own_status().clients == 1 end))
    mark(view, "after_other_close")
    view:on_close()
    local host = context.processes[1][1]
    test.ok(wait_for(view, function() return context.kernel.WaitForSingleObject(host, 0) == 0 end),
      "closing the last Client left its host running")
  end)

  for _, case in ipairs {
    { name = "another process", denied = 0 },
    { name = "a process that denies termination", denied = 1 },
    { name = "a process that denies query access", denied = 0x1001 },
  } do
  test.it("revives the saved session when its PID now belongs to " .. case.name, function(context)
    local view = open(context)
    mark(view, "preserved_reused_pid_history")
    local state = view:get_state()
    local path = USERDIR .. "/terminal-sessions/" .. state.session_id .. ".lua"
    local snapshot = assert(loadfile(path))().snapshot_path
    os.remove(snapshot)
    view:detach_session()
    test.ok(wait_for(view, function()
      return assert(loadfile(path))().attached == false and system.get_file_info(snapshot)
    end))
    local host = context.processes[1][1]
    test.ok(context.kernel.TerminateProcess(host, 99) ~= 0)
    test.equal(context.kernel.WaitForSingleObject(host, 5000), 0)
    local saved_file = assert(io.open(path, "rb"))
    local saved_record = saved_file:read("*a")
    assert(saved_file:close())
    context.private_process = require("process").start {
      "powershell.exe", "-NoLogo", "-NoProfile", "-Command", "Start-Sleep -Seconds 120"
    }
    local unrelated = context.private_process:pid()
    if case.denied ~= 0 then restrict_process(context, unrelated, case.denied) end
    -- Keep the host's record format. Only its saved PID now names a different process.
    local changed
    saved_record, changed = saved_record:gsub("(\n  host_pid = )%d+", "%1" .. unrelated, 1)
    test.equal(changed, 1)
    local file = assert(io.open(path, "wb"))
    assert(file:write(saved_record))
    assert(file:close())
    local restored = open(context, state)
    test.equal(restored.session_id, state.session_id)
    test.not_equal(restored.session:stats().host_pid, unrelated)
    test.ok(wait_for(restored, function() return printed(restored, "preserved_reused_pid_history") end))
    test.ok(context.private_process:running(), "revival ended the unrelated process")
    mark(restored, "after_reused_pid_revival")
  end)
  end

  test.it("does not revive a live host whose identity cannot be read", function(context)
    local view = open(context)
    local state = view:get_state()
    restrict_process(context, view.session:stats().host_pid, 0x1000)
    local restored = terminal.from_state(state)
    context.views[#context.views + 1] = restored
    test.equal(restored.state, "failed")
    test.is_nil(restored.session, "an inaccessible identity started another shell")
    mark(view, "inaccessible_host_still_runs")
  end)

  test.it("keeps a saved session when attachment fails without proving the host ended", function(context)
    local view = open(context)
    local state = view:get_state()
    local native = require "terminal_native"
    local failed = false
    terminal._set_native_for_tests {
      read_session_record = native.read_session_record,
      new = function(options)
        if not failed then
          failed = true
          return nil, "Fixture: process query could not allocate memory", 8
        end
        return native.new(options)
      end,
    }
    local ok, restored = pcall(terminal.from_state, state)
    terminal._set_native_for_tests(nil)
    test.ok(ok, restored)
    context.views[#context.views + 1] = restored
    test.equal(restored.state, "failed", "an unknown attach failure started another shell")
    test.ok(native.read_session_record(state.session_id), "an unknown attach failure retired the saved session")
    mark(view, "unknown_failure_host_still_runs")
  end)

  test.it("reattaches after a writer stall without ending the shell", function(context)
    local view = open(context)
    local stats = view.session:stats()
    local path = USERDIR .. "/terminal-session-stall.txt"
    context.file = path
    local file = assert(io.open(path, "wb"))
    local block = (string.rep("x", 78) .. "\r\n"):rep(1024)
    for _ = 1, 640 do assert(file:write(block)) end -- 50 MiB, beyond old raw replay.
    assert(file:close())
    test.ok(view.session:write('type "' .. path:gsub("/", "\\") .. '" & echo stall_output_done\r'))
    -- Fill both queues, then exceed the host's ten-second writer stall timeout.
    -- Allow queue fill time as well as the writer timeout on a loaded machine.
    local deadline = system.get_time() + 30
    while system.get_time() < deadline do end
    test.ok(wait_for(view, function()
      return view.state == "failed" or (view.session:stats().attach_count or 0) > 1
    end, 20), "editor did not reattach after the writer stalled")
    test.not_equal(view.state, "failed", view.launch_error)
    test.equal(view.session:stats().host_pid, stats.host_pid)
    test.equal(view.session:stats().shell_pid, stats.shell_pid)
    -- Reattach does not mean that TYPE has finished. It can consume input while
    -- checking for cancellation, before CMD reads the next command line.
    test.ok(wait_for(view, function() return printed(view, "stall_output_done") end, 120),
      "the shell did not finish its output after reattach")
    mark(view, "stall_recovery_marker")
    local state = view:get_state()
    view:detach_session()
    local restored = open(context, state)
    test.ok(wait_for(restored, function() return printed(restored, "stall_recovery_marker") end))
    mark(restored, "over_eight_mb_reattach_marker")
  end)
end)
