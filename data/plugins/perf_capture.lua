-- mod-version:3 priority:99
-- Env-gated automated F11-style performance capture for a target file.
-- Does nothing unless ANVIL_PERF_CAPTURE is truthy or USERDIR/perf_capture.cfg enables it.
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local DocView = require "core.docview"
local perf = require "core.perf"

local function is_truthy_value(value)
  if not value or value == "" then return false end
  value = tostring(value):lower():match("^%s*(.-)%s*$")
  return value ~= "0" and value ~= "false" and value ~= "no" and value ~= "off"
end

local function truthy(name)
  return is_truthy_value(os.getenv(name))
end

local control_file = USERDIR and (USERDIR .. PATHSEP .. "perf_capture.cfg") or nil
local function clean_control_value(value)
  value = tostring(value or "")
  return (value:gsub("[\r\n]+$", ""))
end

local control = {}
if control_file then
  local fp = io.open(control_file, "rb")
  if fp then
    for line in fp:lines() do
      local key, value = line:match("^([^=]+)=(.*)$")
      if key then
        key = key:match("^%s*(.-)%s*$")
        control[key] = clean_control_value(value)
      end
    end
    fp:close()
  end
end

if not truthy("ANVIL_PERF_CAPTURE") and not is_truthy_value(control.enabled) then return {} end

local function env_string(name, key, default)
  local value = os.getenv(name)
  if value and value ~= "" then return clean_control_value(value) end
  value = control[key]
  if value and value ~= "" then return clean_control_value(value) end
  return default or ""
end

local function env_number(name, key, default)
  local value = tonumber(os.getenv(name) or "") or tonumber(control[key] or "")
  return value or default
end

local capture = {
  duration = env_number("ANVIL_PERF_CAPTURE_SECONDS", "seconds", 2),
  settle = env_number("ANVIL_PERF_CAPTURE_SETTLE", "settle", 0.25),
  start_line = env_number("ANVIL_PERF_CAPTURE_START_LINE", "start_line", 1),
  result_file = env_string("ANVIL_PERF_CAPTURE_RESULT_FILE", "result_file"),
  go_file = env_string("ANVIL_PERF_CAPTURE_GO_FILE", "go_file"),
  file = env_string("ANVIL_PERF_CAPTURE_FILE", "file"),
  force_redraw = is_truthy_value(env_string("ANVIL_PERF_CAPTURE_FORCE_REDRAW", "force_redraw", "1")),
}

local function write_result(fields)
  if capture.result_file == "" then return end
  local fp = io.open(capture.result_file, "wb")
  if not fp then return end
  for key, value in pairs(fields) do
    fp:write(key, "=", tostring(value or ""), "\n")
  end
  fp:close()
end

local function sibling_perf_path(summary_path, suffix)
  if not summary_path or summary_path == "" then return "" end
  local base = summary_path:match("^(.*)_summary%.txt$")
  if not base then return "" end
  return base .. suffix
end

local function active_docview()
  local view = core.active_view
  if view and view:is(DocView) and view.doc and #view.doc.lines > 0 then
    if capture.file == "" or common.path_equals(view.doc.abs_filename, capture.file) then
      return view
    end
  end
  for _, doc in ipairs(core.docs or {}) do
    if doc and #doc.lines > 0 and (capture.file == "" or common.path_equals(doc.abs_filename, capture.file)) then
      local views = core.get_views_referencing_doc(doc)
      if views and views[1] and views[1]:is(DocView) then return views[1] end
    end
  end
end

local function activate_view(view)
  if not view then return nil end
  local node = core.root_panel and core.root_panel.root_node and core.root_panel.root_node:get_node_for_view(view)
  if node then node:set_active_view(view) else core.set_active_view(view) end
  return view
end

local function open_target_file()
  if capture.file == "" then return nil end
  local ok, doc = pcall(core.open_doc, capture.file)
  if not ok then
    core.log_quiet("Perf capture: refusing target file %q: %s", capture.file, tostring(doc))
    capture.file = ""
    return nil
  end
  if not doc then return nil end
  return activate_view(core.root_panel:open_doc(doc))
end

local function stabilize_ui(dv)
  config.disable_blink = true
  config.animated_caret = false
  config.draw_stats = false
  if core.status_bar then
    core.status_bar:display_messages(false)
    core.status_bar.message = nil
  end
  if dv and dv.doc then
    local line = math.max(1, math.min(#dv.doc.lines, capture.start_line))
    dv.doc:set_selection(line, 1)
    dv:scroll_to_line(line, true)
  end
  core.redraw = true
end

local function wait_for_redraws_until(deadline)
  while system.get_time() < deadline do
    if capture.force_redraw then core.redraw = true end
    coroutine.yield(capture.force_redraw and (1 / (config.fps or 60)) or 0.05)
  end
end

core.add_thread(function()
  coroutine.yield()
  local dv = open_target_file()

  repeat
    dv = active_docview() or open_target_file()
    core.redraw = true
    coroutine.yield(0.05)
  until dv

  activate_view(dv)
  stabilize_ui(dv)

  if capture.go_file ~= "" then
    core.log_quiet("Perf capture: waiting for harness go file %s", capture.go_file)
    repeat
      core.redraw = true
      coroutine.yield(0.05)
    until system.get_file_info(capture.go_file)
  end

  if capture.settle > 0 then
    wait_for_redraws_until(system.get_time() + capture.settle)
  end

  if perf.is_recording() then
    write_result { done = 0, error = "performance recording was already active" }
    core.log_quiet("Perf capture: recording already active; aborting automated capture")
    return
  end

  core.log_quiet(
    "Perf capture: recording %.2fs on %s (force_redraw=%s)",
    capture.duration,
    capture.file ~= "" and capture.file or tostring(dv.doc.abs_filename or ""),
    tostring(capture.force_redraw)
  )

  local frames_path = perf.start_recording()
  local start_time = system.get_time()
  wait_for_redraws_until(start_time + capture.duration)
  local end_time = system.get_time()
  local summary_path = perf.stop_recording()

  write_result {
    done = 1,
    file = capture.file ~= "" and capture.file or tostring(dv.doc.abs_filename or ""),
    start_time = string.format("%.6f", start_time),
    end_time = string.format("%.6f", end_time),
    duration = string.format("%.3f", end_time - start_time),
    summary_file = summary_path or "",
    frames_file = frames_path or sibling_perf_path(summary_path, "_frames.csv"),
    lua_samples_file = sibling_perf_path(summary_path, "_lua_samples.csv"),
    api_calls_file = sibling_perf_path(summary_path, "_api_calls.csv"),
    details_file = sibling_perf_path(summary_path, "_details.csv"),
  }

  core.log_quiet("Perf capture finished: %s", tostring(summary_path or ""))
end)

return capture
