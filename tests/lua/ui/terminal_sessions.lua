local core = require "core"
local common = require "core.common"
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
  local deadline = system.get_time() + (seconds or 10)
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

test.describe("Terminal Session restoration", function()
  test.before_each(function(context)
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    context.views = {}
    context.processes = {}
  end)

  test.after_each(function(context)
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
  end)

  local function open(context, state)
    local view = state and terminal.from_state(state)
      or terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    if state then panes.place(function() return view end, { placement = "current", focus = true }) end
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

  test.it("rejects a second client while the shell has an attached client", function(context)
    local view = open(context)
    mark(view, "single_client_marker")
    local native = require "terminal_native"
    local record = assert(loadfile(USERDIR .. "/terminal-sessions/" .. view:get_state().session_id .. ".lua"))()
    local session, err = native.new {
      session_id = record.session_id, host_pid = record.host_pid,
      host_creation_time = record.host_creation_time, pipe_name = record.pipe_name,
    }
    test.ok(session, err)
    local deadline = system.get_time() + 8
    local status
    repeat
      _, status = session:update()
      if status.kind == "failed" then break end
      coroutine.yield(0.01)
    until system.get_time() >= deadline
    session:close()
    test.equal(status.kind, "failed")
    mark(view, "first_client_still_works")
  end)

  test.it("starts a new shell when the record has a different creation time", function(context)
    local view = open(context)
    mark(view, "original_host_marker")
    local state = view:get_state()
    local path = USERDIR .. "/terminal-sessions/" .. state.session_id .. ".lua"
    local record = assert(loadfile(path))()
    record.host_creation_time = "0000000000000000"
    local file = assert(io.open(path, "wb"))
    assert(file:write("return " .. common.serialize(record)))
    assert(file:close())
    local restored = open(context, state)
    test.not_equal(restored.session:stats().host_pid, view.session:stats().host_pid)
    test.not_equal(restored:get_state().session_id, state.session_id)
    mark(restored, "fresh_host_marker")
    mark(view, "original_still_works")
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
    test.ok(view.session:write('type "' .. path:gsub("/", "\\") .. '"\r'))
    -- Fill both queues, then exceed the host's ten-second writer stall timeout.
    local deadline = system.get_time() + 20
    while system.get_time() < deadline do end
    test.ok(wait_for(view, function()
      return view.state == "failed" or (view.session:stats().attach_count or 0) > 1
    end, 20), "editor did not reattach after the writer stalled")
    test.not_equal(view.state, "failed", view.launch_error)
    test.equal(view.session:stats().host_pid, stats.host_pid)
    test.equal(view.session:stats().shell_pid, stats.shell_pid)
    mark(view, "stall_recovery_marker")
    local state = view:get_state()
    view:detach_session()
    local restored = open(context, state)
    test.ok(wait_for(restored, function() return printed(restored, "stall_recovery_marker") end))
    mark(restored, "over_eight_mb_reattach_marker")
  end)
end)
