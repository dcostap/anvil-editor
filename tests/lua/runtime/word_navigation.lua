local Buffer = require "core.buffer"
local test = require "core.test"
local translate = require "core.buffer.translate"

test.describe("word navigation", function()
  test.it("stops on both sides of opening punctuation when moving forward", function()
    local buffer = Buffer()
    buffer:text_input("fun repartoPorProyecto(input: MovimientoStock.InputExterno, CAS_partidaVenta: Int) {")
    buffer:set_selection(1, 5)

    for _, expected_col in ipairs({ 23, 24, 29 }) do
      buffer:move_to(translate.next_word_end)
      local line, col = buffer:get_selection()
      test.equal(line, 1)
      test.equal(col, expected_col)
    end
  end)

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
