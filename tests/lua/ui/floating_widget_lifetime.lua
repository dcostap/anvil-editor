local core = require "core"
local test = require "core.test"
local Widget = require "widget"

test.describe("Floating widget lifetime", function()
  test.it("keeps a replacement widget reachable after the previous widget closes", function()
    local previous = Widget()
    local replacement = Widget()
    replacement.visible = true
    local received
    function replacement:on_mouse_wheel(y)
      received = y
      return true
    end
    previous:destroy()
    local ok, err = pcall(function()
      core.root_panel:on_mouse_wheel(3, 0)
      test.equal(received, 3)
    end)
    replacement:destroy()
    if not ok then error(err) end
  end)
end)
