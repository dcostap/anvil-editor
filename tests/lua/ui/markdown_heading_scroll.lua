local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function wait_ready(instance)
  local deadline = system.get_time() + 5
  repeat
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == "ready" then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return instance.status == "ready"
end

local function make_view()
  local lines = {}
  for line = 1, 60 do
    lines[line] = line == 36 and "### Customize callouts" or ""
  end
  local buffer = Buffer("markdown-heading-scroll.md", "markdown-heading-scroll.md", true)
  buffer:insert(1, 1, table.concat(lines, "\n"))
  buffer:clear_undo_redo()

  local view = Editor(buffer)
  view.position.x, view.position.y = 0, 0
  -- Match the reported editor viewport closely enough to exercise its
  -- context-boundary scrolling rather than the short-buffer case.
  view.size.x, view.size.y = 1620, 523
  view:set_wrapping_enabled(true)
  return view, buffer
end

local function refresh(view)
  markdown.live_render.refresh_view(view)
  local instance = test.not_nil(markdown_model.peek(view.buffer))
  test.ok(wait_ready(instance), instance.reason)
end

local function highlight_top(view, line)
  local y = view:get_position_highlight_geometry(line, 1)
  return test.not_nil(y)
end

local function move_and_update(view, command_name)
  test.equal(command.perform(command_name), true)
  view:update()
end

test.describe("Markdown heading navigation scrolling", function()
  test.before_each(function(context)
    context.old_active_view = core.active_view
    context.old_markdown_live_editor = config.markdown_live_editor
    context.old_scroll_context_lines = config.scroll_context_lines
    context.old_scroll_past_end = config.scroll_past_end
    context.old_transitions = config.transitions
    config.markdown_live_editor = true
    config.scroll_context_lines = 28
    config.scroll_past_end = true
    config.transitions = false
  end)

  test.after_each(function(context)
    if context.view then context.view:release_owned_features("test") end
    config.markdown_live_editor = context.old_markdown_live_editor
    config.scroll_context_lines = context.old_scroll_context_lines
    config.scroll_past_end = context.old_scroll_past_end
    config.transitions = context.old_transitions
    core.active_view = context.old_active_view
  end)

  test.it("keeps a rendered heading in the same navigation context as adjacent lines", function(context)
    local view, buffer = make_view()
    context.view = view
    refresh(view)
    core.set_active_view(view)

    buffer:set_selection(1, 1)
    view:update()
    view.scroll.y, view.scroll.to.y = 0, 0

    for _ = 2, 35 do move_and_update(view, "core:move_to_next_line") end
    local before_heading_y = highlight_top(view, 35)

    move_and_update(view, "core:move_to_next_line")
    local heading_y = highlight_top(view, 36)

    move_and_update(view, "core:move_to_next_line")
    local after_heading_y = highlight_top(view, 37)
    local context_height = view:get_line_height()

    test.ok(
      math.abs(heading_y - after_heading_y) <= context_height,
      string.format(
        "heading caret moved outside the adjacent navigation band: %.1f vs %.1f",
        heading_y, after_heading_y
      )
    )
    test.ok(
      math.abs(before_heading_y - after_heading_y) <= context_height,
      string.format(
        "adjacent caret positions diverged after crossing heading: %.1f vs %.1f",
        before_heading_y, after_heading_y
      )
    )

    move_and_update(view, "core:move_to_previous_line")
    local heading_up_y = highlight_top(view, 36)
    move_and_update(view, "core:move_to_previous_line")
    local before_heading_up_y = highlight_top(view, 35)

    test.ok(
      math.abs(heading_up_y - before_heading_up_y) <= context_height,
      string.format(
        "upward heading navigation moved outside the adjacent band: %.1f vs %.1f",
        heading_up_y, before_heading_up_y
      )
    )
  end)
end)
