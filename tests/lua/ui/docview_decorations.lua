local core = require "core"
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local style = require "core.style"
local test = require "core.test"

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.ok(file, err)
  file:write(content or "")
  file:close()
end

local function make_view(text)
  local doc = Doc(nil, nil, true)
  doc:insert(1, 1, text)
  doc:clear_undo_redo()
  local view = DocView(doc)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 400, 200
  return view, doc
end

test.describe("DocView decoration providers", function()
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
    view:with_selection_state(function() view.doc:set_selection(1, 2) end)
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

  test.it("draws composed-row current-line highlights across the gutter before row content", function()
    local view, doc = make_view("one\ntwo\nthree")
    view.position.x = 17
    view.size.x = 360
    view:add_visual_row_provider("test", {})
    doc:set_selection(2, 1)

    local old_highlight = config.highlight_current_line
    local old_text = renderer.draw_text
    local old_rect = renderer.draw_rect
    local old_push = core.push_clip_rect
    local old_pop = core.pop_clip_rect
    local events = {}
    config.highlight_current_line = true
    renderer.draw_text = function(font, text, x) return x + (font and font:get_width(text) or 0) end
    renderer.draw_rect = function() end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    view.draw_overlay = function() end
    view.draw_line_gutter = function(_, line)
      events[#events + 1] = { kind = "gutter", line = line }
    end
    view.draw_line_highlight = function(self, x, y)
      local rx, ry, rw, rh = self:get_line_highlight_rect(x, y)
      events[#events + 1] = { kind = "highlight", x = rx, y = ry, w = rw, h = rh }
    end

    local ok, err = pcall(function() view:draw() end)
    config.highlight_current_line = old_highlight
    renderer.draw_text = old_text
    renderer.draw_rect = old_rect
    core.push_clip_rect = old_push
    core.pop_clip_rect = old_pop
    if not ok then error(err, 0) end

    local highlight_index
    local first_gutter_index
    for index, event in ipairs(events) do
      if event.kind == "highlight" and not highlight_index then highlight_index = index end
      if event.kind == "gutter" and not first_gutter_index then first_gutter_index = index end
    end
    test.not_nil(highlight_index, "expected a Current Line Highlight")
    test.ok(highlight_index < first_gutter_index, "expected the highlight beneath the gutter and row content")
    test.equal(events[highlight_index].x, view.position.x)
    test.equal(events[highlight_index].w, view.size.x)
  end)

  test.it("draws and clicks provider-owned visual rows without selecting text", function()
    local view, doc = make_view("one\ntwo\nthree")
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
    local old_push = core.push_clip_rect
    local old_pop = core.pop_clip_rect
    renderer.draw_text = function(font, text, x, y, color) return x + (font and font:get_width(text) or 0) end
    renderer.draw_rect = function() end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    local ok, err = pcall(function() view:draw_folded() end)
    renderer.draw_text = old_text
    renderer.draw_rect = old_rect
    core.push_clip_rect = old_push
    core.pop_clip_rect = old_pop
    if not ok then error(err, 0) end
    test.equal(1, draws)

    doc:set_selection(1, 1)
    local x = view.position.x + view:get_gutter_width() + 5
    local y = view.position.y + style.padding.y + view:get_line_height()
    test.ok(view:on_mouse_pressed("left", x, y, 1))
    test.equal(1, clicks)
    local line, col = doc:get_selection()
    test.equal(1, line)
    test.equal(1, col)
  end)

  test.it("invalidates provider visual rows after same-line document edits", function()
    local view, doc = make_view("TODO one\ntwo")
    view:add_visual_row_provider("todo", {
      visual_rows = function(_, v, line, placement)
        if placement == "before" and (v.doc.lines[line] or ""):find("TODO", 1, true) then
          return { { id = "todo" } }
        end
      end,
    })
    test.equal(3, view:get_scrollable_line_count())
    local observed_in_text_change
    function doc:on_text_change()
      observed_in_text_change = view:get_scrollable_line_count()
    end
    doc:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 5, text = "done" } }, { type = "replace" })
    test.equal(2, observed_in_text_change)
    test.equal(2, view:get_scrollable_line_count())
    doc:undo()
    test.equal(3, view:get_scrollable_line_count())
    doc:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 5, text = "xxxx" } }, { type = "replace" })
    test.equal(2, view:get_scrollable_line_count())
  end)

  test.it("invalidates provider visual rows after same-line-count reload", function()
    local path = core.project_absolute_path("tmp-visual-row-reload.txt")
    pcall(os.remove, path)
    write_file(path, "TODO one\ntwo\n")
    local doc = Doc("tmp-visual-row-reload.txt", path)
    local view = DocView(doc)
    view:add_visual_row_provider("todo", {
      visual_rows = function(_, v, line, placement)
        if placement == "before" and (v.doc.lines[line] or ""):find("TODO", 1, true) then
          return { { id = "todo" } }
        end
      end,
    })
    test.equal(3, view:get_scrollable_line_count())
    write_file(path, "done one\ntwo\n")
    doc:load(path)
    test.ok(not doc.lines[1]:find("TODO", 1, true), doc.lines[1])
    test.equal(2, view:get_scrollable_line_count())
    pcall(os.remove, path)
  end)

  test.it("invalidates wrapped visual rows after same-line-count reload", function()
    local path = core.project_absolute_path("tmp-visual-row-wrap-reload.txt")
    pcall(os.remove, path)
    write_file(path, string.rep("wide ", 40) .. "\nshort\n")
    local doc = Doc("tmp-visual-row-wrap-reload.txt", path)
    local view = DocView(doc)
    view.size.x = 120
    view:set_wrapping_enabled(true)
    view:update_wrap_cache()
    local before = view:get_scrollable_line_count()
    write_file(path, "short\nshort\n")
    doc:load(path)
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
    local old_push = core.push_clip_rect
    local old_pop = core.pop_clip_rect
    renderer.draw_text = function(font, text, x, y, color) return x + (font and font:get_width(text) or 0) end
    renderer.draw_rect = function() end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    local ok, err = pcall(function() view:draw_folded() end)
    renderer.draw_text = old_text
    renderer.draw_rect = old_rect
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
