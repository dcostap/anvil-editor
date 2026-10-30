local core = require "core"
local Buffer = require "core.buffer"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local TextView = require "core.textview"
local test = require "core.test"
local View = require "core.view"

local function preserve_focus_state(fn)
  local old_active_view = core.active_view
  local old_active_window = core.active_window
  local old_event_window = core.event_window
  local old_blink_start = core.blink_start
  local old_blink_timer = core.blink_timer
  local old_redraw = core.redraw
  local old_time = system.get_time
  local old_window_has_focus = system.window_has_focus
  local old_animated_caret = config.animated_caret
  local old_disable_blink = config.disable_blink
  local ok, err = pcall(fn)
  core.active_view = old_active_view
  core.active_window = old_active_window
  core.event_window = old_event_window
  core.blink_start = old_blink_start
  core.blink_timer = old_blink_timer
  core.redraw = old_redraw
  system.get_time = old_time
  system.window_has_focus = old_window_has_focus
  config.animated_caret = old_animated_caret
  config.disable_blink = old_disable_blink
  if not ok then error(err, 0) end
end

local function draw_caret(view)
  local count = 0
  local old_draw_rect = renderer.draw_rect
  renderer.draw_rect = function(x, y, width, height, color)
    if color == style.caret then count = count + 1 end
    return old_draw_rect(x, y, width, height, color)
  end
  renderer.begin_frame(core.window)
  local ok, err = pcall(view.draw_overlay, view)
  renderer.end_frame()
  renderer.draw_rect = old_draw_rect
  if not ok then error(err, 0) end
  return count
end

local function hidden_caret_view()
  local buffer = Buffer()
  buffer:insert(1, 1, "caret")
  local view = TextView(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 300, 120
  view:update()
  return view
end

test.describe("focus blink", function()
  test.test("active view changes make the caret visible", function()
    preserve_focus_state(function()
      local now = 100
      system.get_time = function() return now end
      system.window_has_focus = function() return true end
      config.animated_caret = false
      config.disable_blink = false
      local first = hidden_caret_view()
      local second = hidden_caret_view()
      core.active_view = first
      core.active_window = core.window
      core.event_window = nil
      core.blink_start = now
      core.blink_timer = now + config.blink_period * 0.75
      test.equal(draw_caret(first), 0, "expected the first caret to be in its hidden phase")

      core.set_active_view(second)

      test.equal(core.active_view, second)
      test.ok(draw_caret(second) > 0, "expected focus to show the new caret")
    end)
  end)

  test.test("window focus gained makes the caret visible", function()
    preserve_focus_state(function()
      local now = 100
      system.get_time = function() return now end
      system.window_has_focus = function() return true end
      config.animated_caret = false
      config.disable_blink = false
      core.active_view = hidden_caret_view()
      core.active_window = core.window
      core.event_window = nil
      core.blink_start = now
      core.blink_timer = now + config.blink_period * 0.75
      test.equal(draw_caret(core.active_view), 0,
        "expected the caret to be in its hidden phase before focus returns")

      core.on_event("focusgained")

      test.ok(draw_caret(core.active_view) > 0,
        "expected focus return to show the caret")
    end)
  end)

  test.test("window focus gained clears a stale modifier before the next input", function()
    local invoked = false
    local binding = function() invoked = true end
    local old_alt = keymap.modkeys.alt
    keymap.add({ f13 = { binding } })

    local ok, err = pcall(function()
      keymap.modkeys.alt = true
      core.on_event("focusgained")
      core.on_event("keypressed", "f13", {})
    end)

    keymap.unbind("f13", binding)
    keymap.modkeys.alt = old_alt
    if not ok then error(err, 0) end
    test.ok(invoked, "expected unmodified input after window focus returned")
  end)
end)
