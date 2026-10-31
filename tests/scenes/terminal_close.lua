-- Measure the shared shutdown wait while several test-owned hosts cannot answer.
local core = require "core"
local scene = {}
local HOST_COUNT = 3
local PROCESS_SUSPEND_RESUME = 0x0800
local PROCESS_TERMINATE = 0x0001
local SYNCHRONIZE = 0x100000
local WAIT_OBJECT_0 = 0
local WAIT_TIMEOUT = 258

local function initialize_process_api(context)
  local ffi = require "ffi"
  ffi.cdef [[
    void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
    int __stdcall TerminateProcess(void *process, unsigned int code);
    int __stdcall CloseHandle(void *handle);
    unsigned long __stdcall WaitForSingleObject(void *handle, unsigned long milliseconds);
    unsigned long __stdcall WaitForMultipleObjects(unsigned long count, void **handles,
      int wait_all, unsigned long milliseconds);
    long __stdcall NtSuspendProcess(void *process);
    long __stdcall NtResumeProcess(void *process);
  ]]
  context.ffi = ffi
  context.null_handle = ffi.cast("void *", 0)
  context.kernel = ffi.load("kernel32")
  context.nt = ffi.load("ntdll")
end

local function close_view(context, index)
  if context.view_closed[index] then return end
  context.views[index]:on_close()
  context.view_closed[index] = true
end

local function wait_for_all(context, key, timeout)
  local count = 0
  for _, host in ipairs(context.hosts) do
    if host[key] then count = count + 1 end
  end
  if count == 0 then return true end

  local handles = context.ffi.new("void *[?]", count)
  local index = 0
  for _, host in ipairs(context.hosts) do
    if host[key] then
      handles[index] = host[key]
      index = index + 1
    end
  end
  return context.kernel.WaitForMultipleObjects(count, handles, 1, timeout) == WAIT_OBJECT_0
end

