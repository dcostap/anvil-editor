local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local style = require "core.style"
local test = require "core.test"

local diffview = require "plugins.diffview"
local LineWrapping = require "core.linewrapping"

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function remove_doc(doc)
  for i = #core.docs, 1, -1 do
    if core.docs[i] == doc then
      table.remove(core.docs, i)
      doc:on_close()
      return
    end
  end
end

local function open_editor(context, text)
  local doc = track(context, "docs", core.open_doc())
  if text and text ~= "" then doc:text_input(text) end
  local view = track(context, "views", core.root_panel:open_doc(doc))
  core.set_active_view(view)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 320, 240
  view.scroll.x, view.scroll.to.x = 0, 0
  view.scroll.y, view.scroll.to.y = 0, 0
  return view, doc
end

local function configure_wrapping_for_test(context, view)
  local cfg = config.plugins.linewrapping
  if not context.linewrapping_config then
    context.linewrapping_config = {
      mode = cfg.mode,
      width_override = cfg.width_override,
      indent = cfg.indent,
      wrapping_indent = cfg.wrapping_indent,
      guide = cfg.guide,
    }
  end
  if context.highlight_current_line == nil then
    context.highlight_current_line = config.highlight_current_line
  end
  if context.disable_blink == nil then
    context.disable_blink = config.disable_blink
  end

  cfg.mode = "letter"
  cfg.indent = false
  cfg.wrapping_indent = 0
  cfg.guide = true
  cfg.width_override = view:get_font():get_width("xxxxxxxx")
  config.highlight_current_line = true
  config.disable_blink = true

  view.wrapping_enabled = true
  LineWrapping.update_docview_breaks(view)
end

local function restore_config(context)
  if context.linewrapping_config then
    local cfg = config.plugins.linewrapping
    cfg.mode = context.linewrapping_config.mode
    cfg.width_override = context.linewrapping_config.width_override
    cfg.indent = context.linewrapping_config.indent
    cfg.wrapping_indent = context.linewrapping_config.wrapping_indent
    cfg.guide = context.linewrapping_config.guide
  end
  if context.highlight_current_line ~= nil then
    config.highlight_current_line = context.highlight_current_line
  end
  if context.disable_blink ~= nil then
    config.disable_blink = context.disable_blink
  end
  if context.scroll_past_end ~= nil then
    config.scroll_past_end = context.scroll_past_end
  end
  if context.scroll_context_lines ~= nil then
    config.scroll_context_lines = context.scroll_context_lines
  end
end

local function with_stubbed_renderer(fn)
  local old_draw_rect = renderer.draw_rect
  local old_draw_text = renderer.draw_text
  local old_draw_text_known_bounds = renderer.draw_text_known_bounds
  local old_set_clip_rect = renderer.set_clip_rect
  local old_common_draw_text = common.draw_text

  renderer.draw_rect = function() end
  renderer.draw_text = function(font, text, x)
    return x + font:get_width(text)
  end
  renderer.draw_text_known_bounds = function(_, _, x, _, _, _, w)
    return x + w
  end
  renderer.set_clip_rect = function() end
  common.draw_text = function() end

  local ok, a, b, c, d = pcall(fn)

  renderer.draw_rect = old_draw_rect
  renderer.draw_text = old_draw_text
  renderer.draw_text_known_bounds = old_draw_text_known_bounds
  renderer.set_clip_rect = old_set_clip_rect
  common.draw_text = old_common_draw_text

  if not ok then error(a, 0) end
  return a, b, c, d
end

local function capture_drawn_caret(view)
  local drawn_caret
  local old_draw_caret = view.draw_caret
  view.draw_caret = function(_, x, y, caret_line, caret_col)
    drawn_caret = { x = x, y = y, line = caret_line, col = caret_col }
  end
  with_stubbed_renderer(function() view:draw_overlay() end)
  view.draw_caret = old_draw_caret
  return drawn_caret
end

