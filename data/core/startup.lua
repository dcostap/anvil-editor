local common = require "core.common"

local startup = {}
local trace
local last_path

local function pack(...)
  return { n = select("#", ...), ... }
end

local function unpack_values(values)
  return (table.unpack or unpack)(values, 1, values.n)
end

local function safe_text(value)
  local text = tostring(value == nil and "" or value)
  return text:gsub("\\r", "\\\\r"):gsub("\\n", "\\\\n"):gsub("\\t", "\\\\t")
end

local function enabled_by_environment()
  local value = os.getenv("ANVIL_STARTUP_TRACE")
  if value and value ~= "" then
    value = value:lower():match("^%s*(.-)%s*$")
    return value ~= "0" and value ~= "false" and value ~= "no" and value ~= "off"
  end
  return not RUNNING_LUA_TESTS
end

local function ensure_directory(path)
  local info = system.get_file_info(path)
  if info and info.type == "dir" then return true end
  local created = common.mkdirp(path)
  return created or (system.get_file_info(path) or {}).type == "dir"
end

local function startup_file_path(root, pid)
  local stamp = os.date("%Y%m%d-%H%M%S")
  local monotonic = math.floor(system.get_time() * 1000000) % 1000000
  local stem = string.format("anvil-startup-%s-p%s-m%06d", stamp, tostring(pid), monotonic)
  local path = root .. PATHSEP .. stem .. ".log"
  local suffix = 1
  while system.get_file_info(path) do
    path = root .. PATHSEP .. stem .. string.format("-%d.log", suffix)
    suffix = suffix + 1
  end
  return path
end

