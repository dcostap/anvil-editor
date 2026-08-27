local core = require "core"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local test = require "core.test"
local Editor = require "core.editor"
local panes = require "core.panes"
local line_packets = require "core.textview_line_packets"

require "plugins.intellij_find"

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function remove_buffer(buffer)
  for i = #core.buffers, 1, -1 do
    if core.buffers[i] == buffer then
      table.remove(core.buffers, i)
      buffer:on_close()
      return
    end
  end
end

local function open_editor(context, text)
  local buffer = track(context, "buffers", core.open_buffer())
  if text and text ~= "" then buffer:text_input(text) end
  local view = track(context, "views", panes.place(function() return Editor(buffer) end,
    { placement = "new", focus = true }))
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 220, 180
  view.scroll.x, view.scroll.to.x = 0, 0
  view.scroll.y, view.scroll.to.y = 0, 0
  return view, buffer
end

local function visible_text_screen_edges(view)
  local gw = view:get_gutter_width()
  local _, _, scroll_w = view.v_scrollbar:get_track_rect()
  return view.position.x + gw, view.position.x + view.size.x - scroll_w
end

local function range_screen_x(view, line, col1, col2, target_scroll)
  local gw = view:get_gutter_width()
  local scroll_x = target_scroll == nil and view.scroll.x or target_scroll
  local text_origin = view.position.x - scroll_x + gw
  local x1 = text_origin + view:get_col_x_offset(line, col1)
  local x2 = text_origin + view:get_col_x_offset(line, col2)
  return math.min(x1, x2), math.max(x1, x2)
end

local function numbered_lines(count)
  local lines = {}
  for i = 1, count do lines[i] = "line " .. i end
  return table.concat(lines, "\n")
end

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + timeout
  while not predicate() and system.get_time() < deadline do
    coroutine.yield(0.01)
  end
  return predicate()
end

local function disable_wrapping(view)
  view:set_wrapping_enabled(false)
  view.scroll.x, view.scroll.to.x = 0, 0
end

local function wait_for_horizontal_extent(view)
  view:get_h_scrollable_size()
  return wait_until(function()
    view:get_h_scrollable_size()
    return not view:is_horizontal_extent_scan_pending()
  end, 2)
end

local function expected_horizontal_extent(view, text, opts)
  local font = view:get_font()
  local _, indent_size = view.buffer:get_indent_info()
  font:set_tab_size(indent_size)
  local gutter = view:get_gutter_width()
  local _, _, scroll_w = view.v_scrollbar:get_track_rect()
  return math.max(
    view.size.x,
    gutter + font:get_width(text, opts)
      + math.max(style.padding.x, scroll_w or 0)
  )
end