local function collect_current_line_highlights(view, fn)
  local highlights = {}
  local old_draw_line_highlight = view.draw_line_highlight

  view.draw_line_highlight = function(_, x, y)
    highlights[#highlights + 1] = { x = x, y = y }
  end

  local ok, err = pcall(function()
    with_stubbed_renderer(fn)
  end)

  view.draw_line_highlight = old_draw_line_highlight

  if not ok then error(err, 0) end
  return highlights
end

local function wait_until(predicate, timeout, message)
  local deadline = system.get_time() + (timeout or 1)
  while not predicate() do
    if system.get_time() >= deadline then
      test.fail(message or "timed out waiting for condition", 2)
    end
    coroutine.yield(0.01)
  end
end

test.describe("line wrapping current line highlight", function()
  test.after_each(function(context)
    restore_config(context)
    local root = core.root_panel.root_node
    for _, view in ipairs(context.views or {}) do
      view.wrapping_enabled = false
      view.wrapped_settings = nil
      local node = root:get_node_for_view(view)
      if node then node:remove_view(root, view) end
    end
    for _, doc in ipairs(context.docs or {}) do
      if doc:is_dirty() then doc:clean() end
      remove_doc(doc)
    end
  end)

  test.it("highlights only the wrapped visual line containing the caret", function(context)
    local view, doc = open_editor(context, string.rep("x", 40) .. "\n")
    configure_wrapping_for_test(context, view)

    local first_x, first_y = view:get_line_screen_position(1)
    local _, second_visual_y = view:get_line_screen_position(1, 12)
    test.ok(second_visual_y > first_y, "expected the test caret column to be on a wrapped continuation line")

    doc:set_selection(1, 12, 1, 12)

    local highlights = collect_current_line_highlights(view, function()
      view:draw_line_body(1, first_x, first_y)
    end)

    test.equal(#highlights, 1)
    test.equal(highlights[1].y, second_visual_y)
  end)

  test.it("draws a single current-line highlight during a full wrapped Document View draw", function(context)
    local view, doc = open_editor(context, string.rep("x", 40) .. "\n")
    configure_wrapping_for_test(context, view)
    doc:set_selection(1, 12, 1, 12)

    local _, expected_y = view:get_line_screen_position(1, 12)
    local highlights = collect_current_line_highlights(view, function()
      view:draw()
    end)

    test.equal(#highlights, 1)
    test.equal(highlights[1].y, expected_y)
  end)

  test.it("keeps current-line highlight but hides caret when the DocView is inactive", function(context)
    local view, doc = open_editor(context, "one\ntwo\n")
    context.highlight_current_line = config.highlight_current_line
    context.disable_blink = config.disable_blink
    config.highlight_current_line = true
    config.disable_blink = true
    doc:set_selection(2, 1, 2, 1)

    local original_active_view = core.active_view
    local original_window_has_focus = system.window_has_focus
    core.active_view = {}
    system.window_has_focus = function() return true end

    local carets = {}
    local old_draw_caret = view.draw_caret
    view.draw_caret = function(_, x, y, line, col)
      carets[#carets + 1] = { x = x, y = y, line = line, col = col }
    end

    local highlights = collect_current_line_highlights(view, function()
      view:draw()
    end)

    view.draw_caret = old_draw_caret
    core.active_view = original_active_view
    system.window_has_focus = original_window_has_focus

    test.equal(#highlights, 1)
    test.equal(#carets, 0)
  end)

  test.it("refreshes visible caret cache during a full wrapped Document View draw", function(context)
    local view, doc = open_editor(context, string.rep("x", 40) .. "\n")
    configure_wrapping_for_test(context, view)
    doc:set_selection(1, 20, 1, 20)
    view.__visible_caret_cache = { { 1, 2, 1, 2 } }

    local carets = {}
    local old_draw_caret = view.draw_caret
    view.draw_caret = function(_, x, y, line, col)
      carets[#carets + 1] = { x = x, y = y, line = line, col = col }
    end

    local ok, err = pcall(function()
      with_stubbed_renderer(function()
        view:draw()
      end)
    end)
    view.draw_caret = old_draw_caret
    if not ok then error(err, 0) end

    test.equal(#carets, 1)
    test.equal(carets[1].line, 1)
    test.equal(carets[1].col, 20)
  end)

  test.it("limits wrapped scroll-past-end to the final visual row's context boundary", function(context)
    context.scroll_past_end = config.scroll_past_end
    context.scroll_context_lines = config.scroll_context_lines
    config.scroll_past_end = true
    config.scroll_context_lines = 2

    local view, doc = open_editor(context, string.rep("x", 200))
    view.size.y = 120
    configure_wrapping_for_test(context, view)
    local lh = view:get_line_height()

    view.scroll.to.y = view:get_scrollable_size() + view.size.y
    view:clamp_scroll_position()
    view.scroll.y = view.scroll.to.y
    view:update_scrollbar()

    test.equal(view.scroll.y, view:get_scrollable_size() - view.size.y)
    test.equal(view.v_scrollbar.percent, 1)
    local last_line = #doc.lines
    local _, last_y = view:get_line_screen_position(last_line, #doc.lines[last_line])
    test.equal(last_y + lh, view.position.y + view.size.y - config.scroll_context_lines * lh)
  end)
end)

test.describe("line wrapping visual navigation", function()
  test.after_each(function(context)
    restore_config(context)
    local root = core.root_panel.root_node
    for _, view in ipairs(context.views or {}) do
      view.wrapping_enabled = false
      view.wrapped_settings = nil
      local node = root:get_node_for_view(view)
      if node then node:remove_view(root, view) end
    end
    for _, doc in ipairs(context.docs or {}) do
      if doc:is_dirty() then doc:clean() end
      remove_doc(doc)
    end
  end)

  test.it("moves up and down by wrapped visual rows", function(context)
    local view, doc = open_editor(context, string.rep("x", 40))
    configure_wrapping_for_test(context, view)
    doc:set_selection(1, 1, 1, 1)

    command.perform("doc:move-to-next-line")
    local line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 9)

    command.perform("doc:move-to-next-line")
    line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 17)

    command.perform("doc:move-to-previous-line")
    line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 9)
  end)

  test.it("moves home/end to visual row boundaries before actual line boundaries", function(context)
    local view, doc = open_editor(context, string.rep("x", 40))
    configure_wrapping_for_test(context, view)

    doc:set_selection(1, 12, 1, 12)
    command.perform("doc:move-to-start-of-indentation")
    local line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 9)

    command.perform("doc:move-to-start-of-indentation")
    line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 1)

    doc:set_selection(1, 12, 1, 12)
    command.perform("doc:move-to-end-of-line")
    line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 17)

    command.perform("doc:move-to-end-of-line")
    line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, #doc.lines[1])
  end)

  test.it("draws wrapped plain ASCII text with known bounds to avoid redundant shaping", function(context)
    local view = open_editor(context, string.rep("x", 80))
    configure_wrapping_for_test(context, view)

    local draw_text_calls = 0
    local known_bounds_calls = 0
    local old_draw_text = renderer.draw_text
    local old_draw_text_known_bounds = renderer.draw_text_known_bounds
    renderer.draw_text = function(font, text, x)
      draw_text_calls = draw_text_calls + 1
      return x + font:get_width(text)
    end
    renderer.draw_text_known_bounds = function(_, _, x, _, _, _, w)
      known_bounds_calls = known_bounds_calls + 1
      return x + w
    end

    local ok, err = pcall(function()
      view:draw_line_text(1, select(1, view:get_line_screen_position(1)), select(2, view:get_line_screen_position(1)))
    end)

    renderer.draw_text = old_draw_text
    renderer.draw_text_known_bounds = old_draw_text_known_bounds
    if not ok then error(err, 0) end

    test.ok(known_bounds_calls > 0, "expected wrapped ASCII text to use known-bounds drawing")
    test.equal(draw_text_calls, 0)
  end)

  test.it("keeps typed caret at visual end when insertion fills a wrapped row", function(context)
    local view, doc = open_editor(context, string.rep("x", 15))
    configure_wrapping_for_test(context, view)
    local font = view:get_font()
    local first_row_x, first_row_y = view:get_line_screen_position(1, 1)

    doc:set_selection(1, 8, 1, 8)
    view:on_text_input("x")
    local line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 9)

    local drawn_caret
    local old_draw_caret = view.draw_caret
    view.draw_caret = function(_, x, y, caret_line, caret_col)
      drawn_caret = { x = x, y = y, line = caret_line, col = caret_col }
    end
    with_stubbed_renderer(function() view:draw_overlay() end)
    view.draw_caret = old_draw_caret

    test.equal(drawn_caret.line, line)
    test.equal(drawn_caret.col, col)
    test.equal(drawn_caret.y, first_row_y)
    test.equal(drawn_caret.x, first_row_x + font:get_width("xxxxxxxx"))
  end)

  test.it("keeps next-character movement caret at visual end when crossing a wrap boundary", function(context)
    local view, doc = open_editor(context, string.rep("x", 16))
    configure_wrapping_for_test(context, view)
    local font = view:get_font()
    local first_row_x, first_row_y = view:get_line_screen_position(1, 1)
    local second_row_y = select(2, view:get_line_screen_position(1, 10))

    doc:set_selection(1, 8, 1, 8)
    command.perform("doc:move-to-next-char")
    local line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 9)

    local drawn_caret = capture_drawn_caret(view)
    test.equal(drawn_caret.line, line)
    test.equal(drawn_caret.col, col)
    test.equal(drawn_caret.y, first_row_y)
    test.equal(drawn_caret.x, first_row_x + font:get_width("xxxxxxxx"))

    command.perform("doc:move-to-next-char")
    line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 10)

    drawn_caret = capture_drawn_caret(view)
    test.equal(drawn_caret.y, second_row_y)
    test.equal(drawn_caret.x, select(1, view:get_line_screen_position(1, 9)) + font:get_width("x"))
  end)

  test.it("keeps selection-extension caret at visual end when crossing a wrap boundary", function(context)
    local view, doc = open_editor(context, string.rep("x", 16))
    configure_wrapping_for_test(context, view)
    local font = view:get_font()
    local first_row_x, first_row_y = view:get_line_screen_position(1, 1)

    doc:set_selection(1, 8, 1, 8)
    command.perform("doc:select-to-next-char")
    local line1, col1, line2, col2 = doc:get_selection()
    test.equal(line1, 1)
    test.equal(col1, 9)
    test.equal(line2, 1)
    test.equal(col2, 8)

    local drawn_caret = capture_drawn_caret(view)
    test.equal(drawn_caret.line, line1)
    test.equal(drawn_caret.col, col1)
    test.equal(drawn_caret.y, first_row_y)
    test.equal(drawn_caret.x, first_row_x + font:get_width("xxxxxxxx"))
  end)

  test.it("keeps forward word endpoint caret at visual end when it lands on a wrap boundary", function(context)
    local view, doc = open_editor(context, string.rep("x", 8) .. " y")
    configure_wrapping_for_test(context, view)
    local font = view:get_font()
    local first_row_x, first_row_y = view:get_line_screen_position(1, 1)

    doc:set_selection(1, 1, 1, 1)
    command.perform("doc:move-to-next-word-end")
    local line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 9)

    local drawn_caret = capture_drawn_caret(view)
    test.equal(drawn_caret.line, line)
    test.equal(drawn_caret.col, col)
    test.equal(drawn_caret.y, first_row_y)
    test.equal(drawn_caret.x, first_row_x + font:get_width("xxxxxxxx"))
  end)

  test.it("draws the wrap guide before the visual-end caret so the caret is not cropped", function(context)
    local view, doc = open_editor(context, string.rep("x", 40))
    configure_wrapping_for_test(context, view)
    doc:set_selection(1, 12, 1, 12)
    command.perform("doc:move-to-end-of-line")

    local expected_x = select(1, view:get_line_screen_position(1, 17, true))
    local events = {}
    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    local old_draw_text_known_bounds = renderer.draw_text_known_bounds
    local old_set_clip_rect = renderer.set_clip_rect
    local old_common_draw_text = common.draw_text
    local old_draw_caret = view.draw_caret

    renderer.draw_rect = function(x, y, w, h, color)
      if color == style.line_wrapping_guide and math.abs(x - expected_x) < 0.01 then
        events[#events + 1] = "guide"
      end
    end
    renderer.draw_text = function(font, text, x)
      return x + font:get_width(text)
    end
    renderer.draw_text_known_bounds = function(_, _, x, _, _, _, w)
      return x + w
    end
    renderer.set_clip_rect = function() end
    common.draw_text = function() end
    view.draw_caret = function(_, x, y, caret_line, caret_col)
      if caret_line == 1 and caret_col == 17 and math.abs(x - expected_x) < 0.01 then
        events[#events + 1] = "caret"
      end
    end

    local ok, err = pcall(function() view:draw() end)

    renderer.draw_rect = old_draw_rect
    renderer.draw_text = old_draw_text
    renderer.draw_text_known_bounds = old_draw_text_known_bounds
    renderer.set_clip_rect = old_set_clip_rect
    common.draw_text = old_common_draw_text
    view.draw_caret = old_draw_caret
    if not ok then error(err, 0) end

    test.same(events, { "guide", "caret" })
  end)

  test.it("draws visual-end caret on the previous wrapped row before right moves to the next row", function(context)
    local view, doc = open_editor(context, string.rep("x", 40))
    configure_wrapping_for_test(context, view)
    local font = view:get_font()
    local _, second_row_y = view:get_line_screen_position(1, 12)
    local _, third_row_y = view:get_line_screen_position(1, 20)

    doc:set_selection(1, 12, 1, 12)
    command.perform("doc:move-to-end-of-line")
    local line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 17)

    local drawn_caret
    local old_draw_caret = view.draw_caret
    view.draw_caret = function(_, x, y, caret_line, caret_col)
      drawn_caret = { x = x, y = y, line = caret_line, col = caret_col }
    end
    with_stubbed_renderer(function() view:draw_overlay() end)
    view.draw_caret = old_draw_caret

    test.equal(drawn_caret.line, line)
    test.equal(drawn_caret.col, col)
    test.equal(drawn_caret.y, second_row_y)
    test.equal(drawn_caret.x, select(1, view:get_line_screen_position(1, 9)) + font:get_width("xxxxxxxx"))

    command.perform("doc:move-to-next-char")
    line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 18)

    local x, y = view:get_line_screen_position(line, col)
    test.equal(y, third_row_y)
    test.equal(x, select(1, view:get_line_screen_position(1, 17)) + font:get_width("x"))
  end)

  test.it("keeps wrapped End affinity separate from document selection bounds", function(context)
    local view, doc = open_editor(context, string.rep("x", 40))
    configure_wrapping_for_test(context, view)
    local font = view:get_font()

    doc:set_selection(1, 12, 1, 12)
    command.perform("doc:select-to-end-of-line")
    local line1, col1, line2, col2 = doc:get_selection()
    test.equal(line1, 1)
    test.equal(col1, 17)
    test.equal(line2, 1)
    test.equal(col2, 12)

    test.equal(view:get_col_x_offset(1, 17), 0)
    test.equal(view:get_col_x_offset(1, 17, true), font:get_width("xxxxxxxx"))
  end)

  test.it("moves vertically to the end of a shorter word-wrapped row", function(context)
    local view, doc = open_editor(context, "a " .. string.rep("b", 18))
    configure_wrapping_for_test(context, view)
    config.plugins.linewrapping.mode = "word"
    LineWrapping.reconstruct_breaks(view, view:get_font(), config.plugins.linewrapping.width_override)

    doc:set_selection(1, 8, 1, 8)
    command.perform("doc:move-to-previous-line")
    local line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 3)

    local x, y = view:get_line_screen_position(line, col, true)
    test.equal(y, select(2, view:get_line_screen_position(1, 1)))
    test.equal(x, select(1, view:get_line_screen_position(1, 1)) + view:get_font():get_width("a "))
  end)

  test.it("culls text drawing for offscreen visual rows in one long wrapped line", function(context)
    local view = open_editor(context, string.rep("x", 400))
    configure_wrapping_for_test(context, view)
    local lh = view:get_line_height()
    view.size.y = lh * 4 + style.padding.y * 2
    view.scroll.y, view.scroll.to.y = lh * 10, lh * 10
    LineWrapping.update_docview_breaks(view)

    local x, y = view:get_line_screen_position(1)
    local calls = 0
    local draw_ys = {}
    local old_draw_text = renderer.draw_text
    local old_draw_text_known_bounds = renderer.draw_text_known_bounds
    local old_draw_rect = renderer.draw_rect
    renderer.draw_text = function(font, text, sx, sy)
      calls = calls + 1
      draw_ys[#draw_ys + 1] = sy
      return sx + font:get_width(text)
    end
    renderer.draw_text_known_bounds = function(_, _, sx, sy, _, _, w)
      calls = calls + 1
      draw_ys[#draw_ys + 1] = sy
      return sx + w
    end
    renderer.draw_rect = function() end

    local ok, err = pcall(function()
      local height = view:draw_line_body(1, x, y)
      test.ok(height > lh * 20, "expected the fixture line to wrap far beyond the viewport")
    end)

    renderer.draw_text = old_draw_text
    renderer.draw_text_known_bounds = old_draw_text_known_bounds
    renderer.draw_rect = old_draw_rect
    if not ok then error(err, 0) end

    test.ok(calls > 0, "expected visible wrapped rows to be submitted to renderer")
    test.ok(calls <= 6, "expected only visible wrapped rows to be submitted to renderer")
    for _, sy in ipairs(draw_ys) do
      local row_y = sy - view:get_line_text_y_offset()
      test.ok(row_y + lh > view.position.y, "expected drawn wrapped row to intersect the visible viewport")
      test.ok(row_y < view.position.y + view.size.y, "expected drawn wrapped row to intersect the visible viewport")
    end
  end)
end)

test.describe("line wrapping diff hunk gutter line numbers", function()
  test.after_each(function(context)
    restore_config(context)
    for _, diff in ipairs(context.diffviews or {}) do
      diff.doc_view_a.wrapping_enabled = false
      diff.doc_view_a.wrapped_settings = nil
      diff.doc_view_b.wrapping_enabled = false
      diff.doc_view_b.wrapped_settings = nil
      diff.doc_view_a.doc:on_close()
      diff.doc_view_b.doc:on_close()
    end
  end)

  test.it("positions gutter line numbers after wrapped fake rows and diff hunk gap rows", function(context)
    local long = string.rep("x", 40)
    local view = track(context, "diffviews", diffview.string_to_string(
      long .. "\nshared\nend",
      long .. "\ninserted\nshared\nend",
      "left",
      "right",
      true
    ))

    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    local left = view.doc_view_a
    left.position.x, left.position.y = 0, 0
    left.size.x, left.size.y = 320, 240
    left.scroll.x, left.scroll.to.x = 0, 0
    left.scroll.y, left.scroll.to.y = 0, 0
    configure_wrapping_for_test(context, left)

    local line1_x, line1_y = left:get_line_screen_position(1)
    local _, line2_y = left:get_line_screen_position(2)
    local lh = left:get_line_height()
    local line1_height = with_stubbed_renderer(function()
      return left:draw_line_body(1, line1_x, line1_y)
    end)
    local gap_rows_before_line1 = view.a_gaps[1] and view.a_gaps[1][2] or 0
    local gap_rows_before_line2 = view.a_gaps[2] and view.a_gaps[2][2] or 0
    local hunk_gap_height = (gap_rows_before_line2 - gap_rows_before_line1) * lh

    test.ok(line1_height > lh, "expected the first real line to wrap onto fake visual rows")
    test.equal(hunk_gap_height, lh)
    test.equal(line2_y, line1_y + line1_height + hunk_gap_height)
  end)

  test.it("uses wrapped line-end affinity for DiffView caret screen rows", function(context)
    local long = string.rep("x", 40)
    local view = track(context, "diffviews", diffview.string_to_string(
      long,
      long,
      "left",
      "right",
      true
    ))

    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    local left = view.doc_view_a
    left.position.x, left.position.y = 0, 0
    left.size.x, left.size.y = 320, 240
    left.scroll.x, left.scroll.to.x = 0, 0
    left.scroll.y, left.scroll.to.y = 0, 0
    configure_wrapping_for_test(context, left)

    local row_start_col = 9
    left.doc:set_selection(1, row_start_col, 1, row_start_col)
    LineWrapping.set_wrapped_line_end_affinity(left, {
      [LineWrapping.position_key(1, row_start_col)] = true,
    })

    local _, first_row_y = left:get_line_screen_position(1, 1)
    local _, next_row_y = left:get_line_screen_position(1, row_start_col, false)
    left.__use_wrapped_caret_affinity = true
    local _, affinity_y = left:get_line_screen_position(1, row_start_col)
    left.__use_wrapped_caret_affinity = nil

    test.ok(next_row_y > first_row_y, "expected fixture column to begin the next wrapped row without affinity")
    test.equal(affinity_y, first_row_y)
  end)
end)
