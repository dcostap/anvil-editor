local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function drain_until(pool, predicate, limit)
  limit = limit or 1000
  for _ = 1, limit do
    pool:drain({ max_ms = 5, max_messages = 64 })
    if predicate() then return true end
    coroutine.yield(0.001)
  end
  pool:drain({ max_ms = 5, max_messages = 64 })
  return predicate()
end

test.describe("worker_pool", function()
  local pools = {}

  local function new_pool(name, workers)
    local pool = worker_pool.new({ name = name, worker_count = workers or 1 })
    pools[#pools + 1] = pool
    return pool
  end

  test.after_each(function()
    for i = #pools, 1, -1 do
      pools[i]:shutdown({ cancel_running = true, timeout_ms = 1000 })
      pools[i] = nil
    end
  end)

  test.test("submit returns immediately and delivers a result", function()
    local pool = new_pool("test-submit", 1)
    local seen
    local completed = false
    local handle = pool:submit({
      kind = "worker_pool_test",
      generation = 7,
      project_paths_generation = 3,
      payload = { op = "echo", value = "hello" },
      on_result = function(message)
        if message.type == "result" then seen = message.payload.value end
      end,
      on_complete = function() completed = true end,
    })
    test.not_nil(handle)
    test.equal(pool:status(handle).status, "queued")
    test.ok(drain_until(pool, function() return completed end))
    test.equal(seen, "hello")
    test.equal(pool:status(handle).status, "complete")
  end)

  test.test("multiple jobs complete", function()
    local pool = new_pool("test-many", 2)
    local results = {}
    local completed = 0
    for i = 1, 6 do
      pool:submit({
        kind = "worker_pool_test",
        payload = { op = "echo", value = i },
        on_result = function(message)
          if message.type == "result" then results[message.payload.value] = true end
        end,
        on_complete = function() completed = completed + 1 end,
      })
    end
    test.ok(drain_until(pool, function() return completed == 6 end))
    for i = 1, 6 do test.ok(results[i]) end
  end)

  test.test("errors are delivered", function()
    local pool = new_pool("test-error", 1)
    local error_message
    local handle = pool:submit({
      kind = "worker_pool_test",
      payload = { op = "fail", message = "boom" },
      on_error = function(message) error_message = message.error end,
    })
    test.ok(drain_until(pool, function() return error_message ~= nil end))
    test.ok(error_message:find("boom", 1, true) ~= nil)
    test.equal(pool:status(handle).status, "failed")
  end)

  test.test("drain respects message count budget", function()
    local pool = new_pool("test-budget", 1)
    local seen = 0
    local completed = false
    pool:submit({
      kind = "worker_pool_test",
      payload = { op = "spam", count = 5 },
      on_result = function(message)
        if message.type == "result" then seen = seen + 1 end
      end,
      on_complete = function() completed = true end,
    })

    for _ = 1, 1000 do
      local drained = pool:drain({ max_ms = 100, max_messages = 2 })
      test.ok(drained <= 2)
      if completed then break end
      coroutine.yield(0.001)
    end
    test.equal(seen, 5)
    test.equal(completed, true)
  end)

  test.test("running job cancellation is visible to the handler", function()
    local pool = new_pool("test-cancel", 1)
    local progress = 0
    local cancelled = false
    local handle = pool:submit({
      kind = "worker_pool_test",
      payload = { op = "count_until_cancel", count = 1000, sleep = 0.001 },
      on_progress = function(message)
        progress = message.payload.index
      end,
      on_cancelled = function() cancelled = true end,
    })

    test.ok(drain_until(pool, function() return progress >= 3 end))
    test.ok(pool:cancel(handle))
    test.ok(drain_until(pool, function() return cancelled end))
    test.equal(pool:status(handle).status, "cancelled")
  end)

  test.test("stale generation results are discarded", function()
    local pool = new_pool("test-stale", 1)
    local stale = 0
    local results = 0
    local done = false
    local handle = pool:submit({
      kind = "worker_pool_test",
      generation = 1,
      payload = { op = "echo", value = "old" },
      is_stale = function(message)
        return message.generation == 1
      end,
      on_stale = function() stale = stale + 1 end,
      on_result = function() results = results + 1 end,
      on_complete = function() done = true end,
    })
    test.ok(drain_until(pool, function()
      local status = pool:status(handle)
      return status and status.status == "stale"
    end))
    test.equal(results, 0)
    test.ok(stale > 0)
    test.equal(done, false)
    test.equal(pool:cancel(handle), false)
  end)

  test.test("pools can be created and destroyed repeatedly", function()
    for i = 1, 3 do
      local pool = new_pool("test-repeat-" .. i, 1)
      local completed = false
      pool:submit({
        kind = "worker_pool_test",
        payload = { op = "echo", value = i },
        on_complete = function() completed = true end,
      })
      test.ok(drain_until(pool, function() return completed end))
      pool:shutdown({ timeout_ms = 1000 })
      pools[#pools] = nil
    end
  end)
end)
