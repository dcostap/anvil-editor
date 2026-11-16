local test = require "core.test"
local canvas = require "canvas"

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

  test.it("counts canvas pixels until their canvases close", function()
    collectgarbage("forcecollect")
    local before = system.memory_stats().categories.render_surfaces
    test.ok(before, "memory reports must include owned rendering surfaces")
    local images = { canvas.new(128, 64, { 0, 0, 0, 255 }, true) }
    images[2] = images[1]:copy()
    images[3] = images[1]:scaled(64, 32)
    images[4] = images[1]:copy(0, 0, 32, 16)
    local live = system.memory_stats().categories.render_surfaces
    test.equal(live.bytes - before.bytes, 32768 + 32768 + 8192 + 2048)
    test.equal(live.objects - before.objects, 4)
    for i = 1, #images do images[i] = nil end
    collectgarbage("forcecollect")
    local after = system.memory_stats().categories.render_surfaces
    test.equal(after.bytes, before.bytes)
    test.equal(after.objects, before.objects)
    test.ok(after.peak_bytes >= live.bytes)
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

test.describe("Automatic main-state memory samples", function()
  local server = dofile("tests/fixtures/machine_server.lua")

  test.after_each(function(context)
    server.stop(context.server)
    if context.root then test.ok(test.remove_tree(context.root)) end
  end)

  test.it("refreshes the heap sample while the Machine server runs its event loop", function(context)
    if PLATFORM ~= "Windows" then return end
    context.root = USERDIR .. PATHSEP .. "memory-server-" .. system.get_process_id()
    test.ok(require("core.common").mkdirp(context.root))
    context.server = server.start(context.root, {})
    local first, second
    local deadline = system.get_time() + 90
    repeat
      for _, name in ipairs(system.list_dir(context.root .. PATHSEP .. "logs") or {}) do
        if name:match("%-p" .. context.server:pid() .. "%-native.*%.log$") then
          local file = assert(io.open(context.root .. PATHSEP .. "logs" .. PATHSEP .. name, "rb"))
          for line in file:lines() do
            local elapsed, sample, age = line:match(
              "%s([%d%.]+)%s+%w+%[%d+%].-Memory Lua: sample=(%d+).-age_ms=(%d+) name=main")
            if elapsed then
              local observed = tonumber(elapsed) - tonumber(age) / 1000
              if tonumber(sample) == 1 then first = observed
              elseif first then second = observed end
            end
          end
          file:close()
        end
      end
      if not second then coroutine.yield(0.1) end
    until second or system.get_time() >= deadline
    test.ok(second, "the server must publish its startup memory reports")
    test.ok(second > first + 1, "an active main state must not keep its startup heap sample")
  end)
end)
