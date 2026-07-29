local style = require "core.style"
local test = require "core.test"

test.describe("Native text layout", function()
  test.it("maps UTF-8 byte offsets and horizontal positions in one layout", function()
    local font = test.not_nil(style.code_font or style.font)
    local text = "abé cd"
    local layout = font:text_layout(text)
    test.equal(layout:width(), font:get_width(text))
    test.equal(layout:width_at(2), font:get_width("ab"))
    test.equal(layout:width_at(4), font:get_width("abé"))
    test.equal(layout:byte_at_x(layout:width_at(2)), 2)
    test.equal(layout:byte_at_x(layout:width_at(4)), 4)
  end)

  test.it("returns source-preserving word wrap points", function()
    local font = test.not_nil(style.code_font or style.font)
    local text = "alpha beta gamma"
    local layout = font:text_layout(text)
    local breaks = layout:wrap(font:get_width("alpha b"), "word")
    test.same(breaks, { 0, 6, 11 })
    test.equal(text:sub(breaks[2] + 1, breaks[3]), "beta ")
  end)

  test.it("maps monotonically increasing offsets through a retained cursor", function()
    local font = test.not_nil(style.code_font or style.font)
    local text = "alpha βeta gamma"
    local layout = font:text_layout(text)
    local width_at = layout:width_cursor()
    for offset = 0, #text do
      test.equal(width_at(offset), layout:width_at(offset))
    end
    test.equal(width_at(2), layout:width_at(2), "cursor should recover after a backward lookup")
    test.equal(width_at(#text), layout:width())
  end)
end)
