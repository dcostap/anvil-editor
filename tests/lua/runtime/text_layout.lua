local common = require "core.common"
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

  test.it("wraps UTF-8 directly without retaining a text layout", function()
    local font = test.not_nil(style.code_font or style.font)
    local cell = font:get_width(" ")
    local text = "é aa aa aa aa"
    local breaks = font:wrap_text(
      text, cell * 5, "word", 0, #text, 0, 0, cell, cell * 2
    )

    test.same(breaks, { 0, 6, 9 })
    for _, byte_offset in ipairs(breaks) do
      test.ok(
        byte_offset == #text
          or not common.is_utf8_cont(text, byte_offset + 1),
        "wrap points must remain on UTF-8 boundaries"
      )
    end
  end)

  test.it("honors direct-wrap byte ranges and continuation leading width", function()
    local font = test.not_nil(style.code_font or style.font)
    local cell = font:get_width(" ")
    local text = "xxéééé\nignored"
    local breaks = font:wrap_text(
      text, cell * 3, "letter", 2, 10, cell, cell, cell, cell * 2
    )

    test.same(breaks, { 2, 6 })
  end)

  test.it("preserves standalone shaping for combining marks", function()
    local font = test.not_nil(style.code_font or style.font)
    local cell = font:get_width(" ")
    local text = "éabc"
    local breaks = font:wrap_text(
      text, cell * 2, "letter", 0, #text, 0, 0, cell, cell * 2
    )

    test.same(breaks, { 0, 4 })
  end)

  test.it("advances safely across malformed and truncated UTF-8", function()
    local font = test.not_nil(style.code_font or style.font)
    local cell = font:get_width(" ")
    local malformed = "a" .. string.char(0xc3) .. "b"

    test.same(font:wrap_text(
      malformed, cell * 0.5, "letter", 0, #malformed,
      0, 0, cell, cell * 2
    ), { 0, 1, 2 })
    test.same(font:wrap_text(
      string.char(0xc3), cell, "letter"
    ), { 0 })
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
