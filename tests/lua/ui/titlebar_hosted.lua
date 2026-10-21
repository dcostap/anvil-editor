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
  test.it("shows Tabs only while the Project Sidebar is hidden", function()
    local panes = require "core.panes"
    local content_x = system.get_window_content_x
    local sidebar_width = 240
    system.get_window_content_x = function() return sidebar_width end
    local ok, err = pcall(function()
      local title = TitleBar()
      title.size.x = 800
      title:update()
      test.ok(panes.count() > 0)
      test.is_nil(next(title.entries), "the Title Bar shows Tabs beside the Project Sidebar")
      sidebar_width = 0
      title:update()
      test.not_nil(title.entries[1], "the Title Bar hides Tabs without the Project Sidebar")
    end)
    system.get_window_content_x = content_x
    assert(ok, err)
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
  test.it("asks the shell to toggle the Project Sidebar from the start of the Title Bar", function()
    local hosted, toggle, hit_test = system.is_hosted_surface, system.toggle_project_sidebar, system.set_window_hit_test
    local requests, ranges = 0, nil
    system.is_hosted_surface = function() return true end
    system.toggle_project_sidebar = function() requests = requests + 1; return true end
    system.set_window_hit_test = function(_, _, _, _, x, w, x2, w2) ranges = {{x, w}, {x2, w2}} end
    local ok, err = pcall(function()
      local title = TitleBar()
      core.title_bar = title
      title.size.x = 800
      title:update()
      local x, y = title.position.x + 4, title.position.y + title.size.y / 2
      local interactive = false
      for _, range in ipairs(ranges or {}) do
        interactive = interactive or (x >= range[1] and x < range[1] + range[2])
      end
      test.ok(interactive, "the Sidebar toggle drags the Window instead of taking clicks")
      title:on_mouse_moved(x, y)
      test.ok(title:on_mouse_pressed("left", x, y, 1))
      title:on_mouse_released("left", x, y)
      test.equal(requests, 1)
    end)
    system.is_hosted_surface, system.toggle_project_sidebar, system.set_window_hit_test = hosted, toggle, hit_test
    assert(ok, err)
  end)
end)
