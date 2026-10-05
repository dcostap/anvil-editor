local core = require "core"
local TitleBar = require "core.titlebar"
local test = require "core.test"

test.describe("Hosted Title Bar ownership", function()
  local getter
  test.before_each(function()
    getter = system.get_window_controls
    system.get_window_controls = function() return 640, 0, 160, 40 end
  end)
  test.after_each(function() system.get_window_controls = getter end)
  test.it("keeps Tabs and drop targets outside shell controls", function()
    local title = TitleBar()
    title.size.x = 800
    title:update()
    test.ok(title.tab_lane.x + title.tab_lane.w <= 640, "Tabs cover native controls")
    test.equal(title:caption_at(720, 20), nil, "Lua retains a native control target")
    test.equal(title:get_external_drop_target(720, 20), nil, "native controls accept Project drops")
  end)
end)
