local links = require "core.markdown.links"
local test = require "core.test"

test.describe("Markdown link parsing", function()
  test.it("parses wikilinks with aliases and exact ranges", function()
    local found = links.find_links("See [[Note#Heading|Alias]] now", 3)
    test.equal(#found, 1)
    test.equal(found[1].kind, "wiki")
    test.equal(found[1].source_line, 3)
    test.equal(found[1].source_col1, 5)
    test.equal(found[1].source_col2, 27)
    test.equal(found[1].raw_target, "Note#Heading")
    test.equal(found[1].path, "Note")
    test.equal(found[1].subtarget.type, "heading")
    test.equal(found[1].subtarget.text, "Heading")
    test.equal(found[1].alias, "Alias")
  end)

  test.it("parses current-note heading and block links", function()
    local heading = links.find_links("[[#Local Heading]]", 1)[1]
    test.equal(heading.path, "")
    test.equal(heading.subtarget.type, "heading")
    test.equal(heading.subtarget.text, "Local Heading")

    local block = links.find_links("[[^quote-of-the-day]]", 1)[1]
    test.equal(block.path, "")
    test.equal(block.subtarget.type, "block")
    test.equal(block.subtarget.id, "quote-of-the-day")
  end)

  test.it("parses embed resize syntax", function()
    local image = links.find_links("![[image.png|640x480]] and ![[icon.png|100]]", 1)
    test.equal(#image, 2)
    test.equal(image[1].kind, "embed")
    test.equal(image[1].is_embed, true)
    test.equal(image[1].path, "image.png")
    test.equal(image[1].resize.width, 640)
    test.equal(image[1].resize.height, 480)
    test.equal(image[2].resize.width, 100)
    test.equal(image[2].resize.height, nil)
  end)

  test.it("reads an escaped pipe as the alias separator, as tables need", function()
    local found = links.find_links("| [[Note\\|Alias]] | ![[pic.png\\|Alt\\|200]] |", 1)
    test.equal(#found, 2)
    test.equal(found[1].path, "Note")
    test.equal(found[1].alias, "Alias")
    test.equal(found[2].path, "pic.png")
    test.equal(found[2].alias, "Alt")
    test.equal(found[2].resize.width, 200)
  end)

  test.it("adopts exact semantic Wikilink and image ranges", function()
    local text = "[[Note#Head|Alias]] ![Alt|100x145](image.png)"
    local wiki = test.not_nil(links.from_semantic_node(text, 1, {
      id = "wiki:1", type = "wiki_link",
      source = { line1 = 1, line2 = 1, col1 = 1, col2 = 20 },
      attributes = {
        target = { col1 = 3, col2 = 12 },
        alias = { col1 = 13, col2 = 18 },
      },
    }))
    test.equal(wiki.path, "Note")
    test.equal(wiki.subtarget.text, "Head")
    test.equal(wiki.display, "Alias")
    test.equal(wiki.semantic_id, "wiki:1")

    local image = test.not_nil(links.from_semantic_node(text, 1, {
      id = "image:1", type = "image",
      source = { line1 = 1, line2 = 1, col1 = 21, col2 = #text + 1 },
      attributes = {
        image_alt = { col1 = 23, col2 = 34 },
        link_destination = { col1 = 36, col2 = 45 },
      },
    }))
    test.equal(image.path, "image.png")
    test.equal(image.alt, "Alt")
    test.equal(image.resize.width, 100)
    test.equal(image.resize.height, 145)
  end)

  test.it("distinguishes empty and omitted semantic Wikilink aliases", function()
    local empty = test.not_nil(links.from_semantic_node("[[Note|]]", 1, {
      id = "wiki:empty", type = "wiki_link",
      source = { line1 = 1, line2 = 1, col1 = 1, col2 = 10 },
      attributes = { target = { col1 = 3, col2 = 7 } },
    }))
    local omitted = test.not_nil(links.from_semantic_node("[[Note]]", 1, {
      id = "wiki:omitted", type = "wiki_link",
      source = { line1 = 1, line2 = 1, col1 = 1, col2 = 9 },
      attributes = { target = { col1 = 3, col2 = 7 } },
    }))
    test.equal(empty.alias, "")
    test.equal(omitted.alias, nil)
  end)

  test.it("preserves an explicitly empty semantic Markdown label", function()
    local text = "[](folder/target.md)"
    local target_col = test.not_nil(text:find("folder", 1, true))
    local link = test.not_nil(links.from_semantic_node(text, 1, {
      id = "empty:1", type = "link",
      source = { line1 = 1, line2 = 1, col1 = 1, col2 = #text + 1 },
      attributes = {
        link_destination = { col1 = target_col, col2 = #text },
      },
    }))
    test.equal(link.alias, "")
    test.equal(link.display, "")
    test.equal(link.path, "folder/target.md")
  end)

  test.it("treats a numeric external image label as width rather than alt text", function()
    local found = test.not_nil(links.find_links("![250](image.png)", 1)[1])
    test.equal(found.kind, "image")
    test.equal(found.alt, nil)
    test.equal(found.resize.width, 250)

    local semantic = test.not_nil(links.from_semantic_node("![250](image.png)", 1, {
      id = "image-width", type = "image",
      source = { line1 = 1, col1 = 1, line2 = 1, col2 = 18 },
      attributes = {
        image_alt = { col1 = 3, col2 = 6 },
        link_destination = { col1 = 8, col2 = 17 },
      },
    }))
    test.equal(semantic.alt, nil)
    test.equal(semantic.resize.width, 250)
  end)

  test.it("parses Markdown links and image resize syntax", function()
    local found = links.find_links("[Alias](target.md#Heading) ![Alt|100x145](image.png)", 7)
    test.equal(#found, 2)
    test.equal(found[1].kind, "markdown")
    test.equal(found[1].path, "target.md")
    test.equal(found[1].subtarget.type, "heading")
    test.equal(found[1].subtarget.text, "Heading")
    test.equal(found[1].alias, "Alias")
    test.equal(found[2].kind, "image")
    test.equal(found[2].alt, "Alt")
    test.equal(found[2].resize.width, 100)
    test.equal(found[2].resize.height, 145)
  end)
end)

test.describe("Markdown image width in source", function()
  test.it("sets, replaces and removes the width as the label's last part", function()
    local cases = {
      { "![[photo.png]]", 300, "![[photo.png|300]]" },
      { "![[photo.png|Alt]]", 300, "![[photo.png|Alt|300]]" },
      { "![[photo.png|Alt|120]]", 300, "![[photo.png|Alt|300]]" },
      { "![[photo.png|120x80]]", 300, "![[photo.png|300]]" },
      { "![[photo.png|Alt|120]]", nil, "![[photo.png|Alt]]" },
      { "![[photo.png|120]]", nil, "![[photo.png]]" },
      { "![Alt](photo.png \"Title\")", 300, "![Alt|300](photo.png \"Title\")" },
      { "![](photo.png)", 300, "![300](photo.png)" },
      { "![Alt|120x80](photo.png)", nil, "![Alt](photo.png)" },
      { "![120](photo.png)", nil, "![](photo.png)" },
      { "![[photo.png\\|120]]", 300, "![[photo.png\\|300]]" },
      { "![[photo.png\\|Alt]]", 300, "![[photo.png\\|Alt\\|300]]" },
      { "![[photo.png\\|Alt\\|120]]", nil, "![[photo.png\\|Alt]]" },
    }
    for _, case in ipairs(cases) do
      test.equal(links.with_image_width(case[1], case[2]), case[3], case[1])
    end
  end)

  test.it("rejects text that is not one complete image link", function()
    test.equal(links.with_image_width("[Alt](photo.png)", 300), nil)
    test.equal(links.with_image_width("[[photo.png]]", 300), nil)
    test.equal(links.with_image_width("![Alt][photo]", 300), nil)
    test.equal(links.with_image_width("![[photo.png]] more", 300), nil)
  end)

  test.it("reads the width that it writes after an alias", function()
    local wiki = links.find_links("![[photo.png|Alt|300]]", 1)[1]
    test.equal(wiki.alias, "Alt")
    test.equal(wiki.resize.width, 300)
    local image = links.find_links("![A|B|300](photo.png)", 1)[1]
    test.equal(image.alt, "A|B")
    test.equal(image.resize.width, 300)
  end)

  test.it("finds the target of an image link", function()
    test.same({ links.image_target_range("![[photo.png|Alt|300]]") }, { 4, 13 })
    test.same({ links.image_target_range("![Alt](<my photo.png> \"t\")") }, { 9, 21 })
    test.same({ links.image_target_range("![Alt](photo.png)") }, { 8, 17 })
    test.equal(links.image_target_range("[Alt](photo.png)"), nil)
  end)
end)
