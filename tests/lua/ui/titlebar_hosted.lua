local core = require "core"
local TitleBar = require "core.titlebar"
local RootPanel = require "core.rootpanel"
local test = require "core.test"

test.describe("Hosted Title Bar ownership", function()
  local getter, saved_title
  test.before_each(function()
    getter = system.get_window_controls
    saved_title = core.title_bar
    system.get_window_controls = function() return 640, 0, 160, 40 end
  end)
  test.after_each(function()
    system.get_window_controls = getter
    core.title_bar = saved_title
  end)
  test.it("keeps Tabs and drop targets outside shell controls", function()
    local title = TitleBar()
    title.size.x = 800
    title:update()
    test.ok(title.tab_lane.x + title.tab_lane.w <= 640, "Tabs cover native controls")
    test.equal(title:caption_at(720, 20), nil, "Lua retains a native control target")
    test.equal(title:get_external_drop_target(720, 20), nil, "native controls accept Project drops")
  end)
  test.it("clears Title Bar hover when the pointer leaves the Project", function()
    local title = TitleBar()
    core.title_bar = title
    title.size.x = 800
    title:update()
    local entry = assert(title.entries[1])
    title:on_mouse_moved(entry.x + entry.w / 2, entry.y + entry.h / 2)
    test.ok(title.hovered_entry)
    RootPanel():on_mouse_left()
    test.is_nil(title.hovered_entry)
  end)
end)
