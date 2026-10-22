local core = require "core"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local wrapping = require "core.linewrapping"
local pool = require "core.worker_pool"
local scale = require "plugins.scale"
local test = require "core.test"
local panes = require "core.panes"

local function settle(view, live)
  if live then
    local instance = test.not_nil(model.peek(view.buffer))
    local deadline = system.get_time() + 5
    while instance.status ~= "ready" and system.get_time() < deadline do
      pool.current_system():drain({ max_ms = 5, max_messages = 64 })
      system.sleep(0.001)
    end
    test.equal(instance.status, "ready", instance.reason)
  end
  view:update()
  wrapping.complete_async_reconstruction(view)
  view:get_visual_row_metric_cache()
end

local function row_point_y(view, line, col, fraction)
  local row = view:get_visual_row(line, col, false)
  return style.padding.y + view:get_visual_row_y_offset(row)
    + fraction * view:get_visual_row_height(row) - view.scroll.y
end

test.describe("Zoom caret centering", function()
  for _, mode in ipairs { "source", "Markdown", "wrapped Markdown" } do
    test.it("centers the caret in " .. mode .. " when zooming", function()
      coroutine.yield(0.05)
      local old_live, old_active = config.markdown_live_editor, core.active_view
      local old_scale, old_code = scale.get(), scale.get_code()
      local old_width, old_height = core.root_panel.size.x, core.root_panel.size.y
      panes.reset_for_tests()
      core.root_panel.size.x, core.root_panel.size.y = 600, 500
      local live = mode ~= "source"
      config.markdown_live_editor = live
      local buffer = Buffer(nil, nil, true)
      buffer:set_filename("zoom-center-" .. mode .. (live and ".md" or ".txt"), nil)
      local lines = {}
      for i = 1, 600 do
        lines[#lines + 1] = "# Heading " .. i
        lines[#lines + 1] = "Paragraph " .. i .. " " .. string.rep("words to read and wrap ", 12)
      end
      buffer:insert(1, 1, table.concat(lines, "\n"))
      local view = Editor(buffer)
      view.size.x, view.size.y = 600, 400
      view:set_wrapping_enabled(mode == "wrapped Markdown")
      if live then markdown.live_render.refresh_view(view) end
      local ok, err = pcall(function()
        panes.place(function() return view end, { placement = "new", focus = true })
        core.root_panel:update()
        core.set_active_view(view)
        settle(view, live)
        local row = view:get_visual_row(1002, 1, false)
        if mode == "wrapped Markdown" then
          test.ok(view:get_visual_row_count_for_line(1002) > 2)
          row = row + 1
        end
        local line, col = view:get_visual_row_line_col(row)
        local fraction = 0.5
        view:with_selection_state(function() buffer:set_selection(line, col) end)
        settle(view, live)
        -- Scroll the caret away from the center, as when reading elsewhere.
        view.scroll.y = view.scroll.y + row_point_y(view, line, col, fraction) - view.size.y / 4
        view.scroll.to.y = view.scroll.y
        test.near(row_point_y(view, line, col, fraction), view.size.y / 4, 0.001)
        for _, action in ipairs { "editor:zoom_in", "editor:zoom_out", "editor:zoom_out" } do
          test.ok(command.perform(action))
          core.root_panel:update()
          test.near(row_point_y(view, line, col, fraction), view.size.y / 2, 1,
            string.format("%s left the caret off-center on the first redraw: y=%.2f center=%.2f",
              action, row_point_y(view, line, col, fraction), view.size.y / 2))
          settle(view, live)
          test.near(row_point_y(view, line, col, fraction), view.size.y / 2, 1,
            action .. " left the caret off-center after background layout")
          test.same({ view:with_selection_state(function() return buffer:get_selection() end) },
            { line, col, line, col }, "zoom changed the selection")
        end
      end)
      core.active_view = old_active
      panes.reset_for_tests()
      view:on_close()
      scale.set(old_scale)
      scale.set_code(old_code)
      config.markdown_live_editor = old_live
      core.root_panel.size.x, core.root_panel.size.y = old_width, old_height
      if not ok then error(err, 0) end
    end)
  end
end)
