local core = require "core"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local RootPanel = require "core.rootpanel"
local config = require "core.config"
local test = require "core.test"

test.describe("Off-screen caret movement", function()
  test.it("shows a trail after scrolling hides the previous caret", function()
    local buffer = Buffer(nil, nil, true)
    local lines = {}
    for line = 1, 20 do lines[line] = "line " .. line end
    buffer:insert(1, 1, table.concat(lines, "\n"))
    buffer:clear_undo_redo()
    local view = TextView(buffer)
    local root = RootPanel()
    local old_root, old_active = core.root_panel, core.active_view
    local old_animated = config.animated_caret
    local old_time = system.get_time
    core.root_panel, core.active_view = root, view
    config.animated_caret = true
    local now = 50
    system.get_time = function() return now end
    local polygons = {}
    local old_rect, old_poly = renderer.draw_rect, renderer.draw_poly
    renderer.draw_rect = function() end
    renderer.draw_poly = function(points)
      polygons[#polygons + 1] = points
    end

    local ok, err = pcall(function()
      local function draw_target(line)
        root:begin_keyboard_caret_frame()
        if line then
          buffer:set_selection(line, 1)
          view:draw_caret(10, 100, line, 1, 1)
        end
        return root:draw_keyboard_caret()
      end

      draw_target(1)
      polygons = {}
      view.scroll.y = 300
      now = now + 0.01
      draw_target()
      test.equal(#polygons, 0, "an off-screen caret should not paint")
      now = now + 0.01
      draw_target(20)
      test.ok(#polygons > 0, "the returning caret should animate")
      test.equal(#polygons, 1)
    end)

    core.root_panel, core.active_view = old_root, old_active
    config.animated_caret = old_animated
    system.get_time = old_time
    renderer.draw_rect, renderer.draw_poly = old_rect, old_poly
    buffer:on_close()
    if not ok then error(err, 0) end
  end)

  test.it("keeps far scroll-jump trails independent of Buffer length", function()
    local old_time = system.get_time
    local old_rect, old_poly = renderer.draw_rect, renderer.draw_poly
    local old_animated, old_redraw = config.animated_caret, core.redraw
    local now = 0
    system.get_time = function() return now end
    renderer.draw_rect = function() end
    config.animated_caret = true

    local function first_jump_frame(scroll_distance, app_height)
      local root = RootPanel()
      root.size.x, root.size.y = 800, app_height
      local owner = { scroll = { x = 0, y = 0 } }
      local points
      -- Capture polygons so a failure cannot enter the native rasterizer.
      renderer.draw_poly = function(value) points = value end
      now = 0

      local function draw_target(line)
        root:begin_keyboard_caret_frame()
        if line then
          root:submit_keyboard_caret {
            x = 10, y = 100, width = 2, height = 20,
            owner = owner, line = line, col = 1,
            color = { 12, 34, 56, 255 },
            cell_width = 10, cell_height = 20,
            scroll_x = owner.scroll.x, scroll_y = owner.scroll.y,
          }
        end
        root:draw_keyboard_caret()
      end

      draw_target(1)
      owner.scroll.y = scroll_distance
      now = 0.01
      draw_target()
      now = 0.02
      draw_target(2)
      test.ok(points, "the returning caret should still draw a trail")
      return points
    end

    local ok, err = pcall(function()
      for _, direction in ipairs { -1, 1 } do
        for _, height in ipairs { 600, 1200 } do
          local far = first_jump_frame(direction * 40000, height)
          local farther = first_jump_frame(direction * 80000, height)
          test.same(farther, far, "longer Buffers must not produce longer off-screen trails")
        end
      end
    end)

    system.get_time = old_time
    renderer.draw_rect, renderer.draw_poly = old_rect, old_poly
    config.animated_caret, core.redraw = old_animated, old_redraw
    if not ok then error(err, 0) end
  end)
end)
