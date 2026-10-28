-- Final shutdown closes every pool. This file shuts down all pools, so it holds only this test.
local test = require "core.test"
local worker_pool = require "core.worker_pool"

test.describe("worker_pool.shutdown_all", function()
  test.test("a pool requested by a cancel callback during shutdown starts no workers", function()
    local pool = worker_pool.named("test-shutdown-reentry", { worker_count = 1 })
    local started = false
    local requested
    pool:submit({
      kind = "worker_pool_test",
      payload = { op = "count_until_cancel", count = 100000, sleep = 0.01 },
      on_progress = function() started = true end,
      -- Git's job cancel looks up its pool again, as this callback does.
      on_cancelled = function() requested = worker_pool.named("test-shutdown-reentry") end,
    })
    local deadline = system.get_time() + 10
    while not started and system.get_time() < deadline do
      pool:drain({ max_ms = 5, max_messages = 64 })
      coroutine.yield(0.005)
    end
    test.ok(started, "the job did not start")

    worker_pool.shutdown_all({ cancel_running = true, timeout_ms = 1000 })

    test.not_nil(requested, "the cancel callback did not run")
    local handle, err = requested:submit({ kind = "worker_pool_test", payload = { op = "echo" } })
    test.is_nil(handle)
    test.equal(err, "closed")
    test.equal(#worker_pool.open_pools(), 0)
  end)
end)
