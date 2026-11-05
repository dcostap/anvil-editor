local ready = dofile("tests/fixtures/terminal_ready.lua")
local test = require "core.test"
local core = require "core"
local terminal = require "plugins.terminal"
local panes = require "core.panes"
local storage = require "core.storage"
local json = require "core.json"
local pi_cli = system.getcwd() .. "/tests/fixtures/fake-pi/dist/cli.js"

local function wait_for(view, predicate)
  local deadline = system.get_time() + 30
  repeat
    if view and view.session then view:service_session(true) end
    if predicate() then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return false
end

local function record(view)
  return assert(load(assert(require("terminal_native").read_session_record(view.session_id)), "record", "t", {}))()
end

local function windows()
  local ffi = require "ffi"
  pcall(ffi.cdef, [[
    typedef struct { unsigned long size, usage, tid, pid; long base_priority, delta_priority; unsigned long flags; } SignoutThreadEntry;
    void * __stdcall CreateToolhelp32Snapshot(unsigned long flags, unsigned long pid);
    int __stdcall Thread32First(void *, SignoutThreadEntry *);
    int __stdcall Thread32Next(void *, SignoutThreadEntry *);
    void * __stdcall OpenThread(unsigned long access, int inherit, unsigned long tid);
    unsigned long __stdcall SuspendThread(void *);
    unsigned long __stdcall ResumeThread(void *);
    unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
    void * __stdcall FindWindowA(const char *class_name, const char *title);
    intptr_t __stdcall SendMessageTimeoutA(void *window, unsigned int message, uintptr_t wparam,
      intptr_t lparam, unsigned int flags, unsigned int timeout, uintptr_t *result);
    void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
    int __stdcall TerminateProcess(void *process, unsigned int code);
    unsigned long __stdcall WaitForSingleObject(void *handle, unsigned long milliseconds);
    void * __stdcall CreateMutexA(void *, int, const char *);
    int __stdcall ReleaseMutex(void *);
    int __stdcall CloseHandle(void *handle);
  ]])
  local user, kernel = ffi.load("user32"), ffi.load("kernel32")
  local function message(pid, kind, accept)
    -- Only the host that this test started. Never broadcast a shutdown message.
    local window = user.FindWindowA("AnvilSessionEnd", tostring(pid))
    test.ok(window ~= nil, "the test process has no Windows session-end handler")
    local result = ffi.new("uintptr_t[1]")
    test.ok(user.SendMessageTimeoutA(window, kind, accept and 1 or 0, 0x80000000, 2, 5000, result) ~= 0)
    if kind == 0x11 then test.equal(tonumber(result[0]), 1, "the process refused sign-out") end
  end
  local function kill(pid, code)
    local handle = kernel.OpenProcess(0x100001, 0, pid)
    test.ok(handle ~= nil, "the test process is not running")
    local killed = kernel.TerminateProcess(handle, code or 99)
    local stopped = kernel.WaitForSingleObject(handle, 5000)
    kernel.CloseHandle(handle)
    test.ok(killed ~= 0 and stopped == 0, "the test process did not end")
  end
  local function pause_host(pid)
    local window = user.FindWindowA("AnvilSessionEnd", tostring(pid))
    test.ok(window ~= nil)
    local notifier = user.GetWindowThreadProcessId(window, nil)
    local snapshot = kernel.CreateToolhelp32Snapshot(4, 0)
    test.ok(snapshot ~= ffi.cast("void *", -1))
    local entry, handles = ffi.new("SignoutThreadEntry"), {}
    entry.size = ffi.sizeof(entry)
    local more = kernel.Thread32First(snapshot, entry)
    while more ~= 0 do
      if entry.pid == pid and entry.tid ~= notifier then
        local handle = kernel.OpenThread(2, 0, entry.tid)
        if handle ~= nil then
          if kernel.SuspendThread(handle) ~= 0xffffffff then handles[#handles + 1] = handle
          else kernel.CloseHandle(handle) end
        end
      end
      more = kernel.Thread32Next(snapshot, entry)
    end
    kernel.CloseHandle(snapshot)
    test.ok(#handles > 0)
    return function()
      for _, handle in ipairs(handles) do kernel.ResumeThread(handle); kernel.CloseHandle(handle) end
    end
  end
  local function hold_record(id)
    local mutex = kernel.CreateMutexA(nil, 0, "Local\\AnvilTerminalRecord-" .. id)
    test.ok(mutex ~= nil)
    local acquired = kernel.WaitForSingleObject(mutex, 5000)
    if acquired ~= 0 and acquired ~= 0x80 then kernel.CloseHandle(mutex) end
    test.ok(acquired == 0 or acquired == 0x80, "could not hold the test session's record")
    return function() kernel.ReleaseMutex(mutex); kernel.CloseHandle(mutex) end
  end
  return message, kill, pause_host, hold_record
end

test.describe("Windows sign-out recovery", function()
  for _, stall in ipairs { "suspended", "saving its record", "running" } do
  test.it(stall == "running" and "keeps the Terminal when Windows ends its shell after cancellation"
    or "keeps the Terminal when sign-out is canceled while its host is " .. stall, function()
    test.skip_if(PLATFORM ~= "Windows", "Windows session messages")
    terminal._set_native_for_tests(nil)
    local message, kill, pause_host, hold_record = windows()
    local view = ready(terminal.open {cwd = system.getcwd(), shell = "cmd.exe /D /Q"})
    local pane, host = panes.pane_for_view(view), view.session:stats().host_pid
    local resume
    local ok, err = pcall(function()
      test.ok(wait_for(view, function() return system.get_file_info(record(view).snapshot_path) end))
      if stall == "suspended" then
        resume = pause_host(host)
      elseif stall == "saving its record" then
        resume = hold_record(view.session_id)
        -- A Project update saves on the monitor thread. Hold that save across QUERY and CANCEL.
        local path = USERDIR .. "/logs/terminal-session-" .. view.session_id .. ".log"
        local function read_log()
          local file = assert(io.open(path, "rb"))
          local text = file:read("*a"); file:close(); return text
        end
        local start = #read_log() + 1
        test.ok(view.session:set_project(record(view).project_path))
        test.ok(wait_for(view, function()
          return read_log():find("moved to another Project", start, true)
        end), "the test host did not start its Project save")
      end
      message(host, 0x11)
      if stall == "running" then message(host, 0x16, false) end
      kill(view.session:stats().shell_pid, 0x40010004)
      if stall ~= "running" then message(host, 0x16, false) end
      if resume then resume(); resume = nil end
      test.ok(wait_for(view, function()
        return view.session and view.state == "running" and view.session:stats().host_pid ~= host
      end), "a canceled sign-out lost the Terminal")
      test.equal(pane.current_view, view)
    end)
    if resume then resume() end
    view:on_close()
    test.ok(ok, err)
  end)
  end

  test.it("keeps a Snoozed Terminal in its Pane when its shell ends during sign-out", function()
    test.skip_if(PLATFORM ~= "Windows", "Windows session messages")
    terminal._set_native_for_tests(nil)
    local message, kill = windows()
    local view = ready(terminal.open {cwd = system.getcwd(), shell = "cmd.exe /D /Q"})
    local pane, state = panes.pane_for_view(view), view:get_state()
    local host = view.session:stats().host_pid
    local deadline = os.time() + 3600
    local restored
    local ok, err = pcall(function()
      test.ok(storage.save("sidebar", "snoozes", {[view.session_id] = deadline}))
      test.ok(require("core.snoozed_panes").snooze(pane.id))
      message(host, 0x11)
      kill(view.session:stats().shell_pid, 0x40010004)
      -- Let the reader and drain deadline finish. A normal shell exit removes its View here.
      local until_time = system.get_time() + 4
      test.ok(wait_for(view, function() return system.get_time() >= until_time end))
      require("core.snoozed_panes").check()
      test.equal(pane.current_view, view, "sign-out removed the Terminal View")
      test.ok(pane.group.snoozed, "sign-out woke the Pane")
      message(host, 0x16, true)
      view:detach_session()
      kill(host)
      restored = panes.place(function() return terminal.from_state(state) end, {placement = "current", pane = pane})
      test.ok(wait_for(restored, function() return restored.state == "running" end))
      test.equal(restored.session_id, state.session_id)
      require("core.snoozed_panes").check()
      test.ok(panes.pane_for_view(restored).group.snoozed, "revival lost the Snooze")
      test.equal(storage.load("sidebar", "snoozes")[state.session_id], deadline)
    end)
    if restored then restored:on_close() end
    view:on_close()
    storage.clear("sidebar", "snoozes")
    test.ok(ok, err)
  end)

  for _, replace in ipairs {false, true} do
  test.it(replace and "does not resume an interrupted Pi after the user starts another command"
    or "resumes the same Pi when a canceled sign-out ended Pi before its host", function()
    test.skip_if(PLATFORM ~= "Windows", "Windows session messages")
    local exe = (os.getenv("ProgramFiles") or "") .. "/nodejs/node.exe"
    test.skip_if(not system.get_file_info(exe), "Node is not installed")
    terminal._set_native_for_tests(nil)
    local message, kill = windows()
    local dir = USERDIR .. "/signout-pi-" .. tostring(replace)
    test.ok(system.mkdir(dir))
    local cli = pi_cli
    local view = ready(terminal.open {cwd = system.getcwd()})
    local state, host = view:get_state(), view.session:stats().host_pid
    local restored, interrupted
    local ok, err = pcall(function()
      test.ok(view:write_input(string.format('& "%s" "%s" --session-dir "%s"\r', exe, cli, dir)))
      test.ok(wait_for(view, function()
        local saved = record(view)
        return saved.interrupted_pid > 0 and saved.agent_state == "working"
      end), "Pi did not start")
      local running = record(view)
      message(host, 0x11)
      kill(running.interrupted_pid)
      test.ok(wait_for(view, function()
        local _, status = view.session:update()
        return not status.busy
      end), "the shell did not observe Pi's exit")
      test.equal(record(view).interrupted_pid, running.interrupted_pid, "sign-out cleared Pi's recovery identity")
      message(host, 0x16, false)
      local settled = system.get_time() + 2
      test.ok(wait_for(view, function() return system.get_time() >= settled end))
      test.equal(record(view).interrupted_pid, running.interrupted_pid, "canceling sign-out lost the interrupted Pi")
      if replace then
        test.ok(view:write_input("Write-Output SIGNOUT_NEW_COMMAND\r"))
        test.ok(wait_for(view, function()
          local saved = record(view)
          return saved.interrupted_pid == 0 and saved.command_finished > 0
        end), "a new command kept the old Pi recovery identity")
      end
      message(host, 0x16, true)
      view:detach_session()
      kill(host)
      if not replace then
        -- Another restart can arrive after a new host starts but before the editor sends Pi's resume line.
        interrupted = terminal.from_state(state)
        test.ok(wait_for(nil, function() return record(interrupted).host_pid ~= host end))
        kill(record(interrupted).host_pid)
        interrupted:detach_session()
        -- Delay the resumed program after submission. The host has no new agent report yet.
        interrupted = terminal.from_state(state)
        test.ok(wait_for(nil, function()
          local _, status = interrupted.session:update()
          return status.kind == "running" and not status.replaying
        end))
        local session_path
        for _, name in ipairs(system.list_dir(dir)) do
          if name:match("%.jsonl$") then session_path = dir .. "/" .. name end
        end
        test.ok(session_path)
        test.ok(interrupted.session:resume_agent(string.format(
          'Start-Sleep -Seconds 60; & "%s" "%s" --session "%s"\r', exe, cli, session_path)))
        test.ok(wait_for(nil, function()
          local _, status = interrupted.session:update()
          return status.busy and record(interrupted).command_started > 0
        end))
        -- A preload can replace the report before the host accepts its new identity.
        local path = USERDIR .. "/terminal-sessions/" .. state.session_id .. ".agent"
        local file = assert(io.open(path, "rb"))
        local report = file:read("*a"); file:close()
        file = assert(io.open(path, "wb"))
        assert(file:write((report:gsub("^pid=%d+", "pid=" .. interrupted.session:stats().shell_pid))))
        assert(file:close())
        kill(record(interrupted).host_pid)
        interrupted:detach_session()
      end
      restored = panes.place(function() return terminal.from_state(state) end, {placement = "current"})
      local launches
      test.ok(wait_for(restored, function()
        launches = {}
        local file = io.open(dir .. "/launches.log", "rb")
        if file then for line in file:lines() do launches[#launches + 1] = json.decode(line) end; file:close() end
        return replace and restored.state == "running" or #launches == 2
      end), "revival did not finish")
      if replace then
        test.ok(restored:write_input("Write-Output ('SIGNOUT_' + 'SHELL_READY')\r"))
        test.ok(wait_for(restored, function()
          local text = restored.session:text_capture().text
          return text:find("SIGNOUT_SHELL_READY", 1, true)
        end), "the shell was not usable")
        local count = 0
        local file = assert(io.open(dir .. "/launches.log", "rb"))
        for _ in file:lines() do count = count + 1 end
        file:close()
        test.equal(count, 1, "revival restarted an old Pi")
        return
      end
      local session
      for _, name in ipairs(system.list_dir(dir)) do if name:match("%.jsonl$") then session = name end end
      local args = launches[2]
      local resumed
      for index, arg in ipairs(args) do if arg == "--session" then resumed = args[index + 1] end end
      test.equal(resumed and resumed:match("[^/\\]+$"), session, "revival opened a different conversation")
    end)
    if restored then restored:on_close() end
    if interrupted then interrupted:on_close() end
    view:on_close()
    require("terminal_native").finish_close_commands()
    test.ok(test.remove_tree(dir))
    test.ok(ok, err)
  end)
  end

  for _, draining in ipairs {false, true} do
  test.it(draining and "keeps an intentional shell exit when sign-out starts during its drain"
    or "allows a normal shell exit after Windows cancels sign-out", function()
    test.skip_if(PLATFORM ~= "Windows", "Windows session messages")
    terminal._set_native_for_tests(nil)
    local message = windows()
    local view = ready(terminal.open {cwd = system.getcwd(), shell = "cmd.exe /D /Q"})
    local pane, host = panes.pane_for_view(view), view.session:stats().host_pid
    local ok, err = pcall(function()
      if draining then
        test.ok(view:write_input("exit\r"))
        test.ok(wait_for(nil, function()
          local file = io.open(USERDIR .. "/logs/terminal-session-" .. view.session_id .. ".log", "rb")
          if not file then return false end
          local log = file:read("*a"); file:close()
          return log:find("shell exit code=0; drain", 1, true)
        end), "the shell did not start its normal exit")
      end
      message(host, 0x11)
      if draining then coroutine.yield(0.1) end
      message(host, 0x16, false)
      if not draining then test.ok(view:write_input("exit\r")) end
      test.ok(wait_for(view, function() return pane.current_view ~= view end), "a canceled sign-out kept a normally exited shell")
    end)
    view:on_close()
    test.ok(ok, err)
  end)
  end

  test.it("keeps an exit received during sign-out and revives that Pane after cancellation", function()
    test.skip_if(PLATFORM ~= "Windows", "Windows session messages")
    terminal._set_native_for_tests(nil)
    local message, kill = windows()
    local view = ready(terminal.open {cwd = system.getcwd(), shell = "cmd.exe /D /Q"})
    local pane, host = panes.pane_for_view(view), view.session:stats().host_pid
    local pid = system.get_process_id()
    local ok, err = pcall(function()
      for _ = 1, 2 do
      host = view.session:stats().host_pid
      message(pid, 0x11)
      kill(view.session:stats().shell_pid, 0x40010004)
      test.ok(wait_for(view, function() return view.state == "exited" or view.state == "failed" end))
      test.equal(pane.current_view, view, "a shutdown exit removed the Pane's Terminal")
      message(pid, 0x16, false)
      test.ok(wait_for(view, function()
        return view.state == "running" and view.session:stats().host_pid ~= host
      end), "canceling sign-out did not revive the interrupted Terminal")
      test.equal(pane.current_view, view)
      end
    end)
    message(pid, 0x16, false)
    view:on_close()
    test.ok(ok, err)
  end)
end)
