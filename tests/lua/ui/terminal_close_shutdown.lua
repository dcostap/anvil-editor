local test = require "core.test"
local terminal = require "plugins.terminal"

test.describe("Terminal shutdown", function()
  test.it("finishes pending closes within one shared budget", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local ffi = require "ffi"
    ffi.cdef [[
      void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
      unsigned long __stdcall WaitForSingleObject(void *handle, unsigned long milliseconds);
      int __stdcall CloseHandle(void *handle);
      int __stdcall TerminateProcess(void *handle, unsigned int code);
    ]]
    local kernel = ffi.load("kernel32")
    local views, handles = {}, {}
    local ok, err = pcall(function()
      for _ = 1, 3 do
        local view = terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
        views[#views + 1] = view
        handles[#handles + 1] = kernel.OpenProcess(0x100001, 0, view.session:stats().host_pid)
      end
      for _, view in ipairs(views) do view:on_close() end
      local started = system.get_time()
      test.equal(require("terminal_native").finish_close_commands(), 0)
      test.ok(system.get_time() - started < 1.3, "close drain exceeded its shared budget")
      for _, handle in ipairs(handles) do
        test.equal(kernel.WaitForSingleObject(handle, 3000), 0, "closed terminal left an orphan host")
      end
    end)
    for _, view in ipairs(views) do view:on_close() end
    for _, handle in ipairs(handles) do
      if kernel.WaitForSingleObject(handle, 0) == 258 then kernel.TerminateProcess(handle, 99) end
      kernel.CloseHandle(handle)
    end
    test.ok(ok, err)
  end)
end)
