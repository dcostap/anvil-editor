local core = require "core"
local NagView = require "core.nagview"
local RootPanel = require "core.rootpanel"
local test = require "core.test"

test.describe("Confirmation card", function()
  local saved
  local nag

  local function long_message(count)
    local lines = {}
    for i = 1, count do lines[i] = "DELETE file C:/Projects/example/output/item-" .. i .. ".bin" end
    return table.concat(lines, "\n")
  end

  test.before_each(function()
    saved = {
      root_panel = core.root_panel,
      active_view = core.active_view,
      nag_view = core.nag_view,
      set_active_view = core.set_active_view,
    }
    local root = RootPanel()
    root.size.x, root.size.y = 1200, 4000
    core.root_panel = root
    core.set_active_view = function(view) core.active_view = view end
    nag = NagView()
    core.nag_view = nag
    nag.position.x, nag.position.y = 0, 0
    nag.size.x, nag.size.y = 1200, 4000
  end)

  test.after_each(function()
    if nag.visible then nag:next() end
    for key, value in pairs(saved) do core[key] = value end
  end)

  test.it("stops growing before it fills a tall Window", function()
    nag:show("Apply", long_message(200), {{text = "Apply", default_yes = true}, {text = "Cancel", default_no = true}})
    local layout = nag:layout()
    test.ok(layout.h < 4000 / 2, "card height " .. layout.h)
  end)

  test.it("scrolls a long message with the mouse wheel, up to its last line", function()
    nag:show("Apply", long_message(200), {{text = "Apply", default_yes = true}, {text = "Cancel", default_no = true}})
    nag:update()
    local view = nag.message_view
    test.equal(view.scroll.to.y, 0)

    test.ok(nag:on_mouse_wheel(-1, 0))
    nag:update()
    test.ok(view.scroll.to.y > 0)

    for _ = 1, 1000 do nag:on_mouse_wheel(-1, 0) end
    nag:update()
    test.equal(view.scroll.to.y, view:get_scrollable_size() - view.size.y)
  end)

  test.it("starts the next dialog at the top of its message", function()
    local options = {{text = "Apply", default_yes = true}, {text = "Cancel", default_no = true}}
    nag:show("First", long_message(200), options)
    nag:show("Second", long_message(200), options)
    nag:update()
    nag:on_mouse_wheel(-5, 0)
    nag:update()
    nag:next()
    nag:update()
    test.equal(nag.message_view.scroll.to.y, 0)
  end)
end)
