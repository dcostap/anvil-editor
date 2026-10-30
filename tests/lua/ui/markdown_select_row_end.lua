local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local wrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local workers = require "core.worker_pool"
local test = require "core.test"

local function ready(buffer)
  local instance = test.not_nil(model.peek(buffer))
  local deadline = system.get_time() + 5
  repeat
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == "ready" then return end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.equal(instance.status, "ready", instance.reason)
end

local function settle(view)
  for _ = 1, 3 do
    view:update()
    wrapping.complete_async_reconstruction(view)
  end
end

test.describe("Markdown select to the end of a wrapped row", function()
  test.before_each(function(context)
    context.active = core.active_view
    context.live = config.markdown_live_editor
    context.transitions = config.transitions
    config.markdown_live_editor = true
    config.transitions = false
  end)

  test.after_each(function(context)
    core.active_view = context.active
    config.markdown_live_editor = context.live
    config.transitions = context.transitions
  end)

  test.it("ends on the selected row when the selection reveals code that re-wraps it", function()
    local buffer = Buffer("select-row-end.md", "select-row-end.md", true)
    buffer:insert(1, 1, "1. One\n"
      .. "2. Equipo retirado: no borres la nota. `monitor: ninguno` y descripción `OBSOLETO - …`."
      .. " (Borrar la nota deshabilita el host en Zabbix; el histórico se queda.)\n3. Three\n")
    local view = Editor(buffer)
    view:set_wrapping_enabled(true)
    view.size.y = 500
    buffer:set_selection(3, 1)
    markdown.live_render.refresh_view(view)
    ready(buffer)
    local checked = 0
    for width = 400, 1000, 40 do
      view.size.x = width
      buffer:set_selection(2, 4)
      settle(view)
      core.active_view = view
      test.ok(command.perform("core:select_to_end_of_line", view))
      settle(view)
      local line, col, anchor_line, anchor_col = buffer:get_selection()
      test.same({ anchor_line, anchor_col, line }, { 2, 4, 2 })
      if view:get_visual_row_count_for_line(2) > 1 then
        checked = checked + 1
        local _, start_y = view:get_caret_highlight_geometry(anchor_line, anchor_col)
        local _, end_y = view:get_caret_highlight_geometry(line, col)
        test.ok(col > anchor_col, "the command did not extend the selection")
        test.equal(end_y, start_y,
          string.format("width %d: the selection end at col %d left the selected row", width, col))
        -- The end reaches the row's end, unless selecting the code span there
        -- would reveal it onto the next row.
        test.ok(col >= 1 and col <= #buffer.lines[2],
          string.format("width %d: the selection end is outside the source line", width))
      end
    end
    test.ok(checked > 0, "some width must wrap the line")
    model.close(buffer, "test")
  end)
end)
