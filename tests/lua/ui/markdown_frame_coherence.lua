local command = require "core.command"
local config = require "core.config"
local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

require "core.commands.text"

local serial = 0

local function wait_ready(instance)
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then coroutine.yield(0.001) end
  end
  test.equal(instance.status, "ready", instance.reason)
end

local function make_view(context, source, opts)
  opts = opts or {}
  serial = serial + 1
  local name = "markdown-frame-coherence-" .. serial .. ".md"
  local buffer = Buffer(name, name, true)
  buffer:insert(1, 1, source)
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  context.views[#context.views + 1] = view
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = opts.width or 600, opts.height or 240
  view:set_wrapping_enabled(opts.wrapped == true)
  core.active_view = view
  markdown.live_render.refresh_view(view)
  local instance = test.not_nil(markdown_model.peek(buffer))
  wait_ready(instance)
  return view, buffer, instance
end

local function decoration_provider(view)
  for _, entry in ipairs(view:decoration_provider_entries()) do
    if entry.id == "markdown-live" then return entry.provider end
  end
  error("Markdown decoration provider is missing")
end

local function visible_signature(view, line)
  local render = view:get_line_render(line)
  if not render then
    return (view.buffer.lines[line] or ""):gsub("\n$", "")
  end
  local parts = {}
  for _, fragment in ipairs(render.fragments or {}) do
    if not fragment.hidden then
      if fragment.markdown_task_checkbox then
        parts[#parts + 1] = "<task-checkbox>"
      elseif fragment.widget then
        parts[#parts + 1] = "<widget:" .. tostring(fragment.widget.type) .. ">"
      end
      parts[#parts + 1] = fragment.text or ""
    end
  end
  return table.concat(parts)
end

local function perform(view, name)
  local previous = core.active_view
  core.active_view = view
  local result = command.perform(name, view)
  core.active_view = previous
  return result
end

test.describe("Markdown frame coherence", function()
  test.before_each(function(context)
    context.active = core.active_view
    context.live = config.markdown_live_editor
    context.transitions = config.transitions
    context.merge = config.undo_merge_timeout
    context.images = config.markdown_live_render_images
    context.load_image_data = canvas.load_image_data
    context.views = {}
    config.markdown_live_editor = true
    config.transitions = false
    config.undo_merge_timeout = 0
  end)

  test.after_each(function(context)
    for _, view in ipairs(context.views) do
      view:release_owned_features("test")
    end
    core.active_view = context.active
    config.markdown_live_editor = context.live
    config.transitions = context.transitions
    config.undo_merge_timeout = context.merge
    config.markdown_live_render_images = context.images
    canvas.load_image_data = context.load_image_data
  end)

  test.it("keeps a quote background while an ordinary text edit is pending", function(context)
    local view, buffer, instance = make_view(context, "> quoted text\nplain")
    buffer:set_selection(1, #buffer.lines[1])
    local provider = decoration_provider(view)
    test.not_nil(provider:line_background(view, 1))

    view:on_text_input("!")

    test.equal(instance.status, "pending")
    test.not_nil(
      provider:line_background(view, 1),
      "the quote background disappeared before semantic publication"
    )
  end)

  test.it("keeps heading inline presentation unchanged at publication", function(context)
    local view, buffer, instance = make_view(
      context, "# Heading with **bold** text\nplain"
    )
    buffer:set_selection(1, #buffer.lines[1])
    view:get_line_render(1)
    view:update()

    view:on_text_input("!")

    test.equal(instance.status, "pending")
    local pending_visible = visible_signature(view, 1)
    local _, pending_col = buffer:get_selection()
    local pending_x = view:get_col_x_offset(1, pending_col)
    wait_ready(instance)
    local published_visible = visible_signature(view, 1)
    local published_x = view:get_col_x_offset(1, pending_col)
    test.equal(
      pending_visible, published_visible,
      string.format(
        "semantic publication changed the visible heading from %q to %q",
        pending_visible, published_visible
      )
    )
    test.ok(
      math.abs(pending_x - published_x) < 0.01,
      string.format(
        "semantic publication moved the heading caret from %.2f to %.2f",
        pending_x, published_x
      )
    )
  end)

  test.it("keeps heading caret geometry unchanged at publication", function(context)
    local view, buffer, instance = make_view(
      context, "# Heading with **bold** text\nplain"
    )
    buffer:set_selection(1, #buffer.lines[1])
    view:get_line_render(1)
    view:update()

    view:on_text_input("!")

    test.equal(instance.status, "pending")
    local _, col = buffer:get_selection()
    local pending_x = view:get_col_x_offset(1, col)
    wait_ready(instance)
    local published_x = view:get_col_x_offset(1, col)
    test.ok(
      math.abs(pending_x - published_x) < 0.01,
      string.format(
        "semantic publication moved the heading caret from %.2f to %.2f",
        pending_x, published_x
      )
    )
  end)

  test.it("uses empty-line geometry immediately after deleting a complete heading", function(context)
    local view, buffer, instance = make_view(
      context, "before\n# selected text\nafter"
    )
    buffer:set_selection(2, 1, 2, #buffer.lines[2])
    view:get_line_render(2)
    view:update()

    view:on_text_input("")

    test.equal(instance.status, "pending")
    local pending_height = view:get_position_visual_row_height(2, 1)
    local _, pending_following_y = view:get_line_screen_position(3, 1)
    wait_ready(instance)
    local published_height = view:get_position_visual_row_height(2, 1)
    local _, published_following_y = view:get_line_screen_position(3, 1)
    test.equal(
      pending_height, published_height,
      string.format(
        "the empty row height changed from %.2f to %.2f at publication",
        pending_height, published_height
      )
    )
    test.ok(
      math.abs(pending_following_y - published_following_y) < 0.01,
      string.format(
        "semantic publication moved following content from %.2f to %.2f",
        pending_following_y, published_following_y
      )
    )
  end)

  test.it("moves right for the first character on a source-empty list continuation", function(context)
    local view, buffer, instance = make_view(context, "- item\n\nplain")
    buffer:set_selection(2, 1)
    local before_x = view:get_col_x_offset(2, 1)

    view:on_text_input("x")

    test.equal(instance.status, "pending")
    local _, col = buffer:get_selection()
    local after_x = view:get_col_x_offset(2, col)
    test.ok(
      after_x > before_x,
      string.format(
        "typing moved the caret left from %.2f to %.2f",
        before_x, after_x
      )
    )
    wait_ready(instance)
    local published_x = view:get_col_x_offset(2, col)
    test.ok(
      math.abs(after_x - published_x) < 0.01,
      string.format(
        "semantic publication moved the caret from %.2f to %.2f",
        after_x, published_x
      )
    )
  end)

  test.it("keeps unindented lazy list continuations at the source margin", function(context)
    local view, buffer = make_view(context, table.concat({
      "- first",
      "- parent",
      "    - nested one",
      "    - nested two",
      "- final item" .. string.rep(" ", 6),
      "following text",
      "(following note)",
    }, "\n"))
    buffer:set_selection(1, 3)

    for line = 6, 7 do
      local inactive_x = view:get_col_x_offset(line, 1)
      buffer:set_selection(line, 1)
      local active_x = view:get_col_x_offset(line, 1)
      test.ok(
        math.abs(inactive_x - active_x) < 0.01,
        string.format(
          "moving the caret to line %d changed its indent from %.2f to %.2f",
          line, inactive_x, active_x
        )
      )
      test.ok(
        math.abs(inactive_x) < 0.01,
        string.format(
          "lazy continuation line %d was indented by %.2f pixels",
          line, inactive_x
        )
      )
    end
  end)

  test.it("keeps a joined task prefix unchanged at publication", function(context)
    local view, buffer, instance = make_view(
      context, "before\n\n- [ ] after\nplain"
    )
    buffer:set_selection(3, 1)
    view:get_line_render(3)
    view:update()

    test.equal(perform(view, "core:backspace"), true)

    test.equal(instance.status, "pending")
    local pending = visible_signature(view, 2)
    wait_ready(instance)
    local published = visible_signature(view, 2)
    test.equal(
      pending, published,
      string.format(
        "semantic publication changed the task prefix from %q to %q",
        pending, published
      )
    )
  end)

  test.it("keeps an uncached shifted heading presented while parsing", function(context)
    local lines = {}
    for line = 1, 199 do lines[line] = "ordinary line " .. line end
    lines[200] = "# Ending heading"
    local view, buffer, instance = make_view(
      context, table.concat(lines, "\n"), { height = 120 }
    )
    buffer:set_selection(1, 1)
    view:get_line_render(1)

    view:on_text_input("\n")

    test.equal(instance.status, "pending")
    local pending_height = view:get_position_visual_row_height(201, 1)
    local pending_visible = visible_signature(view, 201)
    wait_ready(instance)
    local published_height = view:get_position_visual_row_height(201, 1)
    local published_visible = visible_signature(view, 201)
    test.equal(
      pending_height, published_height,
      string.format(
        "the uncached heading height changed from %.2f to %.2f at publication",
        pending_height, published_height
      )
    )
    test.equal(
      pending_visible, published_visible,
      string.format(
        "the uncached heading changed from %q to %q at publication",
        pending_visible, published_visible
      )
    )
  end)

  test.it("keeps an uncached shifted image rendered while parsing", function(context)
    config.markdown_live_render_images = true
    canvas.load_image_data = function()
      return {
        get_size = function() return 80, 40 end,
        scaled = function(self) return self end,
      }
    end
    local lines = {}
    for line = 1, 199 do lines[line] = "ordinary line " .. line end
    lines[200] = "![Logo](data:image/png;base64,/9j/4AAQ)"
    local view, buffer, instance = make_view(
      context, table.concat(lines, "\n"), { height = 120 }
    )
    buffer:set_selection(1, 1)
    view:get_line_render(1)

    view:on_text_input("\n")

    test.equal(instance.status, "pending")
    local pending = visible_signature(view, 201)
    wait_ready(instance)
    local published = visible_signature(view, 201)
    test.equal(
      pending, published,
      string.format(
        "the uncached image changed from %q to %q at publication",
        pending, published
      )
    )
  end)
end)
