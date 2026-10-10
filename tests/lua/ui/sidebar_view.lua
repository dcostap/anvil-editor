local test = require "core.test"

test.describe("Sidebar list actions", function()
  test.it("offers explicit target Windows for a loaded Project Move", function()
    local SidebarView = require "core.sidebar_view"
    local actions = {}
    local view = SidebarView(function(...) actions[#actions + 1] = {...} end)
    view:set_model({{row_id=7,id=31,path="C:/A",state="ready",window_id=5,terminals={}},
      windows={{id=5,selected_project=31},{id=8,selected_project=0},{id=9,selected_project=44}}}, 8)
    -- Right-click opens Move choices. It does not move or unload the Project.
    view:on_mouse_pressed("right", 20, view:row_y(1), 240)
    test.equal(#actions, 0)
    test.equal(#view.rows, 3)
    view:on_mouse_pressed("left", 20, view:row_y(3), 240)
    test.same(actions, {{"move", 31, 9}})
    test.equal(#view.rows, 1)
  end)
  test.it("keeps Move choices across Sidebar updates while the Project keeps its owner", function()
    local SidebarView = require "core.sidebar_view"
    local actions = {}
    local view = SidebarView(function(...) actions[#actions + 1] = {...} end)
    local function model(busy, owner, state)
      return {{row_id=7,id=31,path="C:/A",state=state or "ready",window_id=owner,
        terminals={{id="session",title="shell",cwd="C:/A",busy=busy,state="running"}}},
        windows={{id=5,selected_project=31},{id=9,selected_project=0}}}
    end
    view:set_model(model(0, 5), 9)
    view:on_mouse_pressed("right", 20, view:row_y(1), 240)
    -- A Terminal busy change is a new revision. The open choices must stay under the cursor.
    view:set_model(model(1, 5), 9)
    test.equal(#view.rows, 3)
    view:on_mouse_pressed("left", 20, view:row_y(3), 240)
    test.same(actions, {{"move", 31, 9}})
    -- A changed owner or an unloaded Project invalidates the choices.
    view:on_mouse_pressed("right", 20, view:row_y(1), 240)
    view:set_model(model(1, 9), 9)
    test.equal(#view.rows, 2)
    view:set_model(model(1, 9), 9)
    test.equal(#view.rows, 2, "Choices reopened after the owner changed")
    view:on_mouse_pressed("right", 20, view:row_y(1), 240)
    view:set_model(model(1, 0, "dormant"), 9)
    test.equal(#view.rows, 2)
  end)
  test.it("highlights each Window's Selected Project and shows its owning Window", function()
    -- Seam: public model input and renderer output. Both Views share one snapshot.
    local SidebarView = require "core.sidebar_view"
    local style = require "core.style"
    local model = {
      {row_id=1,id=11,path="C:/A",state="ready",window_id=7,terminals={}},
      {row_id=2,id=22,path="C:/B",state="ready",window_id=9,terminals={}},
      windows={{id=7,selected_project=11},{id=9,selected_project=22}},
    }
    local a, b = SidebarView(function() end), SidebarView(function() end)
    a:set_model(model, 7); b:set_model(model, 9)
    local old_rect, old_text, old_clip = renderer.draw_rect, renderer.draw_text, renderer.set_clip_rect
    local function draw(view)
      local selected_y, selected_title, labels = nil, nil, {}
      renderer.draw_rect = function(_, y, _, _, color) if color == style.selection then selected_y = y end end
      renderer.draw_text = function(_, text, _, y)
        if y == selected_y then selected_title = text end
        labels[#labels + 1] = text
      end
      renderer.set_clip_rect = function() end
      view:draw(600, 1000)
      return selected_title, table.concat(labels, "\n")
    end
    local ok, err = pcall(function()
      local title, labels = draw(a)
      test.equal(title, "A")
      test.ok(labels:find("Window 7", 1, true) and labels:find("Window 9", 1, true))
      test.equal(draw(b), "B")
      test.equal(draw(a), "A", "Drawing B changed A's selection")
    end)
    renderer.draw_rect, renderer.draw_text, renderer.set_clip_rect = old_rect, old_text, old_clip
    if not ok then error(err) end
  end)
  test.it("offers Refresh without a Project or Terminal action", function()
    local SidebarView = require "core.sidebar_view"
    local style = require "core.style"
    local actions = {}
    local view = SidebarView(function(action, row) actions[#actions + 1] = {action, row} end)
    view:set_model({})
    view:on_mouse_pressed("left", 20, view:row_y(1) - style.font:get_height(), 240)
    test.same(actions, {{"refresh"}})
  end)
  test.it("selects Projects and requires the explicit Unload button", function()
    local SidebarView = require "core.sidebar_view"
    local actions = {}
    local view = SidebarView(function(action, row) actions[#actions + 1] = {action, row} end)
    view:set_model({{row_id=7,path="C:/B",state="ready",terminals={}},
                    {row_id=9,path="C:/A",state="dormant",terminals={}}})
    view:on_mouse_pressed("left", 20, view:row_y(2))
    test.same(actions[1], {"select", 9})
    view:on_mouse_pressed("right", 20, view:row_y(1))
    test.equal(#actions, 1, "Right-click unloaded the Project")
    view:on_mouse_pressed("left", 230, view:row_y(1), 240)
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
