local command = require "core.command"
local config = require "core.config"
local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function make_view()
  local buffer = Buffer(nil, nil, true)
  buffer:set_filename("markdown-caret-click.md", nil)
  buffer:insert(1, 1, "- one\n\nplain")
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 500, 200
  view:set_wrapping_enabled(false)
  return view, buffer
end

local function wait_for_model(instance)
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    coroutine.yield(0.01)
  end
  test.equal(instance.status, "ready", instance.reason)
end

test.describe("Markdown caret clicks", function()
  test.it("keeps an empty line caret in the same place when the click ends", function(context)
    context.active_view = core.active_view
    context.live = config.markdown_live_editor
    config.markdown_live_editor = true

    local view, buffer = make_view()
    context.view = view
    core.active_view = view
    markdown.live_render.refresh_view(view)
    wait_for_model(test.not_nil(markdown_model.peek(buffer)))
    core.active_view = view

    local blank_line = 2
    local _, y = view:get_line_screen_position(blank_line, 1)
    local x = view.position.x + view:get_gutter_width() + 1
    test.ok(view:get_col_x_offset(blank_line, 1) > 0,
      "the unselected blank line should expose the list continuation layout")

    test.equal(command.perform("core:set_cursor", x, y), true)
    local pressed_line, pressed_col = buffer:get_selection()
    local pressed_x = view:get_col_x_offset(pressed_line, pressed_col)

    view:on_mouse_released("left", x, y)
    local released_line, released_col = buffer:get_selection()
    local released_x = view:get_col_x_offset(released_line, released_col)

    test.same({ pressed_line, pressed_col }, { blank_line, 1 })
    test.same({ released_line, released_col }, { blank_line, 1 })
    test.ok(math.abs(pressed_x - released_x) < 0.01,
      "the caret must not jump when the mouse click ends")
  end)

  test.after_each(function(context)
    if context.view then
      context.view.discard_buffer_on_close = true
      context.view:on_close()
    end
    core.active_view = context.active_view
    config.markdown_live_editor = context.live
  end)
end)
