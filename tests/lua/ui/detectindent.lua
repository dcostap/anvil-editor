local config = require "core.config"
local Doc = require "core.doc"
local detectindent = require "plugins.detectindent"
local test = require "core.test"

local function make_doc(text, syntax)
  local doc = Doc("note.md", "note.md", true)
  doc.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    doc.lines[#doc.lines + 1] = line
  end
  doc.syntax = syntax
  return doc
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
    local doc = make_doc(table.concat({
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

    local indent_type, indent_size, score = detectindent.detect(doc)

    test.equal(indent_type, "hard")
    test.equal(indent_size, config.indent_size)
    test.equal(score, 4)
    doc:on_close()
  end)
end)
