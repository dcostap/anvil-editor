local test = require "core.test"
local terminal = require "plugins.terminal"
local panes = require "core.panes"
local snoozed = require "core.snoozed_panes"
local storage = require "core.storage"
local ready = dofile("tests/fixtures/terminal_ready.lua")

test.describe("Snoozed Terminal restore", function()
  for _, reason in ipairs {"deadline", "selection", "removal"} do
    test.it("keeps an ended shell on disk until " .. reason, function()
      test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
      local original = ready(terminal.TerminalView {shell = "cmd.exe /D /Q"})
      local state = original:get_state()
      local host = original.session:stats().host_pid
      original:end_session()
      require("terminal_native").finish_close_commands()
      local limit = system.get_time() + 30
      while system.process_state(host) ~= "ended" and system.get_time() < limit do coroutine.yield(0.01) end
      test.equal(system.process_state(host), "ended")

      local deadline = os.time() + 3600
      test.ok(storage.save("sidebar", "snoozes", {[state.session_id] = deadline}))
      local restored = terminal.from_state(state, deadline)
      local pane = panes.create {factory = function() return restored end, focus = false}
      panes.snooze(pane)
      snoozed.check()
      test.is_nil(restored.session, "Workspace restore started a snoozed shell")
      test.equal(restored:get_state().session_id, state.session_id)
      if reason == "selection" then
        panes.focus(pane)
        test.ok(panes.is_snoozed(pane))
      elseif reason == "deadline" then
        test.ok(storage.save("sidebar", "snoozes", {[state.session_id] = os.time() - 1}))
        snoozed.check()
        test.not_ok(panes.is_snoozed(pane))
      else
        storage.clear("sidebar", "snoozes")
        snoozed.wake(pane)
        test.not_ok(panes.is_snoozed(pane))
      end
      ready(restored)
      test.equal(restored.session_id, state.session_id)
      test.ok(restored:write_input("echo awake\r"))
      restored:on_close()
      storage.clear("sidebar", "snoozes")
    end)
  end

  test.it("attaches to a live snoozed shell without replacing it", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local original = ready(terminal.TerminalView {shell = "cmd.exe /D /Q"})
    local state, pid = original:get_state(), original.session:stats().shell_pid
    original:detach_session()
    local restored = ready(terminal.from_state(state, os.time() + 3600))
    test.equal(restored.session:stats().shell_pid, pid)
    restored:on_close()
  end)
end)
