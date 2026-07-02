local test = require "core.test"
local model = require "plugins.diff.model"

local function lines(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do out[#out + 1] = line end
  if #out == 0 then out[1] = "\n" end
  return out
end

test.describe("DiffModel", function()
  test.it("computes equal text", function()
    local m = model.compute(lines("a\nb"), lines("a\nb"))
    test.equal(m:line_state("a", 1), "equal")
    test.equal(#m.equal_blocks, 1)
    test.equal(m:map_line("a", 2), 2)
  end)

  test.it("computes insert and delete hunks with line mapping", function()
    local m = model.compute(lines("aa\nbb"), lines("aa\ninserted\nbb"))
    test.equal(m:line_state("b", 2), "insert")
    test.equal(m.b_gaps[2][2], 0)
    test.equal(m.a_gaps[2][2], 1)
    test.equal(m:map_line("a", 2), 3)
    test.equal(m:map_line("b", 3), 2)

    local hunk = m:hunk_at("b", 2)
    test.same({ hunk.tag, hunk.start_line, hunk.end_line }, { "insert", 2, 2 })
  end)

  test.it("computes modify hunks with inline ranges", function()
    local m = model.compute(lines("cat"), lines("cot"))
    test.equal(m:line_state("a", 1), "modify")
    local ranges = m:inline_ranges("a", 1)
    test.ok(type(ranges) == "table" and #ranges > 0, "expected inline ranges")
    test.equal(m:next_hunk("a", 1, 1).tag, "modify")
  end)

  test.it("emits long unchanged fold candidates", function()
    local left, right = {}, {}
    for i = 1, 20 do left[i], right[i] = "same " .. i .. "\n", "same " .. i .. "\n" end
    left[10], right[10] = "old\n", "new\n"
    local m = model.compute(left, right)
    test.ok(#m.equal_blocks >= 2, "expected equal blocks around the change")
    test.equal(m.equal_blocks[1].has_next_change, true)
    test.equal(m.equal_blocks[2].has_prev_change, true)
  end)
end)
