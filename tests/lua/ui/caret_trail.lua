local Buffer = require "core.buffer"
local TextView = require "core.textview"
local RootPanel = require "core.rootpanel"
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
    root_panel = core.root_panel,
    active_view = core.active_view,
    title_bar = core.title_bar,
    nag_view = core.nag_view,
    global_prompt_bar = core.global_prompt_bar,
    status_bar = core.status_bar,
    animated_caret = config.animated_caret,
    animated_caret_animation_length = config.animated_caret_animation_length,
    animated_caret_short_animation_length = config.animated_caret_short_animation_length,
    animated_caret_trail_size = config.animated_caret_trail_size,
    caret = style.caret,
    caret_trail = style.caret_trail,
    redraw = core.redraw,
  }
  local old_time = system.get_time
  local old_rect = renderer.draw_rect
  local old_poly = renderer.draw_poly
  local ok, err = pcall(fn)
  core.root_panel = saved.root_panel
  core.active_view = saved.active_view
  core.title_bar = saved.title_bar
  core.nag_view = saved.nag_view
  core.global_prompt_bar = saved.global_prompt_bar
  core.status_bar = saved.status_bar
  config.animated_caret = saved.animated_caret
  config.animated_caret_animation_length = saved.animated_caret_animation_length
  config.animated_caret_short_animation_length = saved.animated_caret_short_animation_length
  config.animated_caret_trail_size = saved.animated_caret_trail_size
  style.caret = saved.caret
  style.caret_trail = saved.caret_trail
  core.redraw = saved.redraw
  system.get_time = old_time
  renderer.draw_rect = old_rect
  renderer.draw_poly = old_poly
  if not ok then error(err, 0) end
end

local function draw_frame(root, view, x, y, line, col)
  core.active_view = view
  root:begin_keyboard_caret_frame()
  view.buffer:set_selection(line or 1, col or 1)
  view:draw_caret(x, y, line or 1, col or 1, 1)
  root:draw_keyboard_caret()
end

local function x_bounds(points)
  local min_x, max_x = math.huge, -math.huge
  for _, point in ipairs(points) do
    min_x = math.min(min_x, point[1])
    max_x = math.max(max_x, point[1])
  end
  return min_x, max_x
end

test.describe("caret trail", function()
  test.it("follows the focused caret across Text Views", function()
    with_caret_settings(function()
      local first = make_view()
      local second = make_view()
      local root = RootPanel()
      root.size.x, root.size.y = 500, 300
      core.root_panel = root
      core.title_bar = nil
      core.nag_view = nil
      core.global_prompt_bar = nil
      core.status_bar = nil

      local now = 10
      local polygons = {}
      local rects = {}
      system.get_time = function() return now end
      renderer.draw_rect = function(x, y, width, height, color)
        rects[#rects + 1] = { x = x, y = y, width = width, height = height, color = color }
      end
      renderer.draw_poly = function(points, color)
        polygons[#polygons + 1] = { points = points, color = color }
      end
      config.animated_caret = true
      config.animated_caret_animation_length = 0.15
      config.animated_caret_short_animation_length = 0.04
      config.animated_caret_trail_size = 1
      style.caret = { 12, 34, 56, 255 }
      style.caret_trail = { 90, 80, 70, 255 }

      draw_frame(root, first, 10, 20)
      polygons = {}
      rects = {}

      now = 10.01
      core.redraw = false
      draw_frame(root, second, 210, 100)

      test.equal(#polygons, 1)
      test.equal(polygons[1].color[1], 90)
      test.equal(#rects, 1)
      test.equal(rects[1].color[1], 12)
      local min_x, max_x = x_bounds(polygons[1].points)
      test.ok(min_x < 210, "expected the rear corners to follow from the first Text View")
      test.ok(max_x >= 210, "expected the front corners to reach toward the focused caret")
      test.ok(core.redraw, "expected the moving caret to request another frame")
    end)
  end)

  test.it("stretches smoothly across a horizontal jump", function()
    with_caret_settings(function()
      local view = make_view()
      local root = RootPanel()
      root.size.x, root.size.y = 500, 300
      core.root_panel = root
      core.title_bar = nil
      core.nag_view = nil
      core.global_prompt_bar = nil
      core.status_bar = nil

      local now = 20
      local polygons = {}
      system.get_time = function() return now end
      renderer.draw_rect = function() end
      renderer.draw_poly = function(points)
        polygons[#polygons + 1] = points
      end
      config.animated_caret = true
      config.animated_caret_animation_length = 0.15
      config.animated_caret_short_animation_length = 0.04
      config.animated_caret_trail_size = 1

      draw_frame(root, view, 10, 20)
      polygons = {}

      now = 20.01
      draw_frame(root, view, 210, 20, 1, 5)

      test.equal(#polygons, 1)
      local min_x, max_x = x_bounds(polygons[1])
      test.ok(min_x < 210, "expected a visible horizontal trail")
      test.ok(max_x >= 210, "expected the leading edge to follow the target")
    end)
  end)
end)
