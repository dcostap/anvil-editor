local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"

require "plugins.indent_guides"

local function set_text(doc, text)
  doc.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    doc.lines[#doc.lines + 1] = line
  end
  if #doc.lines == 0 then doc.lines[1] = "\n" end
  doc:clear_undo_redo()
  doc:clean()
  doc:set_selection(1, 1)
end

local function new_view(text)
  local doc = Doc()
  set_text(doc, text or "")
  local view = DocView(doc)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 80, 200
  return doc, view
end

test.describe("indent guide drawing", function()
  test.it("batches visible guide rects with draw_rect_grid", function()
    local doc, view = new_view(string.rep(" ", 1000) .. "x")
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
    doc:on_close()
  end)
end)
