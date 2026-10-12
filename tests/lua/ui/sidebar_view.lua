local test = require "core.test"

-- Seam: the Sidebar View's model input, pointer handlers, emitted actions and renderer output.
local SidebarView = require "core.sidebar_view"

local function row_y(view, kind, nth, predicate)
  local seen = 0
  for index, row in ipairs(view.rows) do
    if row.kind == kind and (not predicate or predicate(row)) then
      seen = seen + 1
      if seen == (nth or 1) then return view:row_y(index) + 2 end
    end
  end
  error("no " .. kind .. " row " .. tostring(nth or 1))
end

local function count(view, kind)
  local n = 0
  for _, row in ipairs(view.rows) do if row.kind == kind then n = n + 1 end end
  return n
end

local function recorder()
  local actions = {}
  return actions, function(...) actions[#actions + 1] = {...} end
end

test.describe("Sidebar list actions", function()
  test.it("offers explicit target Windows for a loaded Project Move", function()
    local actions, action = recorder()
    local view = SidebarView(action)
    view:set_model({{row_id=7,id=31,path="C:/A",state="ready",window_id=5,terminals={}},
      windows={{id=5,selected_project=31},{id=8,selected_project=0},{id=9,selected_project=44}}}, 8)
    -- Right-click opens Move choices. It does not move or unload the Project.
    view:on_mouse_pressed("right", 20, row_y(view, "project"), 240)
    test.equal(#actions, 0)
    test.equal(count(view, "move"), 2)
    view:on_mouse_pressed("left", 20, row_y(view, "move", 2), 240)
    test.same(actions, {{"move", 31, 9}})
    test.equal(count(view, "move"), 0)
  end)

  test.it("keeps Move choices across Sidebar updates while the Project keeps its owner", function()
    local actions, action = recorder()
    local view = SidebarView(action)
    local function model(busy, owner, state)
      return {{row_id=7,id=31,path="C:/A",state=state or "ready",window_id=owner,
        terminals={{id="session",title="shell",cwd="C:/A",busy=busy,state="running"}}},
        windows={{id=5,selected_project=31},{id=9,selected_project=0}}}
    end
    view:set_model(model(0, 5), 9)
    view:on_mouse_pressed("right", 20, row_y(view, "project"), 240)
    -- A Terminal busy change is a new revision. The open choices must stay under the cursor.
    view:set_model(model(1, 5), 9)
    test.equal(count(view, "move"), 1)
    view:on_mouse_pressed("left", 20, row_y(view, "move"), 240)
    test.same(actions, {{"move", 31, 9}})
    -- A changed owner or an unloaded Project invalidates the choices.
    view:on_mouse_pressed("right", 20, row_y(view, "project"), 240)
    view:set_model(model(1, 9), 9)
    test.equal(count(view, "move"), 0)
    view:set_model(model(1, 9), 9)
    test.equal(count(view, "move"), 0, "Choices reopened after the owner changed")
    view:on_mouse_pressed("right", 20, row_y(view, "project"), 240)
    view:set_model(model(1, 0, "dormant"), 9)
    test.equal(count(view, "move"), 0)
  end)

  test.it("highlights each Window's Selected Project and names Projects shown in other Windows", function()
    local style = require "core.style"
    local model = {
      {row_id=1,id=11,path="C:/A",state="ready",window_id=7,terminals={}},
      {row_id=2,id=22,path="C:/B",state="ready",window_id=9,terminals={}},
      windows={{id=7,selected_project=11},{id=9,selected_project=22}},
    }
    local a, b = SidebarView(function() end), SidebarView(function() end)
    a:set_model(model, 7); b:set_model(model, 9)
    local old_rect, old_rounded, old_text, old_clip =
      renderer.draw_rect, renderer.draw_rounded_rect, renderer.draw_text, renderer.set_clip_rect
    local function draw(view)
      local selected, selected_title, labels = nil, nil, {}
      renderer.draw_rect = function() end
      renderer.draw_rounded_rect = function(_, y, _, h, _, color)
        if color == style.selection then selected = {y, y + h} end
      end
      renderer.draw_text = function(_, text, _, y)
        if selected and y >= selected[1] and y < selected[2] and not selected_title then selected_title = text end
        labels[#labels + 1] = text
      end
      renderer.set_clip_rect = function() end
      view:draw(600, 1000)
      return selected_title, table.concat(labels, "\n")
    end
    local ok, err = pcall(function()
      local title, labels = draw(a)
      test.equal(title, "A")
      test.ok(labels:find("Window 9", 1, true), "A's Sidebar does not name B's Window")
      test.ok(not labels:find("Window 7", 1, true), "A's Sidebar names its own Window")
      local b_title, b_labels = draw(b)
      test.equal(b_title, "B")
      test.ok(b_labels:find("Window 7", 1, true))
      test.equal(draw(a), "A", "Drawing B changed A's selection")
    end)
    renderer.draw_rect, renderer.draw_rounded_rect, renderer.draw_text, renderer.set_clip_rect =
      old_rect, old_rounded, old_text, old_clip
    if not ok then error(err) end
  end)

  test.it("offers Refresh without a Project or Terminal action", function()
    local actions, action = recorder()
    local view = SidebarView(action)
    view:set_model({})
    view:on_mouse_pressed("left", 235, row_y(view, "header"), 240)
    test.same(actions, {{"refresh"}})
  end)

  test.it("selects Projects and requires the explicit Unload button", function()
    local actions, action = recorder()
    local view = SidebarView(action)
    view:set_model({{row_id=7,path="C:/B",state="ready",terminals={}},
                    {row_id=9,path="C:/A",state="dormant",exists=true,terminals={}}})
    view:on_mouse_pressed("left", 20, row_y(view, "project", 2))
    test.same(actions[1], {"select", 9})
    view:on_mouse_pressed("right", 20, row_y(view, "project", 1))
    test.equal(#actions, 1, "Right-click unloaded the Project")
    view:on_mouse_pressed("left", 230, row_y(view, "project", 1), 240)
    test.same(actions[2], {"unload", 7})
    -- A Dormant Project has nothing to unload.
    view:on_mouse_pressed("left", 230, row_y(view, "project", 2), 240)
    test.same(actions[3], {"select", 9})
  end)

  test.it("lists loaded Projects before Recent Dormant Projects", function()
    local view = SidebarView(function() end)
    view:set_model({{row_id=1,path="C:/Old",state="dormant",exists=true,terminals={}},
                    {row_id=2,path="C:/Open",state="ready",terminals={}},
                    {row_id=3,path="C:/Older",state="dormant",exists=true,terminals={}}})
    local order = {}
    for _, row in ipairs(view.rows) do
      if row.kind == "project" then order[#order + 1] = row.project.path end
      if row.kind == "header" then order[#order + 1] = row.label end
    end
    test.same(order, {"PROJECTS", "C:/Open", "RECENT", "C:/Old", "C:/Older"})
  end)

  test.it("collapses a long Recent list behind Show more", function()
    local actions, action = recorder()
    local view = SidebarView(action)
    local model = {}
    for i = 1, 30 do
      model[i] = {row_id=i,path="C:/P" .. i,state="dormant",exists=true,terminals={}}
    end
    view:set_model(model)
    test.ok(count(view, "project") < 30, "Recent list was not collapsed")
    view:on_mouse_pressed("left", 20, row_y(view, "more"))
    test.equal(count(view, "project"), 30)
    test.equal(#actions, 0)
    -- Expansion survives model revisions.
    view:set_model(model)
    test.equal(count(view, "project"), 30)
  end)

  test.it("shows Terminal records and Project choices without giving Terminals Project actions", function()
    local actions, action = recorder()
    local view = SidebarView(action)
    view:set_model({{row_id=7,path="C:/B",state="closing",close_choice=true,deferred_dialog=true,
      terminals={{id="session",title="shell",cwd="C:/B",busy=1,state="running",attached=false}}}})
    test.equal(count(view, "project"), 1)
    test.equal(count(view, "terminal"), 1)
    view:on_mouse_pressed("left", 20, row_y(view, "terminal"))
    test.equal(#actions, 0)
  end)

  test.it("tracks the hovered row and clears it when the pointer leaves", function()
    local view = SidebarView(function() end)
    view:set_model({{row_id=7,path="C:/B",state="ready",terminals={}}})
    test.ok(view:on_mouse_moved(20, row_y(view, "project"), 240), "Hover change did not request a redraw")
    test.equal(view.hover.project.row_id, 7)
    test.ok(not view:on_mouse_moved(21, row_y(view, "project"), 240), "Same-row motion requested a redraw")
    test.ok(view:on_mouse_left())
    test.is_nil(view.hover)
  end)
end)
