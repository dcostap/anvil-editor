local core = require "core"
local config = require "core.config"
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
  view.size.x, view.size.y = 400, 40
  view:set_wrapping_enabled(false)
  return view, doc
end

test.describe("DocView variable visual row metrics", function()
  test.it("uses provider row heights for scroll size and line positions", function()
    local view = make_view("one\ntwo\nthree")
    local lh = view:get_line_height()
    local base_scroll = view:get_scrollable_size()

    view:add_visual_metric_provider("test", {
      line_height = function(_, _, line)
        if line == 2 then return lh * 2 end
      end,
    })

    test.equal(view:get_visual_row_height(1), lh)
    test.equal(view:get_visual_row_height(2), lh * 2)
    test.equal(view:get_scrollable_size(), base_scroll + lh)

    local _, y1 = view:get_line_screen_position(1)
    local _, y2 = view:get_line_screen_position(2)
    local _, y3 = view:get_line_screen_position(3)
    test.equal(y2 - y1, lh)
    test.equal(y3 - y2, lh * 2)
  end)

  test.it("hit-tests y positions through variable-height rows", function()
    local view = make_view("one\ntwo\nthree")
    local lh = view:get_line_height()
    view:add_visual_metric_provider("test", {
      line_height = function(_, _, line)
        if line == 2 then return lh * 3 end
      end,
    })

    local ox, oy = view:get_content_offset()
    local x = ox + view:get_gutter_width() + 1
    local line2_y = oy + style.padding.y + view:get_visual_row_y_offset(2) + lh * 2
    local line, col = view:resolve_screen_position(x, line2_y)
    test.equal(line, 2)
    test.ok(col >= 1)

    local line3_y = oy + style.padding.y + view:get_visual_row_y_offset(3) + 1
    line = view:resolve_screen_position(x, line3_y)
    test.equal(line, 3)
  end)

  test.it("invalidates metric cache when document text changes", function()
    local view, doc = make_view("plain\ntwo")
    local lh = view:get_line_height()
    view:add_visual_metric_provider("headings", {
      line_height = function(_, v, line)
        if v.doc.lines[line]:match("^#") then return lh * 2 end
      end,
    })
    test.equal(view:get_visual_row_height(1), lh)
    doc:insert(1, 1, "# ")
    test.equal(view:get_visual_row_height(1), lh * 2)
  end)

  test.it("observes visual metric provider generation changes", function()
    local view = make_view("one\ntwo")
    local generation = 1
    local lh = view:get_line_height()
    view:add_visual_metric_provider("external", {
      generation = function() return generation end,
      line_height = function() return generation == 1 and lh or lh * 2 end,
    })
    test.equal(view:get_visual_row_height(1), lh)
    generation = 2
    test.equal(view:get_visual_row_height(1), lh * 2)
  end)

  test.it("invalidates metrics after legacy raw text edits", function()
    local view, doc = make_view("plain")
    local lh = view:get_line_height()
    view:add_visual_metric_provider("headings", {
      line_height = function(_, v, line)
        if v.doc.lines[line]:match("^#") then return lh * 2 end
      end,
    })
    test.equal(view:get_visual_row_height(1), lh)
    doc:raw_insert(1, 1, "# ", doc.undo_stack, system.get_time())
    test.equal(view:get_visual_row_height(1), lh * 2)
  end)

  test.it("anchors the viewport when targeted rows above it change height", function()
    local view = make_view("one\ntwo\nthree\nfour")
    view.size.y = 40
    local lh = view:get_line_height()
    local expanded = false
    view:add_visual_metric_provider("anchor", {
      line_height = function(_, _, line)
        if line == 1 then return expanded and lh * 3 or lh * 2 end
      end,
    })
    view:get_visual_row_height(1)
    view.scroll.y = view:get_visual_row_y_offset(3)
    view.scroll.to.y = view.scroll.y
    local _, before_y = view:get_line_screen_position(3)

    expanded = true
    view:invalidate_visual_metrics("anchor", 1, 1)
    view:get_visual_row_height(1)
    local _, after_y = view:get_line_screen_position(3)
    test.equal(after_y, before_y)
    test.equal(view.scroll.y, view.scroll.to.y)
  end)

  test.it("draws non-composed lines at metric y positions", function()
    local view = make_view("one\ntwo\nthree")
    view.size.y = 200
    local lh = view:get_line_height()
    view:add_visual_metric_provider("test", {
      line_height = function(_, _, line)
        if line == 2 then return lh * 2 end
      end,
    })

    local body_y = {}
    view.draw_background = function() end
    view.draw_scrollbar = function() end
    view.draw_current_line_highlights = function() end
    view.draw_overlay = function() end
    view.prepare_line_body_draw_cache = function() end
    view.draw_line_gutter = function() end
    view.draw_line_body = function(_, line, _, y)
      body_y[line] = y
      return lh
    end

    local old_push = core.push_clip_rect
    local old_pop = core.pop_clip_rect
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    local ok, err = pcall(function() view:draw() end)
    core.push_clip_rect = old_push
    core.pop_clip_rect = old_pop
    if not ok then error(err, 0) end
    test.equal(body_y[2] - body_y[1], lh)
    test.equal(body_y[3] - body_y[2], lh * 2)
  end)

  test.it("keeps scroll-past-end context with no-op metric providers", function()
    local view = make_view("one\ntwo\nthree\nfour")
    local old_scroll_past_end = config.scroll_past_end
    local old_scroll_context_lines = config.scroll_context_lines
    config.scroll_past_end = true
    config.scroll_context_lines = 3
    local base = view:get_scrollable_size()
    view:add_visual_metric_provider("noop", {})
    local with_provider = view:get_scrollable_size()
    config.scroll_past_end = old_scroll_past_end
    config.scroll_context_lines = old_scroll_context_lines
    test.equal(with_provider, base)
  end)

  test.it("removes metric providers and restores constant-height mapping", function()
    local view = make_view("one\ntwo")
    local lh = view:get_line_height()
    view:add_visual_metric_provider("test", {
      line_height = function() return lh * 2 end,
    })
    test.equal(view:get_visual_row_height(1), lh * 2)
    test.equal(view:remove_visual_metric_provider("test"), true)
    test.equal(view:get_visual_row_height(1), lh)
    local _, y1 = view:get_line_screen_position(1)
    local _, y2 = view:get_line_screen_position(2)
    test.equal(y2 - y1, lh)
  end)
end)
