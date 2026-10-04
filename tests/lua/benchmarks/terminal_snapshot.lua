local test = require "core.test"
local common = require "core.common"

test.describe("Terminal snapshot output latency", function()
  test.it("keeps shell replies bounded while saving large scrollback", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local native = require "terminal_native"
    local session = assert(native.new {
      cols = 260, rows = 12, cell_width = 8, cell_height = 16,
      scrollback_lines = 100000,
      shell = string.format('powershell.exe -NoProfile -File "%s/tests/fixtures/terminal_snapshot_latency.ps1"', system.getcwd()),
    })
    local snapshot, text = nil, ""
    local function wait_for(marker, seconds)
      local deadline = system.get_time() + seconds
      repeat
        if session:update() then
          snapshot = session:snapshot(snapshot)
          if snapshot then
            local rows = {}
            for _, row in ipairs(snapshot.rows) do
              for _, run in ipairs(row.text_runs) do rows[#rows + 1] = run.text end
              rows[#rows + 1] = "\n"
            end
            text = table.concat(rows)
          end
        end
        if text:find(marker, 1, true) then return true end
        coroutine.yield(0.001)
      until system.get_time() >= deadline
      return false
    end
    local ok, err = pcall(function()
      test.ok(wait_for("SNAPSHOT_LATENCY_READY", 90), "large-scrollback fixture did not start")
      local latencies, seq, started = {}, 0, system.get_time()
      -- Cross a periodic save without forcing private host behavior.
      repeat
        seq = seq + 1
        local before = system.get_time()
        test.ok(session:write(seq .. "\r"))
        test.ok(wait_for("REPLY_" .. seq .. "\n", 5), "shell reply stalled during a save")
        latencies[#latencies + 1] = (system.get_time() - before) * 1000
        coroutine.yield(0.01)
      until system.get_time() - started >= 25
      table.sort(latencies)
      local log = assert(io.open(USERDIR .. "/logs/terminal-session-" .. session:stats().session_id .. ".log", "rb"))
      local diagnostics = log:read("*a"); log:close()
      local captured, capture_ms, total_ms, saves = 0, 0, 0, 0
      for full, _, locked, total in diagnostics:gmatch("captured=(%d+) bytes=(%d+) capture_ms=(%d+) total_ms=(%d+) final=0") do
        captured = math.max(captured, tonumber(full))
        capture_ms = math.max(capture_ms, tonumber(locked))
        total_ms = math.max(total_ms, tonumber(total))
        saves = saves + 1
      end
      if saves > 0 then
        test.ok(captured > 8 * 1024 * 1024, "fixture did not exercise disk history trimming")
      end
      print("terminal-snapshot-latency " .. common.serialize {
        samples = #latencies, p95_ms = latencies[math.ceil(#latencies * .95)],
        max_ms = latencies[#latencies], session_id = session:stats().session_id,
        saves = saves, captured_bytes = captured, capture_ms = capture_ms, save_total_ms = total_ms,
      })
      test.ok(latencies[#latencies] < 300, "snapshot save blocked shell replies for 300 ms")
    end)
    session:close()
    test.ok(ok, err)
  end)
end)
