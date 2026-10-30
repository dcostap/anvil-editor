local ready = dofile("tests/fixtures/terminal_ready.lua")
local core = require "core"
local test = require "core.test"
local terminal = require "plugins.terminal"

test.describe("Terminal quit decision", function()
  test.it("asks for idle shells and keeps them running when requested", function()
    local statuses = { { kind = "running", busy = false } }
    local decision, reason = terminal.quit_decision(statuses)
    test.equal(decision, nil)
    test.equal(reason, "ask")
    test.same(terminal.quit_decision(statuses, "keep"), { "detach" })
  end)

  test.it("applies one choice to idle and busy sessions", function()
    local statuses = { { kind = "running", busy = false }, { kind = "running", busy = true } }
    local decision, reason = terminal.quit_decision(statuses)
    test.equal(decision, nil)
    test.equal(reason, "ask")
    test.same(terminal.quit_decision(statuses, "keep"), { "detach", "detach" })
    test.same(terminal.quit_decision(statuses, "end"), { "end", "end" })
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
  test.it("cancels, asks again, and preserves idle and busy shells", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local command = require "core.command"
    terminal._set_native_for_tests(nil)
    local idle = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q", placement = "new" })
    local busy = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q", placement = "new" })
    local busy_state = busy:get_state()
    local idle_state = idle:get_state()
    local busy_id = busy.session:stats().host_pid
    local previous_quit = core.quit_request
    local previous_close_decision = system.project_close_decision
    local decisions = {}
    system.project_close_decision = function(decision)
      decisions[#decisions + 1] = decision
      previous_close_decision(decision)
    end
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
      local deadline, ready = system.get_time() + 20, false
      repeat
        local _, a = idle.session:update()
        local _, b = busy.session:update()
        ready = a.busy == false and b.busy == true
        if ready then break end
        coroutine.yield(0.01)
      until system.get_time() >= deadline
      test.ok(ready, "the shells did not report idle and busy")
      core.quit(true)
      test.ok(core.nag_view.visible)
      test.equal(decisions[#decisions], "waiting", "busy confirmation did not suspend the native close timeout")
      select("Cancel")
      test.equal(decisions[#decisions], "cancelled", "Terminal Cancel did not cancel the native close")
      test.equal(core.quit_request, previous_quit)
      test.ok(idle.session and busy.session)
      core.quit(true)
      test.ok(core.nag_view.visible)
      select("Keep running")
      test.equal(decisions[#decisions], "accepted", "Terminal Keep did not accept the native close")
      local accepted = core.quit_request
      core.quit_request = previous_quit
      test.ok(accepted)
      test.equal(idle.state, "detached")
      test.equal(busy.state, "detached")
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
      test.ok(core.nag_view.visible, "a later quit skipped confirmation")
      select("Keep running")
      accepted = core.quit_request
      core.quit_request = previous_quit
      test.ok(accepted, "Keep did not accept quit")
      test.ok(not core.nag_view.visible)
      test.equal(restored.state, "detached")
    end)
    core.quit_request = previous_quit
    system.project_close_decision = previous_close_decision
    -- Detach leaves ownership in the host. Attach once more to close this test's shell.
    local cleanup = terminal.from_state(busy_state)
    local deadline = system.get_time() + 8
    while cleanup.state == "reconnecting" and system.get_time() < deadline do
      cleanup:service_session(true)
      coroutine.yield(0.01)
    end
    cleanup:on_close()
    cleanup = terminal.from_state(idle_state)
    deadline = system.get_time() + 20
    while cleanup.state == "reconnecting" and system.get_time() < deadline do
      cleanup:service_session(true)
      coroutine.yield(0.01)
    end
    cleanup:on_close()
    if restored then restored:on_close() end
    busy:on_close(); idle:on_close()
    test.ok(ok, err)
  end)
end)

test.describe("Terminal quit with Navigation History", function()
  test.it("ends an idle shell that only Navigation History keeps, without asking", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local Editor = require "core.editor"
    local panes = require "core.panes"
    terminal._set_native_for_tests(nil)
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q", placement = "new" })
    local id = view.session_id
    local path = USERDIR .. PATHSEP .. "history-idle.txt"
    local previous_quit = core.quit_request
    local ok, err = pcall(function()
      -- A used shell stays in history. An unused one is replaced.
      view:mark_input_used()
      local deadline = system.get_time() + 20
      repeat
        view:service_session(true)
        if view.busy == false then break end
        coroutine.yield(0.01)
      until system.get_time() >= deadline
      test.equal(view.busy, false, "the shell did not report idle")
      local pane = panes.pane_for_view(view)
      local file = io.open(path, "w")
      file:write("note")
      file:close()
      panes.place(function() return Editor(core.open_buffer(path)) end, { pane = pane, placement = "current" })
      test.ok(pane.current_view ~= view and panes.pane_for_view(view) == pane, "history did not keep the shell")
      core.quit(true)
      test.ok(not core.nag_view.visible, "quit asked about a history-only idle shell")
      local accepted = core.quit_request
      core.quit_request = previous_quit
      test.ok(accepted, "quit was not accepted")
      test.equal(view.state, "closed")
      -- The host deletes its record when it exits.
      deadline = system.get_time() + 20
      while terminal.session_available(id) and system.get_time() < deadline do coroutine.yield(0.05) end
      test.ok(not terminal.session_available(id), "the session can still revive")
    end)
    core.quit_request = previous_quit
    if view.session then view:on_close() end
    os.remove(path)
    test.ok(ok, err)
  end)
end)

test.describe("Idle Pi quit decisions", function()
  test.it("asks what to do with Pi after its turn finishes", function()
    local status = { kind = "running", busy = true, agent_app = "pi", agent_state = "done" }
    local actions, reason = terminal.quit_decision({ status })
    test.equal(actions, nil)
    test.equal(reason, "ask")
    test.equal(status.busy, true)
  end)

  test.it("asks what to do with idle Pi", function()
    local status = { kind = "running", busy = true, agent_app = "pi", agent_state = "idle" }
    local actions, reason = terminal.quit_decision({ status })
    test.equal(actions, nil)
    test.equal(reason, "ask")
    test.equal(status.busy, true)
  end)

  test.it("keeps idle Pi with a Keep answer and ends it with an End answer", function()
    local statuses = {
      { kind = "running", busy = true, agent_app = "pi", agent_state = "done" },
      { kind = "running", busy = true },
    }
    test.same(terminal.quit_decision(statuses, "keep"), { "detach", "detach" })
    test.same(terminal.quit_decision(statuses, "end"), { "end", "end" })
  end)

  test.it("keeps confirmation for other programs and uncertain Pi states", function()
    for _, fields in ipairs {
      { agent_app = "other", agent_state = "idle" },
      { agent_state = "idle" },
      { agent_app = "pi" },
      { agent_app = "pi", agent_state = "working" },
      { agent_app = "pi", agent_state = "blocked" },
      { agent_app = "pi", agent_state = "idle", kind = "reconnecting" },
    } do
      fields.kind = fields.kind or "running"
      fields.busy = true
      local actions, reason = terminal.quit_decision({ fields })
      test.equal(actions, nil)
      test.equal(reason, "ask")
    end
  end)
end)

test.describe("Terminal busy status", function()
  test.it("reports a shell child while it runs and idle after it exits", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" })
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
      test.ok(wait_busy(false, 20), "idle status missing")
      test.ok(view.session:write("ping -n 12 127.0.0.1 > nul\r"))
      test.ok(wait_busy(true, 15), "child status missing")
      test.ok(wait_busy(false, 15), "idle status did not return")
    end)
    view:on_close()
    test.ok(ok, err)
  end)

  test.it("reports a PowerShell command that runs inside the shell itself", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "powershell.exe -NoLogo -NoProfile" })
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
      test.ok(wait_busy(false, 20), "idle status missing")
      -- Start-Sleep is a cmdlet: the shell starts no child process for it.
      test.ok(view.session:write("Start-Sleep -Seconds 10\r"))
      test.ok(wait_busy(true, 15), "in-shell command status missing")
      test.ok(wait_busy(false, 15), "idle status did not return")
    end)
    view:on_close()
    test.ok(ok, err)
  end)

  test.it("keeps a command busy when a program inside it prints prompt marks", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "powershell.exe -NoLogo -NoProfile" })
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
      test.ok(wait_busy(false, 20), "idle status missing")
      -- A nested shell or TUI ends its own commands with these marks.
      test.ok(view.session:write(
        "Start-Sleep -Seconds 1; [Console]::Write([char]27 + ']133;D;0' + [char]7 + [char]27 + ']133;A' + [char]7); Start-Sleep -Seconds 20\r"))
      test.ok(wait_busy(true, 15), "in-shell command status missing")
      local deadline = system.get_time() + 15
      repeat
        local _, status = view.session:update()
        test.ok(status.busy, "a foreign prompt mark ended the running command")
        coroutine.yield(0.05)
      until system.get_time() >= deadline
    end)
    view:on_close()
    test.ok(ok, err)
  end)
end)
