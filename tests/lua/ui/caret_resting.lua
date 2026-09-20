local CaretRenderer = require "core.caret_renderer"
local test = require "core.test"

test.describe("Resting caret", function()
  test.it("keeps scaled caret thickness constant across positions", function()
    local core = require "core"
    local style = require "core.style"
    local config = require "core.config"
    local view = require("core.editor")(require("core.buffer")())
    local old_width, old_active = style.caret_width, core.active_view
    local old_rect, old_submit = renderer.draw_rect, core.root_panel.submit_keyboard_caret
    local old_animated = config.animated_caret
    local widths = {}
    local function capture(x, y, w)
      widths[#widths + 1] = math.floor(x + w + 0.5) - math.floor(x + 0.5)
    end
    local ok, err = pcall(function()
      style.caret_width = 1.5
      config.animated_caret = true
      renderer.draw_rect = capture
      core.root_panel.submit_keyboard_caret = function(_, target)
        capture(target.x, target.y, target.width)
      end
      for _, focused in ipairs { false, true } do
        core.active_view = focused and view or nil
        for _, x in ipairs { 10, 10.25, 10.5, 10.75 } do
          view:draw_caret(x, 0, 1, 1)
        end
      end
      test.equal(#widths, 8)
      for _, width in ipairs(widths) do
        test.equal(width, widths[1], "caret thickness changes with position")
      end
    end)
    style.caret_width, core.active_view = old_width, old_active
    renderer.draw_rect, core.root_panel.submit_keyboard_caret = old_rect, old_submit
    config.animated_caret = old_animated
    if not ok then error(err, 0) end
  end)

  test.it("stops painting the trail when movement has ended", function()
    local caret = CaretRenderer.new()
    local owner = {}
    local color, trail_color = { 0, 0, 0, 255 }, { 30, 30, 30, 255 }
    local painted = {}
    local old_rect, old_poly = renderer.draw_rect, renderer.draw_poly
    renderer.draw_rect = function(_, _, _, _, paint) painted[#painted + 1] = paint end
    renderer.draw_poly = function(_, paint) painted[#painted + 1] = paint end
    local ok, err = pcall(function()
      local function draw(now, x, y, line)
        caret:begin_frame(true)
        caret:submit {
          x = x, y = y, width = 2, height = 20,
          owner = owner, line = line, col = 1,
          color = color, trail_color = trail_color,
        }
        return caret:draw(now, 0.15, 0.025, 1, 1, 6)
      end
      draw(0, 10.25, 10.25, 1)
      draw(0.01, 90.25, 70.25, 2)
      for i = 2, 200 do draw(i / 60, 90.25, 70.25, 2) end
      painted = {}
      test.equal(draw(4, 90.25, 70.25, 2), false)
      test.ok(#painted > 0)
      for _, paint in ipairs(painted) do
        test.same(paint, color, "the stopped caret still paints a trail")
      end
    end)
    renderer.draw_rect, renderer.draw_poly = old_rect, old_poly
    if not ok then error(err, 0) end
  end)

  test.it("snaps to caret positions from a new text revision", function()
    local caret = CaretRenderer.new()
    local owner = {}
    local drawn = {}
    local old_rect = renderer.draw_rect
    renderer.draw_rect = function(x, y, width, height)
      drawn[#drawn + 1] = { x, y, width, height }
    end
    local ok, err = pcall(function()
      local function draw(now, x, col, revision, height)
        caret:begin_frame(true)
        caret:submit {
          x = x, y = 10, width = 2, height = height,
          owner = owner, line = 1, col = col, revision = revision,
          color = { 0, 0, 0, 255 }, cell_width = 10, cell_height = height,
        }
        return caret:draw(now, 0.15, 0.025, 1, 1, 6)
      end
      test.equal(draw(0, 80, 8, 1, 28), false)
      test.equal(draw(0.01, 10, 1, 2, 20), false)
      test.same(drawn[#drawn], { 10, 10, 2, 20 })
    end)
    renderer.draw_rect = old_rect
    if not ok then error(err, 0) end
  end)
end)
