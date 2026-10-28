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
  test.it("unloads the cursor's Project without selecting it or closing its Pane", function()
    local view, actions = sidebar()
    view:on_focus(true)
    view:on_key_pressed("next_project")
    test.equal(view:get_cursor().project.id, 2)
    test.ok(view:unload_cursor_project())
    test.same(actions, {{"unload", 2}})
  end)

  test.it("consumes unload on a Dormant Project without loading it", function()
    local view, actions = sidebar()
    view:on_focus(true)
    view:on_text_input("archive")
    test.ok(view:unload_cursor_project())
    test.same(actions, {})
  end)

  test.it("leaves Pane close keys to the Project and ignores unload without Sidebar focus", function()
    local view, actions = sidebar()
    view:on_focus(true)
    test.equal(view:get_cursor().kind, "tab")
    test.ok(not view:unload_cursor_project())
    view:on_key_pressed("left")
    view:on_focus(false)
    test.ok(not view:unload_cursor_project())
    test.same(actions, {})
  end)

  test.it("jumps between Projects without activating their Panes", function()
    local view, actions = sidebar()
    view:on_focus(true)
    view:on_key_pressed("next_project")
    test.equal(view:get_cursor().kind, "project")
    test.equal(view:get_cursor().project.id, 2)
    view:on_key_pressed("down")
    test.equal(view:get_cursor().tab.id, "c")
    view:on_key_pressed("previous_project")
    test.equal(view:get_cursor().kind, "project")
    test.equal(view:get_cursor().project.id, 1)
    test.ok(view.focused)
    test.same(actions, {})
  end)

  test.it("jumps to visible Dormant Projects and stops at the list ends", function()
    local view, actions = sidebar()
    view:on_focus(true)
    view:on_key_pressed("end")
    view:on_key_pressed("right")
    local before = #actions
    view:on_key_pressed("next_project")
    test.equal(view:get_cursor().kind, "project")
    test.equal(view:get_cursor().project.id, 3)
    view:on_key_pressed("next_project")
    test.equal(view:get_cursor().project.id, 3)
    view:on_key_pressed("previous_project")
    test.equal(view:get_cursor().project.id, 2)
    view:on_key_pressed("previous_project")
    test.equal(view:get_cursor().project.id, 1)
    view:on_key_pressed("previous_project")
    test.equal(view:get_cursor().project.id, 1)
    test.equal(#actions, before)
  end)

  test.it("sends a key to the cursor's Pane, or to the cursor's Project", function()
    local view, actions = sidebar()
    view:on_focus(true)
    view:on_key_pressed("down")
    test.ok(view:forward_key("ctrl+shift+e"))
    test.same(actions[1], {"request", "select", "C:/Alpha", {action="key", stroke="ctrl+shift+e", pane="b"}})
    view:on_key_pressed("left")
    test.ok(view:forward_key("ctrl+shift+e"))
    test.same(actions[2], {"request", "select", "C:/Alpha", {action="key", stroke="ctrl+shift+e"}})
    for _, case in ipairs {{"bsv", "C:/Beta"}, {"archive", "C:/Archive"}} do
      view:on_focus(false)
      view:on_focus(true)
      view:on_text_input(case[1])
      test.ok(view:forward_key("alt+x"))
      test.same(actions[#actions], {"request", "select", case[2], {action="key", stroke="alt+x"}})
    end
  end)

  test.it("sends a key from a row without a Project to the Selected Project", function()
    local view, actions = sidebar()
    view:on_focus(true)
    view:on_key_pressed("end")
    test.equal(view:get_cursor().kind, "group")
    test.ok(view:forward_key("f5"))
    test.same(actions, {{"request", "select", "C:/Alpha", {action="key", stroke="f5"}}})
  end)

  test.it("keeps keys that can type text, and keys without Sidebar focus", function()
    local view, actions = sidebar()
    view:on_focus(true)
    for _, stroke in ipairs {"a", "shift+a", "altgr+2", "space"} do
      test.ok(not view:forward_key(stroke), stroke)
    end
    view:on_focus(false)
    test.ok(not view:forward_key("ctrl+shift+e"))
    test.same(actions, {})
  end)

  test.it("starts at the current Tab and activates only on Enter", function()
    local view, actions = sidebar()
    view:on_focus(true)
    test.equal(view:get_cursor().tab.id, "a")
    view:on_key_pressed("down")
    test.equal(view:get_cursor().tab.id, "b")
    test.same(actions, {})
    view:on_key_pressed("return")
    test.same(actions, {{"request","select","C:/Alpha",{action="focus",pane="b"}}})
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

  test.it("asks before a second Left unloads a collapsed Project", function()
    local view, actions = sidebar()
    local function unloads()
      local found = {}
      for _, action in ipairs(actions) do
        if action[1] == "unload" then found[#found + 1] = action[2] end
      end
      return found
    end
    view:on_focus(true)
    view:on_key_pressed("left")
    view:on_key_pressed("left")
    test.ok(view:get_cursor().collapsed)
    view:on_key_pressed("left")
    view:on_key_pressed("left", true)
    test.same(unloads(), {}, "A held Left must not unload")
    view:on_key_pressed("down")
    view:on_key_pressed("up")
    view:on_key_pressed("left")
    test.same(unloads(), {}, "Another key must cancel the question")
    view:on_key_pressed("left")
    test.same(unloads(), {1})
  end)

  test.it("moves the cursor to the Project above an unloaded Project, or else below it", function()
    local function model(dormant, selected)
      local projects = {windows={{id=7,selected_project=selected}}}
      for id, name in ipairs({"Alpha", "Beta", "Gamma"}) do
        local path = "C:/" .. name
        projects[id] = dormant == path and {id=id,row_id=id,path=path,state="dormant",exists=true}
          or {id=id,row_id=id,path=path,state="ready",panes={active=1,{id=name,name=name .. ".lua"}}}
      end
      return projects
    end
    local view = SidebarView(function() end)
    view:set_model(model(nil, 1), 7)
    view:on_focus(true)
    view:on_key_pressed("end")
    view:on_key_pressed("left")
    test.equal(view:get_cursor().project.path, "C:/Gamma")
    view:set_model(model("C:/Gamma", 1), 7)
    test.equal(view:get_cursor().kind, "project")
    test.equal(view:get_cursor().project.path, "C:/Beta")

    view = SidebarView(function() end)
    view:set_model(model(nil, 1), 7)
    view:on_focus(true)
    test.equal(view:get_cursor().tab.id, "Alpha")
    view:set_model(model("C:/Alpha", 2), 7)
    test.equal(view:get_cursor().kind, "project")
    test.equal(view:get_cursor().project.path, "C:/Beta")
  end)

  test.it("does not unload a Dormant Project", function()
    local view, actions = sidebar()
    view:on_focus(true)
    view:on_key_pressed("end")
    view:on_key_pressed("right")
    view:on_key_pressed("down")
    test.equal(view:get_cursor().project.path, "C:/Archive")
    local before = #actions
    view:on_key_pressed("left")
    view:on_key_pressed("left")
    test.equal(#actions, before)
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
    view:edit("backspace")
    test.equal(view.query, "")
    test.ok(view:get_cursor())
  end)
end)
