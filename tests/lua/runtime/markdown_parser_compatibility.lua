local queries = require "core.markdown.queries"
local test = require "core.test"
local native = require "treesitter"

local block_query = test.not_nil(native.compile_query("markdown", queries.block))
local inline_query = test.not_nil(native.compile_query("markdown_inline", queries.inline))

local function parse(lines)
  local tree, err = native.parse_markdown(lines, { timeout_ms = 1000 })
  test.not_nil(tree, err)
  local blocks = test.not_nil(tree:query_blocks(block_query, {
    timeout_ms = 100,
    match_limit = 4096,
    max_captures = 4096,
  }))
  local inlines = test.not_nil(tree:query_inlines(inline_query, {
    timeout_ms = 100,
    match_limit = 4096,
    max_captures = 4096,
  }))
  return tree, table.concat(lines), blocks, inlines
end

local function captures_named(captures, name)
  local result = {}
  for _, capture in ipairs(captures) do
    if capture.capture == name then result[#result + 1] = capture end
  end
  return result
end

local function captured_text(source, capture)
  return source:sub(capture.start_byte + 1, capture.end_byte)
end

test.describe("Markdown parser compatibility fixtures", function()
  test.it("keeps exact UTF-8 byte columns for nested inline syntax", function()
    local tree, source, blocks, inlines = parse({ "# Héllo ***bold italic*** and `code`\n" })
    local heading = captures_named(blocks, "block.heading")[1]
    local strong = captures_named(inlines, "span.strong")[1]
    local emphasis = captures_named(inlines, "span.emphasis")[1]
    local code = captures_named(inlines, "span.code")[1]
    test.equal(captured_text(source, heading), "# Héllo ***bold italic*** and `code`\n")
    test.ok(strong or emphasis)
    test.equal(captured_text(source, code), "`code`")
    for _, capture in ipairs(inlines) do
      test.ok(capture.start_byte >= 0)
      test.ok(capture.end_byte <= #source)
      test.ok(capture.end_byte >= capture.start_byte)
    end
    tree:close()
  end)

  test.it("distinguishes escapes and code from emphasis", function()
    local tree, source, _, inlines = parse({ "\\*escaped* `**code**` **strong**\n" })
    local escapes = captures_named(inlines, "span.escape")
    local strong = captures_named(inlines, "span.strong")
    local code = captures_named(inlines, "span.code")
    test.equal(#escapes, 1)
    test.equal(captured_text(source, escapes[1]), "\\*")
    test.equal(#code, 1)
    test.equal(captured_text(source, code[1]), "`**code**`")
    test.equal(#strong, 1)
    test.equal(captured_text(source, strong[1]), "**strong**")
    tree:close()
  end)

  test.it("source-ranges frontmatter, tasks, tables, and raw HTML blocks", function()
    local lines = {
      "---\n",
      "aliases: [Example]\n",
      "---\n",
      "\n",
      "- [x] Task\n",
      "\n",
      "| A | B |\n",
      "| - | - |\n",
      "| 1 | 2 |\n",
      "\n",
      "<div>**raw**</div>\n",
    }
    local tree, _, blocks, inlines = parse(lines)
    test.equal(#captures_named(blocks, "block.frontmatter"), 1)
    test.equal(#captures_named(blocks, "marker.task.checked"), 1)
    test.equal(#captures_named(blocks, "block.table"), 1)
    test.equal(#captures_named(blocks, "block.html"), 1)
    for _, capture in ipairs(captures_named(inlines, "span.strong")) do
      test.ok(capture.start_line < 11, "raw HTML content must not be parsed as Markdown")
    end
    tree:close()
  end)

  test.it("exposes the upstream Wikilink ambiguity for semantic-layer fallback", function()
    local tree, source, _, inlines = parse({
      "Incomplete **strong\n",
      "[[Note|Alias]] ==highlight== %%comment%%\n",
    })
    test.equal(#captures_named(inlines, "span.strong"), 0)
    test.equal(#captures_named(inlines, "span.link"), 0)
    local references = captures_named(inlines, "span.link_reference")
    test.equal(#references, 1)
    test.equal(captured_text(source, references[1]), "[Note|Alias]")
    test.equal(#captures_named(inlines, "content.link_destination"), 0)
    test.equal(#captures_named(inlines, "span.strikethrough"), 0)
    tree:close()
  end)

  test.it("accepts CRLF snapshots without normalizing byte ranges", function()
    local tree, source, blocks, inlines = parse({ "# Title\r\n", "Text *value*\r\n" })
    local heading = captures_named(blocks, "block.heading")[1]
    local emphasis = captures_named(inlines, "span.emphasis")[1]
    test.equal(captured_text(source, heading), "# Title\r\n")
    test.equal(captured_text(source, emphasis), "*value*")
    test.equal(emphasis.start_line, 2)
    tree:close()
  end)

  test.it("handles delimiter-heavy malformed input without errors", function()
    local parts = {}
    for i = 1, 2000 do parts[i] = (i % 2 == 0) and "*_" or "_*" end
    local tree = parse({ table.concat(parts) .. "\n" })
    tree:close()
  end)
end)
