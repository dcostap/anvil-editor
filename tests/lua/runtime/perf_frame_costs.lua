local perf = require "core.perf"
local renderer = require "renderer"
local test = require "core.test"
local core = require "core"
local Buffer = require "core.buffer"
local panes = require "core.panes"

test.describe("performance frame cost report", function()
  local frames, original_stats
  test.after_each(function()
    if perf.is_recording() then perf.stop_recording() end
    if original_stats then renderer.get_last_frame_stats = original_stats end
    panes.reset_for_tests()
    if frames then
      for _, suffix in ipairs { "_frames.csv", "_summary.txt", "_draw_scopes.csv",
        "_file_opens.csv", "_lua_samples.csv", "_api_calls.csv", "_details.csv" } do
        os.remove(frames:gsub("_frames%.csv$", suffix))
      end
    end
  end)

  test.it("reports redraw costs without counting idle renderer statistics", function()
    original_stats = renderer.get_last_frame_stats
    renderer.get_last_frame_stats = function()
      return { d3d11_flush_quads_ms = 4, path = "test" }
    end
    frames = perf.start_recording()
    perf.on_frame { did_redraw = true, draw_emit_ms = 8, target_fps = 165 }
    perf.on_frame { did_redraw = false, draw_emit_ms = 100, target_fps = 165 }
    perf.on_frame { did_redraw = true, draw_emit_ms = 12, target_fps = 165 }
    local path = perf.stop_recording()
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    test.match(text, "frame.draw_emit_ms samples=2 total=20.000 avg=10.000 max=12.000")
    test.match(text, "renderer.d3d11_flush_quads_ms samples=2 total=8.000 avg=4.000 max=4.000")
    test.match(text, "target_fps=165")
    test.match(text, "Recording overhead")
    test.match(text, "Renderer paths: test")
  end)

  test.it("writes an isolated capture without changing the clipboard or debug hook", function()
    local base = USERDIR .. PATHSEP .. "isolated-performance"
    local clipboard = system.get_clipboard()
    local hook, mask, count = debug.gethook()
    frames = perf.start_recording {
      base_path = base, quiet = true, instruction_samples = false, detail_interval = 1,
    }
    local active_hook, active_mask, active_count = debug.gethook()
    test.equal(active_hook, hook)
    test.equal(active_mask, mask)
    test.equal(active_count, count)
    perf.on_frame { did_redraw = true, draw_emit_ms = 7 }
    local summary = perf.stop_recording()
    test.equal(frames, base .. "_frames.csv")
    test.equal(summary, base .. "_summary.txt")
    test.equal(system.get_clipboard(), clipboard)
  end)

  test.it("labels captured draw scopes with their phase and action", function()
    frames = perf.start_recording {
      quiet = true, instruction_samples = false,
      context = function() return "measure", "query" end,
    }
    perf.begin_draw_frame()
    local scope = perf.scope_begin("result-list")
    perf.scope_end(scope)
    perf.finish_draw_frame()
    perf.on_frame { did_redraw = true, draw_emit_ms = 1 }
    perf.stop_recording()
    local file = assert(io.open(frames:gsub("_frames%.csv$", "_draw_scopes.csv"), "rb"))
    local text = file:read("*a")
    file:close()
    test.match(text, ",measure,query,")
    test.match(text, "result%-list")
  end)

  test.it("reports small timers even when large counters fill the detail list", function()
    frames = perf.start_recording()
    for i = 1, 80 do perf.add_detail("large_counter_" .. i, 10000) end
    perf.add_detail("diffview_left_draw_ms", 3)
    perf.add_detail("diffview_right_draw_ms", 2)
    local path = perf.stop_recording()
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    test.match(text, "3.000 diffview_left_draw_ms")
    test.match(text, "2.000 diffview_right_draw_ms")
  end)

  test.it("keeps draw scope reports balanced while drawing unwrapped text", function()
    local buffer = Buffer(nil, nil, true)
    buffer:insert(1, 1, "first line\nsecond line\nthird line")
    local view = core.root_panel:open_buffer(buffer)
    view:set_wrapping_enabled(false)
    frames = perf.start_recording()
    core.redraw = true
    coroutine.yield(0.03)
    perf.stop_recording()
    local file = assert(io.open(frames:gsub("_frames%.csv$", "_draw_scopes.csv"), "rb"))
    file:read("*l")
    local rows = 0
    for line in file:lines() do
      rows = rows + 1
      test.match(line, ",0\r?$")
    end
    file:close()
    test.ok(rows > 0, "Expected draw scope rows")
  end)

  test.it("records both Diff View sides with balanced draw scopes", function()
    local diffview = require "plugins.diffview"
    local view = diffview.string_to_string("before\nretained", "after\nretained", "Left", "Right")
    local deadline = system.get_time() + 10
    while view.updater_idx do
      test.ok(system.get_time() < deadline, "Diff computation did not finish")
      coroutine.yield(0.01)
    end
    frames = perf.start_recording()
    core.redraw = true
    coroutine.yield(0.03)
    local path = perf.stop_recording()
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    for _, side in ipairs { "left", "right" } do
      test.match(text, "diffview_" .. side .. "_draw_body_ms")
      test.match(text, "diffview_" .. side .. "_update_body_ms")
    end
    file = assert(io.open(frames:gsub("_frames%.csv$", "_draw_scopes.csv"), "rb"))
    file:read("*l")
    local rows = 0
    for line in file:lines() do
      rows = rows + 1
      test.match(line, ",0\r?$")
    end
    file:close()
    test.ok(rows > 0, "Expected Diff View draw scope rows")
  end)
end)
