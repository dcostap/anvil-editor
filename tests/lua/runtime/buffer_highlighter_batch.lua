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

local function set_test_syntax(buffer)
  buffer.syntax = {
    patterns = { { pattern = "%a+", type = "word" } },
    symbols = {},
  }
end

local function tokens(buffer, line)
  local result = {}
  for _, kind, text in buffer.highlighter:each_token(line) do
    result[#result + 1] = { kind, text }
  end
  return result
end

test.describe("core.buffer.highlighter batch edits", function()
  test.it("updates tokens on an edited line", function()
    local buffer = new_buffer("one\ntwo\nthree")
    set_test_syntax(buffer)
    tokens(buffer, 1)
    tokens(buffer, 2)
    tokens(buffer, 3)

    buffer:insert(2, 1, "changed ")

    test.same(tokens(buffer, 2), {
      { "word", "changed" }, { "word", " two" },
      { "normal", "\n" },
    })
  end)

  test.it("keeps tokens aligned with lines after inserted lines", function()
    local buffer = new_buffer("one\ntwo\nthree")
    set_test_syntax(buffer)
    tokens(buffer, 1)
    tokens(buffer, 2)
    tokens(buffer, 3)

    buffer:insert(1, 1, "zero\n")

    test.same(tokens(buffer, 1), {
      { "word", "zero" }, { "normal", "\n" },
    })
    test.same(tokens(buffer, 3), {
      { "word", "two" }, { "normal", "\n" },
    })
    test.same(tokens(buffer, 4), {
      { "word", "three" }, { "normal", "\n" },
    })
  end)

  test.it("keeps tokens aligned with lines after deleted lines", function()
    local buffer = new_buffer("one\ntwo\nthree\nfour")
    set_test_syntax(buffer)
    for line = 1, 4 do tokens(buffer, line) end

    buffer:remove(2, 1, 3, 1)

    test.same(tokens(buffer, 1), {
      { "word", "one" }, { "normal", "\n" },
    })
    test.same(tokens(buffer, 2), {
      { "word", "three" }, { "normal", "\n" },
    })
    test.same(tokens(buffer, 3), {
      { "word", "four" }, { "normal", "\n" },
    })
  end)
end)
