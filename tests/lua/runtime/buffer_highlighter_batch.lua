local Buffer = require "core.buffer"
local test = require "core.test"

local function set_text(buffer, text)
  buffer.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    buffer.lines[#buffer.lines + 1] = line
  end
  if #buffer.lines == 0 then buffer.lines[1] = "\n" end
  buffer:clear_undo_redo()
  buffer:clean()
  buffer:set_selection(1, 1)
end

local function new_buffer(text)
  local buffer = Buffer()
  set_text(buffer, text or "")
  return buffer
end

local function cached_line(text, state)
  return { text = text, state = state, tokens = { "normal", text } }
end

test.describe("core.buffer.highlighter batch edits", function()
  test.it("keeps cached token lines before the edited line", function()
    local buffer = new_buffer("one\ntwo\nthree")
    local line1 = cached_line("one\n", "s1")
    local line3 = cached_line("three\n", "s3")
    buffer.highlighter.lines = {
      line1,
      cached_line("two\n", "s2"),
      line3,
    }
    buffer.highlighter.first_invalid_line = 4

    buffer:insert(2, 1, "changed ")

    test.equal(buffer.highlighter.lines[1], line1)
    test.equal(buffer.highlighter.lines[2], false)
    test.equal(buffer.highlighter.lines[3], line3)
    test.equal(buffer.highlighter.first_invalid_line, 2)
  end)

  test.it("shifts cached token lines below inserted lines", function()
    local buffer = new_buffer("one\ntwo\nthree")
    local old_line2 = cached_line("two\n", "s2")
    local old_line3 = cached_line("three\n", "s3")
    buffer.highlighter.lines = {
      cached_line("one\n", "s1"),
      old_line2,
      old_line3,
    }
    buffer.highlighter.first_invalid_line = 4

    buffer:insert(1, 1, "zero\n")

    test.equal(buffer.highlighter.lines[1], false)
    test.equal(buffer.highlighter.lines[2], false)
    test.equal(buffer.highlighter.lines[3], old_line2)
    test.equal(buffer.highlighter.lines[4], old_line3)
    test.equal(buffer.highlighter.first_invalid_line, 1)
  end)

  test.it("splices cached token lines across deleted lines", function()
    local buffer = new_buffer("one\ntwo\nthree\nfour")
    local old_line1 = cached_line("one\n", "s1")
    local old_line4 = cached_line("four\n", "s4")
    buffer.highlighter.lines = {
      old_line1,
      cached_line("two\n", "s2"),
      cached_line("three\n", "s3"),
      old_line4,
    }
    buffer.highlighter.first_invalid_line = 5

    buffer:remove(2, 1, 3, 1)

    test.equal(buffer.highlighter.lines[1], old_line1)
    test.equal(buffer.highlighter.lines[2], false)
    test.equal(buffer.highlighter.lines[3], old_line4)
    test.equal(buffer.highlighter.first_invalid_line, 2)
  end)
end)
