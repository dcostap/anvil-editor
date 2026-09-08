local test = require "core.test"
local ranges = require "plugins.gitdiff_highlight.ranges"

test.describe("Git Editor change ranges", function()
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
