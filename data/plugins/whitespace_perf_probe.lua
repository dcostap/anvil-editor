-- mod-version:3 priority:99
-- Env-gated whitespace redraw performance probe.
-- Does nothing unless ANVIL_WHITESPACE_PERF_TEST is truthy.
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local DocView = require "core.docview"

local function is_truthy_value(value)
  if not value or value == "" then return false end
  value = tostring(value):lower():match("^%s*(.-)%s*$")
  return value ~= "0" and value ~= "false" and value ~= "no" and value ~= "off"
end

local function truthy(name)
  return is_truthy_value(os.getenv(name))
end

local control_file = USERDIR and (USERDIR .. PATHSEP .. "whitespace_perf_probe.cfg") or nil
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

if not truthy("ANVIL_WHITESPACE_PERF_TEST") and not is_truthy_value(control.enabled) then return {} end

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

local probe = {
  duration = env_number("ANVIL_WHITESPACE_PERF_SECONDS", "seconds", 2),
  warmup = env_number("ANVIL_WHITESPACE_PERF_WARMUP", "warmup", 0.75),
  settle = env_number("ANVIL_WHITESPACE_PERF_SETTLE", "settle", 0.25),
  start_line = env_number("ANVIL_WHITESPACE_PERF_START_LINE", "start_line", 1),
  result_file = env_string("ANVIL_WHITESPACE_PERF_RESULT_FILE", "result_file"),
  go_file = env_string("ANVIL_WHITESPACE_PERF_GO_FILE", "go_file"),
  file = env_string("ANVIL_WHITESPACE_PERF_FILE", "file"),
}

local function write_result(fields)
  if probe.result_file == "" then return end
  local fp = io.open(probe.result_file, "wb")
  if not fp then return end
  for key, value in pairs(fields) do
    fp:write(key, "=", tostring(value or ""), "\n")
  end
  fp:close()
end

local function active_docview()
  local view = core.active_view
  if view and view:is(DocView) and view.doc and #view.doc.lines > 0 then
    if probe.file == "" or common.path_equals(view.doc.abs_filename, probe.file) then
      return view
    end
    -- In single-instance or restored-session edge cases the file can already be
    -- active with a path spelling that does not compare equal. The harness opens
    -- only the target file, so prefer progress over waiting forever.
    return view
  end
end

local function activate_view(view)
  if not view then return nil end
  local node = core.root_panel and core.root_panel.root_node and core.root_panel.root_node:get_node_for_view(view)
  if node then node:set_active_view(view) else core.set_active_view(view) end
  return view
end

local function open_target_file()
  if probe.file == "" then return nil end
  local ok, doc = pcall(core.open_doc, probe.file)
  if not ok then
    core.log_quiet("Whitespace perf probe: refusing target file %q: %s", probe.file, tostring(doc))
    probe.file = ""
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
    dv.doc:set_selection(math.max(1, math.min(#dv.doc.lines, probe.start_line)), 1)
    dv:scroll_to_line(probe.start_line, true)
  end
  pcall(function() require "plugins.drawwhitespace" end)
  pcall(command.perform, "draw-whitespace:enable")
  core.redraw = true
end

local function force_redraw_until(deadline)
  while system.get_time() < deadline do
    core.redraw = true
    coroutine.yield(1 / (config.fps or 60))
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
  if probe.go_file ~= "" then
    core.log_quiet("Whitespace perf probe: waiting for harness go file %s", probe.go_file)
    repeat
      core.redraw = true
      coroutine.yield(0.05)
    until system.get_file_info(probe.go_file)
  end
  stabilize_ui(dv)
  core.log_quiet(
    "Whitespace perf probe: warmup %.2fs, measuring %.2fs on %s",
    probe.warmup,
    probe.duration,
    probe.file ~= "" and probe.file or tostring(dv.doc.abs_filename or "")
  )

  force_redraw_until(system.get_time() + probe.warmup)

  local start_time = system.get_time()
  force_redraw_until(start_time + probe.duration)
  local end_time = system.get_time()

  stabilize_ui(dv)
  force_redraw_until(system.get_time() + probe.settle)

  write_result {
    done = 1,
    file = probe.file ~= "" and probe.file or tostring(dv.doc.abs_filename or ""),
    start_time = string.format("%.6f", start_time),
    end_time = string.format("%.6f", end_time),
    duration = string.format("%.3f", end_time - start_time),
    frame_stats_file = os.getenv("ANVIL_FRAME_PACING_STATS_FILE") or "",
    d3d_stats_file = os.getenv("ANVIL_D3D11_STATS_FILE") or "",
  }

  core.log_quiet("Whitespace perf probe finished")
end)

return probe
