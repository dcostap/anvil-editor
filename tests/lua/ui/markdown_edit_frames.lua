local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local CaretRenderer = require "core.caret_renderer"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local wrapping = require "core.linewrapping"
local workers = require "core.worker_pool"
local test = require "core.test"

require "core.commands.text"

local function drain()
  local pool = workers.current_system()
  if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
end

local function ready(instance)
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    drain()
    if instance.status ~= "ready" then coroutine.yield(0.001) end
  end
  test.equal(instance.status, "ready", instance.reason)
end

local serial = 0
local function make_view(context, source, defer_layout)
  serial = serial + 1
  local name = "edit-frames-" .. serial .. ".md"
  local buffer = Buffer(name, name, true)
  buffer:insert(1, 1, source)
  local view = Editor(buffer)
  context.views[#context.views + 1] = view
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 1400, 420
  view:set_wrapping_enabled(true)
  -- The dummy window cannot acquire OS focus.
  view.active_window_has_focus = function() return true end
  core.active_view = view
  markdown.live_render.refresh_view(view)
  ready(model.peek(buffer))
  if not defer_layout then wrapping.complete_async_reconstruction(view) end
  return view, buffer, model.peek(buffer)
end

local function frame(context, view)
  core.active_view = view
  local target, painted
  local root = core.root_panel
  local submit, rect = root.submit_keyboard_caret, renderer.draw_rect
  local get_time = system.get_time
  -- Advance animation time without releasing parser publication between frames.
  context.now = (context.now or get_time()) + 1 / 60
  system.get_time = function() return context.now end
  root:begin_keyboard_caret_frame()
  root.submit_keyboard_caret = function(_, value)
    target = value
    submit(root, value)
  end
  renderer.begin_frame(context.window)
  local ok, err = pcall(function()
    view:update()
    view:draw()
    renderer.draw_rect = function(x, y, w, h, color)
      painted = { x = x, y = y, width = w, height = h }
      return rect(x, y, w, h, color)
    end
    root:draw_keyboard_caret()
  end)
  renderer.end_frame()
  root.submit_keyboard_caret, renderer.draw_rect = submit, rect
  system.get_time = get_time
  if not ok then error(err, 0) end
  test.not_nil(target, string.format("the frame must submit the active caret: selection=%s,%s visible=%s,%s active=%s",
    select(1, view.buffer:get_selection()), select(2, view.buffer:get_selection()),
    select(1, view:get_visible_line_range()), select(2, view:get_visible_line_range()), tostring(core.active_view == view)))
  return {
    x = target.x, y = target.y, height = target.height,
    scroll_x = view.scroll.x, scroll_y = view.scroll.y,
    to_x = view.scroll.to.x, to_y = view.scroll.to.y,
    painted = painted,
  }
end

local function same_frame(actual, expected, phase)
  for _, key in ipairs { "x", "y", "height", "scroll_x", "scroll_y", "to_x", "to_y" } do
    test.ok(math.abs(actual[key] - expected[key]) < 0.01,
      string.format("%s: %s changed from %.3f to %.3f", phase, key, expected[key], actual[key]))
  end
  test.not_nil(actual.painted, phase .. ": the caret must be painted")
  test.ok(math.abs(actual.painted.x - actual.x) < 0.01,
    phase .. ": the painted caret must use the current position")
  test.equal(actual.painted.height, actual.height, phase .. ": the painted caret must use the current height")
end

local function presentation(view)
  local rows = {}
  for line = 1, #view.buffer.lines do
    local render = view:get_line_render(line)
    local parts = {}
    for _, fragment in ipairs(render and render.fragments or {}) do
      if not fragment.hidden then
        parts[#parts + 1] = fragment.text or ""
      end
    end
    rows[line] = {
      text = render and table.concat(parts) or view.buffer.lines[line]:gsub("\n$", ""),
      height = view:get_position_visual_row_height(line, 1),
    }
  end
  return rows
end

local function check_edit(context, source, selection, action, options)
  options = options or {}
  if options.long then
    local prefix = {}
    for i = 1, 160 do
      prefix[#prefix + 1] = i % 8 == 1 and "## A heading\n"
        or "A paragraph with **bold** and *italic* text, long enough to wrap at narrow widths. More ordinary text.\n"
    end
    source = table.concat(prefix) .. source
    selection[1] = selection[1] + 160
    if selection[3] then selection[3] = selection[3] + 160 end
  end
  local view, buffer, instance = make_view(context, source)
  buffer:set_selection(selection[1], selection[2])
  view:scroll_to_make_visible(selection[1], selection[2], true)
  local before = frame(context, view)
  buffer:set_selection(unpack(selection))
  action(view, buffer)
  test.equal(instance.status, "pending")
  local first = frame(context, view)
  if options.keep_row then
    test.equal(first.to_y, before.to_y, "typing the first character must not move the viewport")
    test.equal(first.y, before.y, "typing the first character must not move the row")
    test.equal(first.height, before.height, "typing the first character must not resize the caret")
  end
  for i = 1, 4 do
    same_frame(frame(context, view), first, "pending frame " .. i)
  end
  local deadline = system.get_time() + 5
  repeat
    drain()
    same_frame(frame(context, view), first, "publication frame")
    if instance.status ~= "ready" then coroutine.yield(0.001) end
  until instance.status == "ready" or system.get_time() >= deadline
  test.equal(instance.status, "ready", instance.reason)
  for i = 1, 4 do
    same_frame(frame(context, view), first, "settled frame " .. i)
  end
end

test.describe("Markdown edit frames", function()
  test.before_each(function(context)
    context.active = core.active_view
    context.pane_views_only = config.plugins.centered_editor.pane_views_only
    config.plugins.centered_editor.pane_views_only = false
    context.transitions, context.animated = config.transitions, config.animated_caret
    context.blink, context.live = config.disable_blink, config.markdown_live_editor
    context.views = {}
    context.clip = core.clip_rect_stack
    core.clip_rect_stack = { { 0, 0, 1600, 600 } }
    context.caret = core.root_panel.caret_renderer
    core.root_panel.caret_renderer = CaretRenderer.new()
    context.window = core.window
    config.transitions, config.animated_caret = true, true
    config.disable_blink, config.markdown_live_editor = true, true
  end)

  test.after_each(function(context)
    for _, view in ipairs(context.views) do
      view.discard_buffer_on_close = true
      view:on_close()
    end
    core.active_view = context.active
    config.plugins.centered_editor.pane_views_only = context.pane_views_only
    core.clip_rect_stack = context.clip
    core.root_panel.caret_renderer = context.caret
    config.transitions, config.animated_caret = context.transitions, context.animated
    config.disable_blink, config.markdown_live_editor = context.blink, context.live
  end)

  test.it("keeps the caret and viewport fixed after clearing a prose line", function(context)
    check_edit(context, "# Heading\n\nordinary prose\n\nafter\n", { 3, 15, 3, 1 }, function(view)
      test.ok(command.perform("core:backspace", view))
    end)
  end)

  test.it("keeps the caret and viewport fixed after joining into an empty line", function(context)
    check_edit(context, "# Heading\n\n\n\nafter\n", { 4, 1 }, function(view)
      test.ok(command.perform("core:backspace", view))
    end)
  end)

  test.it("keeps the caret and viewport fixed after removing an empty list marker", function(context)
    check_edit(context, "# Heading\n\n- item\n- \n\nafter\n", { 4, 3 }, function(view)
      test.ok(command.perform("core:backspace", view))
    end)
  end)

  test.it("keeps an empty row's viewport fixed when typing its first character", function(context)
    check_edit(context, string.rep("ordinary prose\n", 20) .. "\n\nafter\n", { 21, 1 }, function(view)
      view:on_text_input("x")
    end, { keep_row = true })
  end)

  test.it("keeps long wrapped document geometry after removing an empty list marker", function(context)
    check_edit(context, "# Heading\n\n- item\n- \n\nafter\n", { 4, 3 }, function(view)
      test.ok(command.perform("core:backspace", view))
    end, { long = true })
  end)

  test.it("keeps long wrapped document geometry after clearing a prose line", function(context)
    check_edit(context, "# Heading\n\nordinary prose\n\nafter\n", { 3, 15, 3, 1 }, function(view)
      test.ok(command.perform("core:backspace", view))
    end, { long = true })
  end)

  test.it("keeps lazy list continuation geometry after clearing its text", function(context)
    check_edit(context, "- first\n- second\n    - nested\n    - more\n- last\ncontinuation\n(test)\n", { 6, 13, 6, 1 }, function(view)
      test.ok(command.perform("core:backspace", view))
    end)
  end)

  test.it("keeps geometry after a newline and immediate list marker deletion", function(context)
    check_edit(context, "# Heading\n\n- item\n\nafter\n", { 3, 7 }, function(view)
      test.ok(command.perform("core:newline", view))
      frame(context, view)
      test.ok(command.perform("core:backspace", view))
    end)
  end)

  test.it("keeps geometry after typing and immediately clearing a continuation", function(context)
    check_edit(context, "- first\n- second\n\n", { 3, 1 }, function(view, buffer)
      view:on_text_input("text")
      frame(context, view)
      buffer:set_selection(3, 5, 3, 1)
      test.ok(command.perform("core:backspace", view))
    end)
  end)

  test.it("keeps geometry after removing a nested empty list marker", function(context)
    check_edit(context, "- parent\n    - child\n    - \n\nafter\n", { 3, 7 }, function(view)
      test.ok(command.perform("core:backspace", view))
    end)
  end)

  test.it("uses empty prose geometry after clearing an indented code line", function(context)
    check_edit(context, "before\n\n    code\n\nafter\n", { 3, 9, 3, 1 }, function(view)
      test.ok(command.perform("core:backspace", view))
    end)
  end)

  test.it("uses empty prose geometry after clearing an HTML block", function(context)
    local html = "<div>value</div>"
    check_edit(context, "before\n\n" .. html .. "\n\nafter\n", { 3, #html + 1, 3, 1 }, function(view)
      test.ok(command.perform("core:backspace", view))
    end)
  end)

  test.it("keeps code geometry when the surrounding fence survives deletion", function(context)
    check_edit(context, "before\n\n```lua\ncode\n```\n\nafter\n", { 4, 5, 4, 1 }, function(view)
      test.ok(command.perform("core:backspace", view))
    end)
  end)

  test.it("keeps heading presentation when edits arrive before the first draw", function(context)
    local view, buffer, instance = make_view(context, "## Heading **bold**\n\nplain\n", true)
    core.active_view = view
    buffer:set_selection(1, 10)
    view:on_text_input("a")
    view:on_text_input("b")
    local pending = frame(context, view)
    ready(instance)
    same_frame(frame(context, view), pending, "first heading publication")
  end)

  for _, specimen in ipairs {
    { name = "heading", source = "## Heading **bold**\n\nplain\n", line = 1, col = 10 },
    { name = "code", source = "before\n\n```lua\nlocal value = 1\n```\n\n## Heading\n", line = 4, col = 7 },
    { name = "quote", source = "> quoted **words**\n> continued\n\n## Heading\n", line = 1, col = 9 },
    { name = "nested list", source = "- parent\n    - child\n    - next\n\n## Heading\n", line = 2, col = 12 },
  } do
    test.it("keeps " .. specimen.name .. " presentation through a typing burst", function(context)
      local view, buffer, instance = make_view(context, specimen.source)
      buffer:set_selection(specimen.line, specimen.col)
      frame(context, view)
      for _ = 1, 4 do
        view:on_text_input("a")
        frame(context, view)
      end
      local pending = presentation(view)
      ready(instance)
      frame(context, view)
      test.same(presentation(view), pending, "publication must not replace the visible presentation")
    end)
  end

  test.it("keeps an edited heading formatted after another offscreen edit", function(context)
    local source = "## First **heading**\n\n" .. string.rep("paragraph\n", 200)
      .. "\n## Second heading\n"
    local view, buffer, instance = make_view(context, source)
    buffer:set_selection(1, 9)
    frame(context, view)
    view:on_text_input("a")
    local first = frame(context, view)
    buffer:set_selection(204, 10)
    view:scroll_to_make_visible(204, 10, true)
    frame(context, view)
    view:on_text_input("b")
    frame(context, view)
    buffer:set_selection(1, 10)
    view:scroll_to_make_visible(1, 10, true)
    local returned = frame(context, view)
    test.equal(instance.status, "pending")
    test.equal(returned.height, first.height, "the edited heading must not become a body row")
    local pending = presentation(view)
    ready(instance)
    frame(context, view)
    local published = presentation(view)
    for line, row in ipairs(pending) do
      test.equal(published[line].text, row.text, string.format(
        "line %d changed text at publication: %q -> %q", line, row.text, published[line].text))
      test.equal(published[line].height, row.height, "line " .. line .. " changed height at publication")
    end
  end)
end)
