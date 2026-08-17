local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local style = require "core.style"
local test = require "core.test"

local function make_view(text)
  local buffer = Buffer(nil, nil, true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = TextView(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 400, 40
  view:set_wrapping_enabled(false)
  return view, buffer
end

test.describe("TextView variable visual row metrics", function()
  test.before_each(function(context)
    context.old_scroll_past_end = config.scroll_past_end
    context.old_scroll_context_lines = config.scroll_context_lines
    context.old_render_frame_active = core.render_frame_active
    context.old_render_frame_id = core.render_frame_id
    context.old_ui_snapshot_active = core.ui_snapshot_active
    context.old_ui_snapshot_id = core.ui_snapshot_id
  end)

  test.after_each(function(context)
    config.scroll_past_end = context.old_scroll_past_end
    config.scroll_context_lines = context.old_scroll_context_lines
    core.render_frame_active = context.old_render_frame_active
    core.render_frame_id = context.old_render_frame_id
    core.ui_snapshot_active = context.old_ui_snapshot_active
    core.ui_snapshot_id = context.old_ui_snapshot_id
  end)

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

  test.it("invalidates metric cache when buffer text changes", function()
    local view, buffer = make_view("plain\ntwo")
    local lh = view:get_line_height()
    view:add_visual_metric_provider("headings", {
      line_height = function(_, v, line)
        if v.buffer.lines[line]:match("^#") then return lh * 2 end
      end,
    })
    test.equal(view:get_visual_row_height(1), lh)
    buffer:insert(1, 1, "# ")
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

  test.it("uses one metric snapshot during a UI phase", function()
    local view = make_view("one\ntwo")
    local generation = 1
    local lh = view:get_line_height()
    view:add_visual_metric_provider("external", {
      generation = function() return generation end,
      line_height = function() return lh * generation end,
    })

    core.ui_snapshot_id = (core.ui_snapshot_id or 0) + 1
    core.ui_snapshot_active = true
    test.equal(view:get_visual_row_height(1), lh)
    generation = 2
    test.equal(view:get_visual_row_height(1), lh)

    core.ui_snapshot_id = core.ui_snapshot_id + 1
    test.equal(view:get_visual_row_height(1), lh * 2)

    generation = 3
    view:invalidate_visual_metrics("external")
    test.equal(view:get_visual_row_height(1), lh * 3)
  end)

  test.it("uses one line-render snapshot during a UI phase", function()
    local view = make_view("one\ntwo")
    local generation = 1
    view:add_line_render_provider("external", {
      generation = function() return generation end,
      render_line = function(_, _, _, context)
        return {
          source_text = context.source_text,
          fragments = {},
          marker = generation,
        }
      end,
    })

    core.ui_snapshot_id = (core.ui_snapshot_id or 0) + 1
    core.ui_snapshot_active = true
    test.equal(test.not_nil(view:get_line_render(1)).marker, 1)
    generation = 2
    test.equal(test.not_nil(view:get_line_render(1)).marker, 1)

    core.ui_snapshot_id = core.ui_snapshot_id + 1
    test.equal(test.not_nil(view:get_line_render(1)).marker, 2)
  end)

  test.it("invalidates metrics after legacy raw text edits", function()
    local view, buffer = make_view("plain")
    local lh = view:get_line_height()
    view:add_visual_metric_provider("headings", {
      line_height = function(_, v, line)
        if v.buffer.lines[line]:match("^#") then return lh * 2 end
      end,
    })
    test.equal(view:get_visual_row_height(1), lh)
    buffer:raw_insert(1, 1, "# ", buffer.undo_stack, system.get_time())
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

  test.it("keeps a stable viewport anchor across a same-row wrap refresh", function()
    local lines = {}
    for i = 1, 80 do lines[i] = "line " .. i end
    local view = make_view(table.concat(lines, "\n"))
    local lh = view:get_line_height()
    local tall_height = lh * 50
    view:add_line_render_provider("tall-render", {
      render_line = function(_, _, line, context)
        if line ~= 1 then return end
        return {
          source_text = context.source_text,
          fragments = {
            {
              source_col1 = 1,
              source_col2 = #context.source_text + 1,
              text = context.source_text,
            },
          },
          disable_wrapping = true,
        }
      end,
    })
    view:add_visual_metric_provider("tall-metric", {
      line_height = function(_, _, line)
        if line == 1 then return tall_height end
      end,
    })
    view:set_wrapping_enabled(true)
    test.equal(view:get_visual_row_height(1), tall_height)

    local initial_scroll = tall_height - lh * 5
    view.scroll.y, view.scroll.to.y = initial_scroll, initial_scroll
    view:invalidate_line_render("same-row-refresh", 1, 1)
    view:invalidate_visual_metrics("same-row-refresh", 1, 1)

    test.equal(view:get_visual_row_height(1), tall_height)
    test.equal(view.scroll.y, initial_scroll)
    test.equal(view.scroll.to.y, initial_scroll)
  end)

  test.it("does not anchor a real row splice from placeholder heights", function()
    local lines = {
      string.rep("wrapped metric words ", 30),
    }
    for i = 2, 80 do lines[i] = "line " .. i end
    local view = make_view(table.concat(lines, "\n"))
    view.size.x = 140
    local compact = false
    view:add_line_render_provider("topology-render", {
      render_line = function(_, _, line, context)
        if line ~= 1 or not compact then return end
        return {
          source_text = context.source_text,
          fragments = {
            {
              source_col1 = 1,
              source_col2 = #context.source_text + 1,
              text = context.source_text,
            },
          },
          disable_wrapping = true,
        }
      end,
    })
    view:set_wrapping_enabled(true)
    local expanded_rows = view:get_visual_row_count_for_line(1)
    test.ok(expanded_rows > 2)
    local lh = view:get_line_height()
    local expanded_row_height = lh * 5

    compact = true
    view:invalidate_line_render("compact-topology", 1, 1)
    view:add_visual_metric_provider("topology-metric", {
      line_height = function(_, _, line)
        if line == 1 then
          return compact and expanded_rows * expanded_row_height
            or expanded_row_height
        end
      end,
    })
    local compact_height = expanded_rows * expanded_row_height
    test.equal(view:get_visual_row_count_for_line(1), 1)
    test.equal(view:get_visual_row_height(1), compact_height)

    local initial_scroll = compact_height - lh * 5
    view.scroll.y, view.scroll.to.y = initial_scroll, initial_scroll
    local _, following_y = view:get_line_screen_position(2)
    compact = false
    view:invalidate_line_render("expand-topology", 1, 1)
    view:invalidate_visual_metrics("expand-topology", 1, 1)

    test.equal(view:get_visual_row_count_for_line(1), expanded_rows)
    view:get_visual_row_metric_cache()
    local _, expanded_following_y = view:get_line_screen_position(2)
    test.equal(expanded_following_y, following_y)
    test.equal(view.scroll.y, initial_scroll)
    test.equal(view.scroll.to.y, initial_scroll)
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

  test.it("uses normal rows for context around a taller target row", function()
    local lines = {}
    for line = 1, 40 do lines[line] = "line " .. line end
    local view = make_view(table.concat(lines, "\n"))
    view.size.y = 200
    config.scroll_past_end = true
    config.scroll_context_lines = 28

    local lh = view:get_line_height()
    view:add_visual_metric_provider("tall-target", {
      line_height = function(_, _, line)
        return line == 20 and lh * 2 or nil
      end,
    })

    view:scroll_to_make_visible(19, 1, true)
    local before_top = view:get_position_highlight_geometry(19, 1)
    view:scroll_to_make_visible(20, 1, true)
    local target_top = view:get_position_highlight_geometry(20, 1)
    view:scroll_to_make_visible(21, 1, true)
    local after_top = view:get_position_highlight_geometry(21, 1)

    test.ok(
      math.abs(target_top - after_top) <= lh,
      string.format(
        "tall target left the navigation band: %.1f vs %.1f",
        target_top, after_top
      )
    )
    test.ok(
      math.abs(before_top - after_top) <= lh,
      string.format(
        "adjacent rows diverged after tall target: %.1f vs %.1f",
        before_top, after_top
      )
    )
  end)

  test.it("counts a special final row once when adding scroll-past-end context", function()
    local view = make_view(table.concat({
      "one", "two", "three", "four", "five", "six", "seven", "eight",
    }, "\n"))
    view.size.y = 120
    config.scroll_past_end = true
    config.scroll_context_lines = 3

    local lh = view:get_line_height()
    local base_size = view:get_scrollable_size()
    view:add_visual_metric_provider("tall-final", {
      line_height = function(_, _, line)
        return line == #view.buffer.lines and lh * 3 or nil
      end,
    })

    test.equal(view:get_scrollable_size(), base_size + lh * 2)
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
