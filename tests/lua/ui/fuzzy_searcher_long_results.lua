local test = require "core.test"
local style = require "core.style"
local fuzzy = require "plugins.fuzzy_searcher"
local symbol_index = require "core.treesitter.symbol_index"
local file_icons = require "core.file_icons"

test.describe("Text Search long result rows", function()
  local saved, measured, drawn
  test.before_each(function()
    local methods = getmetatable(style.code_font).__index
    saved = { methods = methods, width = methods.get_width,
      text = renderer.draw_text, rect = renderer.draw_rect,
      icon = file_icons.draw, symbol = symbol_index.enclosing_symbol }
    measured, drawn = 0, {}
    methods.get_width = function(font, text, ...)
      measured = measured + #text
      return saved.width(font, text, ...)
    end
    renderer.draw_text = function(font, text, x)
      drawn[#drawn + 1] = text
      return x + font:get_width(text)
    end
    renderer.draw_rect = function() end
    file_icons.draw = function() end
    symbol_index.enclosing_symbol = function() end
  end)
  test.after_each(function()
    saved.methods.get_width = saved.width
    renderer.draw_text, renderer.draw_rect = saved.text, saved.rect
    file_icons.draw, symbol_index.enclosing_symbol = saved.icon, saved.symbol
  end)

  for _, deep in ipairs { false, true } do
    test.it("bounds display work for a " .. (deep and "deep" or "prefix") .. " match", function()
      local function draw(padding)
        local before = deep and string.rep("x", padding) or ""
        local text = before .. "café NEEDLE 世界 " .. string.rep("x", padding)
        local col = #before + #"café " + 1
        local result = { kind = "grep", file = "long.txt", line = 1,
          text = text, col = col, exact = true, grep_query = "NEEDLE",
          content_spans = { { col, col + 5 } } }
        measured, drawn = 0, {}
        fuzzy._test.draw_grep_result_row(style.code_font, result, 0, 0, 1200, false)
        test.equal(result.text, text, "drawing must preserve the source text")
        test.ok(table.concat(drawn):find("NEEDLE", 1, true), "the match must remain visible")
        return measured
      end
      local small = draw(10000)
      local large = draw(160000)
      test.ok(large <= small * 2,
        string.format("offscreen text increased measured bytes from %d to %d", small, large))
    end)
  end
end)
