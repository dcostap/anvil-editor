local test = require "core.test"

test.describe("Sidebar list actions", function()
  test.it("selects or unloads the clicked Project by stable row identity", function()
    local SidebarView = require "core.sidebar_view"
    local actions = {}
    local view = SidebarView(function(action, row) actions[#actions + 1] = {action, row} end)
    view:set_model({{row_id=7,path="C:/B",state="ready",terminals={}},
                    {row_id=9,path="C:/A",state="dormant",terminals={}}})
    view:on_mouse_pressed("left", 20, view:row_y(2))
    test.same(actions[1], {"select", 9})
    view:on_mouse_pressed("right", 20, view:row_y(1))
    test.same(actions[2], {"unload", 7})
    view:set_model({{row_id=9,path="C:/A",state="starting",terminals={}},
                    {row_id=7,path="C:/B",state="dormant",terminals={}}})
    view:on_mouse_pressed("left", 20, view:row_y(1))
    test.same(actions[3], {"select", 9})
  end)
  test.it("shows Terminal records and Project choices without giving Terminals Project actions", function()
    local SidebarView = require "core.sidebar_view"
    local actions = {}
    local view = SidebarView(function(action, row) actions[#actions + 1] = {action,row} end)
    view:set_model({{row_id=7,path="C:/B",state="closing",close_choice=true,deferred_dialog=true,
      terminals={{id="session",title="shell",cwd="C:/B",busy=1,state="running",attached=false}}}})
    test.equal(#view.rows, 2)
    test.equal(view.rows[1].project.close_choice, true)
    test.equal(view.rows[1].project.deferred_dialog, true)
    test.equal(view.rows[2].terminal.cwd, "C:/B")
    view:on_mouse_pressed("left", 20, view:row_y(2))
    test.equal(#actions, 0)
  end)
end)
