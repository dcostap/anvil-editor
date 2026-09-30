local Buffer = require "core.buffer"
local core = require "core"
local panes = require "core.panes"
local Editor = require "core.editor"
local test = require "core.test"

test.it("updates the scrollbar range with resized wrapped rows", function()
  for _ = 1, 3 do coroutine.yield(0) end
  local width, height, x, y = system.get_window_size(core.window)
  system.set_window_size(core.window, 700, 500, x, y)
  local buffer = Buffer()
  buffer:insert(1, 1, string.rep("words ", 800) .. "\n")
  local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
  view:add_visual_metric_provider("resize", {
    line_metrics = function(_, owner, _, count)
      return { row_count = count, height = owner:get_line_height() }
    end,
  })
  view:set_wrapping_enabled(true)
  core.step(system.get_time(), { immediate = true })
  local before = view:get_scrollable_size()
  system.set_window_size(core.window, 250, 500, x, y)
  core.step(system.get_time(), { immediate = true })
  local after = view:get_scrollable_size()
  local scrollbar = view.v_scrollbar.rect.scrollable
  buffer:clean()
  panes.reset_for_tests()
  system.set_window_size(core.window, width, height, x, y)
  test.ok(after > before, "the narrower viewport did not add wrapped rows")
  test.equal(scrollbar, after, "the scrollbar retained the old row heights")
end)
