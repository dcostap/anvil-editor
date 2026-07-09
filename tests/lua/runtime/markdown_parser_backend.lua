local test = require "core.test"
local native = require "treesitter"

local function capture_named(captures, name)
  for _, capture in ipairs(captures or {}) do
    if capture.capture == name then return capture end
  end
end

test.describe("Markdown parser backend", function()
  test.it("bundles compatible block and inline Tree-sitter grammars", function()
    test.equal(native.has_language("markdown"), true)
    test.equal(native.has_language("markdown_inline"), true)
    local block = native.language_version("markdown")
    local inlines = native.language_version("markdown_inline")
    test.equal(block.semantic, "0.5.3")
    test.equal(inlines.semantic, "0.5.3")
    test.equal(block.compatible, true)
    test.equal(inlines.compatible, true)
  end)

  test.it("publishes exact split-parser ranges through the native Markdown API", function()
    local tree, err = native.parse_markdown({ "# Hello *world*.\n" }, { timeout_ms = 750 })
    test.not_nil(tree, err)
    local block_query = test.not_nil(native.compile_query("markdown", [[
      (atx_heading
        (atx_h1_marker) @marker
        heading_content: (inline) @content) @heading
    ]]))
    local blocks = test.not_nil(tree:query_blocks(block_query, {
      timeout_ms = 20,
      match_limit = 128,
      max_captures = 128,
    }))
    local marker = capture_named(blocks, "marker")
    local content = capture_named(blocks, "content")
    local heading = capture_named(blocks, "heading")
    test.not_nil(marker)
    test.not_nil(content)
    test.not_nil(heading)
    test.same({ marker.start_line, marker.start_col, marker.end_line, marker.end_col }, { 1, 1, 1, 2 })
    test.same({ content.start_line, content.start_col, content.end_line, content.end_col }, { 1, 3, 1, 17 })
    test.same({ heading.start_byte, heading.end_byte }, { 0, 17 })

    local inline_query = test.not_nil(native.compile_query("markdown_inline", [[
      (emphasis
        (emphasis_delimiter) @delimiter
        (emphasis_delimiter) @delimiter) @emphasis
    ]]))
    local inlines = test.not_nil(tree:query_inlines(inline_query, {
      timeout_ms = 20,
      match_limit = 128,
      max_captures = 128,
    }))
    local emphasis = capture_named(inlines, "emphasis")
    test.not_nil(emphasis)
    test.same({ emphasis.start_line, emphasis.start_col, emphasis.end_line, emphasis.end_col }, { 1, 9, 1, 16 })
    test.equal(emphasis.region_index, 1)
    local delimiters = {}
    for _, capture in ipairs(inlines) do
      if capture.capture == "delimiter" then delimiters[#delimiters + 1] = capture end
    end
    table.sort(delimiters, function(a, b) return a.start_byte < b.start_byte end)
    test.equal(#delimiters, 2)
    test.same({ delimiters[1].start_col, delimiters[1].end_col }, { 9, 10 })
    test.same({ delimiters[2].start_col, delimiters[2].end_col }, { 15, 16 })
    tree:close()
  end)

  test.it("coordinates every prose and table inline region", function()
    local tree, err = native.parse_markdown({
      "# First *span*.\n",
      "Second **span**.\n",
      "\n",
      "| A | B |\n",
      "| - | - |\n",
      "| 1 | 2 |\n",
    }, { timeout_ms = 750 })
    test.not_nil(tree, err)
    local regions = tree:inline_regions()
    test.ok(#regions >= 6)
    local previous_end = 0
    for _, region in ipairs(regions) do
      test.ok(region.start_byte >= previous_end)
      test.ok(region.end_byte > region.start_byte)
      previous_end = region.end_byte
    end
    local query = test.not_nil(native.compile_query("markdown_inline", [[
      [(emphasis) (strong_emphasis)] @span
    ]]))
    local captures = test.not_nil(tree:query_inlines(query, {
      timeout_ms = 20,
      match_limit = 128,
      max_captures = 128,
    }))
    test.equal(#captures, 2)
    test.not_equal(captures[1].region_index, captures[2].region_index)
    tree:close()
  end)
end)
