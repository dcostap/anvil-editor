-- Diagnostic stage timings. The GC experiment is not a production setting.
local test = require "core.test"
local encoding = require "encoding"
local common = require "core.common"

test.describe("File load preparation measurements", function()
  test.it("measures bounded reads and line batches for the short-line fixture", function()
    local path = os.getenv("ANVIL_LOAD_PERF_FILE")
    if not path then test.skip("set ANVIL_LOAD_PERF_FILE to an isolated fixture") end
    for round = 1, 3 do
      collectgarbage("collect")
      local start = system.get_time()
      local file = assert(io.open(path, "rb"))
      local lines, clean, highlights, pending = {}, {}, {}, ""
      local function append(text)
        local batch, batch_clean, batch_highlights = encoding.split_lines(text)
        local offset = #lines
        common.move(batch, 1, #batch, offset + 1, lines)
        common.move(batch_highlights, 1, #batch, offset + 1, highlights)
        for line, value in pairs(batch_clean) do clean[offset + line] = value end
      end
      while true do
        local chunk, err = file:read(1024 * 1024)
        assert(not err, err)
        if not chunk then break end
        chunk = pending .. chunk
        local last = chunk:match(".*()\n")
        if last then append(chunk:sub(1, last)); pending = chunk:sub(last + 1)
        else pending = chunk end
      end
      if pending ~= "" or #lines == 0 then append(pending) end
      assert(file:close())
      print(string.format("LOAD_BATCH_PERF round=%d lines=%d total_ms=%.3f", round, #lines,
        (system.get_time() - start) * 1000))
      test.equal(#lines, 500000)
      coroutine.yield()
    end
  end)

  test.it("separates file reading, line construction, and collection", function()
    local path = os.getenv("ANVIL_LOAD_PERF_FILE")
    if not path then test.skip("set ANVIL_LOAD_PERF_FILE to an isolated fixture") end
    for round = 1, 4 do
      collectgarbage("collect")
      local start = system.get_time()
      local file = assert(io.open(path, "rb"))
      local text = assert(file:read("*a"))
      assert(file:close())
      local read_ms = (system.get_time() - start) * 1000
      local paused = round % 2 == 0
      if paused then collectgarbage("stop") end
      start = system.get_time()
      local ok, lines, clean, highlights = pcall(encoding.split_lines, text)
      local split_ms = (system.get_time() - start) * 1000
      if paused then collectgarbage("restart") end
      assert(ok, lines)
      local count, bytes = #lines, #text
      text, lines, clean, highlights = nil, nil, nil, nil
      start = system.get_time()
      collectgarbage("collect")
      local collect_ms = (system.get_time() - start) * 1000
      print(string.format("LOAD_PERF round=%d gc_paused=%s bytes=%d lines=%d read_ms=%.3f split_ms=%.3f collect_ms=%.3f",
        round, tostring(paused), bytes, count, read_ms, split_ms, collect_ms))
      coroutine.yield()
    end
  end)
end)
