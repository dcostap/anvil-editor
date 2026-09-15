local test = require "core.test"
local Actions = require "core.perf_actions"

test.describe("benchmark action completion", function()
  test.it("waits for the requested result to be drawn before completing an action", function()
    local now, ready = 0, false
    local actions = Actions(function() return now end, 1)
    actions:start("query", function() now = 0.002 end, function() return ready end)
    now = 0.010
    actions:before_draw()
    test.is_nil(actions:after_frame(true))
    ready = true
    now = 0.030
    -- A result arriving after drawing cannot complete the action yet.
    test.is_nil(actions:after_frame(true))
    actions:before_draw()
    now = 0.040
    test.is_nil(actions:after_frame(false))
    local row = actions:after_frame(true)
    test.equal(row.name, "query")
    test.equal(row.dispatch_ms, 2)
    test.equal(row.ready_ms, 30)
    test.equal(row.latency_ms, 40)
    test.equal(row.redraws, 3)
    test.is_nil(actions:after_frame(true))
  end)

  test.it("fails a pending action even while redraws continue", function()
    local now = 0
    local actions = Actions(function() return now end, 1)
    actions:start("missing result", function() end, function() return false end)
    now = 2
    local ok, err = pcall(function() actions:after_frame(true) end)
    test.equal(ok, false)
    test.match(tostring(err), "missing result")
  end)
end)
