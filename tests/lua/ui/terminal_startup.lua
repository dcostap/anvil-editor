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
