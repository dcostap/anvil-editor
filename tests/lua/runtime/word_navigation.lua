local Buffer = require "core.buffer"
local test = require "core.test"
local translate = require "core.buffer.translate"

test.describe("word navigation", function()
  test.it("stops before closing punctuation when moving to the previous word", function()
    local text = '#"fun OutlinedTextField"'
    local buffer = Buffer()
    buffer:text_input(text)

    buffer:move_to(translate.previous_word_start)

    local line, col = buffer:get_selection()
    test.equal(line, 1)
    test.equal(col, #text)
  end)
end)
