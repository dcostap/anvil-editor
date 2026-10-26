local common = require "core.common"
local core = require "core"
local startup = require "core.startup"
local test = require "core.test"

local function read_file(path)
  local file, err = io.open(path, "rb")
  test.not_nil(file, err)
  local text = file:read("*a")
  file:close()
  return text
end

local function trace_paths()
  local root = USERDIR .. PATHSEP .. "logs" .. PATHSEP .. "startup"
  local paths = {}
  for _, name in ipairs(system.list_dir(root) or {}) do
    if name:match("^anvil%-startup%-.+%.log$") then
      paths[name] = root .. PATHSEP .. name
    end
  end
  return paths
end

local function trace_root()
  return USERDIR .. PATHSEP .. "logs" .. PATHSEP .. "startup"
end

local function write_file(path, text)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(text)
  file:close()
end

local function table_size(values)
  local count = 0
  for _ in pairs(values) do count = count + 1 end
  return count
end

test.describe("startup performance tracing", function()
  local path
  local extra_paths

  test.before_each(function()
    system.setenv("ANVIL_STARTUP_TRACE", "1")
    if startup.active() then startup.finish("test_reset", "before_each") end
  end)

  test.after_each(function()
    if startup.active() then startup.finish("test_cleanup", "after_each") end
    if path then os.remove(path) end
    for _, extra_path in pairs(extra_paths or {}) do os.remove(extra_path) end
    path = nil
    extra_paths = nil
    system.setenv("ANVIL_STARTUP_TRACE", "0")
  end)

  test.it("writes nested stages and startup completion to a dedicated file", function()
    test.ok(startup.begin({ restarted = false, args = { "anvil", "--new-window" }, detail = "test" }))
    local stage = startup.stage_begin("test_stage", "phase=one")
    startup.mark("test_mark", "value=two")
    startup.stage_end(stage, "ok")
    path = startup.path()
    startup.finish("ready", "test_complete")

    local trace = read_file(path)
    test.match(trace, "Anvil startup trace")
    test.match(trace, "event=stage_begin name=test_stage")
    test.match(trace, "event=mark name=test_mark")
    test.match(trace, "event=stage_end name=test_stage")
    test.match(trace, "event=startup name=end")
    test.match(trace, "status=ready")
  end)

  test.it("removes the oldest traces when a new trace begins", function()
    common.mkdirp(trace_root())
    extra_paths = {}
    for index = 1, 200 do
      local name = string.format("anvil-startup-20000101-%06d-p1-m000000.log", index)
      extra_paths[name] = trace_root() .. PATHSEP .. name
      write_file(extra_paths[name], "old trace\n")
    end

    test.ok(startup.begin({ detail = "test" }))
    path = startup.path()
    startup.finish("ready", "test_complete")

    test.is_nil(system.get_file_info(extra_paths["anvil-startup-20000101-000001-p1-m000000.log"]))
    test.not_nil(system.get_file_info(extra_paths["anvil-startup-20000101-000200-p1-m000000.log"]))
    test.not_nil(system.get_file_info(path))
  end)

  test.it("ends the trace when a background Project skips its first frame", function()
    local should_render, poll_event = system.window_should_render, system.poll_event
    system.window_should_render = function() return false end
    system.poll_event = function() end
    test.ok(startup.begin({ detail = "test" }))
    path = startup.path()
    local ok, err = pcall(core.step, system.get_time(), { immediate = true })
    system.window_should_render, system.poll_event = should_render, poll_event
    test.ok(ok, err)

    test.not_ok(startup.active())
    test.match(read_file(path), "event=startup name=end detail=status=ready detail=background")
  end)

  test.it("does not create application startup traces for Lua worker threads", function()
    local before = trace_paths()
    local worker, err = thread.create("startup-trace-worker", function() return 0 end)
    test.not_nil(worker, err)
    test.equal(worker:wait(), 0)

    extra_paths = trace_paths()
    for name in pairs(before) do extra_paths[name] = nil end
    test.equal(table_size(extra_paths), 0)
  end)
end)
