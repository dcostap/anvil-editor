local core = require "core"
local config = require "core.config"
local command = require "core.command"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local wrapping = require "core.linewrapping"
local workers = require "core.worker_pool"
local test = require "core.test"

require "core.commands.text"

local function ready(view)
  local instance = test.not_nil(model.peek(view.buffer))
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then coroutine.yield(0.001) end
  end
  test.equal(instance.status, "ready", instance.reason)
  wrapping.complete_async_reconstruction(view)
end

local function heading_geometry(view)
  local result = {}
  for _, line in ipairs { 1, 4 } do
    local x, y = view:get_line_screen_position(line, #view.buffer.lines[line])
    local _, next_y = view:get_line_screen_position(line + 1, 1)
    result[#result + 1] = {
      x = x, y = y, next_y = next_y,
      rows = view:get_visual_row_count_for_line(line),
      height = view:get_position_visual_row_height(line, #view.buffer.lines[line]),
    }
  end
  return result
end

test.describe("Markdown batch indentation", function()
  test.before_each(function(context)
    context.active = core.active_view
    context.live = config.markdown_live_editor
    context.centered = config.plugins.centered_editor.pane_views_only
    config.markdown_live_editor = true
    config.plugins.centered_editor.pane_views_only = false
  end)

  test.after_each(function(context)
    if context.view then
      context.view.discard_buffer_on_close = true
      context.view:on_close()
    end
    core.active_view = context.active
    config.markdown_live_editor = context.live
    config.plugins.centered_editor.pane_views_only = context.centered
  end)

  for _, selection in ipairs { "range", "multiple carets" } do
    test.it("keeps headings wrapped when indenting tasks with " .. selection, function(context)
      local buffer = Buffer("batch-indent-headings.md", nil, true)
      buffer:insert(1, 1,
        "# " .. string.rep("Heading words ", 12) .. "\n"
        .. "Following paragraph.\n\n"
        .. "## " .. string.rep("Subheading words ", 10) .. "\n"
        .. "Following paragraph.\n\n"
        .. "- parent\n    - [ ] first task\n    - [ ] second task\n\n"
        .. string.rep("Ordinary paragraph with some words.\n\n", 2000))
      buffer:clear_undo_redo()
      local view = Editor(buffer)
      context.view = view
      view.position.x, view.position.y = 0, 0
      view.size.x, view.size.y = 600, 600
      core.active_view = view
      view:set_wrapping_enabled(true)
      markdown.live_render.refresh_view(view)
      ready(view)
      view:with_selection_state(function()
        if selection == "range" then
          buffer:set_selection(8, 1, 9, #buffer.lines[9])
        else
          buffer:set_selection(8, #buffer.lines[8])
          buffer:add_selection(9, #buffer.lines[9])
        end
      end)
      local expected = heading_geometry(view)
      local _, first_y = view:get_line_screen_position(1, 1)
      test.ok(expected[1].y > first_y, "the heading must start with multiple wrapped rows")

      for _, name in ipairs {
        "core:indent", "core:unindent", "core:indent", "core:undo", "core:redo",
      } do
        core.active_view = view
        test.ok(command.perform(name, view))
        local pending = heading_geometry(view)
        ready(view)
        for phase, actual in pairs { pending = pending, published = heading_geometry(view) } do
          for heading, geometry in ipairs(expected) do
            for key, value in pairs(geometry) do
              test.equal(actual[heading][key], value,
                string.format("%s %s heading %d %s: expected %s, got %s",
                  name, phase, heading, key, value, actual[heading][key]))
            end
          end
        end
      end
    end)
  end
end)
