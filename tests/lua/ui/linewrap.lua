local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local test = require "core.test"

local diffview = require "plugins.diffview"
local LineWrapping = require "plugins.linewrapping"
require "plugins.linewrapping_deep_indent"

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
  local old_set_clip_rect = renderer.set_clip_rect
  local old_common_draw_text = common.draw_text

  renderer.draw_rect = function() end
  renderer.draw_text = function(font, text, x)
    return x + font:get_width(text)
  end
  renderer.set_clip_rect = function() end
  common.draw_text = function() end

  local ok, a, b, c, d = pcall(fn)

  renderer.draw_rect = old_draw_rect
  renderer.draw_text = old_draw_text
  renderer.set_clip_rect = old_set_clip_rect
  common.draw_text = old_common_draw_text

  if not ok then error(a, 0) end
  return a, b, c, d
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
end)