local function capture_unwrapped_line_draw(view, scroll_x)
  local old_draw_text = renderer.draw_text
  local old_draw_text_known_bounds = renderer.draw_text_known_bounds
  local submitted = {}
  renderer.draw_text = function(font, text, x, _, _, opts)
    submitted[#submitted + 1] = text
    return x + font:get_width(text, opts)
  end
  renderer.draw_text_known_bounds = function(_, text)
    submitted[#submitted + 1] = text
  end
  view.__test_force_known_bounds = true
  view.scroll.x, view.scroll.to.x = scroll_x, scroll_x
  local x, y = view:get_line_screen_position(1)
  local ok, err = pcall(view.draw_line_text, view, 1, x, y)
  renderer.draw_text = old_draw_text
  renderer.draw_text_known_bounds = old_draw_text_known_bounds
  if not ok then error(err, 0) end
  return table.concat(submitted)
end

test.describe("TextView selection scrolling", function()
  test.before_each(function(context)
    if command.is_valid("editor:find_close") then command.perform("editor:find_close") end
    context.scroll_past_end = config.scroll_past_end
    context.scroll_context_lines = config.scroll_context_lines
  end)

  test.after_each(function(context)
    if command.is_valid("editor:find_close") then command.perform("editor:find_close") end
    config.scroll_past_end = context.scroll_past_end
    config.scroll_context_lines = context.scroll_context_lines
    panes.reset_for_tests()
    for _, buffer in ipairs(context.buffers or {}) do
      if buffer:is_dirty() then buffer:clean() end
      remove_buffer(buffer)
    end
  end)

  test.it("limits scroll-past-end to the final line's scroll context boundary", function(context)
    config.scroll_past_end = true
    config.scroll_context_lines = 3

    local view, buffer = open_editor(context, numbered_lines(20))
    local lh = view:get_line_height()
    test.ok(lh * #buffer.lines + style.padding.y * 2 > view.size.y, "expected test buffer to overflow vertically")

    view.scroll.to.y = view.size.y * 10
    view:clamp_scroll_position()
    view.scroll.y = view.scroll.to.y
    view:update_scrollbar()

    test.equal(view.scroll.y, view:get_scrollable_size() - view.size.y)
    test.equal(view.v_scrollbar.percent, 1)
    local _, last_y = view:get_line_screen_position(#buffer.lines)
    test.equal(last_y + lh, view.position.y + view.size.y - config.scroll_context_lines * lh)
  end)

  test.it("does not add bottom overscroll when a fitting buffer is already past the context boundary", function(context)
    config.scroll_past_end = true
    config.scroll_context_lines = 1

    local view = open_editor(context, "one\ntwo\nthree")
    view.scroll.to.y = view.size.y
    view:clamp_scroll_position()

    test.equal(view.scroll.to.y, 0)
  end)

  test.it("does not end-scroll short Buffers when existing blank space satisfies context", function(context)
    config.scroll_past_end = true
    config.scroll_context_lines = 28

    local view = open_editor(context, numbered_lines(9))
    local lh = view:get_line_height()
    view.size.y = style.padding.y * 2 + lh * 30

    view:scroll_to_make_visible(9, 1, true)

    test.equal(view.scroll.to.y, 0)
    test.equal(view.scroll.y, 0)
  end)

  test.it("allows fitting Buffers to end-scroll when the caret enters bottom context", function(context)
    config.scroll_past_end = true
    config.scroll_context_lines = 28

    local view = open_editor(context, numbered_lines(29))
    local lh = view:get_line_height()
    view.size.y = style.padding.y * 2 + lh * 30

    view:scroll_to_make_visible(29, 1, true)

    local effective_context = view:get_visible_scroll_context_lines()
    local _, cursor_y = view:get_line_screen_position(29)
    test.ok(view.scroll.y > 0, "expected a fitting buffer near the bottom context to scroll")
    test.equal(cursor_y + lh, view.position.y + view.size.y - effective_context * lh)
  end)

  test.it("keeps mouse-originated clicks near the buffer end from forcing bottom context scrolling", function(context)
    config.scroll_past_end = true
    config.scroll_context_lines = 3

    local view, buffer = open_editor(context, numbered_lines(20))
    view:update_scrollbar()
    local lh = view:get_line_height()
    local scroll_h = view:get_horizontal_scrollbar_height()
    local target_line = #buffer.lines - 1
    local start_scroll = style.padding.y + (target_line - 1) * lh - (view.size.y - scroll_h - 2 * lh)
    test.ok(start_scroll > 0, "expected the target line to require an initial scroll offset")

    view.scroll.y, view.scroll.to.y = start_scroll, start_scroll
    view.mouse_selecting = { target_line, 1, "set" }
    view:scroll_to_make_visible(target_line, 1)

    test.equal(view.scroll.to.y, start_scroll)
  end)

  test.it("shows a horizontal scrollbar for unwrapped text that overflows right", function(context)
    local view = open_editor(context, string.rep("x", 120))
    disable_wrapping(view)
    local line_width = view:get_gutter_width() + view:get_col_x_offset(1, #view.buffer.lines[1] + 1)
    test.ok(line_width > view.size.x, "expected test line to overflow horizontally")

    test.ok(wait_until(function()
      view:update_scrollbar()
      return view:get_h_scrollable_size() > view.size.x
    end, 1), "expected the horizontal extent scan to complete")

    local _, _, track_w, track_h = view.h_scrollbar:get_track_rect()
    local _, _, thumb_w, thumb_h = view.h_scrollbar:get_thumb_rect()
    test.ok(track_w > 0 and track_h > 0, "expected overflowing unwrapped text to show a horizontal scrollbar track")
    test.ok(thumb_w > 0 and thumb_h > 0, "expected overflowing unwrapped text to show a horizontal scrollbar thumb")
  end)

  test.it("defers the initial unwrapped horizontal extent until the scan completes", function(context)
    local view = open_editor(context, string.rep("x", 120))
    disable_wrapping(view)

    test.equal(view:get_h_scrollable_size(), view.size.x)
    test.ok(wait_until(function()
      return view:get_h_scrollable_size() > view.size.x
    end, 1), "expected the deferred horizontal extent scan to complete")
  end)

  test.it("keeps the previous exact width as a finite provisional edit range", function(context)
    local view, buffer = open_editor(context, string.rep("x", 500) .. "\n")
    disable_wrapping(view)
    test.ok(wait_for_horizontal_extent(view))
    local previous_width = view:get_h_scrollable_size()

    buffer:remove(1, 11, 1, #buffer.lines[1])
    test.equal(view:get_h_scrollable_size(), previous_width)
    test.ok(view:is_horizontal_extent_scan_pending())

    view.scroll.to.x = previous_width * 10
    view:clamp_scroll_position()
    test.equal(view.scroll.to.x, previous_width - view.size.x)
  end)

  test.it("keeps reveal targets valid while an edit width scan is pending", function(context)
    local view, buffer = open_editor(context, "short\n")
    disable_wrapping(view)
    test.ok(wait_for_horizontal_extent(view))
    local prefix = string.rep("x", 2000)
    buffer:insert(1, 1, prefix .. "NEEDLE")
    view:get_h_scrollable_size()

    local col1 = #prefix + 1
    local col2 = col1 + #"NEEDLE"
    view:scroll_to_make_visible(1, col1, false, { line2 = 1, col2 = col2 })
    view:clamp_scroll_position()

    test.ok(view:is_horizontal_extent_scan_pending())
    test.ok(view.scroll.to.x > 0)
    test.ok(view.scroll.to.x <= view:get_h_scrollable_size() - view.size.x)
  end)

  test.it("publishes exact edit widths and clamps only invalid targets", function(context)
    local view, buffer = open_editor(context, string.rep("x", 500) .. "\n")
    disable_wrapping(view)
    test.ok(wait_for_horizontal_extent(view))
    local old_max = view:get_h_scrollable_size() - view.size.x

    buffer:remove(1, 21, 1, #buffer.lines[1])
    view:get_h_scrollable_size()
    view.scroll.to.x = old_max
    test.ok(wait_for_horizontal_extent(view))
    test.equal(
      view.scroll.to.x,
      view:get_h_scrollable_size() - view.size.x
    )

    buffer:insert(1, 1, string.rep("y", 200))
    view:get_h_scrollable_size()
    view.scroll.to.x = 5
    test.ok(wait_for_horizontal_extent(view))
    test.equal(view.scroll.to.x, 5)
  end)

  test.it("does not publish a stale horizontal width scan", function(context)
    local huge = string.rep("abc\t", 5000)
    local view, buffer = open_editor(context,
      table.concat({ huge, numbered_lines(120) }, "\n"))
    disable_wrapping(view)
    view.size.x = 40
    view.__test_horizontal_extent_chunk_bytes = 16
    view.__test_horizontal_extent_chunks_per_slice = 1
    view:get_h_scrollable_size()
    test.ok(wait_until(function()
      return view:is_horizontal_extent_scan_pending()
        and view:get_h_scrollable_size() > view.size.x
    end, 1), "expected stale scan work before the edit")

    buffer:remove(1, 1, 1, #buffer.lines[1])
    buffer:insert(1, 1, string.rep("z", 20))
    view:get_h_scrollable_size()
    test.ok(wait_for_horizontal_extent(view))

    local gutter = view:get_gutter_width()
    local _, _, scroll_w = view.v_scrollbar:get_track_rect()
    local expected = math.max(
      view.size.x,
      gutter + view:get_col_x_offset(1, #buffer.lines[1])
        + math.max(style.padding.x, scroll_w or 0)
    )
    test.equal(view:get_h_scrollable_size(), expected)
  end)

  test.it("remeasures the horizontal range after a Font size change", function(context)
    local view = open_editor(context, string.rep("x", 300) .. "\n")
    disable_wrapping(view)
    test.ok(wait_for_horizontal_extent(view))
    local font = view:get_font()
    local old_size = font:get_size()
    local old_width = view:get_h_scrollable_size()
    local retained_target = math.min(20, old_width - view.size.x)
    view.scroll.x, view.scroll.to.x = retained_target, retained_target

    font:set_size(old_size * 1.25)
    local ok, err = pcall(function()
      view:get_h_scrollable_size()
      test.ok(view:is_horizontal_extent_scan_pending())
      view:clamp_scroll_position()
      test.equal(view.scroll.to.x, retained_target)
      test.ok(wait_for_horizontal_extent(view))
      test.ok(view:get_h_scrollable_size() > old_width)
      test.equal(view.scroll.to.x, retained_target)
    end)
    font:set_size(old_size)
    if not ok then error(err, 0) end
  end)

  test.it("publishes exact plain ASCII and tabbed widths", function(context)
    local ascii = string.rep("x", 500)
    local view = open_editor(context, ascii .. "\n")
    disable_wrapping(view)
    test.ok(wait_for_horizontal_extent(view))
    test.equal(view:get_h_scrollable_size(), expected_horizontal_extent(view, ascii))

    local tabbed = table.concat({
      string.rep("a", 17), "\t", string.rep("b", 19), "\t",
      string.rep("c", 23),
    })
    local buffer = view.buffer
    buffer:remove(1, 1, 1, #buffer.lines[1])
    buffer:insert(1, 1, tabbed)
    view.__test_horizontal_extent_chunk_bytes = 7
    view.__test_horizontal_extent_chunks_per_slice = 1
    test.ok(wait_for_horizontal_extent(view))
    test.equal(
      view:get_h_scrollable_size(),
      expected_horizontal_extent(view, tabbed, { tab_offset = 0 })
    )
  end)

  test.it("keeps multibyte width exact during deferred measurement", function(context)
    local text = string.rep("é日 word ", 400)
    local view = open_editor(context, text .. "\n")
    disable_wrapping(view)
    view.size.x = 40
    view.__test_horizontal_extent_chunk_bytes = 32
    view.__test_horizontal_extent_chunks_per_slice = 1

    view:get_h_scrollable_size()
    test.ok(wait_until(function()
      return view:is_horizontal_extent_scan_pending()
        and view:get_h_scrollable_size() > view.size.x
    end, 1), "expected a partial multibyte width before completion")
    test.ok(wait_for_horizontal_extent(view))
    test.equal(view:get_h_scrollable_size(), expected_horizontal_extent(view, text))
  end)

  test.it("yields within one huge ASCII line with tabs", function(context)
    local text = string.rep("abc\t", 20000)
    local view = open_editor(context, text .. "\n")
    disable_wrapping(view)
    view.size.x = 40
    view.__test_horizontal_extent_chunk_bytes = 16
    view.__test_horizontal_extent_chunks_per_slice = 1

    view:get_h_scrollable_size()
    test.ok(wait_until(function()
      return view:is_horizontal_extent_scan_pending()
        and view:get_h_scrollable_size() > view.size.x
    end, 1), "expected a partial in-line width before scan completion")
    test.ok(view:is_horizontal_extent_scan_pending())
    test.ok(view:get_h_scrollable_size() >= view.size.x)
  end)

  test.it("cancels an in-line measurement before exact publication", function(context)
    local text = string.rep("abc\t", 5000)
    local view, buffer = open_editor(context, text .. "\n")
    disable_wrapping(view)
    view.__test_horizontal_extent_chunk_bytes = 16
    view.__test_horizontal_extent_chunks_per_slice = 1
    view:get_h_scrollable_size()
    coroutine.yield(0.01)
    test.ok(view:is_horizontal_extent_scan_pending())

    buffer:remove(1, 6, 1, #buffer.lines[1])
    view:get_h_scrollable_size()
    test.ok(wait_for_horizontal_extent(view))
    test.equal(
      view:get_h_scrollable_size(),
      expected_horizontal_extent(view, "abc\t", { tab_offset = 0 })
    )
  end)

  test.it("maps plain ASCII x offsets to nearest caret columns", function(context)
    local text = string.rep("x", 10000)
    local view = open_editor(context, text .. "\n")
    disable_wrapping(view)
    local cell = view:get_font():get_width(" ")

    test.equal(view:get_x_offset_col(1, 0), 1)
    test.equal(view:get_x_offset_col(1, 100 * cell), 101)
    test.equal(view:get_x_offset_col(1, cell * 0.5), 1)
    test.equal(view:get_x_offset_col(1, cell * 0.5 + 0.01), 2)
    test.equal(view:get_x_offset_col(1, cell * 9999.5), 10000)
    test.equal(view:get_x_offset_col(1, cell * 20000), #view.buffer.lines[1])
  end)

  test.it("keeps tab and multibyte hit testing on the exact fallback", function(context)
    local view, buffer = open_editor(context, "a\tb\n")
    disable_wrapping(view)
    local font = view:get_font()
    local _, indent_size = buffer:get_indent_info()
    font:set_tab_size(indent_size)
    local after_a = font:get_width("a")
    local after_tab = font:get_width("a\t", { tab_offset = 0 })
    test.equal(view:get_x_offset_col(1, (after_a + after_tab) / 2), 2)
    test.equal(view:get_x_offset_col(1, (after_a + after_tab) / 2 + 0.01), 3)

    buffer:remove(1, 1, 1, #buffer.lines[1])
    buffer:insert(1, 1, "aé日b")
    local after_ascii = font:get_width("a")
    local after_multibyte = font:get_width("aé")
    test.equal(
      view:get_x_offset_col(1, (after_ascii + after_multibyte) / 2 + 0.01),
      4
    )
  end)

  test.it("draws bounded source ranges for a huge unwrapped line", function(context)
    local prefix = string.rep("x", 200000)
    local suffix = "UNIQUE-DISTANT-SUFFIX"
    local view = open_editor(context, prefix .. suffix .. "\n")
    disable_wrapping(view)
    view.__test_force_line_packets = true

    local left = capture_unwrapped_line_draw(view, 0)
    local suffix_x = view:get_col_x_offset(1, #prefix + 1)
    local right = capture_unwrapped_line_draw(
      view, math.max(0, suffix_x - view.size.x / 2)
    )
    local diagnostics = line_packets.diagnostics(view)

    test.equal(diagnostics.builds, 0)
    test.ok((diagnostics.fallbacks.unwrapped or 0) >= 2)
    test.ok(not left:find(suffix, 1, true))
    test.ok(right:find(suffix, 1, true) ~= nil)
    test.ok(#left < #prefix)
    test.ok(#right < #prefix)
  end)

  test.it("draws the correct far-right tabbed UTF-8 source range", function(context)
    local prefix = string.rep("a\té", 2000)
    local suffix = "TABBED-UTF8-SUFFIX"
    local view = open_editor(context, prefix .. suffix .. "\n")
    disable_wrapping(view)
    view.__test_force_line_packets = true

    local left = capture_unwrapped_line_draw(view, 0)
    local suffix_x = view:get_col_x_offset(1, #prefix + 1)
    local right = capture_unwrapped_line_draw(
      view, math.max(0, suffix_x - view.size.x / 2)
    )

    test.ok(not left:find(suffix, 1, true))
    test.ok(right:find(suffix, 1, true) ~= nil)
    test.ok(#right < #prefix)
  end)

  test.it("builds and reuses wrapped Display Packets", function(context)
    local view = open_editor(context, string.rep("wrapped words ", 40) .. "\n")
    view.__test_force_line_packets = true
    view:update_wrap_cache()

    capture_unwrapped_line_draw(view, 0)
    capture_unwrapped_line_draw(view, 0)
    local diagnostics = line_packets.diagnostics(view)

    test.equal(diagnostics.builds, 1)
    test.ok(diagnostics.hits >= 1)
    test.ok(diagnostics.resident_packets > 0)

    disable_wrapping(view)
    test.equal(line_packets.diagnostics(view).resident_packets, 0)
  end)

  test.it("scroll_to_make_visible reveals an off-screen same-line range horizontally", function(context)
    local prefix = string.rep("x", 120)
    local target = "NEEDLE"
    local view = open_editor(context, prefix .. target .. "\n")
    disable_wrapping(view)
    local col1 = #prefix + 1
    local col2 = col1 + #target
    local target_x = view:get_col_x_offset(1, col1)
    view.scroll.x, view.scroll.to.x = target_x + view.size.x,
      target_x + view.size.x

    view:scroll_to_make_visible(1, col1, true, {
      line2 = 1, col2 = col2, horizontal_grace = 0,
    })

    local x1, x2 = range_screen_x(view, 1, col1, col2)
    local text_left, text_right = visible_text_screen_edges(view)
    test.ok(view.scroll.x > 0, "expected horizontal scroll to move right for an off-screen match")
    test.ok(x1 >= text_left, "expected match start to stay outside the fixed gutter")
    test.ok(x2 <= text_right + 1, "expected match end to stay left of the vertical scrollbar")
  end)

  test.it("scroll_to_make_visible resets horizontal scroll when a range fits from baseline", function(context)
    local view = open_editor(context, "start NEEDLE then more text\n")
    disable_wrapping(view)
    view.scroll.x, view.scroll.to.x = 160, 160
    local col1 = 7
    local col2 = col1 + #"NEEDLE"

    view:scroll_to_make_visible(1, col1, true, { line2 = 1, col2 = col2 })

    test.equal(view.scroll.x, 0)
    test.equal(view.scroll.to.x, 0)
  end)

  test.it("TextView Prompt Bar find navigation horizontally reveals long-line matches", function(context)
    local prefix = string.rep("x", 120)
    local view = open_editor(context, prefix .. "NEEDLE\n")
    disable_wrapping(view)
    local col1 = #prefix + 1
    local col2 = col1 + #"NEEDLE"

    test.ok(command.perform("editor:find"))
    core.root_panel:on_text_input("NEEDLE")
    view:get_h_scrollable_size()
    test.ok(view:is_horizontal_extent_scan_pending())
    view:clamp_scroll_position()

    local x1, x2 = range_screen_x(view, 1, col1, col2, view.scroll.to.x)
    local text_left, text_right = visible_text_screen_edges(view)
    test.ok(view.scroll.to.x > 0, "expected local find to horizontally scroll the owning Text View")
    test.ok(x1 >= text_left, "expected local find match to stay outside the fixed gutter")
    test.ok(x2 <= text_right + 1, "expected local find match to stay left of the vertical scrollbar")
  end)
end)
