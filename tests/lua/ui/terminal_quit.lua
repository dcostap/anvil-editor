local core = require "core"
local test = require "core.test"
local terminal = require "plugins.terminal"

test.describe("Terminal quit decision", function()
  test.it("closes idle sessions even with a remembered Keep answer", function()
    test.same(terminal.quit_decision({ { kind = "running", busy = false } }, "keep"), { "close" })
  end)

  test.it("asks once for busy sessions and preserves idle close decisions", function()
    local statuses = { { kind = "running", busy = false }, { kind = "running", busy = true } }
    local decision, reason = terminal.quit_decision(statuses)
    test.equal(decision, nil)
    test.equal(reason, "ask")
    test.same(terminal.quit_decision(statuses, "keep"), { "close", "detach" })
    test.same(terminal.quit_decision(statuses, "end"), { "close", "close" })
    decision, reason = terminal.quit_decision(statuses, "cancel")
    test.equal(decision, nil)
    test.equal(reason, "cancel")
  end)

  test.it("does not treat an unknown or reconnecting session as idle", function()
    local decision, reason = terminal.quit_decision({ { kind = "reconnecting", busy = false } })
    test.equal(decision, nil)
    test.equal(reason, "ask")
    decision, reason = terminal.quit_decision({ { kind = "running" } })
    test.equal(decision, nil)
    test.equal(reason, "ask")
  end)
end)

test.describe("Terminal quit confirmation", function()
  test.it("cancels, remembers Keep, closes idle shells, and preserves busy shells", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local command = require "core.command"
    local storage = require "core.storage"
    storage.clear("plugins.terminal", "quit_choice")
    terminal._set_native_for_tests(nil)
    local idle = terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    local busy = terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    local busy_state = busy:get_state()
    local busy_id = busy.session:stats().host_pid
    local previous_quit = core.quit_request
    local function select(text)
      for i, option in ipairs(core.nag_view.options) do
        if option.text == text then
          core.nag_view:change_hovered(i)
          test.ok(command.perform "core:select_dialog_entry")
          return
        end
      end
      test.fail("missing confirmation option: " .. text)
    end
    local restored
    local ok, err = pcall(function()
      test.ok(busy.session:write("ping -n 30 127.0.0.1 > nul\r"))
      local deadline = system.get_time() + 5
      repeat
        local _, a = idle.session:update()
        local _, b = busy.session:update()
        if a.busy == false and b.busy == true then break end
        coroutine.yield(0.01)
      until system.get_time() >= deadline
      core.quit(true)
      test.ok(core.nag_view.visible)
      select("Cancel")
      test.equal(core.quit_request, previous_quit)
      test.ok(idle.session and busy.session)
      core.quit(true)
      select("[ ] Remember my choice")
      test.ok(core.nag_view.visible)
      select("Keep")
      local accepted = core.quit_request
      core.quit_request = previous_quit
      test.ok(accepted)
      test.equal(idle.state, "closed")
      test.equal(busy.state, "detached")
      test.equal(storage.load("plugins.terminal", "quit_choice"), "keep")
      restored = terminal.from_state(busy_state)
      require("core.panes").place(function() return restored end, { placement = "current", focus = true })
      deadline = system.get_time() + 8
      while restored.state ~= "running" and system.get_time() < deadline do
        restored:service_session(true)
        coroutine.yield(0.01)
      end
      test.equal(restored.session:stats().host_pid, busy_id)
      deadline = system.get_time() + 5
      repeat
        local _, status = restored.session:update()
        if status.busy == true then break end
        coroutine.yield(0.01)
      until system.get_time() >= deadline
      core.quit(true)
      accepted = core.quit_request
      core.quit_request = previous_quit
      test.ok(accepted, "remembered Keep did not accept quit")
      test.ok(not core.nag_view.visible, "remembered choice asked again")
      test.equal(restored.state, "detached")
    end)
    core.quit_request = previous_quit
    -- Detach leaves ownership in the host. Attach once more to close this test's shell.
    local cleanup = terminal.from_state(busy_state)
    local deadline = system.get_time() + 8
    while cleanup.state == "reconnecting" and system.get_time() < deadline do
      cleanup:service_session(true)
      coroutine.yield(0.01)
    end
    cleanup:on_close()
    if restored then restored:on_close() end
    busy:on_close(); idle:on_close()
    storage.clear("plugins.terminal", "quit_choice")
    test.ok(ok, err)
  end)
end)

test.describe("Terminal busy status", function()
  test.it("reports a shell child while it runs and idle after it exits", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    local function wait_busy(expected, seconds)
      local deadline = system.get_time() + seconds
      repeat
        local _, status = view.session:update()
        if status.busy == expected then return true end
        coroutine.yield(0.01)
      until system.get_time() >= deadline
      return false
    end
    local ok, err = pcall(function()
      test.ok(wait_busy(false, 5), "idle status missing")
      test.ok(view.session:write("ping -n 6 127.0.0.1 > nul\r"))
      test.ok(wait_busy(true, 4), "child status missing")
      test.ok(wait_busy(false, 10), "idle status did not return")
    end)
    view:on_close()
    test.ok(ok, err)
  end)
end)
