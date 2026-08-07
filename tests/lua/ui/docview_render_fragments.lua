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

  test.it("invalidates cached provider output after text transactions", function()
    local view, doc = make_view("one")
    view:add_line_render_provider("test", {
      render_line = function(_, _, _, context)
        return { fragments = { { text = context.source_text } } }
      end,
    })
    test.equal(view:get_line_render(1).source_text, "one")
    doc:insert(1, 4, "!")
    test.equal(view:get_line_render(1).source_text, "one!")
  end)

  test.it("draws generic fragment backgrounds and strikethrough decorations", function()
    local view = make_view("styled")
    local background = { 1, 2, 3, 4 }
    view:add_line_render_provider("decorated", {
      render_line = function()
        return {
          fragments = {
            {
              source_col1 = 1, source_col2 = 7, text = "styled",
              background = background, strikethrough = true,
            },
          },
        }
      end,
    })
    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    local rectangles = {}
    renderer.draw_rect = function(x, y, w, h, color)
      rectangles[#rectangles + 1] = { x = x, y = y, w = w, h = h, color = color }
    end
    renderer.draw_text = function(font, text, x, _, _, opts)
      return x + font:get_width(text, opts)
    end
    view:draw_line_text(1, 0, 0)
    renderer.draw_text = old_draw_text
    renderer.draw_rect = old_draw_rect
    test.equal(#rectangles, 2)
    test.equal(rectangles[1].color, background)
  end)

  test.it("routes pointer cursor and clicks through rendered text fragments", function()
    local view = make_view("link")
    local clicked = false
    local link_fragment
    view:add_line_render_provider("interactive", {
      render_line = function()
        link_fragment = {
          source_col1 = 1, source_col2 = 5, text = "link", cursor = "hand",
          on_mouse_pressed = function(_, owner, hit, button)
            test.equal(owner, view)
            test.equal(hit.line, 1)
            test.equal(button, "left")
            clicked = true
            return true
          end,
        }
        return {
          fragments = { link_fragment },
        }
      end,
    })
    local x, y = view:get_line_screen_position(1)
    view:on_mouse_moved(x + 2, y + 2)
    test.equal(view.cursor, "hand")
    local hovered_fragment = test.not_nil(
      view:get_render_fragment_at_position(x + 2, y + 2)
    ).fragment
    test.equal(hovered_fragment.hovered, true)

    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    local hover_drawn = false
    renderer.draw_rect = function(_, _, _, _, color)
      if color == style.interactive_hover_background then hover_drawn = true end
    end
    renderer.draw_text = function(font, text, draw_x)
      return draw_x + font:get_width(text)
    end
    view:draw_line_text(1, x, y)
    renderer.draw_text = old_draw_text
    renderer.draw_rect = old_draw_rect
    test.equal(hover_drawn, true)
    test.equal(view:on_mouse_pressed("left", x + 2, y + 2, 1), true)
    test.equal(clicked, true)

    view:set_wrapping_enabled(true)
    clicked = false
    x, y = view:get_line_screen_position(1)
    view:on_mouse_moved(x + view:get_font():get_width("link") + 30, y + 2)
    test.equal(view.cursor, "ibeam")
    test.equal(hovered_fragment.hovered, nil)
    view:on_mouse_pressed("left", x + view:get_font():get_width("link") + 30, y + 2, 1)
    test.equal(clicked, false)
  end)

  test.it("keeps rendered fragment hit testing inside a line's content row", function()
    local view = make_view("heading")
    local base_height = view:get_line_height()
    local leading_gap = math.max(2, math.floor(base_height / 2))
    local fragment
    view:add_visual_metric_provider("tall-rendered-row", {
      line_height = function() return base_height + leading_gap end,
    })
    view:add_line_render_provider("tall-rendered-row", {
      render_line = function()
        fragment = {
          source_col1 = 1, source_col2 = 8, text = "heading", cursor = "hand",
        }
        return {
          first_row_content_y_offset = leading_gap,
          text_row_height = base_height,
          caret_height = base_height,
          fragments = { fragment },
        }
      end,
    })

    local x, y = view:get_line_screen_position(1)
    test.equal(view:get_render_fragment_at_position(x + 2, y + 1), nil)
    local hit = test.not_nil(view:get_render_fragment_at_position(
      x + 2, y + leading_gap + 1
    ))
    test.equal(hit.fragment.text, fragment.text)

    view:set_wrapping_enabled(true)
    view:update_wrap_cache()
    x, y = view:get_line_screen_position(1)
    test.equal(view:get_render_fragment_at_position(x + 2, y + 1), nil)
    hit = test.not_nil(view:get_render_fragment_at_position(
      x + 2, y + leading_gap + 1
    ))
    test.equal(hit.fragment.text, fragment.text)
  end)

  test.it("draws line hints in a rendered line's content row", function()
    local view = make_view("heading")
    local base_height = view:get_line_height()
    local leading_gap = math.max(2, math.floor(base_height / 2))
    view:add_visual_metric_provider("tall-rendered-row", {
      line_height = function() return base_height + leading_gap end,
    })
    view:add_line_render_provider("tall-rendered-row", {
      render_line = function()
        return {
          first_row_content_y_offset = leading_gap,
          text_row_height = base_height,
          caret_height = base_height,
          fragments = {
            { source_col1 = 1, source_col2 = 8, text = "heading" },
          },
        }
      end,
    })
    view.get_line_hint = function()
      return { text = "hint", font = view:get_font(), placement = "after_line_document_text" }
    end

    local old_draw_text = renderer.draw_text
    local old_track_rect = view.v_scrollbar.get_track_rect
    local old_push_clip_rect = core.push_clip_rect
    local old_pop_clip_rect = core.pop_clip_rect
    local hint_y
    view.v_scrollbar.get_track_rect = function() return 0, 0, 0, 0 end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    renderer.draw_text = function(font, text, x, y, color, opts)
      if text == "hint" then hint_y = y end
      return x + font:get_width(text, opts)
    end
    local ok, err = pcall(function()
      local x, y = view:get_line_screen_position(1)
      view:draw_line_hint(1, x, y)
    end)
    renderer.draw_text = old_draw_text
    view.v_scrollbar.get_track_rect = old_track_rect
    core.push_clip_rect = old_push_clip_rect
    core.pop_clip_rect = old_pop_clip_rect
    if not ok then error(err, 0) end

    local _, line_y = view:get_line_screen_position(1)
    test.equal(
      hint_y,
      line_y + leading_gap + (base_height - view:get_font():get_height()) / 2
    )
  end)

  test.it("keeps rendered widget hit testing inside a line's content row", function()
    local view = make_view("image")
    local base_height = view:get_line_height()
    local leading_gap = math.max(2, math.floor(base_height / 2))
    local widget = {
      width = 40, height = base_height, draw = function() end,
    }
    view:add_visual_metric_provider("tall-rendered-row", {
      line_height = function() return base_height + leading_gap end,
    })
    view:add_line_render_provider("tall-rendered-row", {
      render_line = function()
        return {
          first_row_content_y_offset = leading_gap,
          text_row_height = base_height,
          caret_height = base_height,
          fragments = {
            { source_col1 = 1, source_col2 = 6, width = 40, widget = widget },
          },
        }
      end,
    })

    local x, y = view:get_line_screen_position(1)
    test.equal(view:get_render_widget_at_position(x + 2, y + 1), nil)
    test.equal(
      test.not_nil(view:get_render_widget_at_position(
        x + 2, y + leading_gap + 1
      )).widget,
      widget
    )

    view:set_wrapping_enabled(true)
    view:update_wrap_cache()
    x, y = view:get_line_screen_position(1)
    test.equal(view:get_render_widget_at_position(x + 2, y + 1), nil)
    test.equal(
      test.not_nil(view:get_render_widget_at_position(
        x + 2, y + leading_gap + 1
      )).widget.width,
      widget.width
    )
  end)

  test.it("draws outline-only widget hover and routes pointer clicks", function()
    local view = make_view("widget")
    local clicked = false
    local widget_fragment
    view:add_line_render_provider("widget", {
      render_line = function()
        widget_fragment = {
          source_col1 = 1,
          source_col2 = 7,
          width = 40,
          widget = {
            width = 40,
            height = view:get_line_height(),
            padding = 5,
            hover_outline_padding = 0,
            hover_outline_width = math.max(1, math.floor(2 * SCALE)),
            hover_outline_outside = true,
            suppress_hover_background = true,
            cursor = "hand",
            on_mouse_pressed = function(_, owner, hit, button)
              test.equal(owner, view)
              test.equal(hit.line, 1)
              test.equal(button, "left")
              clicked = true
              return true
            end,
            draw = function() end,
          },
        }
        return {
          fragments = { widget_fragment },
        }
      end,
    })
    local x, y = view:get_line_screen_position(1)
    x, y = x + 5, y + 5
    view:on_mouse_moved(x, y)
    test.equal(view.cursor, "hand")
    test.equal(test.not_nil(view:get_render_widget_at_position(x, y)).fragment.hovered, true)

    local old_draw_rect = renderer.draw_rect
    local hover_drawn = false
    local hover_border_count = 0
    local hover_border_rectangles = {}
    renderer.draw_rect = function(x, y, w, h, color)
      if color == style.interactive_hover_overlay then
        hover_drawn = true
      elseif color == style.interactive_hover_border then
        hover_border_count = hover_border_count + 1
        hover_border_rectangles[#hover_border_rectangles + 1] = { x, y, w, h }
      end
    end
    local line_x, line_y = view:get_line_screen_position(1)
    view:draw_line_text(1, line_x, line_y)
    renderer.draw_rect = old_draw_rect
    test.equal(hover_drawn, false)
    test.equal(hover_border_count, 4)
    local image_height = view:get_line_height()
    local border = math.max(1, math.floor(2 * SCALE))
    local outline_offset = border
    local function assert_rect(actual, expected)
      test.not_nil(actual)
      for index = 1, 4 do
        test.ok(
          math.abs(actual[index] - expected[index]) < 0.01,
          string.format("outline coordinate %d differs: %.4f vs %.4f",
            index, actual[index], expected[index])
        )
      end
    end
    assert_rect(
      hover_border_rectangles[1],
      { line_x, line_y - outline_offset, 40 + border, border }
    )
    assert_rect(
      hover_border_rectangles[2],
      { line_x, line_y + image_height, 40 + border, border }
    )
    assert_rect(
      hover_border_rectangles[3],
      { line_x, line_y, border, image_height }
    )
    assert_rect(
      hover_border_rectangles[4],
      { line_x + 40, line_y, border, image_height }
    )
    test.equal(view:on_mouse_pressed("left", x, y, 1), true)
    test.equal(clicked, true)
  end)

  test.it("draws image-like widget hover around its bounds at the current zoom", function()
    local view = make_view("image")
    view.scroll.x, view.scroll.to.x = 0, 0
    local image_height = math.max(1, view:get_line_height() - 4)
    local fragment
    view:add_line_render_provider("image-like-widget", {
      render_line = function()
        fragment = {
          source_col1 = 1,
          source_col2 = 6,
          layout_x = 20,
          widget = {
            type = "image",
            width = 40,
            height = view:get_line_height(),
            image_height = image_height,
            padding = 5,
            hover_outline_padding = 0,
            hover_outline_outside = true,
            suppress_hover_background = true,
            cursor = "hand",
            draw = function() end,
          },
        }
        return { fragments = { fragment } }
      end,
    })

    fragment = test.not_nil(view:get_line_render(1).fragments[1])
    fragment.hovered = true
    local old_scale = SCALE
    local old_draw_rect = renderer.draw_rect
    local ok, err = pcall(function()
      local function draw_hover_outline()
        local rectangles = {}
        renderer.draw_rect = function(x, y, w, h, color)
          if color == style.interactive_hover_border then
            rectangles[#rectangles + 1] = { x, y, w, h }
          end
        end
        local line_x, line_y = view:get_line_screen_position(1)
        view:draw_line_text(1, line_x, line_y)
        return line_x, line_y, rectangles
      end

      local line_x, line_y, rectangles = draw_hover_outline()
      local border = math.max(1, math.floor(old_scale))
      local image_x, image_y = line_x + 20, line_y + 2
      test.same(rectangles, {
        { image_x - border, image_y - border, 40 + border * 2, border },
        { image_x - border, image_y + image_height, 40 + border * 2, border },
        { image_x - border, image_y, border, image_height },
        { image_x + 40, image_y, border, image_height },
      })

      SCALE = math.max(old_scale * 2, old_scale + 1)
      local _, _, zoomed_rectangles = draw_hover_outline()
      local zoomed_border = math.max(1, math.floor(SCALE))
      test.equal(zoomed_rectangles[1][4], zoomed_border)
      test.equal(zoomed_rectangles[3][3], zoomed_border)
      test.equal(zoomed_rectangles[4][1], image_x + 40)
    end)
    SCALE = old_scale
    renderer.draw_rect = old_draw_rect
    if not ok then error(err, 0) end
  end)

  test.it("invalidates cached output after legacy raw text edits", function()
    local view, doc = make_view("one")
    view:add_line_render_provider("test", {
      render_line = function(_, _, _, context)
        return { fragments = { { text = context.source_text } } }
      end,
    })
    test.equal(view:get_line_render(1).source_text, "one")
    doc:raw_insert(1, 1, "x", doc.undo_stack, system.get_time())
    test.equal(view:get_line_render(1).source_text, "xone")
  end)

  test.it("removes line render providers", function()
    local view = make_view("abc")
    view:add_line_render_provider("test", { render_line = function() return { fragments = {} } end })
    test.equal(view:has_line_render_providers(), true)
    test.equal(view:remove_line_render_provider("test"), true)
    test.equal(view:has_line_render_providers(), false)
  end)
end)
