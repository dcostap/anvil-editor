local test = require "core.test"
local terminal = require "plugins.terminal"

local function wait_for(view, predicate)
  local deadline = system.get_time() + 30
  repeat
    view:service_session(true)
    if predicate() then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return false
end

test.describe("Terminal startup", function()
  test.it("returns a pending session and then starts a usable shell", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local started = system.get_time()
    local view = terminal.open { cwd = system.getcwd(), shell = "powershell.exe -NoLogo -NoProfile" }
    local returned_ms = (system.get_time() - started) * 1000
    local initial_state = view.state
    local ok, err = pcall(function()
      test.ok(wait_for(view, function()
        return view.state == "running" and view.session:text_capture().text:find("PS [^\n]*>")
      end), "shell did not reach its prompt: " .. view.session:text_capture().text)
      print(string.format("Terminal startup: open=%.1fms prompt=%.1fms",
        returned_ms, (system.get_time() - started) * 1000))
      test.equal(initial_state, "reconnecting", "opening waited for the host instead of returning a pending session")
      test.ok(view.session:write("echo ANVIL_STARTUP_READY\r"))
      test.ok(wait_for(view, function()
        return view.session:text_capture().text:find("ANVIL_STARTUP_READY", 1, true)
      end), "shell did not accept input")
    end)
    view:on_close()
    require("terminal_native").finish_close_commands()
    test.ok(ok, err)
  end)

  test.it("starts a shell whose host is slow to answer", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local ffi = require "ffi"
    ffi.cdef [[
      typedef struct {
        unsigned long size, usage, pid; uintptr_t heap; unsigned long module, threads, parent;
        long priority; unsigned long flags; uint16_t exe[260];
      } AnvilStartupProcessEntry;
      void * __stdcall CreateToolhelp32Snapshot(unsigned long flags, unsigned long pid);
      int __stdcall Process32FirstW(void *snapshot, AnvilStartupProcessEntry *entry);
      int __stdcall Process32NextW(void *snapshot, AnvilStartupProcessEntry *entry);
      unsigned long __stdcall GetCurrentProcessId(void);
      void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
      int __stdcall CloseHandle(void *handle);
      long __stdcall NtSuspendProcess(void *process);
      long __stdcall NtResumeProcess(void *process);
    ]]
    local kernel, nt = ffi.load("kernel32"), ffi.load("ntdll")
    local function children()
      local found, snapshot = {}, kernel.CreateToolhelp32Snapshot(2, 0)
      if snapshot == ffi.cast("void *", -1) then return found end
      local entry = ffi.new("AnvilStartupProcessEntry")
      entry.size = ffi.sizeof(entry)
      local more = kernel.Process32FirstW(snapshot, entry) ~= 0
      while more do
        if entry.parent == kernel.GetCurrentProcessId() then found[entry.pid] = true end
        more = kernel.Process32NextW(snapshot, entry) ~= 0
      end
      kernel.CloseHandle(snapshot)
      return found
    end
    local existing = children()
    local view = terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    -- Suspend the new host before it answers, like a machine that stalls during startup.
    local host, deadline = nil, system.get_time() + 5
    while not host and system.get_time() < deadline do
      for pid in pairs(children()) do
        if not existing[pid] then host = kernel.OpenProcess(0x800, 0, pid) end
      end
    end
    local ok, err = pcall(function()
      test.ok(host ~= nil, "the host did not start")
      test.equal(nt.NtSuspendProcess(host), 0)
      view:service_session(true)
      test.equal(view.state, "reconnecting", "the host answered before the test suspended it")
      local resume_at = system.get_time() + 7
      while system.get_time() < resume_at and view.state ~= "failed" do
        view:service_session(true)
        coroutine.yield(0.05)
      end
      nt.NtResumeProcess(host)
      test.ok(wait_for(view, function() return view.state ~= "reconnecting" end), "the launch did not finish")
      test.equal(view.state, "running", "a slow host start failed: " .. tostring(view.launch_error))
    end)
    if host ~= nil then nt.NtResumeProcess(host); kernel.CloseHandle(host) end
    view:on_close()
    require("terminal_native").finish_close_commands()
    test.ok(ok, err)
  end)

  test.it("reports a shell launch failure through the pending session", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = terminal.open { cwd = system.getcwd(), shell = "anvil-missing-shell.exe" }
    local ok, err = pcall(function()
      test.ok(view.session, "no pending session returned")
      test.ok(wait_for(view, function() return view.state == "failed" end), "launch failure did not arrive")
    end)
    view:on_close()
    require("terminal_native").finish_close_commands()
    test.ok(ok, err)
  end)

  test.it("closes a shell whose background launch has not been accepted by a view", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local native = require "terminal_native"
    local root = USERDIR .. "/terminal-startup-close"
    test.ok(system.mkdir(root))
    local original = USERDIR
    USERDIR = root
    local session, err = native.new { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    USERDIR = original
    test.ok(session, err)
    local function records()
      for _, name in ipairs(system.list_dir(root .. "/terminal-sessions") or {}) do
        if name:match("%.lua$") then return true end
      end
      return false
    end
    local ok, failure = pcall(function()
      -- Do not update the session: its view has not accepted the completed launch.
      local deadline = system.get_time() + 30
      while not records() and system.get_time() < deadline do coroutine.yield(0.01) end
      test.ok(records(), "shell did not start")
      session:close()
      native.finish_close_commands()
      deadline = system.get_time() + 30
      while records() and system.get_time() < deadline do coroutine.yield(0.01) end
      test.ok(not records(), "closed startup left a Terminal Session record")
    end)
    session:close()
    native.finish_close_commands()
    test.ok(test.remove_tree(root))
    test.ok(ok, failure)
  end)
end)
