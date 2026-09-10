local test = require "core.test"
local ranges = require "plugins.gitdiff_highlight.ranges"

test.describe("Git Editor change ranges", function()
  test.it("keeps distant edits separate across a long unchanged block", function()
    local base, current = { "old first\n" }, { "new first\n" }
    for line = 2, 1600 do
      base[line] = "unchanged line " .. line .. "\n"
      current[line] = base[line]
    end
    base[1601], current[1601] = "old last\n", "new last\n"
    local built, meta = ranges.build(base, current)
    test.ok(not meta.too_large)
    test.same(built, {
      { type = "modification", base_start = 1, base_end = 2, current_start = 1, current_end = 2 },
      { type = "modification", base_start = 1601, base_end = 1602, current_start = 1601, current_end = 1602 },
    })
  end)

  test.test("classifies text added to an empty file as an addition", function()
    local built = ranges.build(
      ranges.split_buffer_lines(""),
      ranges.split_buffer_lines("new\n")
    )
    test.equal(#built, 1)
    test.equal(built[1].type, "addition")
    test.equal(built[1].current_start, 1)
    test.equal(built[1].current_end, 2)
  end)

  test.test("classifies the last line removed from a file as a deletion", function()
    local built = ranges.build(
      ranges.split_buffer_lines("old\n"),
      ranges.split_buffer_lines("")
    )
    test.equal(#built, 1)
    test.equal(built[1].type, "deletion")
    test.equal(built[1].current_start, 1)
    test.equal(built[1].current_end, 1)
  end)

  test.test("keeps CRLF and missing-final-newline content equivalent", function()
    local built = ranges.build(
      ranges.split_buffer_lines("one\r\ntwo"),
      ranges.split_buffer_lines("one\ntwo\n")
    )
    test.equal(#built, 0)
  end)
end)
