-- Blocking Calls: raw file, folder and process functions that the UI thread calls.
-- Each one can wait on the disk or on the OS. A busy disk or a virus scan can make one take seconds,
-- and the UI cannot draw meanwhile. Scenario runs and tests record them to find such waits.
-- A recording can also add a delay to each call, as a slow disk does.
-- Worker threads run in their own Lua states, so their calls do not count.
local blocking_calls = {}

-- `owner` is a table of functions. Each name is a function that can block.
local function targets()
  local file_methods = getmetatable(io.stdout)
  file_methods = file_methods and (type(file_methods.__index) == "table" and file_methods.__index or file_methods)
  local list = {
    { io, "io", { "open", "lines", "input", "output", "popen" } },
    { os, "os", { "remove", "rename", "execute" } },
    { _G, "_G", { "dofile", "loadfile" } },
    { system, "system", { "get_file_info", "list_dir", "list_dir_info", "mkdir", "rmdir", "chdir",
      "get_fs_type", "load_file", "show_in_folder", "load_native_plugin", "replace_file",
      "atomic_replace_file", "exec", "open_in_system" } },
    { rawget(_G, "process"), "process", { "start" } },
    { rawget(_G, "encoding"), "encoding", { "detect" } },
    { rawget(_G, "canvas"), "canvas", { "load_image", "load_svg_image", "open_animation" } },
    { rawget(_G, "renderer") and renderer.font, "renderer.font", { "load" } },
    { file_methods, "file", { "read", "write", "flush", "lines", "seek", "setvbuf", "close" } },
  }
  -- A `require` of a module that is not loaded yet searches and reads files.
  local searchers = package.loaders or package.searchers
  if searchers then list[#list + 1] = { searchers, "require", { 2 } } end
  return list
end

-- wrappers[owner][name] is the counting wrapper installed there.
local wrappers = setmetatable({}, { __mode = "k" })
-- depth[name] counts the wrappers of `name` that are running. Wrappers can wrap each other.
local depth = {}
local recording = nil

-- Frames that only pass a call through. The caller is the first frame outside them.
local PASS_THROUGH = { "core[/\\]blocking_calls%.lua$", "core[/\\]machine_guard%.lua$" }

local function short_source(source)
  source = source:gsub("^.-[/\\]share[/\\]anvil[/\\]", ""):gsub("^.-[/\\]data[/\\]", "")
  return (source:gsub("\\", "/"))
end

-- The caller and the two frames above it. A shared helper, such as a log writer,
-- then shows who called it.
local function caller_stack()
  local frames, source
  for level = 4, 60 do
    local info = debug.getinfo(level, "Sl")
    if not info then break end
    local src = info.short_src or "?"
    local pass = info.what == "C" or src == "[C]"
    if not frames then
      for _, pattern in ipairs(PASS_THROUGH) do
        if src:find(pattern) then pass = true; break end
      end
    end
    if not pass then
      if not frames then frames, source = {}, src end
      frames[#frames + 1] = string.format("%s:%d", short_source(src), info.currentline or 0)
      if #frames == 3 then break end
    end
  end
  if not frames then return "?", "?", nil end
  return frames[1], table.concat(frames, " < "), source
end

local function note(name)
  local current = recording
  if not current or current.paused > 0 then return end
  local at, stack, source = caller_stack()
  for _, pattern in ipairs(current.ignore) do
    if source and source:find(pattern) then return end
  end
  current.total = current.total + 1
  local key = name .. "@" .. stack
  local caller = current.callers[key]
  if not caller then
    caller = { name = name, at = at, stack = stack, calls = 0 }
    current.callers[key] = caller
  end
  caller.calls = caller.calls + 1
  if current.traceback and #current.records < current.max_records then
    current.records[#current.records + 1] = {
      name = name, at = at, traceback = debug.traceback("", 4),
    }
  end
  if current.delay > 0 then
    -- The delay itself must not count or wait again.
    current.paused = current.paused + 1
    system.sleep(current.delay)
    current.paused = current.paused - 1
  end
end

-- The wrappers stay after a recording ends and then only pass calls through.
-- Code that wraps the same functions later, such as the Machine guard, keeps working.
-- Code that restores a function it wrapped earlier removes a wrapper. Each start wraps it again.
local function install()
  for _, target in ipairs(targets()) do
    local owner, owner_name, names = target[1], target[2], target[3]
    if type(owner) == "table" then
      local installed = wrappers[owner] or {}
      wrappers[owner] = installed
      for _, name in ipairs(names) do
        local original = rawget(owner, name)
        if type(original) == "function" and original ~= installed[name] then
          local full_name = type(name) == "number" and owner_name or owner_name .. "." .. name
          local function leave(ok, ...)
            depth[full_name] = depth[full_name] - 1
            if not ok then error((...), 0) end
            return ...
          end
          local wrapper = function(...)
            local running = depth[full_name] or 0
            if running == 0 then note(full_name) end
            depth[full_name] = running + 1
            return leave(pcall(original, ...))
          end
          installed[name] = wrapper
          owner[name] = wrapper
        end
      end
    end
  end
end

---Start a recording. Options:
---  delay      seconds that each call waits first, as on a slow disk
---  traceback  keep a traceback for each call, up to `max_records`
---  ignore     Lua patterns: a call whose caller's source matches one does not count
function blocking_calls.start(options)
  options = options or {}
  install()
  recording = {
    total = 0, callers = {}, records = {}, paused = 0,
    delay = math.max(0, tonumber(options.delay) or 0),
    traceback = options.traceback == true,
    max_records = options.max_records or 10000,
    ignore = options.ignore or {},
  }
  return recording
end

function blocking_calls.stop()
  local finished = recording
  recording = nil
  return finished
end

function blocking_calls.active()
  return recording ~= nil
end

---The number of calls since the recording started.
function blocking_calls.count()
  return recording and recording.total or 0
end

---Each call site with its count, the most frequent first.
function blocking_calls.callers()
  local list = {}
  for _, caller in pairs(recording and recording.callers or {}) do
    list[#list + 1] = { name = caller.name, at = caller.at, stack = caller.stack, calls = caller.calls }
  end
  table.sort(list, function(a, b)
    if a.calls ~= b.calls then return a.calls > b.calls end
    if a.stack ~= b.stack then return a.stack < b.stack end
    return a.name < b.name
  end)
  return list
end

---Each recorded call with its traceback. Only a recording with `traceback = true` keeps them.
function blocking_calls.records()
  return recording and recording.records or {}
end

---Run `fn` without counting its calls, such as the harness's own result files.
function blocking_calls.without(fn, ...)
  local current = recording
  if not current then return fn(...) end
  current.paused = current.paused + 1
  local result = table.pack(pcall(fn, ...))
  current.paused = current.paused - 1
  if not result[1] then error(result[2], 0) end
  return table.unpack(result, 2, result.n)
end

return blocking_calls
