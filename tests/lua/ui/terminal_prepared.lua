local test = require "core.test"
local terminal = require "plugins.terminal"
local config = require "core.config"

test.describe("Prepared Terminal View", function()
  test.it("opens the prepared shell and prepares another only after it is used", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local previous = config.plugins.terminal.shell
    config.plugins.terminal.shell = "powershell.exe -NoLogo -NoProfile"
    local native = require "terminal_native"
    local prepared
    -- Observe real shell creation at the platform boundary.
    terminal._set_native_for_tests {
      new = function(options)
        local session, err, code = native.new(options)
        if options.prepared then prepared = session end
        return session, err, code
      end,
    }
    local view, second
    local ok, err = pcall(function()
      local deadline = system.get_time() + 30
      local ready
      repeat
        ready = terminal.prepare_session() and prepared:text_capture().text:find("PS .*>")
        if not ready then coroutine.yield(0.01) end
      until ready or system.get_time() >= deadline
      test.ok(ready, "prepared PowerShell did not reach its prompt: " ..
        (prepared and prepared:text_capture().text or "no session"))
      for _, open in ipairs(terminal.open_views()) do
        test.ok(open.session ~= prepared, "preparation added a Workspace view")
      end
      local started = system.get_time()
      view = terminal.open()
      print(string.format("Prepared terminal open: %.1fms", (system.get_time() - started) * 1000))
      test.equal(view.state, "running", "opening started a new host instead of using the prepared shell")
      test.equal(view.session, prepared, "opening did not use the prepared native session")
      test.ok(view.session:text_capture().text:find("PS .*>"), "opening lost the prepared prompt")
      local first_pid = view.session:stats().shell_pid
      deadline = system.get_time() + 30
      while not terminal.prepare_session() and system.get_time() < deadline do coroutine.yield(0.01) end
      second = terminal.open()
      test.equal(second.state, "running")
      test.not_equal(second.session:stats().shell_pid, first_pid, "two views received the same shell")
    end)
    if view then view:on_close() end
    if second then second:on_close() end
    terminal.discard_prepared_session()
    terminal._set_native_for_tests(nil)
    config.plugins.terminal.shell = previous
    test.ok(ok, err)
  end)

  test.it("keeps the prepared shell for requests with matching launch settings", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local previous = config.plugins.terminal.shell
    config.plugins.terminal.shell = "cmd.exe /D /Q"
    local views = {}
    local ok, err = pcall(function()
      local deadline = system.get_time() + 30
      while not terminal.prepare_session() and system.get_time() < deadline do coroutine.yield(0.01) end
      views[1] = terminal.open { shell = "powershell.exe -NoLogo -NoProfile" }
      test.equal(views[1].state, "reconnecting", "a different shell received the prepared session")
      views[2] = terminal.open { cwd = USERDIR }
      test.equal(views[2].state, "reconnecting", "a different directory received the prepared session")
      views[3] = terminal.open()
      test.equal(views[3].state, "running", "the matching request lost its prepared shell")
    end)
    for _, view in ipairs(views) do view:on_close() end
    terminal.discard_prepared_session()
    config.plugins.terminal.shell = previous
    test.ok(ok, err)
  end)

  test.it("discards the unused shell when preparation is disabled", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local settings = config.plugins.terminal
    local previous_shell, previous_prepare = settings.shell, settings.prepare_session
    settings.shell, settings.prepare_session = "cmd.exe /D /Q", true
    local view
    local ok, err = pcall(function()
      local deadline = system.get_time() + 30
      while not terminal.prepare_session() and system.get_time() < deadline do coroutine.yield(0.01) end
      settings.prepare_session = false
      test.not_ok(terminal.prepare_session())
      view = terminal.open()
      test.equal(view.state, "reconnecting", "disabled preparation still supplied a shell")
    end)
    if view then view:on_close() end
    terminal.discard_prepared_session()
    settings.shell, settings.prepare_session = previous_shell, previous_prepare
    test.ok(ok, err)
  end)
end)
