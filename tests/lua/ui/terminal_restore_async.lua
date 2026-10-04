local core = require "core"
local test = require "core.test"
local terminal = require "plugins.terminal"

test.describe("Terminal restore", function()
  test.it("returns without waiting for an attached client and fails without ending its shell", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local original = terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    local restored
    local ok, err = pcall(function()
      local started = system.get_time()
      restored = terminal.from_state(original:get_state())
      test.ok(system.get_time() - started < 0.8, "restore waited for the held pipe")
      local deadline = system.get_time() + 8
      while restored.state ~= "failed" and system.get_time() < deadline do
        original:service_session(true)
        restored:service_session(true)
        coroutine.yield(0.01)
      end
      test.equal(restored.state, "failed")
      test.ok(original.session:write("echo original_client_survives\r"))
      deadline = system.get_time() + 5
      local text = ""
      repeat
        original:service_session(true)
        local capture = original.session:text_capture()
        text = capture and capture.text or ""
        if text:find("\noriginal_client_survives\n", 1, true) then break end
        coroutine.yield(0.01)
      until system.get_time() >= deadline
      test.ok(text:find("\noriginal_client_survives\n", 1, true), "original shell stopped")
    end)
    if restored then restored:on_close() end
    original:on_close()
    test.ok(ok, err)
  end)
end)