local function end_live_handles(context, key, errors)
  for _, host in ipairs(context.hosts) do
    local handle = host[key]
    if handle then
      local status = context.kernel.WaitForSingleObject(handle, 0)
      if status == WAIT_TIMEOUT then
        if context.kernel.TerminateProcess(handle, 1) == 0
            and context.kernel.WaitForSingleObject(handle, 0) == WAIT_TIMEOUT then
          errors[#errors + 1] = "could not end a test-owned Terminal process"
        end
      elseif status ~= WAIT_OBJECT_0 then
        errors[#errors + 1] = "could not check a test-owned Terminal process"
      end
    end
  end
end

local function close_process_handles(context, errors)
  for _, host in ipairs(context.hosts) do
    for _, key in ipairs({ "shell_process", "process" }) do
      local handle = host[key]
      if handle then
        if context.kernel.CloseHandle(handle) == 0 then
          errors[#errors + 1] = "could not close a test-owned Terminal process handle"
        end
        host[key] = nil
      end
    end
  end
end

local function cleanup(context)
  if context.cleaned then return end
  local errors = {}
  local function attempt(label, callback)
    local ok, err = pcall(callback)
    if not ok then errors[#errors + 1] = label .. ": " .. tostring(err) end
  end

  for index = 1, #(context.views or {}) do
    attempt("close Terminal View", function() close_view(context, index) end)
  end

  for _, host in ipairs(context.hosts or {}) do
    if host.suspended then
      if context.nt.NtResumeProcess(host.process) == 0 then
        host.suspended = false
      else
        errors[#errors + 1] = "could not resume a test-owned Terminal host"
      end
    end
  end

  local hosts_exited = wait_for_all(context, "process", 5000)
  if not hosts_exited then
    end_live_handles(context, "process", errors)
    hosts_exited = wait_for_all(context, "process", 5000)
  end
  if not hosts_exited then errors[#errors + 1] = "a test-owned Terminal host did not exit" end

  local shells_exited = wait_for_all(context, "shell_process", 1000)
  if not shells_exited then
    end_live_handles(context, "shell_process", errors)
    shells_exited = wait_for_all(context, "shell_process", 5000)
  end
  if not shells_exited then errors[#errors + 1] = "a test-owned Terminal shell did not exit" end

  if context.native then
    attempt("finish Terminal close commands", function()
      local pending = context.native.finish_close_commands()
      if pending ~= 0 then pending = context.native.finish_close_commands() end
      context.cleanup_pending = pending
      if pending ~= 0 then error(pending .. " Terminal close command(s) remain") end
    end)
  end

  close_process_handles(context, errors)
  context.cleaned = true
  if #errors > 0 then error(table.concat(errors, "; "), 0) end
end

local function suspend_hosts(context)
  local access = PROCESS_SUSPEND_RESUME + PROCESS_TERMINATE + SYNCHRONIZE
  for index, view in ipairs(context.views) do
    local stats = view.session:stats()
    assert(stats.host_pid and stats.host_pid > 0, "Terminal has no host process")
    assert(stats.shell_pid and stats.shell_pid > 0 and stats.shell_pid ~= stats.host_pid,
      "Terminal has no child shell process")

    local host = { view = view }
    context.hosts[index] = host
    host.process = context.kernel.OpenProcess(access, 0, stats.host_pid)
    assert(host.process ~= context.null_handle, "could not open the test-owned Terminal host")
    host.shell_process = context.kernel.OpenProcess(PROCESS_TERMINATE + SYNCHRONIZE, 0,
      stats.shell_pid)
    assert(host.shell_process ~= context.null_handle,
      "could not open the test-owned Terminal shell")
    assert(context.nt.NtSuspendProcess(host.process) == 0,
      "could not suspend the test-owned Terminal host")
    host.suspended = true
  end
end

function scene.setup(context)
  assert(PLATFORM == "Windows", "Terminal close-drain scenario needs Windows ConPTY")
  context.views, context.view_closed, context.hosts = {}, {}, {}
  context.native = require "terminal_native"
  initialize_process_api(context)
  local terminal = require "plugins.terminal"
  local config = require "core.config"
  config.plugins.terminal.prepare_session = false
  config.plugins.terminal.prepare_pi = false

  local ok, result = xpcall(function()
    -- Keep a prepared shell from adding an unrelated close command to the drain.
    terminal.discard_prepared_session()
    assert(context.native.finish_close_commands() == 0,
      "a prepared Terminal host did not close")
    for index = 1, HOST_COUNT do
      context.views[index] = assert(terminal.open {
        cwd = context.root,
        shell = "cmd.exe /D /Q",
        placement = "new",
      }, "could not open a test Terminal")
    end
    return context.views[1]
  end, debug.traceback)
  if not ok then
    local clean, cleanup_error = pcall(cleanup, context)
    if not clean then result = result .. "\n" .. tostring(cleanup_error) end
    error(result, 0)
  end
  context.startup_deadline = system.get_time() + 60
  return result
end

function scene.ready(context)
  for _, view in ipairs(context.views) do
    view:service_session(true)
    if view.state == "failed" then
      local message = view.launch_error or "Terminal host failed to start"
      local clean, cleanup_error = pcall(cleanup, context)
      if not clean then message = message .. "\n" .. tostring(cleanup_error) end
      error(message, 0)
    end
    if view.state ~= "running" then
      if system.get_time() >= context.startup_deadline then
        local clean, cleanup_error = pcall(cleanup, context)
        local message = "Terminal hosts did not start within 60 seconds"
        if not clean then message = message .. "\n" .. tostring(cleanup_error) end
        error(message, 0)
      end
      return false
    end
  end

  local ok, err = pcall(suspend_hosts, context)
  if not ok then
    local clean, cleanup_error = pcall(cleanup, context)
    if not clean then err = tostring(err) .. "\n" .. tostring(cleanup_error) end
    error(err, 0)
  end
  return true
end

function scene.action_name()
  return "finish-close-commands"
end

function scene.dispatch(context)
  local ok, err = xpcall(function()
    for index = 1, #context.views do close_view(context, index) end

    local started = system.get_time()
    context.pending_on_return = context.native.finish_close_commands()
    context.close_drain_ms = (system.get_time() - started) * 1000
    assert(context.pending_on_return == HOST_COUNT,
      string.format("expected %d blocked closes, got %d", HOST_COUNT, context.pending_on_return))
    for _, host in ipairs(context.hosts) do
      assert(context.kernel.WaitForSingleObject(host.process, 0) == WAIT_TIMEOUT,
        "a suspended Terminal host exited during the close drain")
    end
  end, debug.traceback)

  local clean, cleanup_error = pcall(cleanup, context)
  if not ok then
    if not clean then err = err .. "\n" .. tostring(cleanup_error) end
    error(err, 0)
  end
  if not clean then error(cleanup_error, 0) end
  core.log_quiet("Scene: %d Terminal hosts blocked close drain for %.1f ms; pending=%d",
    #context.hosts, context.close_drain_ms, context.pending_on_return)
end

function scene.action_ready(context)
  if not context.cleaned then return false end
  return true, string.format("%d suspended hosts; drain %.1f ms; pending %d",
    #context.hosts, context.close_drain_ms, context.pending_on_return)
end

function scene.state(context)
  return {
    close_drain_ms = context.close_drain_ms,
    close_pending_on_return = context.pending_on_return,
    close_pending_after_cleanup = context.cleanup_pending,
    hosts = #context.hosts,
  }
end

return scene
