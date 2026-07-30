local core = require "core"
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local linewrapping = require "core.linewrapping"
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

local function make_slow_wrapping_view(text)
  local view, doc = make_view(text or table.concat({
    "first rendered line",
    "second rendered line",
    "third rendered line",
  }, "\n"))
  view:add_line_render_provider("slow-wrap", {
    render_line = function(_, owner, line)
      system.sleep(0.002)
      local text = (owner.doc.lines[line] or ""):gsub("\n$", "")
      return {
        source_text = text,
        fragments = {
          { source_col1 = 1, source_col2 = #text + 1, text = text },
        },
      }
    end,
  })
  return view, doc
end

test.describe("DocView variable visual row metrics", function()
  test.it("does not adopt sliced wrapping after the wrap cache is cleared", function()
    local view = make_slow_wrapping_view()
    linewrapping.reconstruct_breaks_async(view, view:get_font(), 80, { budget_ms = 1 })
    linewrapping.clear_wrap_cache(view)
    for _ = 1, 8 do coroutine.yield(0.01) end
    test.equal(view.wrapped_settings, nil)
    test.equal(view.wrapped_lines, nil)
  end)

  test.it("rejects sliced wrapping when font metrics change", function()
    local view = make_slow_wrapping_view()
    local font = view:get_font()
    local old_size = font:get_size()
    local completions = {}
    local started = linewrapping.reconstruct_breaks_async(
      view, font, 80, {
        budget_ms = 1,
        on_complete = function(committed) completions[#completions + 1] = committed end,
      }
    )
    test.equal(started, false, "expected the slow fixture to leave sliced wrapping pending")

    font:set_size(old_size + 1)
    local ok, committed = pcall(linewrapping.complete_async_reconstruction, view)
    font:set_size(old_size)
    if not ok then error(committed, 0) end

    test.equal(committed, false)
    test.same(completions, { false })
    test.equal(view.wrapped_settings, nil)
  end)

  test.it("rejects sliced wrapping when continuation indent size changes", function()
    local view, doc = make_slow_wrapping_view()
    local cfg = config.plugins.linewrapping
    local old_indent = cfg.indent
    local old_wrapping_indent = cfg.wrapping_indent
    local old_indent_size = config.indent_size
    doc.indent_info = { type = "soft", size = 2, confirmed = true }
    cfg.indent = true
    cfg.wrapping_indent = "indent"
    local completions = {}
    local started = linewrapping.reconstruct_breaks_async(
      view, view:get_font(), 80, {
        budget_ms = 1,
        on_complete = function(committed) completions[#completions + 1] = committed end,
      }
    )
    test.equal(started, false, "expected the slow fixture to leave sliced wrapping pending")

    config.indent_size = old_indent_size + 1
    local ok, committed = pcall(linewrapping.complete_async_reconstruction, view)
    config.indent_size = old_indent_size
    cfg.indent = old_indent
    cfg.wrapping_indent = old_wrapping_indent
    if not ok then error(committed, 0) end

    test.equal(committed, false)
    test.same(completions, { false })
    test.equal(view.wrapped_settings, nil)
  end)

  test.it("restarts sliced wrapping after targeted line-render invalidation", function()
    local view = make_view("first\nsecond\nthird")
    local expanded = false
    local large_font = view:get_font():copy(view:get_font():get_size() * 4)
    view:add_line_render_provider("changing-wrap", {
      render_line = function(_, owner, line)
        system.sleep(0.002)
        local text = (owner.doc.lines[line] or ""):gsub("\n$", "")
        return {
          source_text = text,
          fragments = {
            {
              source_col1 = 1,
              source_col2 = #text + 1,
              text = text,
              font = line == 1 and expanded and large_font or nil,
            },
          },
        }
      end,
    })
    local completions = {}
    local width = view:get_font():get_width(string.rep("x", 10))
    local started = linewrapping.reconstruct_breaks_async(
      view, view:get_font(), width, {
        budget_ms = 1,
        on_complete = function(committed) completions[#completions + 1] = committed end,
      }
    )
    test.equal(started, false, "expected the slow fixture to leave sliced wrapping pending")

    expanded = true
    view:invalidate_line_render("changing-wrap", 1, 1)
    local committed = linewrapping.complete_async_reconstruction(view)

    test.equal(committed, true)
    test.same(completions, { true })
    test.ok(linewrapping.get_wrapped_line_count(view, 1) > 1)
  end)

  test.it("rejects non-tokenized sliced wrapping when the normal syntax font changes", function()
    local long_line = string.rep("x", 300000)
    local view = make_view(long_line .. "\n" .. long_line)
    local cfg = config.plugins.linewrapping
    local old_require_tokenization = cfg.require_tokenization
    local old_normal_font = style.syntax_fonts.normal
    local font = view:get_font()
    cfg.require_tokenization = false
    style.syntax_fonts.normal = font:copy(font:get_size())
    local completions = {}

    local ok, committed = pcall(function()
      local started = linewrapping.reconstruct_breaks_async(
        view, font, 80, {
          budget_ms = 1,
          on_complete = function(value) completions[#completions + 1] = value end,
        }
      )
      test.equal(started, false, "expected the slow fixture to leave sliced wrapping pending")
      style.syntax_fonts.normal = font:copy(font:get_size() + 1)
      return linewrapping.complete_async_reconstruction(view)
    end)

    style.syntax_fonts.normal = old_normal_font
    cfg.require_tokenization = old_require_tokenization
    if not ok then error(committed, 0) end

    test.equal(committed, false)
    test.same(completions, { false })
    test.equal(view.wrapped_settings, nil)
  end)

  test.it("observes performance recording enabled between wrapping slices", function()
    local view = make_slow_wrapping_view(
      "first rendered line\n" .. string.rep("x", 60000)
    )
    local perf = require "core.perf"
    local old_frame_stats = core.perf_frame_stats
    local old_is_recording = perf.is_recording
    local old_record_linewrap_compute = perf.record_linewrap_compute
    local recording = false
    local recorded
    core.perf_frame_stats = nil
    perf.is_recording = function() return recording end
    perf.record_linewrap_compute = function(row) recorded = row end

    local ok, committed = pcall(function()
      local started = linewrapping.reconstruct_breaks_async(
        view, view:get_font(), 80, { budget_ms = 1 }
      )
      test.equal(started, false, "expected the slow fixture to leave sliced wrapping pending")
      recording = true
      return linewrapping.complete_async_reconstruction(view)
    end)

    core.perf_frame_stats = old_frame_stats
    perf.is_recording = old_is_recording
    perf.record_linewrap_compute = old_record_linewrap_compute
    if not ok then error(committed, 0) end

    test.equal(committed, true)
    test.not_nil(recorded)
    test.ok(recorded.visible_bytes > 50000)
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
