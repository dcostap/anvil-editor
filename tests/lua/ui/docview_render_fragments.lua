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

  test.it("caches provider output and invalidates targeted lines", function()
    local view = make_view("one\ntwo")
    local calls = {}
    view:add_line_render_provider("test", {
      line_generation = function(_, _, line) return line end,
      render_line = function(_, _, line, context)
        calls[line] = (calls[line] or 0) + 1
        return { fragments = { { text = context.source_text } } }
      end,
    })

    view:get_line_render(1)
    view:get_line_render(1)
    view:get_line_render(2)
    test.equal(calls[1], 1)
    test.equal(calls[2], 1)
    view:invalidate_line_render("test", 1, 1)
    view:get_line_render(1)
    view:get_line_render(2)
    test.equal(calls[1], 2)
    test.equal(calls[2], 1)
    local diagnostics = view:get_render_cache_diagnostics()
    test.ok(diagnostics.line_hits >= 2)
    test.equal(diagnostics.line_invalidations, 1)
  end)

  test.it("invalidates cached provider output after text transactions", function()
    local view, doc = make_view("one")
    local calls = 0
    view:add_line_render_provider("test", {
      render_line = function(_, _, _, context)
        calls = calls + 1
        return { fragments = { { text = context.source_text } } }
      end,
    })
    test.equal(view:get_line_render(1).source_text, "one")
    doc:insert(1, 4, "!")
    test.equal(view:get_line_render(1).source_text, "one!")
    test.equal(calls, 2)
  end)

  test.it("routes pointer cursor and clicks through rendered widgets", function()
    local view = make_view("widget")
    local clicked = false
    view:add_line_render_provider("widget", {
      render_line = function()
        return {
          fragments = {
            {
              source_col1 = 1,
              source_col2 = 7,
              width = 40,
              widget = {
                width = 40,
                height = view:get_line_height(),
                cursor = "hand",
                on_mouse_pressed = function(_, owner, hit, button)
                  test.equal(owner, view)
                  test.equal(hit.line, 1)
                  test.equal(button, "left")
                  clicked = true
                  return true
                end,
              },
            },
          },
        }
      end,
    })
    local x, y = view:get_line_screen_position(1)
    x, y = x + 5, y + 5
    view:on_mouse_moved(x, y)
    test.equal(view.cursor, "hand")
    test.equal(view:on_mouse_pressed("left", x, y, 1), true)
    test.equal(clicked, true)
  end)

  test.it("releases cached entries beyond EOF after tail deletion", function()
    local view = make_view("one\ntwo\nthree\nfour\nfive")
    view:add_line_render_provider("tail", {
      render_line = function(_, owner, line)
        return {
          fragments = {
            { source_col1 = 1, source_col2 = #(owner.doc.lines[line] or ""), text = "cached" },
          },
        }
      end,
    })
    view:get_line_render(5)
    test.equal(view:get_render_cache_diagnostics().resident_line_entries, 1)
    view.doc:remove(3, #view.doc.lines[3], 5, #view.doc.lines[5])
    test.equal(view:get_render_cache_diagnostics().resident_line_entries, 0)
  end)

  test.it("invalidates cached output after legacy raw text edits", function()
    local view, doc = make_view("one")
    local calls = 0
    view:add_line_render_provider("test", {
      render_line = function(_, _, _, context)
        calls = calls + 1
        return { fragments = { { text = context.source_text } } }
      end,
    })
    test.equal(view:get_line_render(1).source_text, "one")
    doc:raw_insert(1, 1, "x", doc.undo_stack, system.get_time())
    test.equal(view:get_line_render(1).source_text, "xone")
    test.equal(calls, 2)
  end)

  test.it("removes line render providers", function()
    local view = make_view("abc")
    view:add_line_render_provider("test", { render_line = function() return { fragments = {} } end })
    test.equal(view:has_line_render_providers(), true)
    test.equal(view:remove_line_render_provider("test"), true)
    test.equal(view:has_line_render_providers(), false)
  end)
end)
