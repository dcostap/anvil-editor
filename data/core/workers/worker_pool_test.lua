-- Small worker-pool test jobs. Kept dependency-light so it is safe to load in
-- worker Lua states.

local worker_pool_test = {}

local function maybe_sleep(seconds)
  seconds = tonumber(seconds or 0) or 0
  if seconds > 0 and system and system.sleep then system.sleep(seconds) end
end

function worker_pool_test.run(payload, ctx)
  local op = payload.op or "echo"

  if op == "echo" then
    ctx.send({ type = "result", payload = { value = payload.value } })
    ctx.send({ type = "final", payload = { ok = true } })
    return
  end

  if op == "spam" then
    local count = math.floor(tonumber(payload.count or 1) or 1)
    for i = 1, count do
      if ctx.cancelled() then
        ctx.send({ type = "cancelled", payload = { sent = i - 1 } })
        return
      end
      ctx.send({ type = "result", payload = { index = i } })
    end
    ctx.send({ type = "final", payload = { count = count } })
    return
  end

  if op == "count_until_cancel" then
    local count = math.floor(tonumber(payload.count or 100) or 100)
    local sleep = tonumber(payload.sleep or 0.001) or 0.001
    for i = 1, count do
      if ctx.cancelled() then
        ctx.send({ type = "cancelled", payload = { index = i } })
        return
      end
      ctx.send({ type = "progress", payload = { index = i } })
      maybe_sleep(sleep)
    end
    ctx.send({ type = "final", payload = { count = count } })
    return
  end

  if op == "fail" then
    error(payload.message or "worker-pool-test-failure")
  end

  error("unknown worker_pool_test op: " .. tostring(op))
end

return worker_pool_test
