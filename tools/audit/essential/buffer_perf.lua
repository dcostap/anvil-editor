-- Diagnostic timings only. Run through the isolated Lua test runner.
local test = require "core.test"
local Buffer = require "core.buffer"

local function summarize(samples)
  table.sort(samples)
  return samples[math.ceil(#samples / 2)], samples[math.ceil(#samples * 0.95)], samples[#samples]
end

test.describe("Buffer preparation measurements", function()
  test.it("measures ordinary edits without language services", function()
    for _, count in ipairs { 10000, 100000, 500000 } do
      local buffer = Buffer(nil, nil, true)
      buffer.disable_language_services = true
      buffer.disable_treesitter = true
      buffer:replace_snapshot(string.rep("ordinary text\n", count))
      for _, where in ipairs { "start", "middle", "end" } do
        local line = where == "start" and 1 or where == "middle" and math.floor(count / 2) or count
        local samples = {}
        collectgarbage("collect")
        local memory = collectgarbage("count")
        for i = 1, 110 do
          buffer:set_selection(line, 1)
          local started = system.get_time()
          buffer:text_input("a")
          local elapsed = (system.get_time() - started) * 1000
          if i > 10 then samples[#samples + 1] = elapsed end
        end
        local median, p95, maximum = summarize(samples)
        print(string.format("BUFFER_PERF lines=%d position=%s median_ms=%.3f p95_ms=%.3f max_ms=%.3f heap_delta_kib=%.1f",
          count, where, median, p95, maximum, collectgarbage("count") - memory))
        test.equal(#buffer.lines, count)
        buffer:clear_undo_redo()
      end
      buffer:on_close()
      coroutine.yield()
    end
  end)
end)
