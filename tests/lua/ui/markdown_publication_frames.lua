local core = require "core"
local config = require "core.config"
local command = require "core.command"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local wrapping = require "core.linewrapping"
local workers = require "core.worker_pool"
local style = require "core.style"
local test = require "core.test"

require "core.commands.text"

local function drain()
  local pool = workers.current_system()
  if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
end

local function ready(view)
  local instance = test.not_nil(model.peek(view.buffer))
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    drain()
    if instance.status ~= "ready" then coroutine.yield(0.001) end
  end
  test.equal(instance.status, "ready", instance.reason)
  wrapping.complete_async_reconstruction(view)
end

local function make_view(context, source)
  local buffer = Buffer("publication-frames.md", nil, true)
  buffer:insert(1, 1, source)
  local view = Editor(buffer)
  context.views[#context.views + 1] = view
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 900, 600
  view:set_wrapping_enabled(true)
  core.active_view = view
  markdown.live_render.refresh_view(view)
  ready(view)
  return view, buffer
end

local function frame(view, first, last)
  core.active_view = view
  local draw_text, painted = renderer.draw_text, {}
  renderer.draw_text = function(font, text, x, y, color, opts)
    painted[#painted + 1] = { text = text, x = x, y = y, size = font:get_size() }
    return draw_text(font, text, x, y, color, opts)
  end
  renderer.begin_frame(core.window)
  local ok, err = pcall(function()
    core.ui_snapshot_active = true
    core.ui_snapshot_id = (core.ui_snapshot_id or 0) + 1
    view:update()
    core.ui_snapshot_id = core.ui_snapshot_id + 1
    view:draw()
  end)
  renderer.end_frame()
  renderer.draw_text = draw_text
  core.ui_snapshot_active = false
  if not ok then error(err, 0) end
  local rows = {}
  for line = first, last do
    local render = view:get_line_render(line)
    local parts = {}
    for _, fragment in ipairs(render and render.fragments or {}) do
      if not fragment.hidden then
        parts[#parts + 1] = fragment.text or ""
        if fragment.widget then parts[#parts + 1] = "<widget>" end
      end
    end
    local col = #view.buffer.lines[line]
    local x, y = view:get_line_screen_position(line, col)
    rows[#rows + 1] = {
      text = render and table.concat(parts) or view.buffer.lines[line],
      x = x, y = y, height = view:get_position_visual_row_height(line, col),
    }
  end
  return rows, painted
end

local function same_rows(actual, expected, phase)
  for line, row in ipairs(expected) do
    for _, key in ipairs { "text", "x", "y", "height" } do
      local value = actual[line][key]
      test.equal(value, row[key], string.format(
        "%s row %d %s changed: %s -> %s", phase,
        line, key, tostring(row[key]), tostring(value)))
    end
  end
end

test.describe("Markdown publication frames", function()
  test.before_each(function(context)
    context.active, context.live = core.active_view, config.markdown_live_editor
    context.transitions = config.transitions
    context.snapshot_active, context.snapshot_id = core.ui_snapshot_active, core.ui_snapshot_id
    context.pane_views_only = config.plugins.centered_editor.pane_views_only
    config.plugins.centered_editor.pane_views_only = false
    context.clip = core.clip_rect_stack
    core.clip_rect_stack = { { 0, 0, 1200, 800 } }
    context.views = {}
    config.markdown_live_editor, config.transitions = true, false
  end)

  test.after_each(function(context)
    for _, view in ipairs(context.views) do
      view.discard_buffer_on_close = true
      view:on_close()
    end
    core.active_view, config.markdown_live_editor = context.active, context.live
    config.transitions = context.transitions
    config.plugins.centered_editor.pane_views_only = context.pane_views_only
    core.clip_rect_stack = context.clip
    core.ui_snapshot_active, core.ui_snapshot_id = context.snapshot_active, context.snapshot_id
    if context.path then os.remove(context.path) end
  end)

  test.it("keeps list presentation unchanged when indentation publishes", function(context)
    local view, buffer = make_view(context,
      "- test\n    - child\n    - child two\n- parent\n- test\nfollowing\n(note)\n\n"
      .. string.rep("## Heading\n\nA paragraph with **bold** words.\n", 180))
    buffer:set_selection(5, 3)
    frame(view, 1, 7)
    for step = 1, 5 do
      test.ok(command.perform(step % 2 == 1 and "core:indent" or "core:unindent", view))
      local pending, pending_paint = frame(view, 1, 7)
      local instance = model.peek(buffer)
      local deadline = system.get_time() + 5
      repeat
        drain()
        local rows, painted = frame(view, 1, 7)
        same_rows(rows, pending, "indent publication " .. step)
        test.same(painted, pending_paint)
        if instance.status ~= "ready" then coroutine.yield(0.001) end
      until instance.status == "ready" or system.get_time() >= deadline
      test.equal(instance.status, "ready")
      wrapping.complete_async_reconstruction(view)
      local published = frame(view, 1, 7)
      same_rows(published, pending, "indent step " .. step)
    end
  end)

  test.it("keeps every visible row fixed through an offscreen file reload", function(context)
    local lines = {}
    for i = 1, 360 do
      lines[i] = i % 9 == 1 and ("# " .. string.rep("Heading words ", 30) .. "\n")
        or i % 9 == 2 and "\n"
        or "- A list item with **bold** and *italic* text. " .. string.rep("More wrapped words. ", 15) .. "\n"
    end
    local view, buffer = make_view(context, table.concat(lines))
    local target = 205
    buffer:set_selection(target, 6)
    view:scroll_to_make_visible(target, 6, true)
    frame(view, target, target)
    local first, last = view:get_visible_line_range()
    local baseline = frame(view, first, last)
    context.path = USERDIR .. PATHSEP .. "publication-frame-reload.md"
    lines[20] = lines[20]:gsub("\n$", "x\n")
    local file = test.not_nil(io.open(context.path, "wb"))
    file:write(table.concat(lines))
    file:close()
    buffer:load(context.path)
    same_rows(frame(view, first, last), baseline, "pending reload")
    local instance = model.peek(buffer)
    local deadline = system.get_time() + 5
    repeat
      drain()
      same_rows(frame(view, first, last), baseline, "reload publication")
      if instance.status ~= "ready" then coroutine.yield(0.001) end
    until instance.status == "ready" or system.get_time() >= deadline
    test.equal(instance.status, "ready")
    wrapping.complete_async_reconstruction(view)
    same_rows(frame(view, first, last), baseline, "completed reload layout")
  end)

  test.it("keeps code colors until replacement tokens reach the drawing API", function(context)
    local view, buffer = make_view(context, "```lua\nlocal value = 1\nlocal other = 2\n```\n")
    local function keyword_color(line)
      local render = test.not_nil(view:get_line_render(line))
      for _, fragment in ipairs(render.fragments) do
        if (fragment.text or ""):match("^local") then return fragment.color end
      end
    end
    local deadline = system.get_time() + 5
    repeat
      frame(view, 1, 4)
      if keyword_color(3) == style.syntax.keyword then break end
      coroutine.yield(0.001)
    until system.get_time() >= deadline
    test.equal(keyword_color(3), style.syntax.keyword, "the fixture must have syntax colors")
    buffer:set_selection(2, 12)
    frame(view, 1, 4)
    view:on_text_input("x")
    local instance = model.peek(buffer)
    repeat
      frame(view, 1, 4)
      test.equal(keyword_color(2), style.syntax.keyword, "the edited row flashed to plain text")
      test.equal(keyword_color(3), style.syntax.keyword, "the unchanged suffix flashed to plain text")
      drain()
      if instance.status ~= "ready" then coroutine.yield(0.001) end
    until instance.status == "ready" or system.get_time() >= deadline
    frame(view, 1, 4)
    test.equal(keyword_color(2), style.syntax.keyword, "Markdown publication removed edited-row colors")
    test.equal(keyword_color(3), style.syntax.keyword, "Markdown publication removed suffix colors")
    buffer:insert(2, 1, "--[[")
    deadline = system.get_time() + 5
    repeat
      drain()
      frame(view, 1, 4)
      local color = keyword_color(3)
      test.ok(color == style.syntax.keyword or color == style.syntax.comment,
        "replacement highlighting must not pass through an uncolored frame")
      if color == style.syntax.comment then break end
      coroutine.yield(0.001)
    until system.get_time() >= deadline
    test.equal(keyword_color(3), style.syntax.comment, "new tokenizer state must replace retained colors")
  end)
end)
