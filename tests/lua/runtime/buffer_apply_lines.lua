local Buffer = require "core.buffer"
local test = require "core.test"

local function lines_of(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do lines[#lines + 1] = line end
  return lines
end

local function buffer_with(text)
  local buffer = Buffer(nil, nil, true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  return buffer
end

test.describe("Buffer:apply_lines", function()
  local cases = {
    { "insert at the start", "b\nc", "a\nb\nc" },
    { "insert at the end", "a\nb", "a\nb\nc" },
    { "insert into an empty text", "", "a\nb" },
    { "delete at the start", "a\nb\nc", "b\nc" },
    { "delete at the end", "a\nb\nc", "a\nb" },
    { "delete everything", "a\nb", "" },
    { "replace everything", "one\ntwo", "three\nfour\nfive" },
    { "change one word", "The date is Friday.\nNext", "The date is Monday.\nNext" },
    { "change words on several lines", "a b c\nd e f\ng h i", "a B c\nd e f\ng h I" },
    { "move a block", "1\n2\n3\n4\n5", "4\n5\n1\n2\n3" },
    { "change only the last line", "a\nb", "a\nB" },
    { "add a trailing empty line", "a", "a\n" },
    { "multibyte text", "café crème\nnaïve", "café noir\nnaïve façade" },
  }
  for _, case in ipairs(cases) do
    local name, old_text, new_text = case[1], case[2], case[3]
    test.it("changes the text exactly: " .. name, function()
      local buffer = buffer_with(old_text)
      buffer:apply_lines(lines_of(new_text))
      test.same(buffer.lines, lines_of(new_text))
    end)
  end

  test.it("leaves an equal text unchanged and records no undo step", function()
    local buffer = buffer_with("a\nb")
    local tx = buffer:apply_lines(lines_of("a\nb"))
    test.not_ok(tx.changed)
    test.equal(buffer:get_change_id(), 1)
  end)

  test.it("records one undo step that restores the old text", function()
    local buffer = buffer_with("a\nb\nc")
    buffer:apply_lines(lines_of("x\nb\ny\nz"))
    buffer:undo()
    test.same(buffer.lines, lines_of("a\nb\nc"))
  end)
end)
