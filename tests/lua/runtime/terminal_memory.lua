local test = require "core.test"
local common = require "core.common"

-- Seam: real native sessions and their public allocation reports, without editor Views.
test.describe("Terminal memory ownership", function()
  test.before_each(function(context)
    test.skip_if(PLATFORM ~= "Windows", "Windows Terminal Sessions only")
    context.root = USERDIR .. PATHSEP .. "terminal-memory-" .. system.get_process_id()
    test.ok(common.mkdirp(context.root))
    context.sessions = {}
  end)

  test.after_each(function(context)
    for _, session in ipairs(context.sessions or {}) do session:close() end
    if context.root then test.ok(test.remove_tree(context.root)) end
  end)

  test.it("reports local and prepared queue capacity, and releases it on close", function(context)
    local native = require "terminal_native"
    test.equal(type(native.memory_stats), "function")
    local before = system.memory_stats().categories
    local total = 0
    for _, prepared in ipairs { false, true } do
      local session = assert(native.new {
        cwd = context.root, shell = "cmd.exe /d /q", prepared = prepared,
        cols = 80, rows = 8, cell_width = 8, cell_height = 16,
      })
      context.sessions[#context.sessions + 1] = session
      local deadline = system.get_time() + 30
      local status
      repeat
        local changed
        changed, status = session:update()
        if status.kind ~= "running" then coroutine.yield(0.01) end
      until status.kind == "running" or status.kind == "failed" or system.get_time() >= deadline
      test.equal(status.kind, "running")
      session:snapshot()
      local stats = session:stats()
      test.ok(stats.read_queue_capacity > 0 and stats.write_queue_capacity > 0)
      test.ok(stats.read_queue_bytes <= stats.read_queue_capacity)
      test.ok(stats.write_queue_bytes <= stats.write_queue_capacity)
      test.ok(stats.model_bytes > 0)
      test.ok(stats.snapshot_text_capacity > 0)
      test.equal(stats.prepared, prepared)
      total = total + stats.read_queue_capacity + stats.write_queue_capacity
      local listed
      for _, row in ipairs(native.memory_stats()) do
        if row.memory_id == stats.memory_id then listed = row end
      end
      test.ok(listed, "sessions without Views must appear in the report")
      test.equal(listed.session_id, stats.session_id)
    end
    test.equal(system.memory_stats().categories.terminal_queues.bytes - before.terminal_queues.bytes, total)
    for _, session in ipairs(context.sessions) do
      session:close()
      session:close()
      local stats = session:stats()
      test.equal(stats.read_queue_capacity + stats.write_queue_capacity + stats.model_bytes
        + stats.snapshot_text_capacity + stats.replay_capacity, 0)
      for _, row in ipairs(native.memory_stats()) do test.ok(row.memory_id ~= stats.memory_id) end
    end
    local after = system.memory_stats().categories
    test.equal(after.terminal_queues.bytes, before.terminal_queues.bytes)
    test.equal(after.terminal_model.bytes, before.terminal_model.bytes)
    test.equal(after.terminal_snapshots.bytes, before.terminal_snapshots.bytes)
  end)

  test.it("counts an unattached remote model without inventing queues or retaining its session", function(context)
    local native = require "terminal_native"
    test.equal(type(native.memory_stats), "function")
    local before = system.memory_stats().categories.terminal_model.bytes
    local session = assert(native.new { remote = true, cols = 80, rows = 8, cwd = context.root })
    local stats = session:stats()
    test.ok(stats.model_bytes > 0)
    test.equal(stats.read_queue_capacity + stats.write_queue_capacity, 0)
    test.equal(system.memory_stats().categories.terminal_model.bytes - before, stats.model_bytes)
    local weak = setmetatable({ session }, { __mode = "v" })
    session = nil
    collectgarbage("forcecollect")
    collectgarbage("forcecollect")
    test.equal(weak[1], nil)
    test.equal(system.memory_stats().categories.terminal_model.bytes, before)
    for _, row in ipairs(native.memory_stats()) do test.ok(row.memory_id ~= stats.memory_id) end
  end)
end)
