local test = require "core.test"
local ranges = require "plugins.gitdiff_highlight.ranges"

test.describe("Git Editor change ranges", function()
  test.it("keeps an unequal-line replacement in one change between unchanged lines", function()
    local base = {
      "group = group,\n",
      "working = group.indexedBlocks.any { it.second.pending } ||\n",
      "    (nextBlock == null && conversationStatus.isBusyForUi()),\n",
      "showCompletion = showTimelineCompletion,\n",
      "old final\n",
    }
    local current = {
      "group = group,\n",
      "liveStatus = conversationStatus.takeIf { nextBlock == null && it.isBusyForUi() },\n",
      "showCompletion = showTimelineCompletion,\n",
      "new final\n",
    }
    test.same(ranges.build(base, current), {
      { type = "modification", base_start = 2, base_end = 4, current_start = 2, current_end = 3 },
      { type = "modification", base_start = 5, base_end = 6, current_start = 4, current_end = 5 },
    })
    test.same(ranges.build(current, base), {
      { type = "modification", base_start = 2, base_end = 3, current_start = 2, current_end = 4 },
      { type = "modification", base_start = 4, base_end = 5, current_start = 5, current_end = 6 },
    })
  end)

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
