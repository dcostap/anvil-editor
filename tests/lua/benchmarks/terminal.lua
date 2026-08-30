local common = require "core.common"
local test = require "core.test"

local function snapshot_text(snapshot)
  local parts = {}
  for _, row in ipairs(snapshot.rows or {}) do
    for _, run in ipairs(row.text_runs or {}) do parts[#parts + 1] = run.text end
    parts[#parts + 1] = "\n"
  end
  return table.concat(parts)
end

local function percentile(values, fraction)
  table.sort(values)
  return values[math.max(1, math.min(#values, math.ceil(#values * fraction)))] or 0
end

test.describe("Terminal native benchmark", function()
  test.it("records sustained output update and snapshot costs", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local terminal_native = require "terminal_native"
    collectgarbage("collect")
    local heap_before = collectgarbage("count")
    local session, start_error = terminal_native.new({
      cols = 120, rows = 40, cell_width = 8, cell_height = 16,
      cwd = system.getcwd(),
      shell = [[powershell.exe -NoLogo -NoProfile -Command "1..20000 | ForEach-Object { Write-Output ('{0:D6} terminal benchmark output with colors and unicode [36m界[0m' -f $_) }; Write-Output 'ANVIL_TERMINAL_BENCHMARK_TAIL'"]],
    })
    test.ok(session, start_error)

    local updates, snapshots = {}, {}
    local update_calls, snapshot_calls = 0, 0
    local text, snapshot = "", nil
    local started = system.get_time()
    local deadline = started + 30
    while system.get_time() < deadline and
        not text:find("ANVIL_TERMINAL_BENCHMARK_TAIL", 1, true) do
      local update_started = system.get_time()
      local changed = session:update()
      updates[#updates + 1] = (system.get_time() - update_started) * 1000
      update_calls = update_calls + 1
      if changed then
        local snapshot_started = system.get_time()
        snapshot = session:snapshot(snapshot)
        snapshots[#snapshots + 1] = (system.get_time() - snapshot_started) * 1000
        snapshot_calls = snapshot_calls + 1
        text = snapshot_text(snapshot)
      end
      if not changed then coroutine.yield(0.001) end
    end
    local elapsed_ms = (system.get_time() - started) * 1000
    local search_calls, search_max_ms = 0, 0
    local search_state = "pending"
    while search_state == "pending" do
      local search_started = system.get_time()
      local _, state = session:search("ANVIL_TERMINAL_MISSING_QUERY", false)
      search_max_ms = math.max(search_max_ms, (system.get_time() - search_started) * 1000)
      search_calls = search_calls + 1
      search_state = state
    end
    local native_stats = session:stats()
    session:close()
    test.ok(text:find("ANVIL_TERMINAL_BENCHMARK_TAIL", 1, true), text)

    collectgarbage("collect")
    local report = {
      benchmark = "terminal-native-output",
      recorded_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      output_lines = 20000,
      elapsed_ms = elapsed_ms,
      update_calls = update_calls,
      snapshot_calls = snapshot_calls,
      update_ms = {
        median = percentile(updates, 0.50),
        p95 = percentile(updates, 0.95),
        max = percentile(updates, 1.00),
      },
      snapshot_ms = {
        median = percentile(snapshots, 0.50),
        p95 = percentile(snapshots, 0.95),
        max = percentile(snapshots, 1.00),
      },
      no_match_search = { calls = search_calls, max_step_ms = search_max_ms },
      native = native_stats,
      lua_heap_kib = {
        before = heap_before,
        after = collectgarbage("count"),
      },
    }
    test.ok(report.update_ms.p95 < 5, "terminal native update p95 exceeded 5 ms")
    test.ok(report.snapshot_ms.p95 < 10, "terminal snapshot p95 exceeded 10 ms")
    test.ok(report.no_match_search.max_step_ms < 50,
      "terminal search step exceeded the UI responsiveness limit")
    test.ok(report.elapsed_ms < 30000, "terminal output benchmark exceeded 30 seconds")
    print("terminal-native-benchmark " .. common.serialize(report))
  end)

  test.it("records bounded work across several sessions", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local terminal_native = require "terminal_native"
    local sessions = {}
    for index = 1, 10 do
      local output = index <= 3
        and string.format("1..1000 | ForEach-Object { [Console]::WriteLine('hidden-%d-'+$_) }", index)
        or "Start-Sleep -Seconds 2"
      local session, err = terminal_native.new({
        cols = 80, rows = 12, cell_width = 8, cell_height = 16,
        cwd = system.getcwd(),
        shell = string.format('powershell.exe -NoLogo -NoProfile -Command "%s"', output),
      })
      test.ok(session, err)
      sessions[#sessions + 1] = session
    end
    local started = system.get_time()
    local update_ms, update_calls = 0, 0
    while system.get_time() - started < 1 do
      for _, session in ipairs(sessions) do
        local step = system.get_time()
        local changed = session:update()
        update_ms = update_ms + (system.get_time() - step) * 1000
        update_calls = update_calls + 1
        if changed then session:snapshot(nil, false) end
      end
      coroutine.yield(0.002)
    end
    local high_water, rejected = 0, 0
    for _, session in ipairs(sessions) do
      local stats = session:stats()
      high_water = math.max(high_water, stats.read_queue_high_water or 0)
      rejected = rejected + (stats.rejected_writes or 0)
      session:close()
    end
    local report = {
      benchmark = "terminal-native-multi-session",
      sessions = #sessions,
      update_calls = update_calls,
      update_ms = update_ms,
      read_queue_high_water = high_water,
      rejected_writes = rejected,
    }
    test.ok(update_calls > 0)
    print("terminal-native-multi-session " .. common.serialize(report))
  end)
end)
