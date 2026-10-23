local ready = dofile("tests/fixtures/terminal_ready.lua")
local command = require "core.command"
local core = require "core"
local panes = require "core.panes"
local terminal = require "plugins.terminal"
local test = require "core.test"

local function select_option(text)
  for i, option in ipairs(core.nag_view.options) do
    if option.text == text then
      core.nag_view:change_hovered(i)
      test.ok(command.perform "core:select_dialog_entry")
      return
    end
  end
  test.fail("missing confirmation option: " .. text)
end

test.describe("Terminal Pane close", function()
  test.it("keeps busy terminals open until confirmed and closes idle terminals without asking", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" })
    local pane = panes.pane_for_view(view)
    local function wait_busy(expected)
      local deadline = system.get_time() + 20
      repeat
        local _, status = view.session:update()
        if status.busy == expected then return end
        coroutine.yield(0.01)
      until system.get_time() >= deadline
      test.fail("terminal did not report the expected busy state")
    end
    local ok, err = pcall(function()
      wait_busy(false)
      test.ok(view.session:write("ping -n 60 127.0.0.1 > nul\r"))
      wait_busy(true)
      panes.close(pane)
      test.ok(panes.contains(pane), "busy Pane closed without confirmation")
      test.ok(core.nag_view.visible)
      select_option("Cancel")
      test.ok(panes.contains(pane))
      test.ok(view.session)
      panes.close(pane)
      select_option("End")
      test.ok(not panes.contains(pane))
      test.equal(view.session, nil)

      view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" })
      pane = panes.pane_for_view(view)
      wait_busy(false)
      test.ok(panes.close(pane))
      test.ok(not core.nag_view.visible)
      test.equal(view.session, nil)
    end)
    if panes.contains(pane) then panes.close(pane, { force = true }) end
    test.ok(ok, err)
  end)

  test.it("closes a new terminal without asking while its shell starts", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    local pane = panes.pane_for_view(view)
    local _, status = view.session:update()
    test.equal(status.kind, "reconnecting", "the shell started before the close")
    test.ok(panes.close(pane))
    test.ok(not core.nag_view.visible, "a starting terminal asked before it closed")
    test.ok(not panes.contains(pane))
    if panes.contains(pane) then
      if core.nag_view.visible then select_option("End") end
      panes.close(pane, { force = true })
    end
  end)
end)
