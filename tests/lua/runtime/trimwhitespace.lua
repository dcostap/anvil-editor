local Doc = require "core.doc"
local config = require "core.config"
local test = require "core.test"
local trimwhitespace = require "plugins.trimwhitespace"

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

local function text(doc)
  return table.concat(doc.lines)
end

test.describe("trimwhitespace", function()
  test.before_each(function(context)
    context.previous_enabled = config.plugins.trimwhitespace.enabled
    context.previous_trim_empty = config.plugins.trimwhitespace.trim_empty_end_lines
  end)

  test.after_each(function(context)
    config.plugins.trimwhitespace.enabled = context.previous_enabled
    config.plugins.trimwhitespace.trim_empty_end_lines = context.previous_trim_empty
  end)

  test.it("trims trailing whitespace in one document edit", function()
    local doc = Doc()
    set_text(doc, "aa   \nbb\t  \ncc")
    local changes = 0
    function doc:on_text_change()
      changes = changes + 1
    end

    trimwhitespace.trim(doc)

    test.equal(text(doc), "aa\nbb\ncc\n")
    test.equal(changes, 1)
  end)

  test.it("preserves whitespace before the active caret while trimming other lines", function()
    local doc = Doc()
    set_text(doc, "aa   \nbb   ")
    doc:set_selection(1, 5, 1, 5)

    trimwhitespace.trim(doc)

    test.equal(text(doc), "aa  \nbb\n")
    test.same(doc.selections, { 1, 5, 1, 5 })
  end)

  test.it("removes trailing empty lines in one document edit", function()
    local doc = Doc()
    set_text(doc, "aa\n\n\n")
    local changes = 0
    function doc:on_text_change()
      changes = changes + 1
    end

    trimwhitespace.trim_empty_end_lines(doc)

    test.equal(text(doc), "aa\n")
    test.equal(changes, 1)
  end)
end)
