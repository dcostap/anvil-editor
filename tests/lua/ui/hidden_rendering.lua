local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local panes = require "core.panes"
local test = require "core.test"

-- Seam: core.step with a fake native window permission and real editing state.
test.describe("Hidden Project rendering", function()
  local saved, buffer, enabled

  test.before_each(function()
    saved = {
      poll_event = system.poll_event,
      should_render = system.window_should_render,
      redraw = core.redraw,
    }
    enabled = false
    system.window_should_render = function() return enabled end
    system.poll_event = function() end
    buffer = Buffer()
    buffer:insert(1, 1, "before")
    buffer:set_selection(1, 7)
    panes.place(function() return Editor(buffer) end, {placement = "new", focus = true})
  end)

  test.after_each(function()
    system.poll_event = saved.poll_event
    system.window_should_render = saved.should_render
    buffer:clean()
    panes.reset_for_tests()
    core.redraw = saved.redraw
  end)

  test.it("defers drawing without losing a pending redraw", function()
    core.redraw = true
    test.not_ok(core.step(system.get_time(), {immediate = true}), "hidden Project drew a frame")
    test.ok(core.redraw, "hidden Project consumed its pending redraw")
    enabled = true
    test.ok(core.step(system.get_time(), {immediate = true}))
  end)

  test.it("processes editing events while drawing is disabled", function()
    local delivered = false
    system.poll_event = function()
      if delivered then return end
      delivered = true
      return "textinput", " after"
    end
    test.not_ok(core.step(system.get_time(), {immediate = true}), "hidden event caused a frame")
    test.equal(buffer:get_text(1, 1, math.huge, math.huge), "before after")
    test.ok(core.redraw)
    enabled = true
    test.ok(core.step(system.get_time(), {immediate = true}))
    test.equal(buffer:get_text(1, 1, math.huge, math.huge), "before after")
  end)
end)
