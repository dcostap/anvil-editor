local test = require "core.test"

local MB = 1024 * 1024

-- Segoe UI Emoji has a 7 MB COLR table. Each copy of a fallback group opens the font again.
local EMOJI_FONT = "C:/Windows/Fonts/seguiemj.ttf"
local COPIES = 24

local function skip_without_memory_report()
  test.skip_if(not system.get_private_memory(), "needs a private memory report")
end

test.describe("renderer memory", function()
  test.it("shares the file data of a font between its copies", function()
    skip_without_memory_report()
    test.skip_if(not system.get_file_info(EMOJI_FONT), "needs Segoe UI Emoji")
    local first = renderer.font.load(EMOJI_FONT, 14)
    collectgarbage()
    local before = system.get_private_memory()

    local fonts = {}
    for i = 1, COPIES do fonts[i] = first:copy(10 + i) end
    local growth = system.get_private_memory() - before

    test.equal(#fonts, COPIES)
    test.ok(growth < COPIES * MB, string.format(
      "%d copies added %.1f MB of private memory", COPIES, growth / MB
    ))
  end)

  test.it("keeps a new window's software surface out of RAM until it draws", function()
    skip_without_memory_report()
    collectgarbage()
    local before = system.get_private_memory()

    -- The software surface of a 2560x1440 window holds 14 MB of pixels.
    local window = renwindow.create("renderer-memory-window", 2560, 1440)
    local growth = system.get_private_memory() - before

    test.not_nil(window)
    test.ok(growth < 4 * MB, string.format(
      "a new window added %.1f MB of private memory", growth / MB
    ))
  end)
end)
