local core = require "core"
local test = require "core.test"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local Editor = require "core.editor"
local markdown_live = require "core.markdown.live_render"
local sticky_scroll = require "plugins.sticky_scroll"
local renwindow = require "renwindow"

local function make_view(text, editor)
  local buffer = Buffer("sticky.md", "sticky.md", true)
  buffer:insert(1, 1, text)
  local view = editor and Editor(buffer) or TextView(buffer)
  view.position.x, view.position.y = 10, 20
  view.size.x, view.size.y = 500, 240
  view:set_wrapping_enabled(false)
  return view, buffer
end

local function drawn_overlay_text(view, window)
  local old_draw_text = renderer.draw_text
  local old_clip = core.clip_rect_stack[1]
  local text = {}
  renderer.draw_text = function(font, value, x, _, _, options)
    text[#text + 1] = tostring(value)
    return x + font:get_width(tostring(value), options)
  end
  renderer.begin_frame(window)
  renderer.set_clip_rect(0, 0, 800, 600)
  core.clip_rect_stack[1] = { 0, 0, 800, 600 }
  local ok, err = pcall(view.draw_overlay, view)
  renderer.end_frame()
  renderer.draw_text = old_draw_text
  core.clip_rect_stack[1] = old_clip
  if not ok then error(err, 0) end
  return table.concat(text)
end

test.describe("sticky scroll", function()
  test.it("does not run in Markdown Live Preview", function()
    local view = make_view("# Parent\nbody", true)
    test.equal(markdown_live.attach(view), true)
    test.equal(markdown_live.is_live_mode(view), true)

    test.equal(sticky_scroll.should_run(view), false)

    markdown_live.detach(view)
  end)

  test.it("uses cleaned UTF-8 text when measuring indentation in binary-marked Buffers", function()
    local invalid_surrogate = "\237\160\128"
    local line = "  " .. invalid_surrogate .. "heading\n"
    local clean_line = line:uclean("\26", true)
    local buffer = {
      binary = true,
      lines = { line },
      clean_lines = { clean_line },
      get_utf8_line = function(self, idx)
        if self.binary and self.clean_lines[idx] then return self.clean_lines[idx] end
        return self.lines[idx]
      end,
    }

    test.ok(sticky_scroll.get_level_from_indent(buffer, 1) >= 0)
  end)

  test.it("keeps visible Markdown headings until a typed scope change is ready", function()
    local lines = { "# Parent", "## Short section" }
    for i = 3, 6 do lines[i] = "short section paragraph " .. i end
    lines[7] = "## Following section"
    for i = 8, 24 do lines[i] = "following section paragraph " .. i end
    local view, buffer = make_view(table.concat(lines, "\n"))
    local window = renwindow.create("sticky-scroll-rebuild", 800, 600)
    view.scroll.y = view:get_visual_row_y_offset(5)
    view.scroll.to.y = view.scroll.y

    local function wait_for_text(predicate)
      local deadline = system.get_time() + 15
      repeat
        view:update()
        local text = drawn_overlay_text(view, window)
        if predicate(text) then return text end
        coroutine.yield(0.01)
      until system.get_time() >= deadline
    end

    local ok, err = pcall(function()
      local initial = wait_for_text(function(text) return text:find("# Parent", 1, true) end)
      test.ok(initial, "the visible parent heading did not become sticky")
      test.ok(not initial:find("Short section", 1, true), "a heading without a child became sticky")

      -- Changing the parent to a sibling heading removes the sticky scope after
      -- its replacement model is ready. The old heading stays visible meanwhile.
      buffer:insert(1, 1, "#")
      view:update()
      local during_rebuild = drawn_overlay_text(view, window)
      test.ok(during_rebuild:find("## Parent", 1, true),
        "typing removed the last settled heading before its replacement was ready")
      local settled = wait_for_text(function(text) return not text:find("Parent", 1, true) end)
      test.ok(settled, "the old heading stayed sticky after its scope ended")
    end)
    renwindow.close(window)
    if not ok then error(err, 0) end
  end)

  test.it("lays out sticky Markdown headings with their visual row heights", function()
    local view = make_view("# Parent\n## Child\nbody")
    local base = view:get_line_height()
    view:add_visual_metric_provider("sticky-test", {
      line_height = function(_, _, line)
        if line == 1 then return base * 2 end
        if line == 2 then return base * 3 end
      end,
    })

    local layout = sticky_scroll.get_sticky_layout(view, { 2, 1 }, 3)
    test.equal(#layout, 2)
    test.equal(layout[1].line, 1)
    test.equal(layout[1].y, view.position.y)
    test.equal(layout[1].height, base * 2)
    test.equal(layout[2].line, 2)
    test.equal(layout[2].y, view.position.y + base * 2)
    test.equal(layout[2].height, base * 3)
  end)

  test.it("allocates every wrapped visual row of a sticky heading", function()
    local view = make_view(
      "# A parent heading long enough to wrap across several visual rows in a narrow editor\nbody"
    )
    view.size.x = 190
    view:set_wrapping_enabled(true)
    local row_count = view:get_line_visual_row_count(1)
    test.ok(row_count > 1)

    local layout = sticky_scroll.get_sticky_layout(view, { 1 }, 2)
    test.equal(#layout, 1)
    test.equal(layout[1].height, view:get_line_height() * row_count)

    local row2_col = test.not_nil(view:get_visual_row_bounds_for_line(1, 2))
    local data = sticky_scroll.managed_textviews[view]
    data.enabled = true
    data.sticky_lines = { 1 }
    data.reference_line = nil
    local sticky_x = view:get_line_screen_position(1)
    test.equal(
      view:on_mouse_pressed("left", sticky_x + 4, layout[1].y + view:get_line_height() + 2, 1),
      true
    )
    local selected_line, selected_col = view.buffer:get_selection()
    test.equal(selected_line, 1)
    test.ok(selected_col >= row2_col)

    view:add_fold_region { line1 = 1, line2 = 2 }
    local folded = sticky_scroll.get_sticky_layout(view, { 1 }, 2)
    test.equal(folded[1].height, view:get_position_visual_row_height(1, 1))
  end)

  test.it("keeps sticky lines inside the enclosing view clip", function()
    local view = make_view("# Parent\nbody")
    local data = sticky_scroll.managed_textviews[view]
    data.enabled = true
    data.sticky_lines = { 1 }
    data.reference_line = 2
    view.scroll.y = view:get_line_height() * 3
    view.scroll.to.y = view.scroll.y

    local clip_top = view.position.y
    local layout = sticky_scroll.get_sticky_layout(view, data.sticky_lines, data.reference_line)
    test.ok(layout[1].y < clip_top)

    local initial_clip_depth = #core.clip_rect_stack
    local original_set_clip_rect = renderer.set_clip_rect
    local original_draw_rect = renderer.draw_rect
    local escaped = false
    local checking = false
    renderer.set_clip_rect = function(_, y, _, h)
      if checking and h > 0 and y < clip_top then escaped = true end
    end
    renderer.draw_rect = function() end
    core.push_clip_rect(view.position.x, view.position.y, view.size.x, view.size.y)
    local gutter_width = view:get_gutter_width()
    core.push_clip_rect(
      view.position.x + gutter_width,
      view.position.y,
      view.size.x - gutter_width,
      view.size.y
    )
    view.draw_line_gutter = function() end
    view.draw_line_text = function() end

    checking = true
    local ok, err = pcall(function() view:draw_overlay() end)
    checking = false

    while #core.clip_rect_stack > initial_clip_depth do core.pop_clip_rect() end
    renderer.set_clip_rect = original_set_clip_rect
    renderer.draw_rect = original_draw_rect
    test.ok(ok, err)
    test.equal(escaped, false)
  end)

end)
