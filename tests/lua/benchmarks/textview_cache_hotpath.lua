local core = require "core"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"

local function elapsed_ms(fn)
  local started = system.get_time()
  fn()
  return (system.get_time() - started) * 1000
end

test.describe("TextView cache hot-path benchmark", function()
  test.it("reports unchanged metric and line-render cache costs", function()
    local lines = {}
    for line = 1, 100 do lines[line] = "representative line " .. line end
    local buffer = Buffer(nil, nil, true)
    buffer:insert(1, 1, table.concat(lines, "\n"))
    buffer:clear_undo_redo()
    local view = TextView(buffer)
    view.size.x, view.size.y = 800, 1200
    view:set_wrapping_enabled(false)

    local metric_seed_calls = 0
    local metric_generation_calls = 0
    local metric_seed = {}
    view:add_visual_metric_provider("benchmark", {
      generation_seed = function()
        metric_seed_calls = metric_seed_calls + 1
        return metric_seed
      end,
      generation = function()
        metric_generation_calls = metric_generation_calls + 1
        return 1
      end,
      line_height = function() end,
    })
    view:get_visual_row_metric_cache()
    metric_seed_calls, metric_generation_calls = 0, 0

    local old_render_active = core.render_frame_active
    local old_render_frame_id = core.render_frame_id
    core.render_frame_id = (core.render_frame_id or 0) + 1
    core.render_frame_active = true
    local metric_ms = elapsed_ms(function()
      for _ = 1, 200000 do view:get_visual_row_metric_cache() end
    end)
    local geometry_total = 0
    local geometry_ms = elapsed_ms(function()
      for call = 1, 200000 do
        local row = (call - 1) % 100 + 1
        geometry_total = geometry_total + view:get_visual_row_y_offset(row)
          + view:get_visual_row_height(row)
      end
    end)

    local line_generation_calls = 0
    view:add_line_render_provider("benchmark", {
      generation = function()
        line_generation_calls = line_generation_calls + 1
        return 1
      end,
      render_line = function() end,
    })
    for line = 1, 50 do view:get_line_render(line) end
    line_generation_calls = 0
    core.render_frame_id = core.render_frame_id + 1
    local line_ms = elapsed_ms(function()
      for call = 1, 80000 do
        view:get_line_render((call - 1) % 50 + 1)
      end
    end)
    core.render_frame_active = old_render_active
    core.render_frame_id = old_render_frame_id

    print(string.format(
      "TextView cache hot path: metric_ms=%.3f geometry_ms=%.3f metric_seed_calls=%d metric_generation_calls=%d line_ms=%.3f line_generation_calls=%d",
      metric_ms, geometry_ms, metric_seed_calls, metric_generation_calls, line_ms,
      line_generation_calls
    ))
    io.stdout:flush()
    test.ok(view:get_visual_row_metric_cache())
    test.ok(geometry_total > 0)
  end)
end)
