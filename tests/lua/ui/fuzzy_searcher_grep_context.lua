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
      draw_file_icon = file_icons.draw,
      draw_symbol_icon = symbol_icons.draw,
    }
  end)

  test.after_each(function()
    symbol_index.enclosing_symbol = saved.enclosing_symbol
    renderer.draw_text = saved.draw_text
    renderer.draw_rect = saved.draw_rect
    file_icons.draw = saved.draw_file_icon
    symbol_icons.draw = saved.draw_symbol_icon
  end)

  test.it("draws the enclosing function without parameters at the file column edge", function()
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
