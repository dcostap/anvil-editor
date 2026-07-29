local common = require "core.common"
local style = require "core.style"
local test = require "core.test"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local findfile = require "plugins.findfile"

local function text_call(calls, text)
  for _, call in ipairs(calls) do
    if call.text == text then return call end
  end
end

test.describe("Fuzzy Searcher typography", function()
  test.it("uses prose for paths while retaining monospace metadata", function()
    local calls = {}
    local old_draw_text = renderer.draw_text
    renderer.draw_text = function(font, text, x)
      calls[#calls + 1] = { font = font, text = text, x = x }
      return x + font:get_width(text)
    end

    local ok, err = pcall(function()
      fuzzy_searcher._test.draw_file_result_row(
        style.code_font, "src/example.py", {}, "# ", 10, 0, 500,
        ":42", nil, nil, false
      )
    end)
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end

    test.equal(text_call(calls, "# ").font, style.code_font)
    test.equal(text_call(calls, "src/").font, style.get_small_font(style.prose_font))
    test.equal(text_call(calls, "example.py").font, style.prose_font)
    test.equal(text_call(calls, ":42").font, style.code_font)
  end)

  test.it("draws the File Tree Git change marker beside changed file results", function()
    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    local colors = {}
    renderer.draw_rect = function(_, _, _, _, color)
      colors[#colors + 1] = color
    end
    renderer.draw_text = function(font, text, x)
      return x + font:get_width(text)
    end

    local ok, err = pcall(function()
      fuzzy_searcher._test.draw_file_result_row(
        style.code_font, "src/example.py", {}, "", 10, 0, 500,
        nil, nil, nil, false, "modified"
      )
    end)
    renderer.draw_rect = old_draw_rect
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end

    test.equal(colors[1], style.git_change_modification)
  end)

  test.it("uses prose for Find File suggestions without changing the prompt font", function()
    local call
    local old_draw_text = common.draw_text
    common.draw_text = function(font, color, text)
      call = { font = font, color = color, text = text }
    end

    local ok, err = pcall(function()
      findfile.draw_file_suggestion(
        { text = "src/example.py" }, style.code_font, style.text,
        10, 0, 500, style.code_font:get_height()
      )
    end)
    common.draw_text = old_draw_text
    if not ok then error(err, 0) end

    test.equal(call.font, style.prose_font)
    test.equal(call.text, "src/example.py")
  end)
end)
