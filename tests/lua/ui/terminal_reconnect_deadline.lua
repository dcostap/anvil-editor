local test = require "core.test"
local terminal = require "plugins.terminal"

test.describe("Terminal reconnect deadline", function()
  test.it("fails within a bounded time without ending an unavailable live host", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    local ffi = require "ffi"
    ffi.cdef [[
      void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
      int __stdcall TerminateProcess(void *process, unsigned int code);
      int __stdcall CloseHandle(void *handle);
      unsigned long __stdcall WaitForSingleObject(void *handle, unsigned long milliseconds);
      long __stdcall NtSuspendProcess(void *process);
      long __stdcall NtResumeProcess(void *process);
    ]]
    local kernel, nt = ffi.load("kernel32"), ffi.load("ntdll")
    local handle = kernel.OpenProcess(0x100801, 0, view.session:stats().host_pid)
    test.ok(handle ~= nil)
    local ok, err = pcall(function()
      test.equal(nt.NtSuspendProcess(handle), 0)
      require("terminal_native")._break_transport_for_tests(view.session)
      local deadline = system.get_time() + 34
      while view.state ~= "failed" and system.get_time() < deadline do
        local started = system.get_time()
        view:service_session(true)
        test.ok(system.get_time() - started < 0.8, "reconnect blocked a UI update")
        coroutine.yield(0.01)
      end
      test.equal(view.state, "failed", "reconnect never stopped retrying")
      test.equal(kernel.WaitForSingleObject(handle, 0), 258, "failed reconnect ended the host")
    end)
    nt.NtResumeProcess(handle)
    -- The failed view released its handle. End only this test's retained host.
    kernel.TerminateProcess(handle, 99)
    kernel.WaitForSingleObject(handle, 5000)
    kernel.CloseHandle(handle)
    view:on_close()
    test.ok(ok, err)
  end)
end)
