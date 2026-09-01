local startup = require "core.startup"
local test = require "core.test"

local function read_file(path)
  local file, err = io.open(path, "rb")
  test.not_nil(file, err)
  local text = file:read("*a")
  file:close()
  return text
end

test.describe("startup performance tracing", function()
  local path

  test.before_each(function()
    system.setenv("ANVIL_STARTUP_TRACE", "1")
    if startup.active() then startup.finish("test_reset", "before_each") end
  end)

  test.after_each(function()
    if startup.active() then startup.finish("test_cleanup", "after_each") end
    if path then os.remove(path) end
    path = nil
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
end)
