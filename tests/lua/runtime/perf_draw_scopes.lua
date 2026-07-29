local perf = require "core.perf"
local test = require "core.test"

local function read_all(path)
  local file = assert(io.open(path, "rb"))
  local contents = file:read("*a")
  file:close()
  return contents
end

local function remove_recording_files(summary_path)
  local base = summary_path:gsub("_summary%.txt$", "")
  for _, suffix in ipairs {
    "_frames.csv",
    "_lua_samples.csv",
    "_api_calls.csv",
    "_details.csv",
    "_draw_scopes.csv",
    "_summary.txt",
  } do
    os.remove(base .. suffix)
  end
end

test.describe("Draw scope performance diagnostics", function()
  test.it("records hierarchical inclusive and exclusive draw scopes", function()
    perf.start_recording()
    perf.begin_draw_frame()
    local root = perf.scope_begin("root")
    local child = perf.scope_begin("child")
    system.sleep(0.001)
    perf.scope_add_child(child, "hot_leaf", 0.25, 4)
    perf.scope_end(child)
    perf.scope_end(root)
    perf.finish_draw_frame()
    perf.on_frame {
      time = system.get_time(),
      did_redraw = true,
      draw_emit_ms = 12,
      frame_ms = 12,
      total_ms = 12,
      target_fps = 60,
    }
    local summary_path = perf.stop_recording()
    local base = summary_path:gsub("_summary%.txt$", "")
    local scopes = read_all(base .. "_draw_scopes.csv")
    local summary = read_all(summary_path)

    test.ok(scopes:find("frame,time,draw_emit_ms,path,calls,inclusive_ms,exclusive_ms", 1, true))
    test.ok(scopes:find("root/child", 1, true))
    test.ok(scopes:find("root/child/hot_leaf,4,0.250,0.250", 1, true))
    test.ok(summary:find("Draw scope aggregates", 1, true))
    test.ok(summary:find("Slow draw scope frames", 1, true))
    test.ok(summary:find("root/child", 1, true))

    remove_recording_files(summary_path)
  end)
end)
