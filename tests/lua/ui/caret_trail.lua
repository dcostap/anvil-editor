local Buffer = require "core.buffer"
local TextView = require "core.textview"
local config = require "core.config"
local style = require "core.style"
local test = require "core.test"

local function make_view()
  local buffer = Buffer(nil, nil, true)
  buffer:insert(1, 1, "alpha\nbeta")
  buffer:clear_undo_redo()
  local view = TextView(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 400, 200
  return view
end

local function with_caret_settings(fn)
  local saved = {
    animated_caret = config.animated_caret,
    caret_trail = config.caret_trail,
    caret_trail_duration = config.caret_trail_duration,
    caret_trail_max_points = config.caret_trail_max_points,
    caret_trail_min_distance = config.caret_trail_min_distance,
    caret_trail_opacity = config.caret_trail_opacity,
    caret_trail_width = config.caret_trail_width,
    style_caret_trail = style.caret_trail,
    redraw = core.redraw,
  }
  local old_time = system.get_time
  local old_rect = renderer.draw_rect
  local ok, err = pcall(fn)
  config.animated_caret = saved.animated_caret
  config.caret_trail = saved.caret_trail
  config.caret_trail_duration = saved.caret_trail_duration
  config.caret_trail_max_points = saved.caret_trail_max_points
  config.caret_trail_min_distance = saved.caret_trail_min_distance
  config.caret_trail_opacity = saved.caret_trail_opacity
  config.caret_trail_width = saved.caret_trail_width
  style.caret_trail = saved.style_caret_trail
  core.redraw = saved.redraw
  system.get_time = old_time
  renderer.draw_rect = old_rect
  if not ok then error(err, 0) end
end

test.describe("caret trail", function()
  test.it("shows and expires a customizable trail after caret movement", function()
    with_caret_settings(function()
      local view = make_view()
      local now = 10
      local rects = {}
      system.get_time = function() return now end
      renderer.draw_rect = function(x, y, w, h, color)
        rects[#rects + 1] = { x = x, y = y, w = w, h = h, color = color }
      end
      config.animated_caret = false
      config.caret_trail = true
      config.caret_trail_duration = 0.2
      config.caret_trail_max_points = 8
      config.caret_trail_min_distance = 1
      config.caret_trail_opacity = 0.5
      config.caret_trail_width = 3
      style.caret_trail = { 12, 34, 56, 200 }

      view:draw_caret(10, 20, 1, 1, 1)
      test.equal(#rects, 1)

      rects = {}
      now = 10.01
      core.redraw = false
      view:draw_caret(110, 20, 1, 5, 1)
      test.ok(#rects > 1, "expected trail marks before the live caret")
      test.equal(rects[1].color[1], 12)
      test.equal(rects[1].color[2], 34)
      test.equal(rects[1].color[3], 56)
      test.ok(rects[1].color[4] <= 100)
      test.equal(rects[1].w, 3)
      test.ok(core.redraw, "expected the fading trail to request another frame")

      rects = {}
      now = 10.3
      view:draw_caret(110, 20, 1, 5, 1)
      test.equal(#rects, 1)
    end)
  end)
end)
