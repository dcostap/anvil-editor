local core = require "core"

local perf = {}

local recording = false
local record = nil
local originals = {}
local sample_interval = 1000

local function csv_escape(value)
  value = tostring(value or "")
  if value:find('[,"\n\r]') then
    value = '"' .. value:gsub('"', '""') .. '"'
  end
  return value
end

local function temp_dir()
  return os.getenv("TEMP") or os.getenv("TMP") or "."
end

local function timestamp_name()
  local t = os.date("*t")
  return string.format(
    "anvil_perf_%04d%02d%02d_%02d%02d%02d",
    t.year, t.month, t.day, t.hour, t.min, t.sec
  )
end

local function source_key(info)
  if not info then return "unknown" end
  local src = info.short_src or info.source or "unknown"
  local line = info.currentline or 0
  return string.format("%s:%d", src, line)
end

local function add_count(tbl, key, amount)
  tbl[key] = (tbl[key] or 0) + (amount or 1)
end

local function hook()
  if not record then return end
  local info = debug.getinfo(2, "Sl")
  add_count(record.lua_samples, source_key(info), 1)
  record.sample_count = record.sample_count + 1
end

local function wrap_renderer_api(name)
  if originals[name] or type(renderer[name]) ~= "function" then return end
  local original = renderer[name]
  originals[name] = original
  renderer[name] = function(...)
    if record then
      local info = debug.getinfo(2, "Sl")
      local key = name .. "," .. source_key(info)
      add_count(record.api_calls, key, 1)
    end
    return original(...)
  end
end

local function unwrap_renderer_api()
  for name, fn in pairs(originals) do
    renderer[name] = fn
  end
  originals = {}
end

local function write_frame_header(file)
  file:write(table.concat({
    "time", "fps", "target_fps", "frame_ms", "update_ms", "draw_emit_ms",
    "renderer_end_ms", "present_ms", "core_step_ms", "total_ms",
    "draw_calls", "quad_instances", "texture_uploads", "texture_upload_bytes",
    "docview_draw_ms", "docview_body_ms", "docview_text_ms",
    "docview_draw_text_calls", "over_budget"
  }, ",") .. "\n")
end

local function snapshot_value(s, key)
  local value = s and s[key]
  if type(value) == "boolean" then return value and 1 or 0 end
  return value or 0
end

function perf.on_frame(snapshot)
  if not recording or not record or not snapshot or not snapshot.did_redraw then return end
  record.frame_count = record.frame_count + 1
  if snapshot.over_budget then record.over_budget_count = record.over_budget_count + 1 end
  record.file:write(table.concat({
    string.format("%.6f", snapshot.time or system.get_time()),
    string.format("%.3f", snapshot.fps or 0),
    string.format("%.3f", snapshot.target_fps or 0),
    string.format("%.3f", snapshot.frame_ms or 0),
    string.format("%.3f", snapshot.update_ms or 0),
    string.format("%.3f", snapshot.draw_emit_ms or 0),
    string.format("%.3f", snapshot.renderer_end_ms or 0),
    string.format("%.3f", snapshot.present_ms or 0),
    string.format("%.3f", snapshot.core_step_ms or 0),
    string.format("%.3f", snapshot.total_ms or 0),
    tostring(snapshot_value(snapshot, "draw_calls")),
    tostring(snapshot_value(snapshot, "quad_instances")),
    tostring(snapshot_value(snapshot, "texture_uploads")),
    tostring(snapshot_value(snapshot, "texture_upload_bytes")),
    string.format("%.3f", snapshot.docview_draw_ms or 0),
    string.format("%.3f", snapshot.docview_body_ms or 0),
    string.format("%.3f", snapshot.docview_text_ms or 0),
    tostring(snapshot_value(snapshot, "docview_draw_text_calls")),
    snapshot.over_budget and "1" or "0",
  }, ",") .. "\n")
end

local function sorted_counts(tbl)
  local rows = {}
  for key, count in pairs(tbl) do
    rows[#rows + 1] = { key = key, count = count }
  end
  table.sort(rows, function(a, b) return a.count > b.count end)
  return rows
end

local function write_counts_csv(path, header, rows)
  local file = io.open(path, "wb")
  if not file then return end
  file:write(header .. "\n")
  for _, row in ipairs(rows) do
    file:write(tostring(row.count), ",", csv_escape(row.key), "\n")
  end
  file:close()
end

local function write_summary(path)
  local file = io.open(path, "wb")
  if not file then return end
  local elapsed = record.stop_time - record.start_time
  file:write("Anvil performance recording\n")
  file:write(string.format("Elapsed: %.3fs\n", elapsed))
  file:write(string.format("Redraw frames: %d\n", record.frame_count))
  if elapsed > 0 then
    file:write(string.format("Redraw FPS: %.1f\n", record.frame_count / elapsed))
  end
  file:write(string.format("Over-budget frames: %d (%.1f%%)\n\n",
    record.over_budget_count,
    record.frame_count > 0 and (record.over_budget_count * 100 / record.frame_count) or 0
  ))

  file:write("Top Lua samples:\n")
  for i, row in ipairs(sorted_counts(record.lua_samples)) do
    if i > 30 then break end
    local pct = record.sample_count > 0 and (row.count * 100 / record.sample_count) or 0
    file:write(string.format("%6.2f%% %7d %s\n", pct, row.count, row.key))
  end

  file:write("\nTop renderer API callers:\n")
  local total_api = 0
  for _, count in pairs(record.api_calls) do total_api = total_api + count end
  for i, row in ipairs(sorted_counts(record.api_calls)) do
    if i > 40 then break end
    local pct = total_api > 0 and (row.count * 100 / total_api) or 0
    file:write(string.format("%6.2f%% %7d %s\n", pct, row.count, row.key))
  end
  file:close()
end

function perf.is_recording()
  return recording
end

function perf.start_recording()
  if recording then return record and record.dir end
  local base = temp_dir() .. PATHSEP .. timestamp_name()
  local frames_path = base .. "_frames.csv"
  local file = assert(io.open(frames_path, "wb"))
  write_frame_header(file)
  record = {
    base = base,
    frames_path = frames_path,
    summary_path = base .. "_summary.txt",
    samples_path = base .. "_lua_samples.csv",
    api_path = base .. "_api_calls.csv",
    file = file,
    start_time = system.get_time(),
    stop_time = nil,
    frame_count = 0,
    over_budget_count = 0,
    lua_samples = {},
    sample_count = 0,
    api_calls = {},
  }
  recording = true
  wrap_renderer_api("draw_text")
  wrap_renderer_api("draw_rect")
  debug.sethook(hook, "", sample_interval)
  return frames_path
end

function perf.stop_recording()
  if not recording or not record then return nil end
  debug.sethook()
  unwrap_renderer_api()
  record.stop_time = system.get_time()
  record.file:close()
  write_counts_csv(record.samples_path, "samples,source", sorted_counts(record.lua_samples))
  write_counts_csv(record.api_path, "calls,api_source", sorted_counts(record.api_calls))
  write_summary(record.summary_path)
  local summary_path = record.summary_path
  recording = false
  record = nil
  system.set_clipboard(summary_path)
  core.log("Performance recording saved: %s", summary_path)
  return summary_path
end

function perf.toggle_recording()
  if recording then
    return false, perf.stop_recording()
  else
    return true, perf.start_recording()
  end
end

return perf
