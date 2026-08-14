local style = require "core.style"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"

require "plugins.indent_guides"

local function set_text(buffer, text)
  buffer.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    buffer.lines[#buffer.lines + 1] = line
  end
  if #buffer.lines == 0 then buffer.lines[1] = "\n" end
  buffer:clear_undo_redo()
  buffer:clean()
  buffer:set_selection(1, 1)
end

local function new_view(text)
  local buffer = Buffer()
  set_text(buffer, text or "")
  local view = TextView(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 80, 200
  return buffer, view
end

test.describe("indent guide drawing", function()
  test.it("batches visible guide rects with draw_rect_grid", function()
    local buffer, view = new_view(string.rep(" ", 1000) .. "x")
    local rect_grid_calls = 0
    local guide_rect_calls = 0
    local old_draw_rect = renderer.draw_rect
    local old_draw_rect_grid = renderer.draw_rect_grid
    local old_draw_text = renderer.draw_text

    renderer.draw_rect = function(_, _, _, _, color)
      if color == style.indent_guide then guide_rect_calls = guide_rect_calls + 1 end
    end
    renderer.draw_rect_grid = function(_, _, _, _, _, count, color)
      if color == style.indent_guide then rect_grid_calls = rect_grid_calls + 1 end
    end
    renderer.draw_text = function(_, text, x)
      return x + #tostring(text)
    end

    local ok, err = pcall(function()
      local x, y = view:get_line_screen_position(1)
      view:draw_line_body(1, x, y)
    end)
    renderer.draw_rect = old_draw_rect
    renderer.draw_rect_grid = old_draw_rect_grid
    renderer.draw_text = old_draw_text
    if not ok then error(err) end

    test.ok(rect_grid_calls > 0, "expected indent guides to use renderer.draw_rect_grid")
    test.equal(guide_rect_calls, 0)
    buffer:on_close()
  end)
end)
