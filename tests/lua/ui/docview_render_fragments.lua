local Doc = require "core.doc"
local DocView = require "core.docview"
local style = require "core.style"
local test = require "core.test"

local function make_view(text)
  local doc = Doc(nil, nil, true)
  doc:insert(1, 1, text)
  doc:clear_undo_redo()
  local view = DocView(doc)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 500, 120
  view:set_wrapping_enabled(false)
  return view, doc
end

test.describe("DocView render fragments", function()
  test.it("maps hidden source markers to stable x positions", function()
    local view = make_view("## Heading")
    view:add_line_render_provider("markdown", {
      render_line = function()
        return {
          fragments = {
            { source_col1 = 1, source_col2 = 4, hidden = true },
            { source_col1 = 4, source_col2 = 11, text = "Heading" },
          },
        }
      end,
    })

    local width = view:get_font():get_width("Heading")
    test.equal(view:get_col_x_offset(1, 1), 0)
    test.equal(view:get_col_x_offset(1, 3), 0)
    test.equal(view:get_col_x_offset(1, 4), 0)
    test.equal(view:get_col_x_offset(1, 11), width)
    test.equal(view:get_x_offset_col(1, 0), 1)
    test.equal(view:get_x_offset_col(1, width + 100), 11)
  end)

  test.it("normalizes fragments without explicit source columns", function()
    local view = make_view("abc")
    view:add_line_render_provider("test", {
      render_line = function()
        return { fragments = { { text = "abc" } } }
      end,
    })

    local width = view:get_font():get_width("abc")
    test.equal(view:get_col_x_offset(1, 4), width)

    local old_draw_text = renderer.draw_text
    local drawn = {}
    renderer.draw_text = function(font, text, x, y, color, opts)
      drawn[#drawn + 1] = text
      return x + font:get_width(text, opts)
    end
    local ok, err = pcall(function() view:draw_line_text(1, 0, 0) end)
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end
    test.same(drawn, { "abc" })
  end)

  test.it("draws visible fragments and skips hidden syntax", function()
    local view = make_view("**bold**")
    view:add_line_render_provider("markdown", {
      render_line = function()
        return {
          fragments = {
            { source_col1 = 1, source_col2 = 3, hidden = true },
            { source_col1 = 3, source_col2 = 7, text = "bold", color = style.syntax.keyword },
            { source_col1 = 7, source_col2 = 9, hidden = true },
          },
        }
      end,
    })

    local old_draw_text = renderer.draw_text
    local drawn = {}
    renderer.draw_text = function(font, text, x, y, color)
      drawn[#drawn + 1] = { text = text, x = x, y = y, color = color }
      return x + font:get_width(text)
    end
    local ok, err = pcall(function() view:draw_line_text(1, 10, 20) end)
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end

    test.equal(#drawn, 1)
    test.equal(drawn[1].text, "bold")
    test.same(drawn[1].color, style.syntax.keyword)
  end)

  test.it("uses rendered x mapping for inline decoration widths", function()
    local view = make_view("**bold**")
    view:add_line_render_provider("markdown", {
      render_line = function()
        return {
          fragments = {
            { source_col1 = 1, source_col2 = 3, hidden = true },
            { source_col1 = 3, source_col2 = 7, text = "bold" },
            { source_col1 = 7, source_col2 = 9, hidden = true },
          },
        }
      end,
    })
    view:add_decoration_provider("test", {
      inline_ranges = function()
        return {
          { col1 = 1, col2 = 3, color = { 1, 2, 3, 255 } },
          { col1 = 3, col2 = 7, color = { 4, 5, 6, 255 } },
        }
      end,
    })

    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    local rects = {}
    renderer.draw_rect = function(x, y, w, h, color)
      rects[#rects + 1] = { w = w, color = color }
    end
    renderer.draw_text = function(font, text, x, y, color, opts) return x + font:get_width(text, opts) end
    local ok, err = pcall(function() view:draw_line_body(1, 0, 0) end)
    renderer.draw_rect = old_draw_rect
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end

    local visible_width = view:get_font():get_width("bold")
    local found_visible = false
    for _, rect in ipairs(rects) do
      if rect.color[1] == 4 then
        found_visible = true
        test.equal(rect.w, visible_width)
      end
      test.not_equal(rect.color[1], 1)
    end
    test.ok(found_visible)
  end)

  test.it("falls back to raw rendering for raw passthrough lines", function()
    local view = make_view("raw")
    view:add_line_render_provider("markdown", {
      render_line = function()
        return { raw_passthrough = true }
      end,
    })
    test.equal(view:get_col_x_offset(1, 4), view:get_font():get_width("raw"))
  end)

  test.it("removes line render providers", function()
    local view = make_view("abc")
    view:add_line_render_provider("test", { render_line = function() return { fragments = {} } end })
    test.equal(view:has_line_render_providers(), true)
    test.equal(view:remove_line_render_provider("test"), true)
    test.equal(view:has_line_render_providers(), false)
  end)
end)
