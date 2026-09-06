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
end)
