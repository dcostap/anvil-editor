-- mod-version:3 priority:99
-- Deterministic, low-overhead performance scenario runner.
-- Inert unless ANVIL_PERF_BENCHMARK is enabled by the isolated harness.
local function truthy(value)
  if not value or value == "" then return false end
  value = tostring(value):lower():match("^%s*(.-)%s*$")
  return value ~= "0" and value ~= "false" and value ~= "no" and value ~= "off"
end

if not truthy(os.getenv("ANVIL_PERF_BENCHMARK")) then return {} end

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local DocView = require "core.docview"
local View = require "core.view"
local linewrapping = require "core.linewrapping"
local perf = require "core.perf"
local style = require "core.style"

local function env_string(name, default)
  local value = os.getenv(name)
  return value and value ~= "" and value or (default or "")
end

local function env_number(name, default)
  return tonumber(os.getenv(name) or "") or default
end

local benchmark = {
  scenario = env_string("ANVIL_PERF_BENCHMARK_SCENARIO", "wrapped-document-steady"),
  mode = env_string("ANVIL_PERF_BENCHMARK_MODE", "metrics"),
  fixture = env_string("ANVIL_PERF_BENCHMARK_FILE"),
  tab_dir = env_string("ANVIL_PERF_BENCHMARK_TAB_DIR"),
  result_file = env_string("ANVIL_PERF_BENCHMARK_RESULT"),
  metrics_file = env_string("ANVIL_PERF_BENCHMARK_METRICS"),
  screenshot_file = env_string("ANVIL_PERF_BENCHMARK_SCREENSHOT"),
  capture_frames = math.max(1, math.floor(env_number("ANVIL_PERF_BENCHMARK_CAPTURE_FRAMES", 3))),
  capture_settle_frames = math.max(0, math.floor(env_number("ANVIL_PERF_BENCHMARK_CAPTURE_SETTLE_FRAMES", 5))),
  warmup_frames = math.max(1, math.floor(env_number("ANVIL_PERF_BENCHMARK_WARMUP_FRAMES", 120))),
  measured_frames = math.max(2, math.floor(env_number("ANVIL_PERF_BENCHMARK_FRAMES", 600))),
  start_line = math.max(1, math.floor(env_number("ANVIL_PERF_BENCHMARK_START_LINE", 1))),
  scroll_lines = math.max(1, math.floor(env_number("ANVIL_PERF_BENCHMARK_SCROLL_LINES", 1))),
  tab_count = math.max(1, math.floor(env_number("ANVIL_PERF_BENCHMARK_TAB_COUNT", 40))),
  window_width = math.max(320, math.floor(env_number("ANVIL_PERF_BENCHMARK_WINDOW_WIDTH", 1400))),
  window_height = math.max(240, math.floor(env_number("ANVIL_PERF_BENCHMARK_WINDOW_HEIGHT", 900))),
  rows = {},
  action_count = 0,
  phase = "setup",
  warmup_count = 0,
  measure_count = 0,
  pending_action_ms = 0,
  measure_start = nil,
  measure_end = nil,
  finished = false,
  capture_index = 0,
  capture_settle_count = 0,
}

local metric_fields = {
  "completion_ms", "action_ms", "event_ms", "update_ms", "pre_draw_ms",
  "draw_emit_ms", "renderer_end_ms", "frame_ms", "present_ms", "core_step_ms",
  "total_ms", "draw_calls", "quad_instances", "texture_batch_breaks",
  "quad_batches", "unique_batch_srvs", "repeated_batch_srvs",
  "rencache_commands", "rencache_text_commands", "rencache_command_bytes",
  "display_packet_replays", "display_packet_commands_replayed",
  "display_packet_frame_bytes_copied", "display_packet_replay_ms",
  "text_render_calls", "text_render_glyphs", "text_render_hb_shape_ms",
}

local function write_atomic(path, contents)
  if path == "" then return true end
  local tmp = path .. ".tmp"
  local fp, err = io.open(tmp, "wb")
  if not fp then return nil, err end
  fp:write(contents)
  fp:close()
  os.remove(path)
  local ok, rename_err = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return nil, rename_err
  end
  return true
end

