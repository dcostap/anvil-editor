local Buffer = require "core.buffer"
local system = require "system"
local test = require "core.test"

-- Run explicitly. Timings are measurements, not correctness limits.
test.it("measures edits and undo at three positions in a large Buffer", function()
  local buffer = Buffer()
  buffer.lines = {}
  for i = 1, 456328 do
    buffer.lines[i] = string.format("int sqlite_value_%d = 123456789;\n", i)
  end
  for _, line in ipairs { 1, 228164, 456328 } do
    for _, value in ipairs { "x", "\n", "" } do
      local original = buffer.lines[line]
      local edit_ms, undo_ms = 0, 0
      for _ = 1, 3 do
        buffer:clear_undo_redo()
        buffer:set_selection(line, 2, line, value == "" and 3 or 2)
        local before = { table.unpack(buffer.selections) }
        collectgarbage("collect")
        local start = system.get_time()
        buffer:text_input(value)
        edit_ms = edit_ms + (system.get_time() - start) * 1000
        start = system.get_time()
        buffer:undo()
        undo_ms = undo_ms + (system.get_time() - start) * 1000
        test.equal(buffer.lines[line], original)
        test.equal(#buffer.lines, 456328)
        test.same(buffer.selections, before)
      end
      print(string.format("BUFFER_EDIT line=%d text=%q edit_ms=%.3f undo_ms=%.3f",
        line, value, edit_ms / 3, undo_ms / 3))
    end
  end
end)
