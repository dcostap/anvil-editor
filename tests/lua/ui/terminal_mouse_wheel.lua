local core = require "core"
local panes = require "core.panes"
local test = require "core.test"
local terminal = require "plugins.terminal"

test.describe("Terminal View wheel input", function()
  test.it("sends wheel input after a full-screen application sets raw console input", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    panes.reset_for_tests()
    terminal._set_native_for_tests(nil)
    local view = terminal.open({
      cwd = system.getcwd(),
      shell = [[powershell.exe -NoLogo -NoProfile -File tests/fixtures/terminal_mouse_wheel.ps1]],
    })
    test.ok(view)
    local ok, failure = pcall(function()
      local deadline = system.get_time() + 8
      while system.get_time() < deadline do
        core.root_panel:update()
        view:update()
        if view.snapshot.mouse_tracking
          and view.session:text_capture().text:find("WHEEL_READY", 1, true) then break end
        coroutine.yield(0.005)
      end
      test.ok(view.snapshot.mouse_tracking, "Application mouse tracking is not active")
      panes.present(view, { pane = panes.pane_for_view(view), focus = true })
      core.root_panel:update()
      core.on_event("mousemoved", view.position.x + 6 + view.cell_width,
        view.position.y + 6 + view.cell_height, 0, 0)
      test.equal(core.root_panel:view_at(core.root_panel.mouse.x, core.root_panel.mouse.y), view)
      core.on_event("mousewheel", 1, 0)
      deadline = system.get_time() + 8
      local text = ""
      while system.get_time() < deadline do
        view:update()
        text = view.session:text_capture().text
        if text:find("WHEEL_RECEIVED", 1, true) then break end
        coroutine.yield(0.005)
      end
      test.ok(text:find("WHEEL_RECEIVED", 1, true), text)
    end)
    view.session:close()
    panes.close(panes.pane_for_view(view), { force = true })
    panes.reset_for_tests()
    if not ok then error(failure) end
  end)
end)