local function prune_old_traces(root)
  local names = {}
  for _, name in ipairs(system.list_dir(root) or {}) do
    if name:match("^anvil%-startup%-%d%d%d%d%d%d%d%d%-%d%d%d%d%-p%d+") then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  local keep = 100
  for i = 1, math.max(0, #names - keep) do
    os.remove(root .. PATHSEP .. names[i])
  end
end

local function write_line(line)
  if not trace or not trace.file then return false end
  trace.file:write(line, "\n")
  -- Keep the trace useful after a crash. Startup work is short, so flush every event.
  trace.file:flush()
  return true
end

local function emit(event, name, detail, depth, now)
  if not trace or not trace.file then return false end
  now = now or system.get_time()
  trace.sequence = trace.sequence + 1
  local elapsed_ms = (now - trace.started) * 1000
  return write_line(string.format(
    "%06d time=%.6f elapsed_ms=%.3f depth=%d event=%s name=%s detail=%s",
    trace.sequence, now, elapsed_ms, depth or #trace.stack,
    safe_text(event), safe_text(name), safe_text(detail)
  ))
end

function startup.begin(options)
  if trace or not enabled_by_environment() then return false end
  options = options or {}
  if type(USERDIR) ~= "string" or USERDIR == "" then return false end

  local root = USERDIR .. PATHSEP .. "logs" .. PATHSEP .. "startup"
  if not ensure_directory(root) then return false end
  prune_old_traces(root)

  local pid = system.get_process_id and system.get_process_id() or 0
  local path = startup_file_path(root, pid)
  local file = io.open(path, "wb")
  if not file then return false end

  trace = {
    file = file,
    path = path,
    root = root,
    pid = pid,
    started = system.get_time(),
    sequence = 0,
    stack = {},
    first_run_step = false,
    first_present = false,
  }
  last_path = path

  write_line("Anvil startup trace")
  write_line("trace_version=1")
  write_line("started=" .. os.date("%Y-%m-%d %H:%M:%S"))
  write_line("pid=" .. safe_text(pid))
  write_line("restarted=" .. safe_text(options.restarted))
  write_line("platform=" .. safe_text(PLATFORM))
  write_line("arch=" .. safe_text(ARCH))
  write_line("exefile=" .. safe_text(EXEFILE))
  write_line("datadir=" .. safe_text(DATADIR))
  write_line("userdir=" .. safe_text(USERDIR))
  write_line("cwd=" .. safe_text(system.getcwd()))
  write_line("args=" .. safe_text(options.args and table.concat(options.args, " | ") or ""))
  write_line("environment_renderer=" .. safe_text(os.getenv("ANVIL_RENDERER")))
  write_line("environment_scale=" .. safe_text(os.getenv("ANVIL_SCALE")))
  write_line("environment_disable_plugins=" .. safe_text(os.getenv("ANVIL_DISABLE_PLUGINS")))
  emit("startup", "begin", options.detail or "lua_runtime", 0)
  return true
end

function startup.active()
  return trace ~= nil and trace.file ~= nil
end

function startup.path()
  return trace and trace.path or last_path
end

function startup.mark(name, detail)
  return emit("mark", name, detail)
end

function startup.stage_begin(name, detail)
  if not startup.active() then return nil end
  local now = system.get_time()
  local token = {
    name = name,
    started = now,
    depth = #trace.stack + 1,
  }
  trace.stack[#trace.stack + 1] = token
  emit("stage_begin", name, detail or "", token.depth, now)
  return token
end

function startup.stage_end(token, status, detail)
  if not token or token.ended or not trace then return end
  token.ended = true
  local now = system.get_time()
  for index = #trace.stack, 1, -1 do
    if trace.stack[index] == token then
      table.remove(trace.stack, index)
      break
    end
  end
  local suffix = string.format(
    "status=%s duration_ms=%.3f%s",
    tostring(status or "ok"), (now - token.started) * 1000,
    detail and (" " .. tostring(detail)) or ""
  )
  emit("stage_end", token.name, suffix, token.depth, now)
end

function startup.measure(name, fn, detail)
  if not startup.active() then return fn() end
  local token = startup.stage_begin(name, detail)
  local ok, values_or_error = xpcall(function()
    return pack(fn())
  end, debug.traceback)
  if token then
    startup.stage_end(token, ok and "ok" or "error", not ok and ("error=" .. values_or_error) or nil)
  end
  if not ok then error(values_or_error, 0) end
  return unpack_values(values_or_error)
end

function startup.thread_scheduled(key, location, background)
  startup.mark("thread_scheduled", string.format(
    "key=%s background=%s location=%s", tostring(key), tostring(background), tostring(location)
  ))
end

function startup.thread_started(key, location, background)
  startup.mark("thread_started", string.format(
    "key=%s background=%s location=%s", tostring(key), tostring(background), tostring(location)
  ))
end

function startup.thread_finished(key, location, background, elapsed_ms, dead)
  startup.mark("thread_finished", string.format(
    "key=%s background=%s dead=%s elapsed_ms=%.3f location=%s",
    tostring(key), tostring(background), tostring(dead), elapsed_ms or 0, tostring(location)
  ))
end

function startup.event(event_type)
  startup.mark("event", event_type)
end

function startup.run_step_begin(options)
  if not startup.active() then return nil end
  trace.run_steps = (trace.run_steps or 0) + 1
  if trace.run_steps == 1 then trace.first_run_step = true end
  return startup.stage_begin("run_step_" .. tostring(trace.run_steps), string.format(
    "immediate=%s reason=%s", tostring(options and options.immediate), tostring(options and options.reason or "")
  ))
end

function startup.run_step_end(token, did_redraw)
  startup.stage_end(token, "ok", "did_redraw=" .. tostring(did_redraw))
end

function startup.on_present()
  if not startup.active() or trace.first_present then return end
  trace.first_present = true
  startup.mark("first_present")
  startup.finish("ready", "first_present")
end

function startup.finish(status, detail)
  if not startup.active() then return end
  local current = trace
  emit("startup", "end", string.format(
    "status=%s detail=%s total_ms=%.3f",
    tostring(status or "complete"), tostring(detail or ""),
    (system.get_time() - current.started) * 1000
  ), 0)
  current.file:flush()
  current.file:close()
  trace = nil
  if type(core) == "table" then core.startup_trace_active = false end
end

return startup
