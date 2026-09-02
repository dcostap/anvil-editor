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
