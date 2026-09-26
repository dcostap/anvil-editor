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
local native = require "treesitter"

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
    -- These fixtures use ASCII. Compare glyph positions, not draw-call splits.
    for col = 1, #text do
      local char = text:sub(col, col)
      if not char:match("%s") then
        painted[#painted + 1] = {
          text = char, x = x + font:get_width(text:sub(1, col - 1)),
          y = y, size = font:get_size(),
        }
      end
    end
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

local function same_paint(actual, expected)
  test.equal(#actual, #expected, "the drawn glyph count changed")
  for index, glyph in ipairs(expected) do
    test.equal(actual[index].text, glyph.text)
    test.equal(actual[index].size, glyph.size)
    test.ok(math.abs(actual[index].x - glyph.x) < 0.001, "a drawn glyph moved horizontally")
    test.ok(math.abs(actual[index].y - glyph.y) < 0.001, "a drawn glyph moved vertically")
  end
end

test.describe("Markdown publication frames", function()
  test.before_each(function(context)
    context.active, context.live = core.active_view, config.markdown_live_editor
    context.transitions = config.transitions
    context.index_text = native.index_text
    -- Keep short deadlines out of grammar checks. Separate cases exercise
    -- timeout replies at the native parser boundary.
    native.index_text = function(opts)
      local options = {}
      for key, value in pairs(opts) do options[key] = value end
      options.parse_timeout_ms, options.query_timeout_ms = 5000, 5000
      return context.index_text(options)
    end
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
    native.index_text = context.index_text
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
        same_paint(painted, pending_paint)
        if instance.status ~= "ready" then coroutine.yield(0.001) end
      until instance.status == "ready" or system.get_time() >= deadline
      test.equal(instance.status, "ready")
      wrapping.complete_async_reconstruction(view)
      local published = frame(view, 1, 7)
      same_rows(published, pending, "indent step " .. step)
    end
  end)

  for _, case in ipairs {
    { name = "at the end of the file", source = "- test" },
    { name = "before a blank line", source = "- test\n" },
    { name = "before plain text", source = "- test\nplain\n" },
  } do
    test.it("keeps a new sibling marker presented " .. case.name, function(context)
      local view, buffer = make_view(context, case.source)
      buffer:set_selection(1, #buffer.lines[1])
      frame(view, 1, 1)
      test.ok(command.perform("core:newline", view))
      test.equal((buffer.lines[2] or ""):gsub("\n$", ""), "- ")
      local last = math.min(#buffer.lines, 3)
      local frames = { { frame(view, 1, last) } }
      local instance = test.not_nil(model.peek(buffer))
      local deadline = system.get_time() + 5
      repeat
        local pool = workers.current_system()
        if pool then pool:drain({ max_ms = 1, max_messages = 1 }) end
        frames[#frames + 1] = { frame(view, 1, last) }
        if instance.status ~= "ready" then coroutine.yield(0.001) end
      until instance.status == "ready" or system.get_time() >= deadline
      test.equal(instance.status, "ready")
      wrapping.complete_async_reconstruction(view)
      local published, painted = frame(view, 1, last)
      test.equal(published[2].text, "<widget>", "the new list marker must be presented")
      for index, captured in ipairs(frames) do
        same_rows(captured[1], published, "new sibling frame " .. index)
        same_paint(captured[2], painted)
      end
    end)
  end

  test.it("keeps a new sibling marker presented when the list probe times out", function(context)
    local view, buffer = make_view(context, "- test\nplain\n")
    buffer:set_selection(1, #buffer.lines[1])
    frame(view, 1, 2)
    native.index_text = function() return nil, "Tree-sitter parse timed out" end
    test.ok(command.perform("core:newline", view))
    local frames = { { frame(view, 1, 3) } }
    test.equal(frames[1][1][2].text, "<widget>", "Enter exposed the new list source")
    native.index_text = context.index_text
    local instance = test.not_nil(model.peek(buffer))
    local deadline = system.get_time() + 5
    repeat
      local pool = workers.current_system()
      if pool then pool:drain({ max_ms = 1, max_messages = 1 }) end
      frames[#frames + 1] = { frame(view, 1, 3) }
      if instance.status ~= "ready" then coroutine.yield(0.001) end
    until instance.status == "ready" or system.get_time() >= deadline
    test.equal(instance.status, "ready")
    wrapping.complete_async_reconstruction(view)
    local published, painted = frame(view, 1, 3)
    test.equal(published[2].text, "<widget>")
    for index, captured in ipairs(frames) do
      same_rows(captured[1], published, "bounded parser Enter frame " .. index)
      same_paint(captured[2], painted)
    end
  end)

  test.it("keeps an empty nested marker raw until it has a body", function(context)
    local view, buffer = make_view(context, "- sdfsdf\n     - \n")
    buffer:set_selection(2, #buffer.lines[2])
    test.equal(frame(view, 1, 2)[2].text, "     - ")
    view:on_text_input("x")
    local pending = frame(view, 1, 2)
    test.equal(pending[2].text, "<widget>x", "the new item did not gain a bullet")
    ready(view)
    same_rows(frame(view, 1, 2), pending, "nested list first character")
  end)

  test.it("outdents the third nested item by one list level", function(context)
    local view, buffer = make_view(context,
      "- sdfsdf\n     - testing this thing\n     - testing \n     - \n")
    buffer:set_selection(4, #buffer.lines[4])
    frame(view, 1, 4)
    test.ok(command.perform("core:unindent", view))
    test.equal(buffer.lines[4], "- \n", "outdent left the item inside the parent")
    local line, col = buffer:get_selection()
    test.same({ line, col }, { 4, 3 })
    local pending = frame(view, 1, 4)
    ready(view)
    same_rows(frame(view, 1, 4), pending, "third list item outdent")
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

  test.it("keeps a sole nested item stable when typing after clearing its body", function(context)
    local view, buffer = make_view(context,
      "- test\n    - child\n    - child two\n- parent\n    - test\nfollowing\n(note)\n")
    buffer:set_selection(5, 7, 5, #buffer.lines[5])
    frame(view, 1, 7)
    view:on_text_input("")
    ready(view)
    frame(view, 1, 7)
    view:on_text_input("t")
    local pending = frame(view, 1, 7)
    ready(view)
    same_rows(frame(view, 1, 7), pending, "first nested character")
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

  test.it("keeps list-looking source inside a fence as code while typing", function(context)
    local view, buffer = make_view(context, "```text\n- item\n```\n")
    buffer:set_selection(2, #buffer.lines[2])
    local before = frame(view, 1, 3)
    test.equal(before[2].text, "- item")
    view:on_text_input("x")
    local pending = frame(view, 1, 3)
    test.equal(pending[2].text, "- itemx")
    ready(view)
    same_rows(frame(view, 1, 3), pending, "fenced list source")
  end)

  test.it("keeps deep indentation frames consistent with a fresh Buffer", function(context)
    local source = "- test\n    - child\n    - child two\n- parent\n- test\nfollowing\n(note)\n"
    local view, buffer = make_view(context, source)
    buffer:set_selection(5, #buffer.lines[5])
    for step = 1, 6 do
      frame(view, 1, 7)
      test.ok(command.perform(step <= 3 and "core:indent" or "core:unindent", view))
      local frames = { { frame(view, 1, 7) } }
      local instance = model.peek(buffer)
      local deadline = system.get_time() + 5
      repeat
        drain()
        frames[#frames + 1] = { frame(view, 1, 7) }
        if instance.status ~= "ready" then coroutine.yield(0.001) end
      until instance.status == "ready" or system.get_time() >= deadline
      test.equal(instance.status, "ready")
      wrapping.complete_async_reconstruction(view)
      local published = frame(view, 1, 7)
      local fresh, fresh_buffer = make_view(context, table.concat(buffer.lines))
      fresh_buffer:set_selection(5, #fresh_buffer.lines[5])
      local expected, painted = frame(fresh, 1, 7)
      same_rows(published, expected, "fresh indentation " .. step)
      for index, captured in ipairs(frames) do
        same_rows(captured[1], expected, "indent step " .. step .. " frame " .. index)
        same_paint(captured[2], painted)
      end
    end
  end)

  for _, case in ipairs {
    { name = "short", body = "item" },
    { name = "wrapped", body = string.rep("item ", 40) .. "end" },
  } do
    test.it("retains " .. case.name .. " indentation when the bounded parser cannot finish", function(context)
      local view, buffer = make_view(context, "- parent\n- " .. case.body .. "\nplain\n")
      buffer:set_selection(2, #buffer.lines[2])
      for step = 1, 6 do
        local before = frame(view, 1, 3)
        native.index_text = function() return nil, "Tree-sitter parse timed out" end
        test.ok(command.perform(step <= 3 and "core:indent" or "core:unindent", view))
        same_rows(frame(view, 1, 3), before, "deferred indentation " .. step)
        native.index_text = context.index_text
        ready(view)
        local published = frame(view, 1, 3)
        local fresh, fresh_buffer = make_view(context, table.concat(buffer.lines))
        fresh_buffer:set_selection(2, #fresh_buffer.lines[2])
        same_rows(frame(fresh, 1, 3), published, "completed deferred indentation " .. step)
        frame(view, 1, 3)
        native.index_text = function() return nil, "Tree-sitter parse timed out" end
        view:on_text_input("x")
        local edited = frame(view, 1, 3)
        native.index_text = context.index_text
        ready(view)
        same_rows(frame(view, 1, 3), edited, "typing after deferred indentation " .. step)
      end
    end)
  end

  for _, case in ipairs {
    { name = "formatted", body = "**item**" },
    { name = "wrapped", body = "**" .. string.rep("item ", 40) .. "end**" },
  } do
    test.it("keeps rapid " .. case.name .. " indentation coherent before worker results", function(context)
      local view, buffer = make_view(context, "- parent\n- " .. case.body .. "\nplain\n")
      buffer:set_selection(2, #buffer.lines[2])
      frame(view, 1, 3)
      local edits = {}
      for step = 1, 3 do
        test.ok(command.perform("core:indent", view))
        edits[#edits + 1] = { source = table.concat(buffer.lines), frame(view, 1, 3) }
      end
      ready(view)
      for step, edit in ipairs(edits) do
        local fresh, fresh_buffer = make_view(context, edit.source)
        fresh_buffer:set_selection(2, #fresh_buffer.lines[2])
        local expected, painted = frame(fresh, 1, 3)
        same_rows(edit[1], expected, "rapid indentation " .. step)
        same_paint(edit[2], painted)
      end
    end)
  end
end)
