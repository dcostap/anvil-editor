local test = require "core.test"

test.describe("Memory diagnostics", function()
  test.it("reports process memory and the calling Lua heap", function()
    local report = system.memory_stats()
    test.ok(report.lua_bytes > 0)
    test.ok(report.categories.treesitter.bytes >= 0)
    test.ok(report.categories.treesitter.peak_bytes >= report.categories.treesitter.bytes)
    if PLATFORM == "Windows" then
      test.ok(report.process.private_commit_bytes > 0)
      test.ok(report.process.working_set_bytes > 0)
    end
  end)

  test.it("reports an idle worker's heap and removes its sample when its state closes", function()
    local name = "memory-worker-" .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    local stop = thread.get_channel(name)
    local worker = assert(thread.create(name, function(channel_name)
      local value = string.rep("x", 2 * 1024 * 1024)
      thread.get_channel(channel_name):wait()
      return #value
    end, name))
    local found
    local deadline = system.get_time() + 30
    repeat
      for _, state in ipairs(system.memory_stats().lua_states) do
        if state.name == name and state.bytes >= 2 * 1024 * 1024 then found = state end
      end
      if not found then coroutine.yield() end
    until found or system.get_time() >= deadline
    stop:push(true)
    worker:wait()
    worker = nil
    collectgarbage("forcecollect")
    test.ok(found, "the blocked worker must publish its heap before it waits")
    for _, state in ipairs(system.memory_stats().lua_states) do
      test.ok(state.id ~= found.id, "a closed Lua state must not keep a memory sample")
    end
    stop:clear()
  end)
end)
