local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local style = require "core.style"
local test = require "core.test"
local tokenizer = require "core.tokenizer"

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
      require_tokenization = cfg.require_tokenization,
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
  cfg.require_tokenization = false
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
    cfg.require_tokenization = context.linewrapping_config.require_tokenization
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

  test.it("rebuilds stale wrapped rows after document line count changes outside transactions", function(context)
    local view, doc = open_editor(context, string.rep("x", 40) .. "\n" .. string.rep("y", 40) .. "\n")
    configure_wrapping_for_test(context, view)
    test.equal(view.wrapped_doc_line_count, #doc.lines)

    doc.lines = { string.rep("z", 40) .. "\n" }
    view:update_wrap_cache()

    test.equal(view.wrapped_doc_line_count, 1)
    for i = 1, #view.wrapped_lines, 2 do
      test.ok(view.wrapped_lines[i] <= #doc.lines, "wrapped row points past document line count")
    end
    with_stubbed_renderer(function() view:draw_wrapped() end)
  end)

  test.it("revalidates stale wrapped rows when the document shrinks between update and draw", function(context)
    local view, doc = open_editor(context, string.rep("x", 40) .. "\n" .. string.rep("y", 40) .. "\n")
    configure_wrapping_for_test(context, view)
    test.ok(view.wrapped_doc_line_count > 1)

    doc.lines = { string.rep("z", 40) .. "\n" }

    with_stubbed_renderer(function() view:draw() end)
    test.equal(view.wrapped_doc_line_count, #doc.lines)
  end)

  test.it("revalidates wrapped rows that point past the document despite current line-count metadata", function(context)
    local view, doc = open_editor(context, string.rep("x", 40) .. "\n" .. string.rep("y", 40) .. "\n")
    configure_wrapping_for_test(context, view)
    test.ok(view.wrapped_doc_line_count > 1)

    doc.lines = { string.rep("z", 40) .. "\n" }
    view.wrapped_doc_line_count = #doc.lines

    with_stubbed_renderer(function() view:draw() end)
    test.equal(view.wrapped_doc_line_count, #doc.lines)
    test.ok(view.wrapped_lines[#view.wrapped_lines - 1] <= #doc.lines)
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

  test.it("does not wrap a trailing stored newline into a phantom row", function(context)
    local view = open_editor(context, "abc")
    configure_wrapping_for_test(context, view)
    config.plugins.linewrapping.width_override = view:get_font():get_width("abc")
    LineWrapping.update_docview_breaks(view)

    test.equal(view:get_total_visual_lines(), 1)
  end)

  test.it("keeps wrapped x-to-column API returning only a column", function(context)
    local view = open_editor(context, string.rep("x", 40))
    configure_wrapping_for_test(context, view)

    test.equal(view:get_x_offset_col(1, view:get_font():get_width("xx")), 3)
  end)

  test.it("updates long plain ASCII line breaks after text input", function(context)
    local view, doc = open_editor(context, string.rep("x", 80))
    configure_wrapping_for_test(context, view)
    test.equal(view:get_total_visual_lines(), 10)

    doc:set_selection(1, 41, 1, 41)
    doc:text_input("y")

    test.equal(doc.lines[1], string.rep("x", 40) .. "y" .. string.rep("x", 40) .. "\n")
    test.equal(view:get_total_visual_lines(), 11)
    test.equal(view.wrapped_line_to_idx[1], 1)
  end)

  test.it("updates long plain ASCII word-wrapped line breaks after text input", function(context)
    local view, doc = open_editor(context, ("word "):rep(80))
    configure_wrapping_for_test(context, view)
    config.plugins.linewrapping.mode = "word"
    LineWrapping.update_docview_breaks(view)
    local old_visual_lines = view:get_total_visual_lines()

    doc:set_selection(1, 21, 1, 21)
    doc:text_input("inserted ")

    test.equal(doc.lines[1]:sub(21, 29), "inserted ")
    test.ok(view:get_total_visual_lines() >= old_visual_lines)
    test.equal(view.wrapped_line_to_idx[1], 1)
  end)

  test.it("uses letter fast path for long no-space ASCII in word mode", function(context)
    local view, doc = open_editor(context, string.rep("f", 80))
    configure_wrapping_for_test(context, view)
    config.plugins.linewrapping.mode = "word"
    LineWrapping.update_docview_breaks(view)
    test.equal(view:get_total_visual_lines(), 10)

    doc:set_selection(1, 41, 1, 41)
    doc:text_input("f")

    test.equal(view:get_total_visual_lines(), 11)
    test.equal(view.wrapped_line_to_idx[1], 1)
  end)

  test.it("updates long no-space UTF-8 word-wrapped line breaks after text input", function(context)
    local view, doc = open_editor(context, ("é"):rep(80))
    configure_wrapping_for_test(context, view)
    config.plugins.linewrapping.mode = "word"
    LineWrapping.update_docview_breaks(view)
    local old_visual_lines = view:get_total_visual_lines()

    doc:set_selection(1, 41, 1, 41)
    doc:text_input("é")

    test.ok(view:get_total_visual_lines() >= old_visual_lines)
    test.equal(view.wrapped_line_to_idx[1], 1)
  end)

  test.it("scrolls to the end of huge simple unwrapped lines without tokenizing for x offset", function(context)
    local view, doc = open_editor(context, string.rep("a", 5000))
    view.wrapping_enabled = false
    view.wrapped_settings = nil
    view.size.x = view:get_font():get_width("x") * 20

    local old_syntax_fonts = style.syntax_fonts
    local old_each_render_token = doc.highlighter.each_render_token
    style.syntax_fonts = {}
    doc.highlighter.each_render_token = function()
      error("scroll-to-visible should use the simple ASCII width fast path", 2)
    end

    local ok, err = pcall(function()
      view:scroll_to_make_visible(1, #doc.lines[1], true)
    end)
    style.syntax_fonts = old_syntax_fonts
    doc.highlighter.each_render_token = old_each_render_token

    if not ok then error(err, 0) end
    test.ok(view.scroll.x > 0, "expected horizontal scroll to move near the end of the long line")
  end)

  test.it("does not send a huge ligature-sensitive unwrapped token to the renderer", function(context)
    local view = open_editor(context, string.rep("f", 5000))
    view.wrapping_enabled = false
    view.wrapped_settings = nil
    view.size.x = view:get_font():get_width("x") * 20

    local calls = 0
    local max_len = 0
    local old_draw_text = renderer.draw_text
    renderer.draw_text = function(font, text, x)
      calls = calls + 1
      max_len = math.max(max_len, #text)
      return x + font:get_width(text)
    end
    local ok, err = pcall(function()
      view:draw_line_text(1, select(1, view:get_line_screen_position(1)), select(2, view:get_line_screen_position(1)))
    end)
    renderer.draw_text = old_draw_text

    if not ok then error(err, 0) end
    test.ok(calls > 0, "expected unwrapped text to be drawn")
    test.ok(max_len <= 512, "expected long unwrapped text to be chunked before renderer draw")
  end)

  test.it("keeps ligature-sensitive unwrapped runs aligned with caret positions", function(context)
    local prefix = "main :: proc()" .. string.rep(":", 40)
    local text = prefix .. "{"
    local view, doc = open_editor(context, text)
    view.wrapping_enabled = false
    view.wrapped_settings = nil
    view.__test_force_known_bounds = true
    view.size.x = 2000

    local old_get_render_line = doc.highlighter.get_render_line
    doc.highlighter.get_render_line = function()
      return {
        text = text .. "\n",
        tokens = { "normal", prefix, "keyword", "{", "normal", "\n" },
        source = "test",
      }
    end

    local drawn_brace_x
    local old_draw_text = renderer.draw_text
    local old_draw_text_known_bounds = renderer.draw_text_known_bounds
    renderer.draw_text = function(font, chunk, x, _, _, opts)
      if chunk == "{" then drawn_brace_x = x end
      return x + font:get_width(chunk, opts)
    end
    renderer.draw_text_known_bounds = function(font, chunk, x, _, _, _, w)
      if chunk == "{" then drawn_brace_x = x end
      return x + w
    end

    local line_x, line_y = view:get_line_screen_position(1)
    local ok, err = pcall(function()
      view:draw_line_text(1, line_x, line_y)
    end)

    renderer.draw_text = old_draw_text
    renderer.draw_text_known_bounds = old_draw_text_known_bounds
    doc.highlighter.get_render_line = old_get_render_line
    if not ok then error(err, 0) end

    local caret_x = select(1, view:get_line_screen_position(1, #prefix + 1))
    test.not_nil(drawn_brace_x)
    test.equal(drawn_brace_x, caret_x, "expected the rendered brace and caret column to stay aligned")
  end)

  test.it("skips far-left chunks of deeply scrolled unwrapped long lines", function(context)
    local view = open_editor(context, string.rep("f", 8000))
    view.wrapping_enabled = false
    view.wrapped_settings = nil
    view.size.x = view:get_font():get_width("x") * 20
    view.scroll.x = view:get_font():get_width("x") * 6000
    view.scroll.to.x = view.scroll.x

    local calls = 0
    local old_draw_text = renderer.draw_text
    renderer.draw_text = function(font, text, x)
      calls = calls + 1
      return x + font:get_width(text)
    end
    local ok, err = pcall(function()
      view:draw_line_text(1, select(1, view:get_line_screen_position(1)), select(2, view:get_line_screen_position(1)))
    end)
    renderer.draw_text = old_draw_text

    if not ok then error(err, 0) end
    test.ok(calls > 0, "expected deeply scrolled long line to still draw visible text")
    test.ok(calls < 80, "expected deeply scrolled long line to draw only visible-adjacent chunks")
  end)

  test.it("does not over-cull deeply scrolled unwrapped tabbed long lines", function(context)
    local view = open_editor(context, string.rep("\t", 3000))
    view.wrapping_enabled = false
    view.wrapped_settings = nil
    view.size.x = view:get_font():get_width("x") * 20
    view.scroll.x = view:get_font():get_width("x") * 6000
    view.scroll.to.x = view.scroll.x

    local calls = 0
    local old_draw_text = renderer.draw_text
    renderer.draw_text = function(font, text, x, y, color, opts)
      calls = calls + 1
      return x + font:get_width(text, opts)
    end
    local ok, err = pcall(function()
      view:draw_line_text(1, select(1, view:get_line_screen_position(1)), select(2, view:get_line_screen_position(1)))
    end)
    renderer.draw_text = old_draw_text

    if not ok then error(err, 0) end
    test.ok(calls > 0, "expected tabbed long line to still draw visible text")
    test.ok(calls < 80, "expected tabbed long line to skip far-left chunks")
  end)

  test.it("does not send a huge non-ASCII unwrapped suffix to the renderer", function(context)
    local view = open_editor(context, string.rep("é", 8000))
    view.wrapping_enabled = false
    view.wrapped_settings = nil
    view.size.x = view:get_font():get_width("x") * 20
    view.scroll.x = view:get_font():get_width("x") * 6000
    view.scroll.to.x = view.scroll.x

    local calls = 0
    local max_len = 0
    local old_draw_text = renderer.draw_text
    renderer.draw_text = function(font, text, x)
      calls = calls + 1
      max_len = math.max(max_len, #text)
      return x + font:get_width(text)
    end
    local ok, err = pcall(function()
      view:draw_line_text(1, select(1, view:get_line_screen_position(1)), select(2, view:get_line_screen_position(1)))
    end)
    renderer.draw_text = old_draw_text

    if not ok then error(err, 0) end
    test.ok(calls > 0, "expected non-ASCII long line to draw visible text")
    test.ok(max_len <= 1024, "expected non-ASCII long line drawing to stay chunked")
  end)

  test.it("does not ask tokenizer to slice huge deeply scrolled unwrapped suffixes", function(context)
    local view = open_editor(context, string.rep("a", 10000))
    view.wrapping_enabled = false
    view.wrapped_settings = nil
    view.size.x = view:get_font():get_width("x") * 20
    view.scroll.x = view:get_font():get_width("x") * 8000
    view.scroll.to.x = view.scroll.x

    local old_each_token = tokenizer.each_token
    tokenizer.each_token = function(tokens, scol)
      if scol then error("unexpected tokenizer suffix slice", 2) end
      return old_each_token(tokens, scol)
    end
    local ok, err = pcall(function()
      with_stubbed_renderer(function()
        view:draw_line_text(1, select(1, view:get_line_screen_position(1)), select(2, view:get_line_screen_position(1)))
      end)
    end)
    tokenizer.each_token = old_each_token

    if not ok then error(err, 0) end
  end)

  test.it("left-culls deeply scrolled unwrapped text in the known-bounds path", function(context)
    local view, doc = open_editor(context, string.rep("a\t", 3000))
    view.wrapping_enabled = false
    view.wrapped_settings = nil
    view.__test_force_known_bounds = true
    view.size.x = view:get_font():get_width("x") * 20
    view.scroll.x = view:get_font():get_width("x") * 6000
    view.scroll.to.x = view.scroll.x

    local calls = 0
    local drawn_text, drawn_x, drawn_opts
    local old_draw_text_known_bounds = renderer.draw_text_known_bounds
    renderer.draw_text_known_bounds = function(_, text, sx, _, _, _, w, _, _, opts)
      calls = calls + 1
      drawn_text = text
      drawn_x = sx
      drawn_opts = opts
      return sx + w
    end
    local ok, err = pcall(function()
      view:draw_line_text(1, select(1, view:get_line_screen_position(1)), select(2, view:get_line_screen_position(1)))
    end)
    renderer.draw_text_known_bounds = old_draw_text_known_bounds

    if not ok then error(err, 0) end
    test.equal(calls, 1)
    test.ok(drawn_text and #drawn_text < #doc.lines[1] / 2, "expected known-bounds path to skip the far-left prefix")
    test.ok(drawn_x > view.position.x - view:get_font():get_width("W") * 80, "expected known-bounds text to start near the visible area")
    test.ok(drawn_opts and drawn_opts.tab_offset and drawn_opts.tab_offset > 0, "expected tab offset relative to original line start")
  end)

  test.it("uses known-bounds drawing for culled multi-token ASCII chunks", function(context)
    local text = string.rep("a", 4000) .. string.rep("b", 4000)
    local view, doc = open_editor(context, text)
    view.wrapping_enabled = false
    view.wrapped_settings = nil
    view.__test_force_known_bounds = true
    view.size.x = view:get_font():get_width("x") * 20
    view.scroll.x = view:get_font():get_width("x") * 6000
    view.scroll.to.x = view.scroll.x

    local old_get_render_line = doc.highlighter.get_render_line
    doc.highlighter.get_render_line = function()
      return {
        text = text,
        tokens = { "normal", text:sub(1, 4000), "normal", text:sub(4001) },
        source = "test",
      }
    end
    local known_calls = 0
    local draw_calls = 0
    local old_draw_text_known_bounds = renderer.draw_text_known_bounds
    local old_draw_text = renderer.draw_text
    renderer.draw_text_known_bounds = function(_, _, sx, _, _, _, w)
      known_calls = known_calls + 1
      return sx + w
    end
    renderer.draw_text = function(font, chunk, sx)
      draw_calls = draw_calls + 1
      return sx + font:get_width(chunk)
    end
    local ok, err = pcall(function()
      view:draw_line_text(1, select(1, view:get_line_screen_position(1)), select(2, view:get_line_screen_position(1)))
    end)
    renderer.draw_text_known_bounds = old_draw_text_known_bounds
    renderer.draw_text = old_draw_text
    doc.highlighter.get_render_line = old_get_render_line

    if not ok then error(err, 0) end
    test.ok(known_calls > 0, "expected generic chunk path to use known-bounds drawing")
    test.equal(draw_calls, 0)
  end)

  test.it("rebuilds wrap cache when wrap settings change without width changes", function(context)
    local view = open_editor(context, "a " .. string.rep("b", 18))
    configure_wrapping_for_test(context, view)
    local letter_rows = view:get_total_visual_lines()

    config.plugins.linewrapping.mode = "word"
    LineWrapping.update_docview_breaks(view)

    test.ok(view:get_total_visual_lines() ~= letter_rows, "expected mode change to rebuild wrap cache")
  end)

  test.it("uses padding-aware visible line range for wrapped views", function(context)
    local view = open_editor(context, "abc\nsecond")
    configure_wrapping_for_test(context, view)
    config.plugins.linewrapping.width_override = view:get_font():get_width("xxxxxxxx")
    LineWrapping.update_docview_breaks(view)
    local lh = view:get_line_height()
    view.scroll.y, view.scroll.to.y = style.padding.y + lh, style.padding.y + lh

    local minline = view:get_visible_line_range()
    test.equal(minline, 2)
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

  test.it("preserves desired horizontal x across short wrapped visual rows", function(context)
    local view, doc = open_editor(context, "abcdefg hi abcdefg")
    configure_wrapping_for_test(context, view)
    config.plugins.linewrapping.mode = "word"
    config.plugins.linewrapping.width_override = view:get_font():get_width("xxxxxxxx")
    LineWrapping.update_docview_breaks(view)

    doc:set_selection(1, 7, 1, 7)
    command.perform("doc:move-to-next-line")
    local line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 12)

    command.perform("doc:move-to-next-line")
    line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 18)
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

  test.it("deletes to wrapped visual row boundaries", function(context)
    local view, doc = open_editor(context, string.rep("x", 40))
    configure_wrapping_for_test(context, view)

    doc:set_selection(1, 12, 1, 12)
    command.perform("doc:delete-to-end-of-line")
    test.equal(doc.lines[1], string.rep("x", 35) .. "\n")
    local line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 12)

    doc:set_selection(1, 10, 1, 10)
    command.perform("doc:delete-to-start-of-line")
    test.equal(doc.lines[1], string.rep("x", 34) .. "\n")
    line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 9)
  end)

  test.it("applies wrapped line-end affinity from mouse cursor commands", function(context)
    local view, doc = open_editor(context, string.rep("x", 40))
    configure_wrapping_for_test(context, view)

    local x, y = view:get_line_screen_position(1, 9, true)
    command.perform("doc:set-cursor", x, y + view:get_line_height() / 2, 1)
    local line, col = doc:get_selection()
    test.equal(line, 1)
    test.equal(col, 9)

    local _, next_row_y = view:get_line_screen_position(1, 9, false)
    view.__use_wrapped_caret_affinity = true
    local _, affinity_y = view:get_line_screen_position(1, 9)
    view.__use_wrapped_caret_affinity = nil
    test.ok(next_row_y > y, "expected column to normally be on the next wrapped row")
    test.equal(affinity_y, y)
  end)

  test.it("applies wrapped line-end affinity from mouse selection commands", function(context)
    local view, doc = open_editor(context, string.rep("x", 40))
    configure_wrapping_for_test(context, view)
    doc:set_selection(1, 1, 1, 1)

    local x, y = view:get_line_screen_position(1, 9, true)
    command.perform("doc:select-to-cursor", x, y + view:get_line_height() / 2, 1)
    local line1, col1, line2, col2 = doc:get_selection()
    test.equal(line1, 1)
    test.equal(col1, 9)
    test.equal(line2, 1)
    test.equal(col2, 1)

    local _, next_row_y = view:get_line_screen_position(1, 9, false)
    view.__use_wrapped_caret_affinity = true
    local _, affinity_y = view:get_line_screen_position(1, 9)
    view.__use_wrapped_caret_affinity = nil
    test.ok(next_row_y > y, "expected column to normally be on the next wrapped row")
    test.equal(affinity_y, y)
  end)

  test.it("splits cursors using wrapped visual row coordinates", function(context)
    local view, doc = open_editor(context, string.rep("x", 40))
    configure_wrapping_for_test(context, view)
    doc:set_selection(1, 1, 1, 1)

    local x, y = view:get_line_screen_position(1, 9)
    command.perform("doc:split-cursor", x, y + view:get_line_height() / 2, 1)

    test.equal(#doc.selections, 8)
    test.same({ doc.selections[1], doc.selections[2], doc.selections[5], doc.selections[6] }, { 1, 1, 1, 9 })
  end)

  test.it("toggle follows requested wrapping state even when no wrap cache exists", function(context)
    local view = open_editor(context, string.rep("x", 40))
    local old_override = config.plugins.linewrapping.width_override
    config.plugins.linewrapping.width_override = math.huge
    view:set_wrapping_enabled(true)
    test.equal(view.wrapping_enabled, true)
    test.equal(view.wrapped_settings, nil)

    command.perform("line-wrapping:toggle")
    test.equal(view.wrapping_enabled, false)
    config.plugins.linewrapping.width_override = old_override
  end)

  test.it("keeps wrapped cache current through undo and redo", function(context)
    local view, doc = open_editor(context, string.rep("x", 40))
    configure_wrapping_for_test(context, view)
    local initial_rows = view:get_total_visual_lines()
    doc:clear_undo_redo()

    doc:set_selection(1, 1, 1, 1)
    doc:text_input(string.rep("y", 40))
    test.ok(view:get_total_visual_lines() > initial_rows, "expected insert to update wrapped row cache")

    command.perform("doc:undo")
    test.equal(doc.lines[1], string.rep("x", 40) .. "\n")
    test.equal(view:get_total_visual_lines(), initial_rows)

    command.perform("doc:redo")
    test.equal(doc.lines[1], string.rep("y", 40) .. string.rep("x", 40) .. "\n")
    test.ok(view:get_total_visual_lines() > initial_rows, "expected redo to update wrapped row cache")
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

  test.it("same-line edits keep incremental wrapped suffix cache equivalent to a full rebuild", function(context)
    local view, doc = open_editor(context, string.rep("alpha\tbeta gamma δέλτα ", 80))
    configure_wrapping_for_test(context, view)
    config.plugins.linewrapping.mode = "word"
    config.plugins.linewrapping.width_override = view:get_font():get_width("xxxxxxxxxxxxxxxx")
    LineWrapping.update_docview_breaks(view)

    local row_count = LineWrapping.get_total_wrapped_lines(view)
    test.ok(row_count > 8, "expected fixture to wrap into many visual rows")
    local edit_idx = math.max(2, row_count - 3)
    local edit_line, edit_col = LineWrapping.get_idx_line_col(view, edit_idx)
    doc:set_selection(edit_line, edit_col, edit_line, edit_col)
    doc:text_input("Z")

    local incremental_lines = { table.unpack(view.wrapped_lines) }
    local incremental_offsets = { table.unpack(view.wrapped_line_offsets) }
    LineWrapping.reconstruct_breaks(view, view:get_font(), config.plugins.linewrapping.width_override)

    test.same(view.wrapped_lines, incremental_lines)
    test.same(view.wrapped_line_offsets, incremental_offsets)
  end)

  test.it("clamps oversized continuation indent for right-aligned extracted text", function(context)
    local view = open_editor(context, string.rep(" ", 128) .. "2 de 112")
    configure_wrapping_for_test(context, view)
    config.plugins.linewrapping.mode = "word"
    config.plugins.linewrapping.indent = true
    config.plugins.linewrapping.wrapping_indent = 6
    config.plugins.linewrapping.width_override = view:get_font():get_width(string.rep("x", 100))
    LineWrapping.update_docview_breaks(view)

    test.ok(LineWrapping.get_wrapped_line_count(view, 1) <= 3, "expected oversized indentation to be clamped instead of producing many blank rows")
  end)

  test.it("keeps wrapped cache equivalent to a full rebuild when editing wrapped indentation", function(context)
    local view, doc = open_editor(context, string.rep(" ", 40) .. "tail words tail words")
    configure_wrapping_for_test(context, view)
    config.plugins.linewrapping.mode = "word"
    config.plugins.linewrapping.indent = true
    config.plugins.linewrapping.wrapping_indent = "indent"
    config.plugins.linewrapping.width_override = view:get_font():get_width("xxxxxxxx")
    LineWrapping.update_docview_breaks(view)

    local edit_line, edit_col = LineWrapping.get_idx_line_col(view, 3)
    doc:set_selection(edit_line, edit_col, edit_line, edit_col)
    doc:text_input(" ")

    local incremental_lines = { table.unpack(view.wrapped_lines) }
    local incremental_offsets = { table.unpack(view.wrapped_line_offsets) }
    LineWrapping.reconstruct_breaks(view, view:get_font(), config.plugins.linewrapping.width_override)

    test.same(view.wrapped_lines, incremental_lines)
    test.same(view.wrapped_line_offsets, incremental_offsets)
  end)

  test.it("keeps wrapped cache equivalent to a full rebuild with tokenized wrapping enabled", function(context)
    local view, doc = open_editor(context, string.rep("local value = alpha_beta_gamma + delta\n", 20))
    configure_wrapping_for_test(context, view)
    config.plugins.linewrapping.mode = "word"
    config.plugins.linewrapping.require_tokenization = true
    config.plugins.linewrapping.width_override = view:get_font():get_width("xxxxxxxxxxxx")
    LineWrapping.update_docview_breaks(view)

    local edit_line, edit_col = LineWrapping.get_idx_line_col(view, 8)
    doc:set_selection(edit_line, edit_col, edit_line, edit_col)
    doc:text_input("z")

    local incremental_lines = { table.unpack(view.wrapped_lines) }
    local incremental_offsets = { table.unpack(view.wrapped_line_offsets) }
    LineWrapping.reconstruct_breaks(view, view:get_font(), config.plugins.linewrapping.width_override)

    test.same(view.wrapped_lines, incremental_lines)
    test.same(view.wrapped_line_offsets, incremental_offsets)
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
    local old_get_idx_line_col = LineWrapping.get_idx_line_col
    local idx_lookup_calls = 0
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
    LineWrapping.get_idx_line_col = function(...)
      idx_lookup_calls = idx_lookup_calls + 1
      return old_get_idx_line_col(...)
    end

    local ok, err = pcall(function()
      local height = view:draw_line_body(1, x, y)
      test.ok(height > lh * 20, "expected the fixture line to wrap far beyond the viewport")
    end)

    renderer.draw_text = old_draw_text
    renderer.draw_text_known_bounds = old_draw_text_known_bounds
    renderer.draw_rect = old_draw_rect
    LineWrapping.get_idx_line_col = old_get_idx_line_col
    if not ok then error(err, 0) end

    test.ok(calls > 0, "expected visible wrapped rows to be submitted to renderer")
    test.ok(calls <= 6, "expected only visible wrapped rows to be submitted to renderer")
    test.ok(idx_lookup_calls <= 12, "expected wrapped text drawing to avoid scanning all offscreen rows")
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

  test.it("draws diff backgrounds on wrapped continuation rows", function(context)
    local long = string.rep("x", 40)
    local changed = string.rep("y", 40)
    local view = track(context, "diffviews", diffview.string_to_string(
      long,
      changed,
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

    local _, y = left:get_line_screen_position(1)
    local count = 0
    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    local old_draw_text_known_bounds = renderer.draw_text_known_bounds
    renderer.draw_rect = function(_, _, _, _, color)
      if color == style.diff_delete_background then count = count + 1 end
    end
    renderer.draw_text = function(font, text, sx) return sx + font:get_width(text) end
    renderer.draw_text_known_bounds = function(_, _, sx, _, _, _, w) return sx + w end
    local ok, err = pcall(function()
      left:draw_line_body(1, select(1, left:get_line_screen_position(1)), y)
    end)
    renderer.draw_rect = old_draw_rect
    renderer.draw_text = old_draw_text
    renderer.draw_text_known_bounds = old_draw_text_known_bounds
    if not ok then error(err, 0) end

    test.ok(count > 1, "expected wrapped diff background on continuation rows")
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
