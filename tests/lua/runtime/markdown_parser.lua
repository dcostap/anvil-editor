local parser = require "core.markdown.parser"
local anchors = require "core.markdown.anchors"
local test = require "core.test"

test.describe("Markdown shared parser", function()
  test.it("parses headings with source ranges", function()
    local parsed = parser.parse("## Heading **strong**\n\nBody")
    local heading = parsed.blocks[1]
    test.equal(heading.type, "heading")
    test.equal(heading.level, 2)
    test.equal(heading.line1, 1)
    test.equal(heading.marker_col1, 1)
    test.equal(heading.marker_col2, 3)
    test.equal(heading.content_col1, 4)
    test.equal(heading.content_col2, 22)
    test.equal(heading.text, "Heading **strong**")
    test.equal(heading.inline[1].type, "strong")
    test.equal(heading.inline[1].col1, 12)
    test.equal(heading.inline[1].col2, 22)
  end)

  test.it("parses emphasis, code, Markdown images, and wikilinks with ranges", function()
    local parsed = parser.parse("Paragraph with **bold**, *italic*, `code`, [link](target.md), ![Alt](image.png), and [[Note|Alias]].")
    local paragraph = parsed.blocks[1]
    local by_type = {}
    for _, span in ipairs(paragraph.inline) do
      by_type[span.type] = span
    end
    test.equal(by_type.strong.text, "bold")
    test.equal(by_type.emphasis.text, "italic")
    test.equal(by_type.code.text, "code")
    test.equal(by_type.link.link.raw_target, "target.md")
    test.equal(by_type.image.link.raw_target, "image.png")
    test.equal(by_type.wiki.link.raw_target, "Note")
    test.equal(by_type.wiki.link.alias, "Alias")
  end)

  test.it("does not report links inside code spans or escaped links", function()
    local spans = parser.parse_inline("`[not a link](target.md)` and \\[not](target.md)", 1)
    local code_count = 0
    local link_count = 0
    for _, span in ipairs(spans) do
      if span.type == "code" then code_count = code_count + 1 end
      if span.type == "link" then link_count = link_count + 1 end
    end
    test.equal(code_count, 1)
    test.equal(link_count, 0)
  end)

  test.it("indexes heading anchors and block ids", function()
    local parsed = parser.parse("# Repeated Heading\n\n## Repeated Heading\n\nA block ^quote-of-the-day\nSee [[^not-a-definition]]")
    local index = anchors.index_document(parsed)
    test.equal(index.headings[1].slug, "repeated-heading")
    test.equal(index.headings[2].slug, "repeated-heading-1")
    test.equal(#index.blocks, 1)
    test.equal(index.blocks[1].id, "quote-of-the-day")
    test.equal(index.blocks[1].line, 5)
  end)
end)
