local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local style = require "core.style"
local test = require "core.test"

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.ok(file, err)
  file:write(content or "")
  file:close()
end

local function make_view(text)
  local buffer = Buffer(nil, nil, true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = TextView(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 400, 200
  return view, buffer
end

test.describe("TextView decoration providers", function()
  test.it("draws the content left edge without a current line highlight", function()
    local view = make_view("alpha")
    view.show_current_line_highlight = false
    local old_rect = renderer.draw_rect
    local edge
    renderer.draw_rect = function(x, y, w, h, color)
      if color == style.textview_content_left_edge then
        edge = { x = x, y = y, w = w, h = h }
      end
    end

    local ok, err = pcall(function()
      view:draw_current_line_underlay_highlights(1, 1)
    end)
    renderer.draw_rect = old_rect
    if not ok then error(err, 0) end

    test.not_nil(edge)
    test.equal(edge.y, view.position.y)
    test.equal(edge.h, view.size.y)
  end)

  test.it("draws line backgrounds and inline ranges in provider order", function()
    local view = make_view("alpha\nbeta")
    local old_rect = renderer.draw_rect
    local old_text = renderer.draw_text
    local rects = {}
    renderer.draw_rect = function(x, y, w, h, color)
      rects[#rects + 1] = { x = x, y = y, w = w, h = h, color = color }
    end
    renderer.draw_text = function(font, text, x, y, color) return x + (font and font:get_width(text) or 0) end
    view:add_decoration_provider("later", {
      line_background = function(_, _, line) if line == 1 then return { 2, 2, 2, 255 } end end,
    }, { priority = 20 })
    view:add_decoration_provider("earlier", {
      line_background = function(_, _, line) if line == 1 then return { 1, 1, 1, 255 } end end,
      inline_ranges = function(_, _, line) if line == 1 then return { { col1 = 2, col2 = 4, color = { 3, 3, 3, 255 } } } end end,
    }, { priority = 10 })

    local ok, err = pcall(function() view:draw_line_body(1, 0, 0) end)
    renderer.draw_rect = old_rect
    renderer.draw_text = old_text
    if not ok then error(err, 0) end

    test.same(rects[1].color, { 1, 1, 1, 255 })
    test.same(rects[2].color, { 2, 2, 2, 255 })
    local found_inline = false
    for _, rect in ipairs(rects) do
      if rect.color[1] == 3 then found_inline = true end
    end
    test.ok(found_inline, "expected inline provider range to be drawn")
  end)

  test.it("aligns inline ranges with rendered line content", function()
    local view = make_view("heading")
    local base_height = view:get_line_height()
    local leading_gap = math.max(2, math.floor(base_height / 2))
    local inline_color = { 9, 8, 7, 255 }
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
    view:add_decoration_provider("rendered-inline", {
      inline_ranges = function()
        return { { col1 = 1, col2 = 8, color = inline_color } }
      end,
    })

    local old_rect = renderer.draw_rect
    local old_text = renderer.draw_text
    local inline_rect
    renderer.draw_rect = function(x, y, w, h, color)
      if color == inline_color then inline_rect = { x = x, y = y, w = w, h = h } end
    end
    renderer.draw_text = function(font, text, x, y, color, opts)
      return x + font:get_width(text, opts)
    end
    local ok, err = pcall(function()
      local x, y = view:get_line_screen_position(1)
      view:draw_line_body(1, x, y)
    end)
    renderer.draw_rect = old_rect
    renderer.draw_text = old_text
    if not ok then error(err, 0) end

    local _, line_y = view:get_line_screen_position(1)
    local rect = test.not_nil(inline_rect)
    test.equal(rect.y, line_y + leading_gap)
    test.equal(rect.h, base_height)
  end)

  test.it("draws inset rounded background descriptors with an accent rail", function()
    local view = make_view("alpha")
    local background = { 10, 20, 30, 255 }
    local accent = { 40, 50, 60, 255 }
    view:add_decoration_provider("card", {
      line_background_descriptor = function()
        return {
          color = background, rail_color = accent, rail_width = 3,
          x_offset = 12, width = 120, radius = 6,
          first = true, last = true,
        }
      end,
    })

    local old_rect = renderer.draw_rect
    local old_rounded = renderer.draw_rounded_rect
    local old_text = renderer.draw_text
    local rounded, rail
    renderer.draw_rounded_rect = function(x, y, w, h, radius, color)
      if color == background then
        rounded = { x = x, y = y, w = w, h = h, radius = radius }
      end
    end
    renderer.draw_rect = function(x, y, w, h, color)
      if color == accent then rail = { x = x, y = y, w = w, h = h } end
    end
    renderer.draw_text = function(font, text, x, y, color, opts)
      return x + font:get_width(text, opts)
    end
    local ok, err = pcall(function() view:draw_line_body(1, 20, 0) end)
    renderer.draw_rect = old_rect
    renderer.draw_rounded_rect = old_rounded
    renderer.draw_text = old_text
    if not ok then error(err, 0) end

    rounded = test.not_nil(rounded)
    rail = test.not_nil(rail)
    test.equal(rounded.x, 32)
    test.equal(rounded.w, 120)
    test.equal(rounded.radius, 6)
    test.equal(rail.x, rounded.x)
    test.equal(rail.w, 3)
  end)

  test.it("removes decoration and POI providers", function()
    local view = make_view("alpha")
    view:add_decoration_provider("test", { line_background = function() return { 1, 1, 1, 255 } end })
    view:add_poi_provider("test", { points_of_interest = function() return { { line = 1, col = 1, kind = "test" } } end })
    local points = view:get_points_of_interest()
    test.equal(#points, 1)
    test.equal(view:remove_decoration_provider("test"), true)
    test.equal(view:remove_poi_provider("test"), true)
    test.equal(#view:decoration_provider_entries(), 0)
    points = view:get_points_of_interest()
    test.equal(#points, 0)
  end)

  test.it("routes and removes generic file-drop providers", function()
    local view = make_view("alpha")
    local dropped
    view:add_file_drop_provider("test", {
      on_file_dropped = function(_, owner, filename, x, y)
        test.equal(owner, view)
        dropped = { filename, x, y }
        return true
      end,
    })
    test.equal(view:on_file_dropped("asset.png", 10, 20), true)
    test.same(dropped, { "asset.png", 10, 20 })
    test.equal(view:remove_file_drop_provider("test"), true)
  end)

  test.it("notifies selection listeners for view-local selection changes", function()
    local view = make_view("alpha")
    local count = 0
    view:add_selection_listener("test", function(_, state) count = count + 1; test.equal(state.selections[1], 1) end)
    view:with_selection_state(function() view.buffer:set_selection(1, 2) end)
    test.ok(count > 0, "expected selection listener to fire")
  end)

  test.it("uses visual row providers for line-height rows", function()
    local view = make_view("one\ntwo\nthree")
    local base = view:get_scrollable_line_count()
    view:add_visual_row_provider("test", { before = { [2] = 2, [3] = 2 } })
    test.equal(view:get_extra_visual_rows_before_line(2), 2)
    test.equal(view:get_scrollable_line_count(), base + 2)
    test.equal(view:remove_visual_row_provider("test"), true)
    test.equal(view:get_scrollable_line_count(), base)
  end)

  test.it("draws current-line highlights over decoration backgrounds with gutter coverage", function()
    local view, buffer = make_view("one\ntwo\nthree")
    view.position.x = 17
    view.size.x = 360
    view.__full_width_highlight_position_x = 3
    view.__full_width_highlight_size_x = 500
    view:add_visual_row_provider("test", {})
    local decoration = { 12, 34, 56, 255 }
    view:add_decoration_provider("current-line-order", {
      line_background = function(_, _, line)
        if line == 2 then return decoration end
      end,
    })
    buffer:set_selection(2, 1)

    local old_highlight = config.highlight_current_line
    local old_text = renderer.draw_text
    local old_rect = renderer.draw_rect
    local old_rounded_rect = renderer.draw_rounded_rect
    local old_push = core.push_clip_rect
    local old_pop = core.pop_clip_rect
    local events = {}
    config.highlight_current_line = true
    renderer.draw_text = function(font, text, x) return x + (font and font:get_width(text) or 0) end
    renderer.draw_rect = function(x, _, width, _, color)
      if color == style.line_highlight then
        events[#events + 1] = { kind = "highlight", x = x, width = width }
      elseif color == decoration then
        events[#events + 1] = { kind = "decoration" }
      end
    end
    renderer.draw_rounded_rect = function() end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    view.draw_overlay = function() end
    view.draw_line_gutter = function(_, line)
      events[#events + 1] = { kind = "gutter", line = line }
    end
    local ok, err = pcall(function() view:draw() end)
    config.highlight_current_line = old_highlight
    renderer.draw_text = old_text
    renderer.draw_rect = old_rect
    renderer.draw_rounded_rect = old_rounded_rect
    core.push_clip_rect = old_push
    core.pop_clip_rect = old_pop
    if not ok then error(err, 0) end

    local highlight_indexes = {}
    local decoration_index
    for index, event in ipairs(events) do
      if event.kind == "highlight" then
        highlight_indexes[#highlight_indexes + 1] = index
      elseif event.kind == "decoration" then
        decoration_index = index
      end
    end
    test.not_nil(decoration_index)
    test.ok(#highlight_indexes >= 2, "expected gutter and content highlights")
    test.ok(highlight_indexes[1] < decoration_index, "expected gutter coverage before row content")
    test.ok(highlight_indexes[#highlight_indexes] > decoration_index, "expected content highlight over its decoration")
    test.equal(events[highlight_indexes[1]].x, 3)
    test.equal(events[highlight_indexes[1]].width, 500)
  end)

  test.it("draws and clicks provider-owned visual rows without selecting text", function()
    local view, buffer = make_view("one\ntwo\nthree")
    local draws, clicks = 0, 0
    view.draw_overlay = function() end
    view:add_visual_row_provider("actions", {
      visual_rows = function(_, _, line, placement)
        if line == 2 and placement == "before" then
          return {
            {
              id = "action",
              kind = "action",
              draw = function() draws = draws + 1 end,
              on_click = function() clicks = clicks + 1 end,
            }
          }
        end
      end,
    })

    local entry = view:get_visual_row_entry(2)
    test.equal("provider", entry.type)
    test.equal("actions", entry.provider_id)
    test.equal("action", entry.provider_row.id)

    local old_text = renderer.draw_text
    local old_rect = renderer.draw_rect
    local old_rounded_rect = renderer.draw_rounded_rect
    local old_push = core.push_clip_rect
    local old_pop = core.pop_clip_rect
    renderer.draw_text = function(font, text, x, y, color) return x + (font and font:get_width(text) or 0) end
    renderer.draw_rect = function() end
    renderer.draw_rounded_rect = function() end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    local ok, err = pcall(function() view:draw_folded() end)
    renderer.draw_text = old_text
    renderer.draw_rect = old_rect
    renderer.draw_rounded_rect = old_rounded_rect
    core.push_clip_rect = old_push
    core.pop_clip_rect = old_pop
    if not ok then error(err, 0) end
    test.equal(1, draws)

    buffer:set_selection(1, 1)
    local x = view.position.x + view:get_gutter_width() + 5
    local y = view.position.y + style.padding.y + view:get_line_height()
    test.ok(view:on_mouse_pressed("left", x, y, 1))
    test.equal(1, clicks)
    local line, col = buffer:get_selection()
    test.equal(1, line)
    test.equal(1, col)
  end)

  test.it("invalidates provider visual rows after same-line buffer edits", function()
    local view, buffer = make_view("TODO one\ntwo")
    view:add_visual_row_provider("todo", {
      visual_rows = function(_, v, line, placement)
        if placement == "before" and (v.buffer.lines[line] or ""):find("TODO", 1, true) then
          return { { id = "todo" } }
        end
      end,
    })
    test.equal(3, view:get_scrollable_line_count())
    local observed_in_text_change
    function buffer:on_text_change()
      observed_in_text_change = view:get_scrollable_line_count()
    end
    buffer:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 5, text = "done" } }, { type = "replace" })
    test.equal(2, observed_in_text_change)
    test.equal(2, view:get_scrollable_line_count())
    buffer:undo()
    test.equal(3, view:get_scrollable_line_count())
    buffer:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 5, text = "xxxx" } }, { type = "replace" })
    test.equal(2, view:get_scrollable_line_count())
  end)

  test.it("invalidates provider visual rows after same-line-count reload", function()
    local path = core.project_absolute_path("tmp-visual-row-reload.txt")
    pcall(os.remove, path)
    write_file(path, "TODO one\ntwo\n")
    local buffer = Buffer("tmp-visual-row-reload.txt", path)
    local view = TextView(buffer)
    view:add_visual_row_provider("todo", {
      visual_rows = function(_, v, line, placement)
        if placement == "before" and (v.buffer.lines[line] or ""):find("TODO", 1, true) then
          return { { id = "todo" } }
        end
      end,
    })
    test.equal(3, view:get_scrollable_line_count())
    write_file(path, "done one\ntwo\n")
    buffer:load(path)
    test.ok(not buffer.lines[1]:find("TODO", 1, true), buffer.lines[1])
    test.equal(2, view:get_scrollable_line_count())
    pcall(os.remove, path)
  end)

  test.it("invalidates wrapped visual rows after same-line-count reload", function()
    local path = core.project_absolute_path("tmp-visual-row-wrap-reload.txt")
    pcall(os.remove, path)
    write_file(path, string.rep("wide ", 40) .. "\nshort\n")
    local buffer = Buffer("tmp-visual-row-wrap-reload.txt", path)
    local view = TextView(buffer)
    view.size.x = 120
    view:set_wrapping_enabled(true)
    view:update_wrap_cache()
    local before = view:get_scrollable_line_count()
    write_file(path, "short\nshort\n")
    buffer:load(path)
    view:update_wrap_cache()
    local after = view:get_scrollable_line_count()
    test.ok(after < before, string.format("expected reload to reduce wrapped rows from %d, got %d", before, after))
    pcall(os.remove, path)
  end)

  test.it("invalidates provider visual rows by generation and explicit request", function()
    local view = make_view("one\ntwo")
    local generation = 1
    local enabled = true
    view:add_visual_row_provider("dynamic", {
      generation = function() return generation end,
      visual_rows = function(_, _, line, placement)
        if enabled and line == 1 and placement == "after" then return { { id = "dynamic" } } end
      end,
    })
    test.equal(3, view:get_scrollable_line_count())
    enabled = false
    generation = generation + 1
    test.equal(2, view:get_scrollable_line_count())
    enabled = true
    view:invalidate_visual_rows("dynamic")
    test.equal(3, view:get_scrollable_line_count())
  end)

  test.it("skips provider rows during folded vertical navigation", function()
    local view = make_view("one\ntwo\nthree\nfour\nfive")
    view:add_visual_row_provider("gap", {
      visual_rows = function(_, _, line, placement)
        if line == 1 and placement == "after" then return { { id = "gap" } } end
      end,
    })
    local fold = assert(view:add_fold_region { line1 = 3, line2 = 4 })
    local line, col = view:folded_visual_line_position(2, 1, 1)
    test.equal(3, line)
    test.equal(1, col)
    view:remove_fold_region(fold)
  end)

  test.it("isolates provider row duplicate ids and callback errors", function()
    local view = make_view("one\ntwo")
    view.draw_overlay = function() end
    view:add_visual_row_provider("bad", {
      visual_rows = function(_, _, line, placement)
        if line == 1 and placement == "before" then
          return {
            { id = "dup", height_rows = 2, draw = function() error("draw boom") end, on_click = function() error("click boom") end },
            { id = "dup" },
          }
        end
      end,
    })
    test.equal(4, view:get_scrollable_line_count())
    test.equal("dup", view:get_visual_row_entry(1).provider_row_id)
    test.equal("dup#2", view:get_visual_row_entry(2).provider_row_id)

    local old_text = renderer.draw_text
    local old_rect = renderer.draw_rect
    local old_rounded_rect = renderer.draw_rounded_rect
    local old_push = core.push_clip_rect
    local old_pop = core.pop_clip_rect
    renderer.draw_text = function(font, text, x, y, color) return x + (font and font:get_width(text) or 0) end
    renderer.draw_rect = function() end
    renderer.draw_rounded_rect = function() end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    local ok, err = pcall(function() view:draw_folded() end)
    renderer.draw_text = old_text
    renderer.draw_rect = old_rect
    renderer.draw_rounded_rect = old_rounded_rect
    core.push_clip_rect = old_push
    core.pop_clip_rect = old_pop
    test.ok(ok, err)

    local x = view.position.x + view:get_gutter_width() + 5
    local y = view.position.y + style.padding.y
    test.ok(view:on_mouse_pressed("left", x, y, 1))
  end)

  test.it("notifies fold listeners for expand and removal", function()
    local view = make_view("one\ntwo\nthree")
    local events = {}
    view:add_fold_listener("test", function(_, event, fold, reason)
      events[#events + 1] = event .. ":" .. tostring(reason)
    end)
    local fold = assert(view:add_fold_region { line1 = 1, line2 = 2 })
    view:expand_fold_region(fold, "test-expand")
    view:remove_fold_region(fold, "test-remove")
    test.same(events, { "add:add", "expand:test-expand", "remove:test-remove" })
  end)
end)
