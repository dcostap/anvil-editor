local core = require "core"
local ready = dofile("tests/fixtures/terminal_ready.lua")
local panes = require "core.panes"
local test = require "core.test"
local terminal = require "plugins.terminal"

local function wait_for(view, predicate, message)
  local deadline = system.get_time() + 20
  repeat
    view:update()
    local text = view.session:text_capture().text
    if predicate(text) then return text end
    coroutine.yield(0.02)
  until system.get_time() >= deadline
  error(message .. "\n" .. view.session:text_capture().text)
end

local function with_shell(shell, check)
  test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
  panes.reset_for_tests()
  terminal._set_native_for_tests(nil)
  local view = ready(terminal.open { cwd = system.getcwd(), shell = shell })
  local ok, err = pcall(check, view)
  view.session:close()
  panes.close(panes.pane_for_view(view), { force = true })
  panes.reset_for_tests()
  test.ok(ok, err)
end

local function check_recovery(keyboard)
  with_shell("powershell.exe -NoLogo -NoProfile", function(view)
    panes.present(view, { pane = panes.pane_for_view(view), focus = true })
    core.root_panel:update()
    wait_for(view, function(text) return text:find("PS .*>") end, "no first prompt")
    test.ok(view.session:write(
      "powershell.exe -NoLogo -NoProfile -File tests/fixtures/terminal_stale_modes.ps1"
      .. (keyboard == "modifyOtherKeys" and " -ModifyOtherKeys" or "") .. "\r"))
    wait_for(view, function(text)
      local after = text:match("MODES_LEFT_ON(.*)")
      return after and after:find("PS .*>")
    end, "no prompt after the crashed program")
    test.not_ok(view.snapshot.mouse_tracking, "mouse reporting stays on")
    test.ok(view.snapshot.cursor.visible, "the cursor stays hidden")

    view.session:focus(false)
    view.session:focus(true)
    test.ok(view:on_key_pressed("escape"))
    view:on_key_released("escape")
    test.ok(view:on_text_input("Write-Output "))
    test.ok(view:paste("plain-input"))
    test.ok(view:on_key_pressed("return"))
    view:on_key_released("return")
    local text = wait_for(view, function(text)
      return text:find("\nplain%-input\n")
    end, "the shell did not run the plain command")
    local after = text:match("MODES_LEFT_ON(.*)")
    test.not_ok(after:find("[", 1, true), after)
  end)
end

test.describe("Terminal modes after a crashed program", function()
  for _, keyboard in ipairs { "Kitty", "modifyOtherKeys" } do
    test.it("gives the prompt plain input after " .. keyboard, function() check_recovery(keyboard) end)
  end

  test.it("keeps custom prompt modes, terminal text and the exit code", function()
    with_shell('powershell.exe -NoLogo -NoProfile -File tests/fixtures/terminal_custom_prompt.ps1 "'
      .. DATADIR .. '/tools/shell-integration/anvil.ps1"', function(view)
        local text = wait_for(view, function(text) return text:find("EXIT_CODE=42", 1, true) end,
          "the custom prompt did not preserve the exit code")
        test.ok(text:find("BEFORE_PROMPT", 1, true), text)
        test.ok(text:find("CUSTOM_PROMPT", 1, true), text)
        test.ok(view.snapshot.mouse_tracking, "cleanup disabled the custom prompt's mouse input")
      end)
  end)
end)
