local test = require "core.test"
local SidebarView = require "core.sidebar_view"

-- Seam: model updates and visible rows.
local function sidebar()
  local view = SidebarView(function() end)
  view:set_model({
    {id=1,row_id=1,path="C:/Alpha",state="ready",panes={active=1,
      {id="a",name="main.lua"}, {id="b",name="notes.md"}}},
    {id=2,row_id=2,path="C:/Beta",state="ready",panes={{id="c",name="main.lua"}},
      terminals={{id="shell",title="Build server",state="running"}}},
    {id=3,row_id=3,path="C:/Archive",state="dormant",exists=true},
    windows={{id=7,selected_project=1}},
  }, 7)
  return view
end

test.describe("Sidebar cursor after a Pane closes", function()
  test.it("follows the Project's active Pane instead of the next Project", function()
    local view = sidebar()
    view:on_focus(true)
    view:on_key_pressed("down")
    test.equal(view:get_cursor().tab.id, "b")
    table.remove(view.projects[1].panes, 2)
    view:set_model(view.projects, 7)
    test.equal(view:get_cursor().tab.id, "a")
    test.equal(view:get_cursor().project.path, "C:/Alpha")
  end)

  test.it("follows the reported active Pane instead of Sidebar row order", function()
    local view = sidebar()
    local project = view.projects[1]
    table.insert(project.panes, {id="d",name="other.lua"})
    view:set_model(view.projects, 7)
    view:on_focus(true)
    test.equal(view:get_cursor().tab.id, "a")
    table.remove(project.panes, 1)
    project.panes.active = 2
    view:set_model(view.projects, 7)
    test.equal(view:get_cursor().tab.id, "d")
  end)

  test.it("keeps the cursor in its Project when no Pane remains", function()
    local view = sidebar()
    view:on_focus(true)
    view:on_key_pressed("down")
    view.projects[1].panes = {}
    view:set_model(view.projects, 7)
    test.equal(view:get_cursor().kind, "project")
    test.equal(view:get_cursor().project.path, "C:/Alpha")
  end)

  test.it("reveals the replacement Pane when the search hides it", function()
    local view = sidebar()
    view:on_focus(true)
    view:on_text_input("notes")
    test.equal(view:get_cursor().tab.id, "b")
    table.remove(view.projects[1].panes, 2)
    view:set_model(view.projects, 7)
    test.equal(view:get_cursor().tab.id, "a")
    test.equal(view:get_cursor().project.path, "C:/Alpha")
  end)
end)
