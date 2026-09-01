local core = require "core"
local test = require "core.test"


test.describe("Core terminal events", function()
  test.it("updates without rendering for a clean terminal output event", function()
    local previous_poll_event = system.poll_event
    local previous_update = core.root_panel.update
    local previous_draw = core.root_panel.draw
    local previous_redraw = core.redraw
    local delivered = false
    local updated, drawn = false, false
    local ok, err

    system.poll_event = function()
      if delivered then return nil end
      delivered = true
      return "terminaloutput"
    end
    core.root_panel.update = function() updated = true end
    core.root_panel.draw = function() drawn = true end
    core.redraw = false
    ok, err = pcall(function()
      local result = core.step(system.get_time() - 1)
      test.ok(updated)
      test.not_ok(drawn)
      test.not_ok(result)
    end)

    system.poll_event = previous_poll_event
    core.root_panel.update = previous_update
    core.root_panel.draw = previous_draw
    core.redraw = previous_redraw
    if not ok then error(err, 0) end
  end)
end)