local function write_result(fields)
  local keys = {}
  for key in pairs(fields) do keys[#keys + 1] = key end
  table.sort(keys)
  local lines = {}
  for _, key in ipairs(keys) do
    local value = tostring(fields[key] == nil and "" or fields[key]):gsub("[\r\n]", " ")
    lines[#lines + 1] = key .. "=" .. value
  end
  return write_atomic(benchmark.result_file, table.concat(lines, "\n") .. "\n")
end

-- Publish a startup marker immediately so the harness can distinguish a load
-- failure from a scenario failure or an unexpected process exit.
write_result {
  done = 0,
  scenario = benchmark.scenario,
  mode = benchmark.mode,
  error = "benchmark did not complete",
}

local function write_metrics()
  if benchmark.mode ~= "metrics" and benchmark.mode ~= "paced-metrics" then return true end
  if benchmark.metrics_file == "" then return true end
  local lines = { table.concat(metric_fields, ",") }
  for _, row in ipairs(benchmark.rows) do
    local values = {}
    for i, key in ipairs(metric_fields) do
      values[i] = string.format("%.6f", tonumber(row[key]) or 0)
    end
    lines[#lines + 1] = table.concat(values, ",")
  end
  return write_atomic(benchmark.metrics_file, table.concat(lines, "\n") .. "\n")
end

local function active_docview()
  local view = core.active_view
  if view and view:is(DocView) and view.doc then return view end
end

local function activate_view(view)
  local node = core.root_panel.root_node:get_node_for_view(view)
  if node then node:set_active_view(view) else core.set_active_view(view) end
  return view
end

local function open_file(path)
  local doc = assert(core.open_doc(path))
  return activate_view(core.root_panel:open_doc(doc))
end

local function set_position(view, line)
  line = math.max(1, math.min(#view.doc.lines, line))
  view.doc:set_selection(line, 1)
  view:scroll_to_line(line, true)
end

local function setup_tabs(primary)
  if benchmark.scenario ~= "tab-heavy-titlebar" then return end
  assert(benchmark.tab_dir ~= "", "tab-heavy-titlebar requires a tab fixture directory")
  local node = assert(
    core.root_panel.root_node:get_node_for_view(primary),
    "primary benchmark Editor is not attached to a pane"
  )
  for i = 1, benchmark.tab_count do
    local path = benchmark.tab_dir .. PATHSEP .. string.format("benchmark-tab-%03d.lua", i)
    node:add_view(DocView(assert(core.open_doc(path))))
  end
  node:set_active_view(primary)
end

local PrimitiveRenderView = View:extend()

function PrimitiveRenderView:new()
  PrimitiveRenderView.super.new(self)
  self.scrollable = false
end

function PrimitiveRenderView:get_name()
  return "Renderer Primitives"
end

function PrimitiveRenderView:draw()
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  renderer.draw_rect(x, y, w, h, { 18, 20, 28, 255 })

  local pad = 36 * SCALE
  local left, top = x + pad, y + pad
  renderer.draw_rect(left, top, 360 * SCALE, 190 * SCALE, { 210, 62, 75, 210 })
  renderer.draw_rect(left + 90 * SCALE, top + 45 * SCALE, 360 * SCALE, 190 * SCALE,
    { 45, 155, 225, 175 })
  renderer.draw_rect(left + 180 * SCALE, top + 90 * SCALE, 360 * SCALE, 190 * SCALE,
    { 72, 200, 125, 145 })

  if renderer.draw_rounded_rect then
    renderer.draw_rounded_rect(
      left + 580 * SCALE, top, 310 * SCALE, 150 * SCALE, 24 * SCALE,
      { 127, 92, 220, 220 }
    )
  end

  local clip_x, clip_y = left, top + 330 * SCALE
  renderer.draw_rect(clip_x, clip_y, 520 * SCALE, 160 * SCALE, { 32, 36, 48, 255 })
  core.push_clip_rect(clip_x + 35 * SCALE, clip_y + 25 * SCALE, 330 * SCALE, 90 * SCALE)
  renderer.draw_rect(clip_x - 40 * SCALE, clip_y + 45 * SCALE,
    470 * SCALE, 55 * SCALE, { 245, 183, 65, 225 })
  renderer.draw_text(style.code_font,
    "clipped office -> affine éλ漢字 0123456789",
    clip_x - 15 * SCALE, clip_y + 52 * SCALE, { 235, 240, 250, 255 })
  core.pop_clip_rect()

  local text_y = clip_y + 220 * SCALE
  local samples = {
    { "Regular text and punctuation: ()[]{} <> /\\", style.text },
    { "Ligatures: office affine -> => != ===", style.syntax.keyword },
    { "Fallback glyphs: é λ 漢字 Ελληνικά", style.syntax.string },
    { "Alpha/order must remain stable across D3D batches", style.syntax.comment },
  }
  for _, sample in ipairs(samples) do
    renderer.draw_text(style.code_font, sample[1], left, text_y, sample[2])
    text_y = text_y + style.code_font:get_height() * 1.45
  end

  local grid_y = math.min(y + h - 150 * SCALE, text_y + 45 * SCALE)
  for row = 0, 5 do
    for col = 0, 17 do
      local tint = (row * 18 + col) % 255
      renderer.draw_rect(
        left + col * 34 * SCALE, grid_y + row * 18 * SCALE,
        28 * SCALE, 12 * SCALE,
        { 40 + tint % 150, 70 + (tint * 3) % 140, 90 + (tint * 7) % 130, 210 }
      )
    end
  end
end

local function open_primitive_view()
  local view = PrimitiveRenderView()
  local node = core.root_panel:get_active_node_default()
  node:add_view(view)
  node:set_active_view(view)
  core.set_active_view(view)
  return view
end

local function setup_scenario()
  assert(benchmark.fixture ~= "", "ANVIL_PERF_BENCHMARK_FILE is required")
  system.set_window_size(core.window, benchmark.window_width, benchmark.window_height, 0, 0)
  config.auto_fps = false
  config.disable_blink = true
  config.animated_caret = false
  config.draw_stats = false
  core.perf_capture_active = true
  core.perf_cadence_uncapped = true

  if core.status_bar then
    core.status_bar:display_messages(false)
    core.status_bar.message = nil
  end

  local view = open_file(benchmark.fixture)
  setup_tabs(view)
  if benchmark.scenario == "renderer-primitives" then
    view = open_primitive_view()
  else
    activate_view(view)
    set_position(view, benchmark.start_line)
  end
  benchmark.view = view

  if benchmark.scenario:find("wrapped%-document", 1, false) then
    view:set_wrapping_enabled(true)
    linewrapping.update_docview_breaks(view)
  elseif benchmark.scenario == "markdown-long-link-caret-repeat" then
    assert(view.__markdown_live_attached, "Markdown Live Preview did not attach")
    view:set_wrapping_enabled(true)
    view.doc:set_selection(1, 1000)
    linewrapping.update_docview_breaks(view)
  elseif benchmark.scenario == "caret-repeat" then
    view:set_wrapping_enabled(false)
  end

  collectgarbage("collect")
  core.redraw = true
end

local function perform_action()
  local view = benchmark.view or active_docview()
  if not view then return end
  local started = system.get_time()
  if benchmark.scenario == "wrapped-document-scroll" then
    local line = benchmark.start_line + benchmark.action_count * benchmark.scroll_lines
    if line > #view.doc.lines then line = benchmark.start_line end
    set_position(view, line)
    benchmark.action_count = benchmark.action_count + 1
  elseif benchmark.scenario == "caret-repeat"
      or benchmark.scenario == "markdown-long-link-caret-repeat"
  then
    if benchmark.scenario == "markdown-long-link-caret-repeat" then
      local line = view.doc:get_selection()
      if line ~= 1 then view.doc:set_selection(1, 1000) end
    end
    if not command.perform("doc:move-to-next-line") then
      error("doc:move-to-next-line was unavailable")
    end
    benchmark.action_count = benchmark.action_count + 1
  end
  benchmark.pending_action_ms = (system.get_time() - started) * 1000
  core.redraw = true
end

local function metric_row(snapshot)
  local renderer_stats = renderer.get_last_frame_stats and renderer.get_last_frame_stats() or {}
  local row = {
    completion_ms = (system.get_time() - benchmark.measure_start) * 1000,
    action_ms = benchmark.pending_action_ms,
  }
  benchmark.pending_action_ms = 0
  for _, key in ipairs({
    "event_ms", "update_ms", "pre_draw_ms", "draw_emit_ms", "renderer_end_ms",
    "frame_ms", "present_ms", "core_step_ms", "total_ms", "draw_calls",
    "quad_instances",
  }) do
    row[key] = tonumber(snapshot[key]) or 0
  end
  for _, key in ipairs({
    "texture_batch_breaks", "quad_batches", "unique_batch_srvs",
    "repeated_batch_srvs", "rencache_commands", "rencache_text_commands",
    "rencache_command_bytes", "display_packet_replays",
    "display_packet_commands_replayed", "display_packet_frame_bytes_copied",
    "display_packet_replay_ms", "text_render_calls", "text_render_glyphs",
    "text_render_hb_shape_ms",
  }) do
    row[key] = tonumber(renderer_stats[key]) or 0
  end
  return row
end

local function finish_success()
  if benchmark.finished then return end
  benchmark.finished = true
  benchmark.phase = "finished"
  benchmark.measure_end = benchmark.measure_end or system.get_time()
  local elapsed = math.max(0.000001, benchmark.measure_end - benchmark.measure_start)
  local renderer_stats = renderer.get_last_frame_stats and renderer.get_last_frame_stats() or {}
  local metrics_ok, metrics_err = write_metrics()
  local result_ok, result_err = write_result {
    done = metrics_ok and 1 or 0,
    error = metrics_ok and "" or tostring(metrics_err),
    scenario = benchmark.scenario,
    mode = benchmark.mode,
    warmup_frames = benchmark.warmup_count,
    measured_frames = benchmark.measure_count,
    elapsed_ms = string.format("%.6f", elapsed * 1000),
    active_fps = string.format("%.6f", benchmark.measure_count / elapsed),
    action_count = benchmark.action_count,
    renderer_path = renderer_stats.path or "unknown",
    sync_interval = renderer_stats.sync_interval or 0,
    target_fps = config.fps,
    scale = SCALE,
    window_width = benchmark.window_width,
    window_height = benchmark.window_height,
    screenshot = benchmark.screenshot_file,
    capture_frames = benchmark.capture_index,
    metrics_file = benchmark.metrics_file,
  }
  if not result_ok then
    core.log_quiet("Performance benchmark result write failed: %s", tostring(result_err))
  end
  core.log_quiet(
    "Performance benchmark complete: scenario=%s frames=%d fps=%.1f",
    benchmark.scenario, benchmark.measure_count, benchmark.measure_count / elapsed
  )
  core.add_thread(function()
    coroutine.yield()
    core.quit(true)
  end)
end

local function fail(err)
  if benchmark.finished then return end
  benchmark.finished = true
  benchmark.phase = "failed"
  write_result {
    done = 0,
    scenario = benchmark.scenario,
    mode = benchmark.mode,
    error = tostring(err),
  }
  core.log_quiet("Performance benchmark failed: %s", tostring(err))
  core.add_thread(function()
    coroutine.yield()
    core.quit(true, 1)
  end)
end

local function request_screenshot()
  if benchmark.screenshot_file == "" then
    finish_success()
    return
  end
  benchmark.capture_index = benchmark.capture_index + 1
  local path = benchmark.screenshot_file
  if benchmark.capture_index > 1 then
    path = path:gsub("(%.[^./\\]+)$", string.format("-stability-%d%%1", benchmark.capture_index))
  end
  benchmark.current_capture_path = path
  local ok, reason = renwindow.request_frame_capture(core.window, path)
  if not ok then
    fail("frame capture request failed: " .. tostring(reason))
    return
  end
  benchmark.phase = "capture"
  core.redraw = true
end

local function prepare_screenshot()
  if benchmark.screenshot_file == "" then
    finish_success()
  elseif benchmark.capture_settle_frames == 0 then
    request_screenshot()
  else
    benchmark.phase = "capture_settle"
    benchmark.capture_settle_count = 0
    core.redraw = true
  end
end

local old_on_frame = perf.on_frame
function perf.on_frame(snapshot)
  old_on_frame(snapshot)
  if benchmark.finished or not snapshot or not snapshot.did_redraw then return end
  local ok, err = xpcall(function()
    if benchmark.phase == "warmup" then
      benchmark.warmup_count = benchmark.warmup_count + 1
      if benchmark.warmup_count >= benchmark.warmup_frames then
        collectgarbage("collect")
        benchmark.phase = "measure"
        benchmark.measure_start = system.get_time()
        perform_action()
      else
        perform_action()
      end
    elseif benchmark.phase == "measure" then
      benchmark.measure_count = benchmark.measure_count + 1
      if benchmark.mode == "metrics" or benchmark.mode == "paced-metrics" then
        benchmark.rows[#benchmark.rows + 1] = metric_row(snapshot)
      else
        benchmark.pending_action_ms = 0
      end
      if benchmark.measure_count >= benchmark.measured_frames then
        benchmark.measure_end = system.get_time()
        prepare_screenshot()
      else
        perform_action()
      end
    elseif benchmark.phase == "capture_settle" then
      benchmark.capture_settle_count = benchmark.capture_settle_count + 1
      if benchmark.capture_settle_count >= benchmark.capture_settle_frames then
        request_screenshot()
      else
        core.redraw = true
      end
    elseif benchmark.phase == "capture" then
      local info = system.get_file_info(benchmark.current_capture_path)
      if not info then error("requested frame capture did not produce a file") end
      if benchmark.capture_index < benchmark.capture_frames then
        request_screenshot()
      else
        finish_success()
      end
    end
  end, debug.traceback)
  if not ok then fail(err) end
end

core.add_thread(function()
  local ok, err = xpcall(setup_scenario, debug.traceback)
  if not ok then
    fail(err)
    return
  end
  -- Let resize, syntax setup, line packets, and font atlases settle before the
  -- fixed warmup begins.
  for _ = 1, 30 do
    core.redraw = true
    coroutine.yield()
  end
  benchmark.phase = "warmup"
  perform_action()
end)

return benchmark
