local core = require "core"
local test = require "core.test"

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + timeout
  while not predicate() and system.get_time() < deadline do
    coroutine.yield(0.01)
  end
  return predicate()
end

test.describe("core scheduler threads", function()
  test.it("wakes a sleeping thread immediately by its stable key", function()
    local key = {}
    local runs = 0
    core.add_thread(function()
      runs = runs + 1
      coroutine.yield(10)
      runs = runs + 1
    end, key)

    test.ok(wait_until(function() return runs == 1 end, 0.5))
    test.ok(core.wake_thread(key))
    test.ok(wait_until(function() return runs == 2 end, 0.5),
      "scheduler thread did not resume after an explicit wake")
    test.not_ok(core.wake_thread(key), "completed scheduler thread should be removed")
  end)

  test.it("keeps a replacement registered under the exiting thread's key", function()
    local key = {}
    local replacement_runs = 0
    core.add_thread(function()
      core.add_thread(function()
        replacement_runs = replacement_runs + 1
      end, key)
    end, key)

    test.ok(wait_until(function() return replacement_runs == 1 end, 0.5),
      "scheduler cleanup removed the replacement thread")
  end)

  test.it("keeps returned numeric keys stable when an earlier thread exits", function()
    local first_key = core.add_thread(function() end)
    local runs = 0
    local second_key = core.add_thread(function()
      runs = runs + 1
      coroutine.yield(10)
      runs = runs + 1
    end)

    test.ok(first_key ~= second_key)
    test.ok(wait_until(function()
      return runs == 1 and core.threads[first_key] == nil
    end, 0.5))
    test.ok(core.wake_thread(second_key),
      "the key returned for a later thread shifted after cleanup")
    test.ok(wait_until(function() return runs == 2 end, 0.5))
  end)
end)
