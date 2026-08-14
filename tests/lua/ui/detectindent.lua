local config = require "core.config"
local Buffer = require "core.buffer"
local detectindent = require "plugins.detectindent"
local test = require "core.test"

local function make_buffer(text, syntax)
  local buffer = Buffer("note.md", "note.md", true)
  buffer.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    buffer.lines[#buffer.lines + 1] = line
  end
  buffer.syntax = syntax
  return buffer
end

test.describe("Indent detection", function()
  test.it("excludes complete Markdown fenced blocks from indentation evidence", function()
    local markdown = {
      name = "Markdown",
      -- Inline-code highlighting overlaps fenced-code markers. Indentation
      -- detection must not depend on which highlighting pattern matches first.
      patterns = {
        { pattern = { "`", "`" }, type = "string" },
      },
    }
    local buffer = make_buffer(table.concat({
      "\toutside one",
      "\toutside two",
      "```sql",
      " one",
      "  two",
      "   three",
      " one again",
      "  two again",
      "   three again",
      "```",
      "\toutside three",
      "~~~ text",
      " one",
      "  two",
      "~~",
      "   still fenced",
      "~~~~",
      "\toutside four",
    }, "\n"), markdown)

    local indent_type, indent_size, score = detectindent.detect(buffer)

    test.equal(indent_type, "hard")
    test.equal(indent_size, config.indent_size)
    test.equal(score, 4)
    buffer:on_close()
  end)
end)
