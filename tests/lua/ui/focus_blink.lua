local core = require "core"
local test = require "core.test"
local View = require "core.view"

local function preserve_focus_state(fn)
  local old_active_view = core.active_view
  local old_active_window = core.active_window
  local old_event_window = core.event_window
  local old_blink_start = core.blink_start
  local old_blink_timer = core.blink_timer
  local old_redraw = core.redraw
  local ok, err = pcall(fn)
  core.active_view = old_active_view
  core.active_window = old_active_window
  core.event_window = old_event_window
  core.blink_start = old_blink_start
  core.blink_timer = old_blink_timer
  core.redraw = old_redraw
  if not ok then error(err, 0) end
end

test.describe("focus blink", function()
  test.test("active view changes restart the caret blink visible phase", function()
    preserve_focus_state(function()
      local first = View()
      local second = View()
      core.active_view = first
      core.active_window = core.window
      core.event_window = nil
      core.blink_start = -100
      core.blink_timer = -50

      core.set_active_view(second)

      test.equal(core.active_view, second)
      test.ok(core.blink_start ~= -100)
      test.equal(core.blink_timer, core.blink_start)
    end)
  end)

  test.test("window focus gained restarts the caret blink visible phase", function()
    preserve_focus_state(function()
      core.active_view = View()
      core.active_window = core.window
      core.event_window = nil
      core.blink_start = -100
      core.blink_timer = -50

      core.on_event("focusgained")

      test.ok(core.blink_start ~= -100)
      test.equal(core.blink_timer, core.blink_start)
    end)
  end)
end)
