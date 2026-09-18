local test = require "core.test"
local style = require "core.style"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local symbol_index = require "core.treesitter.symbol_index"
local symbol_icons = require "core.symbol_icons"
local file_icons = require "core.file_icons"

local helpers = fuzzy_searcher._test

test.describe("Fuzzy Searcher Text Search context", function()
  local saved

  test.before_each(function()
    saved = {
      enclosing_symbol = symbol_index.enclosing_symbol,
      draw_text = renderer.draw_text,
      draw_rect = renderer.draw_rect,
      draw_canvas = renderer.draw_canvas,
      draw_file_icon = file_icons.draw,
      draw_symbol_icon = symbol_icons.draw,
      file_metadata_parts = fuzzy_searcher.file_metadata_parts,
    }
  end)

  test.after_each(function()
    symbol_index.enclosing_symbol = saved.enclosing_symbol
    renderer.draw_text = saved.draw_text
    renderer.draw_rect = saved.draw_rect
    renderer.draw_canvas = saved.draw_canvas
    file_icons.draw = saved.draw_file_icon
    symbol_icons.draw = saved.draw_symbol_icon
    fuzzy_searcher.file_metadata_parts = saved.file_metadata_parts
  end)

  test.it("draws the enclosing function without parameters at the file column edge", function()
    renderer.draw_canvas = function() end
    local calls = {}
    symbol_index.enclosing_symbol = function(path, line, col, opts)
      test.equal(path, "C:/project/src/parser.lua")
      test.equal(line, 42)
      test.equal(col, 9)
      test.same(opts.kinds, { "function", "method" })
      return {
        name = "parse_expression",
        kind = "function",
        declaration = "Parser::parse_expression(Token token)",
        declaration_name_span = { 9, 24 },
      }
    end
    renderer.draw_text = function(font, text, x, _, color)
      calls[#calls + 1] = { text = text, x = x, color = color }
      return x + font:get_width(text)
    end
    renderer.draw_rect = function() end
    file_icons.draw = function() end
    symbol_icons.draw = function() end

    helpers.draw_grep_result_row(style.font, {
      kind = "grep",
      file = "src/parser.lua",
      abs_path = "C:/project/src/parser.lua",
      line = 42,
      col = 9,
      text = "return parse_expression(token)",
      exact = true,
      grep_query = "parse_expression",
    }, 0, 0, 1400, false)

    local context_call, prefix_call, signature_call
    for _, call in ipairs(calls) do
      if call.text == "parse_expression" then context_call = call; break end
    end
    for _, call in ipairs(calls) do
      if call.text == "Parser::" then prefix_call = call end
      if call.text == "(Token token)" then signature_call = call end
    end
    test.not_nil(context_call, "expected the enclosing function name in the Text Search row")
    test.not_nil(prefix_call, "expected the enclosing function qualifier in the Text Search row")
    test.is_nil(signature_call, "did not expect function parameters in the Text Search row")
    test.equal(context_call.color, style.text)
    test.equal(prefix_call.color, style.dim)
    test.ok(context_call.x > 200, "expected the function context on the right of the file column")
  end)

  test.it("shows file metadata only on the first row of a text match group", function()
    local calls = {}
    renderer.draw_canvas = function() end
    symbol_index.enclosing_symbol = function() end
    renderer.draw_text = function(font, text, x)
      calls[#calls + 1] = { text = text, x = x, right = x + font:get_width(text) }
      return x + font:get_width(text)
    end
    renderer.draw_rect = function() end
    file_icons.draw = function() end
    local row = {
      kind = "grep", file = "example.lua", line = 12, col = 1,
      text = "matched content", file_size = 123456, exact = true,
    }
    local width = 2400
    local line_x = helpers.draw_grep_result_row(style.font, row, 0, 0, width, false)
    local size_text = require("plugins.path_tree").format_file_size(row.file_size)
    local size_call, content_call
    for _, call in ipairs(calls) do
      if call.text == size_text then size_call = call end
      if call.text == row.text then content_call = call end
    end
    test.not_nil(size_call, "expected file size beside the file path")
    test.not_nil(content_call)
    test.ok(size_call.right < content_call.x, "metadata must stay in the file column")
    calls = {}
    helpers.draw_grep_result_row(style.font, row, 0, 0, width, true, line_x)
    for _, call in ipairs(calls) do
      test.ok(call.text ~= size_text, "continuation rows must not repeat file metadata")
    end
  end)

  test.it("keeps enclosing symbols aligned when file metadata is sparse", function()
    local calls = {}
    renderer.draw_canvas = function() end
    renderer.draw_rect = function() end
    file_icons.draw = function() end
    symbol_icons.draw = function() end
    symbol_index.enclosing_symbol = function()
      return {
        name = "WinMain",
        kind = "function",
        declaration = "int __stdcall WinMain()",
        declaration_name_span = { 15, 21 },
      }
    end
    fuzzy_searcher.file_metadata_parts = function(result)
      return result.metadata_parts
    end
    renderer.draw_text = function(font, text, x)
      calls[#calls + 1] = { text = text, x = x }
      return x + font:get_width(text)
    end

    local function draw(metadata_parts)
      calls = {}
      helpers.draw_grep_result_row(style.font, {
        kind = "grep", file = "src/main.cpp", abs_path = "C:/project/src/main.cpp",
        line = 27, col = 1, text = "return WinMain()", exact = true,
        metadata_parts = metadata_parts,
      }, 0, 0, 1400, false)
      local positions = {}
      for _, call in ipairs(calls) do
        if call.text == "WinMain" then positions.symbol = call.x end
        if call.text == "3K" then positions.size = call.x end
      end
      return positions
    end

    local sparse = draw {
      { id = "additions", text = "", sample = "+999" },
      { id = "deletions", text = "", sample = "−999", separator = " " },
      { id = "size", text = "3K", sample = "999M" },
      { id = "age", text = "4h", sample = "99yr" },
    }
    local changed = draw {
      { id = "additions", text = "+27", sample = "+999" },
      { id = "deletions", text = "−58", sample = "−999", separator = " " },
      { id = "size", text = "3K", sample = "999M" },
      { id = "age", text = "4h", sample = "99yr" },
    }
    test.not_nil(sparse.symbol, "expected the sparse enclosing symbol name")
    test.not_nil(changed.symbol, "expected the changed enclosing symbol name")
    test.equal(sparse.symbol, changed.symbol,
      "sparse metadata must not move the enclosing symbol column")
    test.equal(sparse.size, changed.size,
      "sparse metadata must not move the size column")
  end)

  test.it("keeps the full filename and a clear gap before the declaration", function()
    local calls = {}
    local symbol_x
    symbol_index.enclosing_symbol = function()
      return {
        name = "ApplyCollisionAlt",
        kind = "function",
        declaration = "CPhysical::ApplyCollisionAlt(CEntity *B, CColPoint &colpoint, float &impulse)",
        declaration_name_span = { 12, 28 },
      }
    end
    renderer.draw_text = function(font, text, x)
      calls[#calls + 1] = { font = font, text = text, x = x }
      return x + font:get_width(text)
    end
    renderer.draw_rect = function() end
    file_icons.draw = function() end
    symbol_icons.draw = function(_, x)
      symbol_x = x
    end

    helpers.draw_grep_result_row(style.font, {
      kind = "grep",
      file = "src/a/very/long/path/PhysicalCollisionManager.cpp",
      abs_path = "C:/project/src/parser.lua",
      line = 42,
      col = 9,
      text = "return parse_expression(token)",
      exact = true,
      grep_query = "parse_expression",
    }, 0, 0, 1100, false)

    local line_call
    for _, call in ipairs(calls) do
      if call.text:find(":42", 1, true) == 1 then line_call = call; break end
    end
    test.not_nil(line_call, "expected the file line suffix")
    test.not_nil(symbol_x, "expected the declaration symbol icon")
    local filename_call
    for _, call in ipairs(calls) do
      if call.text == "PhysicalCollisionManager.cpp" then filename_call = call; break end
    end
    test.not_nil(filename_call, "expected the complete filename")
    local line_end = line_call.x + line_call.font:get_width(line_call.text)
    test.ok(
      symbol_x - line_end >= style.padding.x * 2,
      "expected two horizontal padding units before the declaration"
    )
  end)
end)
