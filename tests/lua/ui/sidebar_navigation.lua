local test = require "core.test"
local SidebarView = require "core.sidebar_view"

-- Seam: keyboard and text events, visible rows, and emitted shell actions.
local function sidebar()
  local actions = {}
  local view = SidebarView(function(...) actions[#actions + 1] = {...} end)
  view:set_model({
    {id=1,row_id=1,path="C:/Alpha",state="ready",panes={active=1,
      {id="a",name="main.lua"}, {id="b",name="notes.md"}}},
    {id=2,row_id=2,path="C:/Beta",state="ready",panes={{id="c",name="main.lua"}},
      terminals={{id="shell",title="Build server",state="running"}}},
    {id=3,row_id=3,path="C:/Archive",state="dormant",exists=true},
    windows={{id=7,selected_project=1}},
  }, 7)
  return view, actions
end

test.describe("Sidebar keyboard navigation", function()
  test.it("starts at the current Tab and activates only on Enter", function()
    local view, actions = sidebar()
    view:on_focus(true)
    test.equal(view:get_cursor().tab.id, "a")
    view:on_key_pressed("down")
    test.equal(view:get_cursor().tab.id, "b")
    test.same(actions, {})
    view:on_key_pressed("return")
    test.same(actions, {{"pane",1,"b","focus"}})
  end)

  test.it("collapses a Project and searches its hidden Tabs with Project context", function()
    local view = sidebar()
    view:on_focus(true)
    view:on_key_pressed("left")
    test.equal(view:get_cursor().project.id, 1)
    test.equal(view:get_cursor().kind, "project")
    view:on_key_pressed("left")
    test.equal(view.rows[2].project.id, 2, "Collapsed Projects must hide their children")
    view:on_text_input("main")
    local names = {}
    for _, row in ipairs(view.rows) do
      names[#names + 1] = row.kind == "project" and row.project.path or row.tab.name
    end
    test.same(names, {"C:/Alpha","main.lua","C:/Beta","main.lua"})
    view:on_key_pressed("return")
  end)

  test.it("finds detached Terminals and Dormant Projects without loading them", function()
    local view, actions = sidebar()
    view:on_focus(true)
    view:on_text_input("bsv")
    test.equal(view:get_cursor().terminal.id, "shell")
    test.same(actions, {})
    view:on_key_pressed("return")
    test.same(actions, {{"select_terminal",2,"shell"}})
    view:on_focus(false)
    view:on_focus(true)
    view:on_text_input("archive")
    test.equal(view:get_cursor().project.id, 3)
    view:on_key_pressed("return")
    test.same(actions[2], {"select",3})
  end)

  test.it("keeps selection through model refresh and returns focus on Escape", function()
    local view, actions = sidebar()
    view:on_focus(true)
    view:on_key_pressed("down")
    view:set_model(view.projects, 7)
    test.equal(view:get_cursor().tab.id, "b")
    view:on_key_pressed("escape")
    test.same(actions, {{"return_focus"}})
  end)

  test.it("keeps keyboard selection visible and removes complete UTF-8 characters", function()
    local view = sidebar()
    view:set_size(240, 120)
    view:on_focus(true)
    view:on_key_pressed("down")
    local row = view:get_cursor()
    test.ok(view:row_y(view.cursor) + row.h <= view:main_bottom())
    view:on_text_input("é")
    view:on_key_pressed("backspace")
    test.equal(view.query, "")
    test.ok(view:get_cursor())
  end)
end)
