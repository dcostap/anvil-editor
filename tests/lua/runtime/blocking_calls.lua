local test = require "core.test"
local blocking_calls = require "core.blocking_calls"

local function temp_file()
  local path = USERDIR .. PATHSEP .. "blocking-calls.txt"
  local file = assert(io.open(path, "wb"))
  file:write("text")
  file:close()
  return path
end

test.describe("blocking calls", function()
  test.after_each(function() blocking_calls.stop() end)

  test.it("counts each UI-thread file call at its caller", function()
    local path = temp_file()
    blocking_calls.start()
    system.get_file_info(path)
    local file = assert(io.open(path, "rb"))
    file:read("*a")
    file:close()
    test.equal(blocking_calls.count(), 4)
    local names = {}
    for _, caller in ipairs(blocking_calls.callers()) do
      names[#names + 1] = caller.name
      test.match(caller.at, "tests/lua/runtime/blocking_calls%.lua:%d+$")
    end
    table.sort(names)
    test.same(names, { "file.close", "file.read", "io.open", "system.get_file_info" })
  end)

  test.it("does not count calls on worker threads", function()
    local path = temp_file()
    local channel = thread.get_channel("blocking-calls-test")
    channel:clear()
    blocking_calls.start()
    local worker = assert(thread.create("blocking-calls-test", function(file_path)
      local file = io.open(file_path, "rb")
      local text = file and file:read("*a")
      if file then file:close() end
      thread.get_channel("blocking-calls-test"):push(text or "")
    end, path))
    worker:wait()
    test.equal(channel:first(), "text")
    test.equal(blocking_calls.count(), 0)
  end)

  test.it("counts each call once while the Machine guard wraps and restores the same functions", function()
    local guard = require "core.machine_guard"
    local path = temp_file()
    local machine_root = USERDIR .. PATHSEP .. "blocking-calls-machine"
    blocking_calls.start()
    guard.enable({ machine_root })
    system.get_file_info(path)
    test.equal(blocking_calls.count(), 1, "a guarded call must count once")
    test.error(function() system.get_file_info(machine_root .. PATHSEP .. "file") end)
    guard.disable()
    system.get_file_info(path)
    test.equal(blocking_calls.count(), 2, "counting must go on after the guard")

    -- The guard wraps the counter. A new recording wraps the guard again.
    guard.enable({ machine_root })
    blocking_calls.start()
    system.get_file_info(path)
    test.equal(blocking_calls.count(), 1, "a call through two counters must count once")
    guard.disable()
    system.get_file_info(path)
    test.equal(blocking_calls.count(), 2)
  end)

  test.it("makes each counted call wait like a slow disk", function()
    local path = temp_file()
    blocking_calls.start { delay = 0.05 }
    local started = system.get_time()
    system.get_file_info(path)
    test.ok(system.get_time() - started >= 0.045, "the call must wait for the delay")
    started = system.get_time()
    blocking_calls.without(system.get_file_info, path)
    test.ok(system.get_time() - started < 0.045, "a call outside the recording must not wait")
    test.equal(blocking_calls.count(), 1)
  end)
end)
