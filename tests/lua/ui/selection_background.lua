local Buffer = require "core.buffer"
local Editor = require "core.editor"
local style = require "core.style"
local test = require "core.test"

local function make_view(text)
  local buffer = Buffer(nil, nil, true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 400, 200
  return view, buffer
end

test.describe("Selection Background", function()
  test.it("draws selected newlines through the right edge", function()
    local view, buffer = make_view("one\n\nthree")
    buffer:set_selection(1, 2, 3, 3)

    local old_rect = renderer.draw_rect
    local old_text = renderer.draw_text
    local selection_rects = {}
    renderer.draw_rect = function(x, y, width, height, color)
      if color == style.selection then
        selection_rects[#selection_rects + 1] = {
          x = x, y = y, width = width, height = height
        }
      end
    end
    renderer.draw_text = function(font, text, x)
      return x + font:get_width(text)
    end

    local ok, err = pcall(function()
      view:prepare_line_body_draw_cache(1, 3)
      view:draw_line_body(1, 0, 0)
      view:draw_line_body(2, 0, view:get_line_height())
    end)
    renderer.draw_rect = old_rect
    renderer.draw_text = old_text
    buffer:on_close()
    if not ok then error(err, 0) end

    local right_edge_rects = {}
    for _, rect in ipairs(selection_rects) do
      if rect.x + rect.width == view.size.x then
        right_edge_rects[rect.y] = rect
      end
    end
    local first_line = right_edge_rects[0]
    local blank_line = right_edge_rects[view:get_line_height()]
    test.not_nil(first_line, "expected the first selected newline to reach the right edge")
    test.equal(first_line.x, style.code_font:get_width("one"))
    test.not_nil(blank_line, "expected a selection background on the blank line")
    test.equal(blank_line.x, 0)
    test.equal(blank_line.width, view.size.x)
  end)
end)
