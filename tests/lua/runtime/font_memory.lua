local test = require "core.test"

-- Segoe UI Emoji has a 7 MB COLR table. Each copy of a fallback group opens the font again.
local EMOJI_FONT = "C:/Windows/Fonts/seguiemj.ttf"
local COPIES = 24

test.describe("font memory", function()
  test.it("shares the file data of a font between its copies", function()
    test.skip_if(not system.get_private_memory() or not system.get_file_info(EMOJI_FONT),
      "needs Windows and Segoe UI Emoji")
    local first = renderer.font.load(EMOJI_FONT, 14)
    collectgarbage()
    local before = system.get_private_memory()

    local fonts = {}
    for i = 1, COPIES do fonts[i] = first:copy(10 + i) end
    local growth = system.get_private_memory() - before

    test.equal(#fonts, COPIES)
    test.ok(growth < COPIES * 1024 * 1024, string.format(
      "%d copies added %.1f MB of private memory", COPIES, growth / (1024 * 1024)
    ))
  end)
end)
