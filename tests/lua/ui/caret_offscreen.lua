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
end)
