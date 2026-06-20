local Doc = require "core.doc"
local test = require "core.test"

local function set_text(doc, text)
  doc.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    doc.lines[#doc.lines + 1] = line
  end
  if #doc.lines == 0 then doc.lines[1] = "\n" end
  doc:clear_undo_redo()
  doc:clean()
  doc:set_selection(1, 1)
end

local function new_doc(text)
  local doc = Doc()
  set_text(doc, text or "")
  return doc
end

local function cached_line(text, state)
  return { text = text, state = state, tokens = { "normal", text } }
end

test.describe("core.doc.highlighter batch edits", function()
  test.it("keeps cached token lines before the edited line", function()
    local doc = new_doc("one\ntwo\nthree")
    local line1 = cached_line("one\n", "s1")
    local line3 = cached_line("three\n", "s3")
    doc.highlighter.lines = {
      line1,
      cached_line("two\n", "s2"),
      line3,
    }
    doc.highlighter.first_invalid_line = 4

    doc:insert(2, 1, "changed ")

    test.equal(doc.highlighter.lines[1], line1)
    test.equal(doc.highlighter.lines[2], false)
    test.equal(doc.highlighter.lines[3], line3)
    test.equal(doc.highlighter.first_invalid_line, 2)
  end)

  test.it("shifts cached token lines below inserted lines", function()
    local doc = new_doc("one\ntwo\nthree")
    local old_line2 = cached_line("two\n", "s2")
    local old_line3 = cached_line("three\n", "s3")
    doc.highlighter.lines = {
      cached_line("one\n", "s1"),
      old_line2,
      old_line3,
    }
    doc.highlighter.first_invalid_line = 4

    doc:insert(1, 1, "zero\n")

    test.equal(doc.highlighter.lines[1], false)
    test.equal(doc.highlighter.lines[2], false)
    test.equal(doc.highlighter.lines[3], old_line2)
    test.equal(doc.highlighter.lines[4], old_line3)
    test.equal(doc.highlighter.first_invalid_line, 1)
  end)

  test.it("splices cached token lines across deleted lines", function()
    local doc = new_doc("one\ntwo\nthree\nfour")
    local old_line1 = cached_line("one\n", "s1")
    local old_line4 = cached_line("four\n", "s4")
    doc.highlighter.lines = {
      old_line1,
      cached_line("two\n", "s2"),
      cached_line("three\n", "s3"),
      old_line4,
    }
    doc.highlighter.first_invalid_line = 5

    doc:remove(2, 1, 3, 1)

    test.equal(doc.highlighter.lines[1], old_line1)
    test.equal(doc.highlighter.lines[2], false)
    test.equal(doc.highlighter.lines[3], old_line4)
    test.equal(doc.highlighter.first_invalid_line, 2)
  end)
end)
