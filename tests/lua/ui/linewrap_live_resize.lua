local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local LineWrapping = require "core.linewrapping"
local test = require "core.test"

test.describe("Line wrapping during live window resize", function()
  test.before_each(function(context)
    local cfg = config.plugins.linewrapping
    context.old_config = {
      mode = cfg.mode,
      width_override = cfg.width_override,
      indent = cfg.indent,
      wrapping_indent = cfg.wrapping_indent,
      require_tokenization = cfg.require_tokenization,
    }
    context.old_resizing_until = core.window_resizing_until
    context.old_live_resize_frame = core.in_live_resize_frame
    cfg.mode = "word"
    cfg.width_override = nil
    cfg.indent = false
    cfg.wrapping_indent = 0
    cfg.require_tokenization = false
  end)

  test.after_each(function(context)
    local cfg = config.plugins.linewrapping
    for key, value in pairs(context.old_config) do cfg[key] = value end
    if context.old_config.width_override == nil then cfg.width_override = nil end
    core.window_resizing_until = context.old_resizing_until
    core.in_live_resize_frame = context.old_live_resize_frame
    if context.buffer then context.buffer:on_close() end
  end)

  test.it("reflows width changes during live resizing", function(context)
    local buffer = Buffer()
    context.buffer = buffer
    buffer:insert(1, 1, string.rep("a word with wrapping spaces ", 80))
    local view = TextView(buffer)
    view.wrapping_enabled = true
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 320, 240
    LineWrapping.update_textview_breaks(view)

    local initial_width = view.wrapped_settings.width
    local initial_rows = LineWrapping.get_total_wrapped_lines(view)
    core.window_resizing_until = system.get_time() + 10
    view.size.x = 640
    LineWrapping.update_textview_breaks(view)

    test.ok(view.wrapped_settings.width > initial_width)
    test.ok(LineWrapping.get_total_wrapped_lines(view) < initial_rows)
  end)

  test.it("wraps only the viewport in a resize frame of a long document", function(context)
    local lines = {}
    for i = 1, 3000 do
      lines[i] = string.format("line %d %s", i, string.rep("wrapped words ", 6))
    end
    local buffer = Buffer()
    context.buffer = buffer
    buffer:insert(1, 1, table.concat(lines, "\n"))
    local view = TextView(buffer)
    view.wrapping_enabled = true
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 640, 240
    LineWrapping.update_textview_breaks(view)

    core.window_resizing_until = system.get_time() + 10
    core.in_live_resize_frame = true
    local previous_stats = core.perf_frame_stats
    core.perf_frame_stats = {}
    view.size.x = 320
    view:update_wrap_cache()
    local stats = core.perf_frame_stats
    core.perf_frame_stats = previous_stats
    core.in_live_resize_frame = false

    local wrapped = (stats.linewrapping_reconstruct_breaks_lines or 0)
      + (stats.linewrapping_update_breaks_lines or 0)
      + (stats.linewrapping_async_reconstruct_lines or 0)
    test.ok(wrapped < 300, ("the resize frame wrapped %d of 3000 lines"):format(wrapped))
    test.ok(view:get_visual_row_count_for_line(1) > 1, "the visible rows kept the old width")

    LineWrapping.complete_async_reconstruction(view)
    local reference = TextView(buffer)
    reference.wrapping_enabled = true
    reference.size.x, reference.size.y = 320, 240
    LineWrapping.update_textview_breaks(reference)
    LineWrapping.complete_async_reconstruction(reference)
    test.equal(LineWrapping.get_total_wrapped_lines(view),
      LineWrapping.get_total_wrapped_lines(reference))
  end)

  test.it("wraps only the viewport in the first frame of a long document", function(context)
    local lines = {}
    for i = 1, 3000 do
      lines[i] = string.format("line %d %s", i, string.rep("wrapped words ", 6))
    end
    local buffer = Buffer()
    context.buffer = buffer
    buffer:insert(1, 1, table.concat(lines, "\n"))
    local view = TextView(buffer)
    view.wrapping_enabled = true
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 320, 240
    local planned = {}
    view:add_line_render_provider("plain", {
      render_line = function(_, _, line) planned[line] = true end,
    })

    -- The frame can also run one background slice of the thread budget.
    local previous_stats, previous_budget = core.perf_frame_stats, core.co_max_time
    core.perf_frame_stats, core.co_max_time = {}, 0.001
    view:update_wrap_cache()
    local stats = core.perf_frame_stats
    core.perf_frame_stats, core.co_max_time = previous_stats, previous_budget

    local wrapped = (stats.linewrapping_reconstruct_breaks_lines or 0)
      + (stats.linewrapping_update_breaks_lines or 0)
      + (stats.linewrapping_async_reconstruct_lines or 0)
    test.ok(wrapped < 1500, ("the first frame wrapped %d of 3000 lines"):format(wrapped))
    test.ok(view:get_visual_row_count_for_line(1) > 1, "the visible lines are not wrapped")
    view:get_visual_row_metric_cache()
    test.equal(planned[3000], nil, "row metrics built a plan for each line")

    -- A scroll before the background wrap finishes shows wrapped lines.
    local _, y = view:get_line_screen_position(2900)
    view.scroll.y, view.scroll.to.y = y, y
    view:reconcile_visible_line_layout()
    local first, last = view:get_visible_line_range()
    test.ok(first > 2000, "the scroll did not reach the unwrapped lines")
    for line = first, math.min(last, 3000) do
      test.ok(view:get_visual_row_count_for_line(line) > 1,
        ("visible line %d is not wrapped"):format(line))
    end

    LineWrapping.complete_async_reconstruction(view)
    local reference = TextView(buffer)
    reference.wrapping_enabled = true
    reference.size.x, reference.size.y = 320, 240
    LineWrapping.update_textview_breaks(reference)
    test.equal(LineWrapping.get_total_wrapped_lines(view),
      LineWrapping.get_total_wrapped_lines(reference))
  end)

  test.it("keeps the top visible Buffer line anchored while wrapping reflows", function(context)
    local lines = {}
    for i = 1, 80 do
      lines[i] = string.format("line %d %s", i, string.rep("wrapped words ", (i % 5) + 2))
    end
    local buffer = Buffer()
    context.buffer = buffer
    buffer:insert(1, 1, table.concat(lines, "\n"))
    local view = TextView(buffer)
    view.wrapping_enabled = true
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 320, 240
    LineWrapping.update_textview_breaks(view)

    local anchor_line = 45
    local _, anchor_y = view:get_line_screen_position(anchor_line)
    view.scroll.y, view.scroll.to.y = anchor_y, anchor_y
    local _, before_y = view:get_line_screen_position(anchor_line)

    core.window_resizing_until = system.get_time() + 10
    core.in_live_resize_frame = true
    for _, width in ipairs({ 520, 260, 460, 300 }) do
      view.size.x = width
      view:update_wrap_cache()

      local _, after_y = view:get_line_screen_position(anchor_line)
      test.equal(after_y, before_y)
      test.equal(view.scroll.y, view.scroll.to.y)
    end
  end)
end)
