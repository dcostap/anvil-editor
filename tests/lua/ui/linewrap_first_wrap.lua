local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local TextView = require "core.textview"
local LineWrapping = require "core.linewrapping"
local test = require "core.test"

local function long_text()
  local lines = {}
  for i = 1, 3000 do
    lines[i] = string.format("line %d %s", i, string.rep("wrapped words ", 6))
  end
  return table.concat(lines, "\n")
end

-- Render and metric providers make the first wrap of a long document sliced.
local function prepare(view, planned)
  view.wrapping_enabled = true
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 320, 240
  view:add_line_render_provider("plain", {
    render_line = function(_, _, line) if planned then planned[line] = true end end,
  })
  view:add_visual_metric_provider("plain", { line_height = function() end })
  return view
end

test.describe("First wrap of a long rendered document", function()
  test.before_each(function(context)
    local cfg = config.plugins.linewrapping
    context.old_config = {
      mode = cfg.mode,
      width_override = cfg.width_override,
      indent = cfg.indent,
      wrapping_indent = cfg.wrapping_indent,
      require_tokenization = cfg.require_tokenization,
    }
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
    if context.buffer then context.buffer:on_close() end
  end)

  test.it("wraps only the viewport in the first frame", function(context)
    local buffer = Buffer()
    context.buffer = buffer
    buffer:insert(1, 1, long_text())
    local planned = {}
    local view = prepare(TextView(buffer), planned)

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

  test.it("restores the saved top line", function(context)
    local buffer = Buffer(nil, nil, true)
    context.buffer = buffer
    buffer:insert(1, 1, long_text())
    local saved = prepare(Editor(buffer))
    LineWrapping.update_textview_breaks(saved)
    LineWrapping.complete_async_reconstruction(saved)
    local anchor_line = 2000
    buffer:set_selection(anchor_line, 1)
    local _, anchor_y = saved:get_line_screen_position(anchor_line)
    saved.scroll.y, saved.scroll.to.y = anchor_y, anchor_y
    local _, before_y = saved:get_line_screen_position(anchor_line)

    local restored = prepare(Editor.from_state(saved:get_state()))
    context.restored_buffer = restored.buffer
    restored:update_wrap_cache()
    restored:reconcile_visible_line_layout()
    local _, after_y = restored:get_line_screen_position(anchor_line)
    test.equal(after_y, before_y)

    LineWrapping.complete_async_reconstruction(restored)
    _, after_y = restored:get_line_screen_position(anchor_line)
    test.equal(after_y, before_y)
    restored.buffer:on_close()
  end)
end)
