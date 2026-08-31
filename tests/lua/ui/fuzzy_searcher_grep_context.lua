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

  test.it("draws the enclosing function at the right edge of the file column", function()
    local calls = {}
    symbol_index.enclosing_symbol = function(path, line, col, opts)
      test.equal(path, "C:/project/src/parser.lua")
      test.equal(line, 42)
      test.equal(col, 9)
      test.same(opts.kinds, { "function", "method" })
      return { name = "parse_expression", kind = "function" }
    end
    renderer.draw_text = function(font, text, x)
      calls[#calls + 1] = { text = text, x = x }
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
    }, 0, 0, 900, false)

    local context_call
    for _, call in ipairs(calls) do
      if call.text == "parse_expression" then context_call = call; break end
    end
    test.not_nil(context_call, "expected the enclosing function name in the Text Search row")
    test.ok(context_call.x > 200, "expected the function context on the right of the file column")
  end)
end)
