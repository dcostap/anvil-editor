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

-- Runs `fn` with the renderer's draw calls replaced. `calls` records the ones that a test reads; the others do
-- nothing, because tests draw outside a frame.
local DRAW_CALLS = {"draw_rect", "draw_rounded_rect", "draw_text", "draw_poly", "set_clip_rect", "push_transform",
  "pop_transform"}
local function with_renderer(calls, fn)
  local saved = {}
  for _, name in ipairs(DRAW_CALLS) do
    saved[name] = renderer[name]
    renderer[name] = calls[name] or function() end
  end
  local ok, err = pcall(fn)
  for _, name in ipairs(DRAW_CALLS) do renderer[name] = saved[name] end
  if not ok then error(err, 0) end
end

-- Records each text's position, colour and effective opacity at `width` x `height`.
local function drawn_texts(view, width, height)
  local texts, stack, opacity = {}, {}, 1
  with_renderer({
    push_transform = function(x, y, scale, alpha)
      stack[#stack + 1] = opacity
      opacity = opacity * (alpha or 1)
    end,
    pop_transform = function() opacity = table.remove(stack) end,
    draw_text = function(font, text, x, y, color)
      texts[#texts + 1] = {text = text, x = x, y = y, color = color, right = x + font:get_width(text),
        opacity = opacity * (color[4] or 255) / 255}
    end,
  }, function() view:draw(width or 400, height or 800) end)
  return texts
end

local function joined(texts)
  local parts = {}
  for _, item in ipairs(texts) do parts[#parts + 1] = item.text end
  return table.concat(parts, " | ")
end

local function find_text(texts, text)
  for _, item in ipairs(texts) do if item.text == text then return item end end
end

-- The names of the rows that carry the selection highlight.
local function highlighted(view)
  local names = {}
  for _, row in ipairs(view.rows) do
    if row.selected then
      names[#names + 1] = row.tab and row.tab.name or row.project.path:match("[^/]+$")
    end
  end
  return table.concat(names, ",")
end

test.describe("Sidebar title tooltips", function()
  local function sidebar(name, width)
    local view = SidebarView(function() end)
    view:set_size(width or 500, 800)
    view:set_model({{row_id=1,path="C:/A",state="ready",terminals={
      {id="detached",title=name,state="running"}},panes={
      {id="pane-1",name=name,terminal={session="shown",state="running"}}}}})
    return view
  end

  test.it("does not repeat a fully visible Terminal title", function()
    local view = sidebar("π - .pi")
    for _, kind in ipairs({"tab", "terminal"}) do
      view:on_mouse_moved(100, row_y(view, kind))
      test.equal(view:get_tooltip(), nil, "A visible title has a redundant tooltip")
    end
  end)

  test.it("keeps the full title available when the Tab hides part of it", function()
    local original = [[C:\Program Files\PowerShell\7\pwsh.exe]]
    local view = sidebar(original)
    view:on_mouse_moved(100, row_y(view, "tab"))
    test.equal(view:get_tooltip(), original)
    local long = "a terminal command with arguments that do not fit in this narrow Sidebar"
    view = sidebar(long, 180)
    view:on_mouse_moved(100, row_y(view, "terminal"))
    test.equal(view:get_tooltip(), long)
    view:set_size(1200, 800)
    test.equal(view:get_tooltip(), nil, "Resizing leaves a redundant tooltip")
  end)

  test.it("places the tooltip near the pointer and keeps it inside the Sidebar", function()
    local view = sidebar([[C:\tools\tool.exe]])
    local boxes = {}
    local function draw_at(x, y)
      view:on_mouse_moved(x, y)
      view.clock = system.get_time() + 10
      boxes = {}
      view:draw_tooltip(view.width, view.view_h)
      return test.not_nil(boxes[2], "The hidden title has no tooltip")
    end
    with_renderer({draw_rounded_rect = function(x, y, w, h) boxes[#boxes + 1] = {x=x,y=y,w=w,h=h} end}, function()
      local y = row_y(view, "tab")
      local box = draw_at(180, y)
      test.ok(box.x >= 180, "The tooltip does not follow the pointer")
      test.ok(box.y > y, "The tooltip covers the pointer")
      test.ok(view:on_mouse_moved(200, y), "Tooltip motion does not request a redraw")
      box = draw_at(view.width - 1, y)
      test.ok(box.x >= 0 and box.x + box.w <= view.width, "The tooltip leaves the Sidebar")
    end)
  end)
end)

test.describe("Sidebar list actions", function()
  test.it("asks the shell for a Project's actions menu when a right-click releases on it", function()
    local actions, action = recorder()
    local view = SidebarView(action, {["group:week"]=false})
    view:set_model({{row_id=7,id=31,path="C:/A",state="ready",window_id=5,terminals={}},
      {row_id=9,path="C:/B",state="dormant",exists=true,activity=os.time(),terminals={}},
      windows={{id=5,selected_project=31},{id=8,selected_project=0}}}, 8)
    local y = row_y(view, "project", 1)
    -- The menu waits for the release, so its loop never takes the press's own release.
    view:on_mouse_pressed("right", 20, y, 240)
    test.same(actions, {})
    view:on_mouse_released("right", 21, y)
    test.same(actions, {{"menu", 7, 21, y}})
    -- A Dormant Project has a menu too, and the right-click neither selects nor starts it.
    local dormant_y = row_y(view, "project", 2)
    view:on_mouse_pressed("right", 230, dormant_y, 240)
    view:on_mouse_released("right", 230, dormant_y)
    test.same(actions[2], {"menu", 9, 230, dormant_y})
    test.equal(#actions, 2)
  end)

  test.it("shows no menu when a right-click releases on another row", function()
    local actions, action = recorder()
    local view = SidebarView(action, {["group:week"]=false})
    view:set_model({{row_id=7,id=31,path="C:/A",state="ready",window_id=5,terminals={}},
      {row_id=9,path="C:/B",state="dormant",exists=true,activity=os.time(),terminals={}}}, 5)
    view:on_mouse_pressed("right", 20, row_y(view, "project", 1), 240)
    view:on_mouse_released("right", 20, row_y(view, "project", 2))
    test.same(actions, {})
  end)

  test.it("unloads a Project when a middle-click releases on it", function()
    local actions, action = recorder()
    local view = SidebarView(action)
    view:set_model({{row_id=7,id=31,path="C:/A",state="ready",window_id=5,terminals={}},
      {row_id=9,id=32,path="C:/B",state="ready",window_id=5,terminals={}}}, 5)
    local y = row_y(view, "project", 1)
    view:on_mouse_pressed("middle", 20, y, 240)
    test.same(actions, {})
    view:on_mouse_released("middle", 20, y)
    test.same(actions, {{"unload", 7}})
    -- A middle-click that moves to another row does nothing.
    view:on_mouse_pressed("middle", 20, y, 240)
    view:on_mouse_released("middle", 20, row_y(view, "project", 2))
    test.equal(#actions, 1)
  end)

  test.it("highlights each Window's Selected Project and names Projects shown in other Windows", function()
    local model = {
      {row_id=1,id=11,path="C:/A",state="ready",window_id=7,terminals={}},
      {row_id=2,id=22,path="C:/B",state="ready",window_id=9,terminals={}},
      windows={{id=7,selected_project=11},{id=9,selected_project=22}},
    }
    local a, b = SidebarView(function() end), SidebarView(function() end)
    a:set_model(model, 7); b:set_model(model, 9)
    test.equal(highlighted(a), "A")
    local labels = joined(drawn_texts(a, 600, 1000))
    test.ok(labels:find("Window 9", 1, true), "A's Sidebar does not name B's Window")
    test.ok(not labels:find("Window 7", 1, true), "A's Sidebar names its own Window")
    test.equal(highlighted(b), "B")
    test.ok(joined(drawn_texts(b, 600, 1000)):find("Window 7", 1, true))
    test.equal(highlighted(a), "A", "Drawing B changed A's selection")
  end)

  test.it("dims another Window's Project and its children, but not Dormant Projects", function()
    local model = {
      {row_id=1,id=11,path="C:/Alpha",state="ready",window_id=7,panes={
        {id="pane-1",group=1,name="notes.lua"}},terminals={
        {id="recent",title="recent shell",state="running"},
        {id="old",title="old shell",state="running",activity=os.time() - 15 * 86400}}},
      {row_id=2,path="C:/Dormant",state="dormant",window_id=0,exists=true,activity=os.time()},
      windows={{id=7,selected_project=11},{id=9,selected_project=0}},
    }
    local a, b = SidebarView(function() end), SidebarView(function() end)
    for _, view in ipairs {a, b} do
      view:toggle("terminals:month:C:/Alpha", true)
      view:toggle("group:week", true)
    end
    a:set_model(model, 7); b:set_model(model, 9)
    local local_texts, remote_texts = drawn_texts(a, 600, 1000), drawn_texts(b, 600, 1000)
    for _, label in ipairs {"Alpha", "notes.lua", "recent shell", "OLDER THAN A WEEK", "old shell"} do
      local normal = test.not_nil(find_text(local_texts, label), label .. " is missing locally")
      local dimmed = test.not_nil(find_text(remote_texts, label), label .. " is missing remotely")
      test.ok(dimmed.opacity > 0 and dimmed.opacity < normal.opacity, label .. " is not dimmed remotely")
    end
    test.equal(find_text(remote_texts, "Dormant").opacity, find_text(local_texts, "Dormant").opacity)
    -- Moving the Project changes which Sidebar dims it.
    model[1].window_id = 9
    model.windows = {{id=7,selected_project=0},{id=9,selected_project=11}}
    a:set_model(model, 7); b:set_model(model, 9)
    test.ok(find_text(drawn_texts(a, 600, 1000), "notes.lua").opacity
      < find_text(drawn_texts(b, 600, 1000), "notes.lua").opacity)
  end)

  test.it("selects a Project clicked anywhere on its row", function()
    local actions, action = recorder()
    local view = SidebarView(action, {["group:week"]=false})
    view:set_model({{row_id=7,path="C:/B",state="ready",terminals={}},
                    {row_id=9,path="C:/A",state="dormant",exists=true,activity=os.time(),terminals={}}})
    view:on_mouse_pressed("left", 20, row_y(view, "project", 2), 240)
    view:on_mouse_moved(230, row_y(view, "project", 1), 240)
    view:on_mouse_pressed("left", 230, row_y(view, "project", 1), 240)
    test.same(actions, {{"select", 9}, {"select", 7}})
  end)

  test.it("toggles the Selected Project's children when its row is clicked", function()
    local actions, action = recorder()
    local view = SidebarView(action)
    local model = {{row_id=7,id=31,path="C:/A",state="ready",window_id=5,terminals={},
      panes={active=1,{id="pane",name="A.lua"}}}, windows={{id=5,selected_project=31}}}
    view:set_model(model, 5)
    test.equal(count(view, "tab"), 1)
    view:on_mouse_pressed("left", 60, row_y(view, "project"))
    test.equal(count(view, "tab"), 0, "Clicking the Selected Project does not collapse its children")
    view:set_model(model, 5)
    test.equal(count(view, "tab"), 0, "A model refresh expands the collapsed Project")
    view:on_mouse_pressed("left", 60, row_y(view, "project"))
    test.equal(count(view, "tab"), 1, "Clicking the collapsed Project does not expand its children")
    test.same(actions, {{"collapsed", "project:C:/A", true}, {"collapsed", "project:C:/A", false}})
  end)

  test.it("selects another Window's Selected Project without collapsing its children", function()
    local actions, action = recorder()
    local view = SidebarView(action)
    view:set_model({{row_id=7,id=31,path="C:/A",state="ready",window_id=5,terminals={},
      panes={active=1,{id="pane",name="A.lua"}}},
      windows={{id=5,selected_project=31},{id=8,selected_project=0}}}, 8)
    view:on_mouse_pressed("left", 60, row_y(view, "project"))
    test.equal(count(view, "tab"), 1)
    test.same(actions, {{"select", 7}})
  end)

  test.it("requests a redraw when the pointer enters or leaves the Project arrow", function()
    local view = SidebarView(function() end)
    view:set_model({{row_id=7,path="C:/A",state="ready",terminals={},panes={{id="pane",name="A.lua"}}}})
    local y = row_y(view, "project")
    view:on_mouse_moved(60, y)
    test.ok(view:on_mouse_moved(230, y), "Entering the arrow does not request hover feedback")
    test.ok(view:on_mouse_moved(60, y), "Leaving the arrow does not clear hover feedback")
  end)

  test.it("asks to focus a clicked Terminal Session without giving it Project actions", function()
    local actions, action = recorder()
    local view = SidebarView(action)
    view:set_model({{row_id=7,path="C:/B",state="closing",close_choice=true,deferred_dialog=true,
      terminals={{id="session",title="shell",cwd="C:/B",busy=1,state="running",attached=false}}}})
    test.equal(count(view, "project"), 1)
    test.equal(count(view, "terminal"), 1)
    view:on_mouse_pressed("left", 230, row_y(view, "terminal"), 240)
    test.same(actions, {{"select_terminal", 7, "session"}})
    -- Right-click has no Terminal Session action yet.
    view:on_mouse_pressed("right", 20, row_y(view, "terminal"), 240)
    test.equal(#actions, 1)
    test.ok(view:on_mouse_moved(20, row_y(view, "terminal"), 240), "A Terminal Session row is not a hover target")
    test.equal(view.hover.terminal.id, "session")
  end)

  test.it("highlights the active Tab of the Window's Selected Project instead of the Project", function()
    local function model(active)
      return {
        {row_id=1,id=11,path="C:/A",state="ready",window_id=7,terminals={},panes={active=active,visible=1,
          {id="pane-1",group=1,name="first.lua"},{id="pane-2",group=1,name="second.lua"}}},
        windows={{id=7,selected_project=11},{id=9,selected_project=0}},
      }
    end
    local view = SidebarView(function() end)
    view:set_model(model(2), 7)
    test.equal(highlighted(view), "second.lua")
    -- No active Tab: the Project row shows the selection.
    view:set_model(model(nil), 7)
    test.equal(highlighted(view), "A")
    -- Another Window's Sidebar highlights neither.
    local other = SidebarView(function() end)
    other:set_model(model(2), 9)
    test.equal(highlighted(other), "")
  end)

  -- The shell keeps the Window's old selection until a chosen Pane renders. The Sidebar shows the user's choice.
  local function two_projects(selected, b_active, b_panes)
    return {
      {row_id=1,id=11,path="C:/A",state="ready",window_id=7,terminals={},panes={active=1,visible=1,
        {id="pane-1",group=1,name="a.lua"}}},
      {row_id=2,id=12,path="C:/B",state="ready",window_id=7,activity=os.time(),panes=b_panes or {active=b_active,
        visible=1,{id="pane-2",group=1,name="b1.lua"},{id="pane-3",group=1,name="b2.lua"}},
        terminals={{id="server",title="server",cwd="C:/B",state="running",busy=1,activity=os.time()}}},
      windows={{id=7,selected_project=selected}},
    }
  end

  test.it("keeps the highlight on a chosen Tab while its Project opens it", function()
    local view = SidebarView(function() end)
    view:set_model(two_projects(11, 1), 7)
    test.equal(highlighted(view), "a.lua")
    view:on_mouse_pressed("left", 20, row_y(view, "tab", 3), 240)
    view:on_mouse_released("left", 20, row_y(view, "tab", 3))
    -- The shell reports other changes while it holds the old selection.
    view:set_model(two_projects(11, 1), 7)
    test.equal(highlighted(view), "b2.lua")
    view:set_model(two_projects(12, 2), 7)
    test.equal(highlighted(view), "b2.lua")
    -- After that, the model's selection shows again.
    view:set_model(two_projects(12, 1), 7)
    test.equal(highlighted(view), "b1.lua")
  end)

  test.it("keeps the highlight on a chosen Terminal Session until its Tab is active", function()
    local view = SidebarView(function() end)
    view:set_model(two_projects(11, 1), 7)
    view:on_mouse_pressed("left", 20, row_y(view, "terminal"), 240)
    -- The Project is selected before its Pane for the Terminal Session opens.
    view:set_model(two_projects(12, 1), 7)
    test.equal(highlighted(view), "server")
    view:set_model(two_projects(12, nil, {active=3,visible=1,{id="pane-2",group=1,name="b1.lua"},
      {id="pane-3",group=1,name="b2.lua"},{id="pane-4",group=1,name="server",
      terminal={session="server",state="running",busy=true}}}), 7)
    test.equal(highlighted(view), "server")
    test.equal(count(view, "terminal"), 0)
  end)

  test.it("shows the model's selection when a chosen Tab closes before it opens", function()
    local view = SidebarView(function() end)
    view:set_model(two_projects(11, 1), 7)
    view:on_mouse_pressed("left", 20, row_y(view, "tab", 3), 240)
    view:set_model(two_projects(12, nil, {active=1,visible=1,{id="pane-2",group=1,name="b1.lua"}}), 7)
    test.equal(highlighted(view), "b1.lua")
  end)

  test.it("lists a loaded Project's Tabs in Pane order and acts on a clicked Tab", function()
    local actions, action = recorder()
    local view = SidebarView(action)
    view:set_model({{row_id=7,id=31,path="C:/A",state="ready",window_id=5,terminals={},panes={active=1,visible=1,
      {id="pane-4",group=1,name="init.lua"},{id="pane-9",group=2,name="notes.md"}}}}, 5)
    local names = {}
    for _, row in ipairs(view.rows) do
      if row.kind == "tab" then names[#names + 1] = row.tab.name end
    end
    test.same(names, {"init.lua", "notes.md"})
    view:on_mouse_pressed("left", 20, row_y(view, "tab", 2), 240)
    test.same(actions, {{"request", "select", "C:/A", {action = "focus", pane = "pane-9"}}})
    -- A middle-click closes the Tab at its release over the same Tab.
    local y = row_y(view, "tab", 1)
    view:on_mouse_pressed("middle", 20, y, 240)
    test.equal(#actions, 1)
    view:on_mouse_released("middle", 20, y)
    test.same(actions[2], {"request", "select", "C:/A", {action = "close", pane = "pane-4"}})
    view:on_mouse_pressed("middle", 20, y, 240)
    view:on_mouse_released("middle", 20, row_y(view, "tab", 2))
    test.equal(#actions, 2)
  end)

  test.it("shows a Terminal Session that a Tab shows only as that Tab", function()
    local view = SidebarView(function() end)
    view:set_model({{row_id=7,id=31,path="C:/A",state="ready",window_id=5,activity=os.time(),terminals={
      {id="shown",title="pwsh",cwd="C:/A",state="running",busy=0,activity=os.time()},
      {id="detached",title="server",cwd="C:/A",state="running",busy=1,activity=os.time()}},
      panes={active=1,visible=1,{id="pane-1",group=1,name="pwsh",
        terminal={session="shown",state="running",busy=false,activity=os.time()}}}}}, 5)
    test.equal(count(view, "tab"), 1)
    test.equal(count(view, "terminal"), 1)
    for _, row in ipairs(view.rows) do
      if row.kind == "terminal" then test.equal(row.terminal.id, "detached") end
    end
  end)

  test.it("hides a Terminal Session in a Pane's history unless it needs the user", function()
    local view = SidebarView(function() end)
    view:set_model({{row_id=7,id=31,path="C:/A",state="ready",window_id=5,activity=os.time(),terminals={
      {id="idle",title="ls",cwd="C:/A",state="running",busy=0,activity=os.time()},
      {id="asks",title="pi",cwd="C:/A",state="running",busy=1,activity=os.time(),
        agent_state="blocked",agent_since=os.time() - 60},
      {id="detached",title="server",cwd="C:/A",state="running",busy=1,activity=os.time()}},
      panes={active=1,visible=1,held={"idle","asks"},{id="pane-1",group=1,name="init.lua"}}}}, 5)
    local ids = {}
    for _, row in ipairs(view.rows) do
      if row.kind == "terminal" then ids[#ids + 1] = row.terminal.id end
    end
    test.same(ids, {"asks", "detached"})
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

local DAY = 24 * 60 * 60

local function paths(view, area)
  local list = {}
  for _, row in ipairs(view.rows) do
    if row.kind == "project" and row.area == area then list[#list + 1] = row.project.path end
  end
  return list
end

local function titles(view)
  local list = {}
  for _, row in ipairs(view.rows) do
    if row.kind == "terminal" then list[#list + 1] = row.terminal.title end
  end
  return list
end

local function row_index(view, predicate)
  for index, row in ipairs(view.rows) do
    if predicate(row) then return index, row end
  end
  error("no matching row")
end

test.describe("Sidebar Window folding", function()
  test.it("keeps Project age groups and Terminal age groups separate between Windows", function()
    local model = {
      {row_id=1,id=1,path="C:/A",state="ready",window_id=7,terminals={
        {id="old",title="old shell",state="running",activity=os.time() - 15 * 86400}}},
      {row_id=2,path="C:/Old",state="dormant",activity=os.time() - 60 * 86400},
    }
    local saved_a, saved_b = {["project:C:/A"]=false, ["group:older"]=false},
      {["project:C:/A"]=false, ["group:older"]=false}
    local a, b = SidebarView(function() end, saved_a, nil, true), SidebarView(function() end, saved_b, nil, true)
    a:set_model(model, 7); b:set_model(model, 9)
    a:toggle("terminals:month:C:/A", true)
    b:toggle("group:older", false)
    for _ = 1, 2 do
      test.equal(count(a, "terminal"), 1)
      test.equal(count(b, "terminal"), 0)
      test.equal(count(a, "project"), 2)
      test.equal(count(b, "project"), 1)
      a = SidebarView(function() end, saved_a, nil, true)
      b = SidebarView(function() end, saved_b, nil, true)
      a:set_model(model, 7); b:set_model(model, 9)
    end
  end)

  test.it("keeps each Window's manual folds without folding Projects when selection changes", function()
    local model = {
      {row_id=1,id=11,path="C:/A",state="ready",window_id=7,panes={{id="a",name="a.lua"}}},
      {row_id=2,id=22,path="C:/B",state="ready",window_id=9,panes={{id="b",name="b.lua"}}},
      {row_id=3,id=33,path="C:/C",state="ready",window_id=7,panes={{id="c",name="c.lua"}}},
      windows={{id=7,selected_project=11},{id=9,selected_project=22}},
    }
    local saved_a, saved_b = {}, {}
    local a, b = SidebarView(function() end, saved_a, nil, true), SidebarView(function() end, saved_b, nil, true)
    local function tabs(view)
      local names = {}
      for _, row in ipairs(view.rows) do if row.kind == "tab" then names[#names + 1] = row.tab.name end end
      return table.concat(names, ",")
    end
    a:set_model(model, 7); b:set_model(model, 9)
    test.equal(tabs(a), "a.lua,b.lua,c.lua")
    test.equal(tabs(b), "a.lua,b.lua,c.lua")
    -- Collapse A in A's Window and B in B's Window. Each choice stays local.
    b:toggle("project:C:/B", false)
    a:toggle("project:C:/A", false)
    test.equal(tabs(a), "b.lua,c.lua")
    test.equal(tabs(b), "a.lua,c.lua")
    a:set_model(model, 7); b:set_model(model, 9)
    test.equal(tabs(a), "b.lua,c.lua")
    test.equal(tabs(b), "a.lua,c.lua")
    -- A fresh frontend restores the manual folds, including the Selected Project's fold.
    a = SidebarView(function() end, saved_a, nil, true)
    b = SidebarView(function() end, saved_b, nil, true)
    a:set_model(model, 7); b:set_model(model, 9)
    test.equal(tabs(a), "b.lua,c.lua")
    test.equal(tabs(b), "a.lua,c.lua")
    model.windows[1].selected_project = 33
    a:set_model(model, 7)
    test.equal(tabs(a), "b.lua,c.lua", "Changing selection folded another Project")
    model.windows[1].selected_project = 11
    a:set_model(model, 7)
    test.equal(tabs(a), "a.lua,b.lua,c.lua", "Selecting the folded Project again did not expand it")
  end)
end)

test.describe("Sidebar age groups", function()
  local now = os.time()
  local function project(id, path, age, state, terminals)
    return {row_id=id,id=id,path=path,state=state or "dormant",exists=true,
      activity=age and now - age or 0,terminals=terminals or {}}
  end

  test.it("keeps loaded Projects on top and groups unloaded Projects by age at the bottom", function()
    local view = SidebarView(function() end, {["group:week"]=false, ["group:month"]=false, ["group:older"]=false})
    view:set_size(240, 800)
    view:set_model({project(1, "C:/Week", DAY), project(2, "C:/Month", 10 * DAY), project(3, "C:/Old", 60 * DAY),
      project(4, "C:/Loaded", 90 * DAY, "ready"), project(5, "C:/Unknown")})
    test.same(paths(view, "main"), {"C:/Loaded"})
    -- Saved choices keep these groups open.
    test.same(paths(view, "bottom"), {"C:/Week", "C:/Month", "C:/Old", "C:/Unknown"})
    local index = row_index(view, function(row) return row.kind == "group" and row.bucket == "older" end)
    view:on_mouse_pressed("left", 20, view:row_y(index) + 2, 240)
    test.same(paths(view, "bottom"), {"C:/Week", "C:/Month"})
  end)

  test.it("aligns the groups to the bottom, below a gap after the main list", function()
    local view = SidebarView(function() end)
    view:set_size(240, 800)
    view:set_model({project(1, "C:/Loaded", DAY, "ready"), project(2, "C:/Month", 10 * DAY)})
    local main_index = row_index(view, function(row) return row.area == "main" end)
    local last_main = view:row_y(main_index) + view.rows[main_index].h
    local first_bottom, last_bottom = math.huge, 0
    for index, row in ipairs(view.rows) do
      if row.area == "bottom" then
        first_bottom = math.min(first_bottom, view:row_y(index))
        last_bottom = math.max(last_bottom, view:row_y(index) + row.h)
      end
    end
    test.ok(first_bottom - last_main > 800 - last_bottom, "The groups are not aligned to the bottom")
  end)

  test.it("gives the groups at most part of the height and scrolls them on their own", function()
    local view = SidebarView(function() end, {["group:month"]=false})
    view:set_size(240, 600)
    local model = {project(100, "C:/Loaded", DAY, "ready")}
    for i = 1, 40 do model[#model + 1] = project(i, "C:/Month" .. i, 10 * DAY) end
    view:set_model(model)
    local top = math.huge
    for index, row in ipairs(view.rows) do
      if row.area == "bottom" then top = math.min(top, view:row_y(index)) end
    end
    test.ok(top >= 300, "The groups took more than half of the height")
    local main_index = row_index(view, function(row) return row.area == "main" end)
    local main_y = view:row_y(main_index)
    local month_index = row_index(view, function(row) return row.kind == "project" and row.project.path == "C:/Month1" end)
    local month_y = view:row_y(month_index)
    view:on_mouse_wheel(-3, 600, 590)
    test.ok(view:row_y(month_index) < month_y, "The groups did not scroll")
    test.equal(view:row_y(main_index), main_y, "Scrolling the groups moved the main list")
  end)

  test.it("limits the groups to a few rows in a tall Sidebar and scrolls the rest", function()
    local view = SidebarView(function() end, {["group:older"]=false})
    view:set_size(240, 3000)
    local model = {}
    for i = 1, 60 do model[#model + 1] = project(i, "C:/Old" .. i, 60 * DAY) end
    view:set_model(model)
    local top, height = view:bottom_area()
    test.ok(height < (3000 - view:list_top()) * 0.25, "The groups grew with the Sidebar's height")
    local last = row_index(view, function(row) return row.kind == "project" and row.project.path == "C:/Old60" end)
    test.ok(view:row_y(last) >= top + height, "The last older Project fits without scrolling")
    view:on_mouse_wheel(-1000, 3000, 2990)
    test.ok(view:row_y(last) + view.rows[last].h <= 3000, "Scrolling did not reach the last older Project")
  end)

  test.it("scrolls the groups by dragging their scrollbar without selecting a Project", function()
    local actions, action = recorder()
    local view = SidebarView(action, {["group:older"]=false})
    view:set_size(240, 600)
    local model = {}
    for i = 1, 40 do model[#model + 1] = project(i, "C:/Old" .. i, 60 * DAY) end
    view:set_model(model)
    local top = view:bottom_area()
    local first = row_index(view, function(row) return row.kind == "project" and row.project.path == "C:/Old1" end)
    local first_y = view:row_y(first)
    view:on_mouse_pressed("left", 237, top + 2, 240)
    view:on_mouse_moved(237, top + 60)
    view:on_mouse_released("left", 237, top + 60)
    test.ok(view:row_y(first) < first_y, "Dragging the scrollbar did not scroll the groups")
    test.same(actions, {})
    -- The drag ended at the release.
    local dragged_y = view:row_y(first)
    view:on_mouse_moved(237, top + 120)
    test.equal(view:row_y(first), dragged_y)
  end)

  test.it("moves an older Project to the main list when it loads", function()
    local view = SidebarView(function() end)
    view:set_size(240, 800)
    view:set_model({project(1, "C:/Old", 10 * DAY)})
    test.same(paths(view, "main"), {})
    view:set_model({project(1, "C:/Old", 10 * DAY, "starting")})
    test.same(paths(view, "main"), {"C:/Old"})
  end)

  test.it("folds a Project's older Terminal Sessions into collapsed groups", function()
    local view = SidebarView(function() end)
    view:set_size(240, 800)
    local function terminal(title, age, asks)
      return {id=title,title=title,cwd="C:/P",state="running",busy=0,activity=now - age,
        agent_state=asks and "blocked" or nil,agent_since=asks and now - age or nil}
    end
    view:set_model({project(1, "C:/P", 60, "ready", {terminal("recent", 20 * 60), terminal("days", 3 * DAY),
      terminal("week", 10 * DAY), terminal("month", 40 * DAY), terminal("asks", 40 * DAY, true)})})
    -- A Terminal Session that needs the user stays visible however old it is.
    test.same(titles(view), {"recent", "days", "asks"})
    local index = row_index(view, function(row) return row.kind == "terminal_group" and row.bucket == "older" end)
    view:on_mouse_pressed("left", 20, view:row_y(index) + 2, 240)
    test.same(titles(view), {"recent", "days", "asks", "month"})
  end)

  test.it("shows an unloaded Project's running Terminal Sessions as a hint on its row", function()
    local view = SidebarView(function() end, {["group:week"]=false})
    view:set_size(400, 800)
    local function terminal(id, state, busy)
      return {id=id,title=id,cwd="C:/P",state=state,busy=busy,activity=now}
    end
    view:set_model({project(1, "C:/P", DAY, "dormant", {terminal("a", "running", 1), terminal("b", "running", 0),
      terminal("c", "exited", 0)})})
    test.equal(count(view, "terminal"), 0, "An unloaded Project lists its Terminal Sessions")
    local text = joined(drawn_texts(view, 400, 800))
    test.ok(text:find("2 terminals, 1 busy", 1, true), "The hint is missing: " .. text)
  end)

  test.it("expands a Project each time it becomes selected and saves a collapse made there", function()
    local function model(selected)
      local function project(id, name)
        return {row_id=id,id=id,path="C:/" .. name,state="ready",window_id=1,terminals={},
          panes={active=1,visible=1,{id=name .. "-pane",name=name .. ".lua",group=1}}}
      end
      return {project(1, "A"), project(2, "B"), windows={{id=1,selected_project=selected}}}
    end
    local actions, action = recorder()
    local view = SidebarView(action, {["project:C:/A"]=true, ["project:C:/B"]=true})
    local function shown_tabs()
      local names = {}
      for _, row in ipairs(view.rows) do
        if row.kind == "tab" then names[#names + 1] = row.tab.name end
      end
      return table.concat(names, ",")
    end
    local function toggle_first()
      view:on_mouse_pressed("left", 235, row_y(view, "project", 1))
    end
    view:set_model(model(1), 1)
    test.equal(shown_tabs(), "A.lua", "The Selected Project does not expand")
    test.same(view.collapsed, {["project:C:/A"]=true, ["project:C:/B"]=true})
    -- A collapse while the Project is selected acts and is saved.
    toggle_first()
    test.equal(shown_tabs(), "", "The Selected Project does not collapse")
    toggle_first()
    test.equal(shown_tabs(), "A.lua")
    test.same(actions, {{"collapsed", "project:C:/A", true}, {"collapsed", "project:C:/A", false}})
    toggle_first()
    test.equal(shown_tabs(), "")
    -- Another Project's selection expands it and leaves A collapsed. Selecting A again expands it again.
    view:set_model(model(2), 1)
    test.equal(shown_tabs(), "B.lua")
    view:set_model(model(1), 1)
    test.equal(shown_tabs(), "A.lua", "A does not expand when it is selected again")
    test.same(view.collapsed, {["project:C:/A"]=true, ["project:C:/B"]=true})
  end)

  test.it("restores collapsed groups and reports changes for the next Sidebar", function()
    local actions, action = recorder()
    local view = SidebarView(action, {["group:older"] = true})
    view:set_size(240, 800)
    view:set_model({project(1, "C:/Old", 60 * DAY)})
    test.same(paths(view, "bottom"), {})
    local index = row_index(view, function(row) return row.kind == "group" and row.bucket == "older" end)
    view:on_mouse_pressed("left", 20, view:row_y(index) + 2, 240)
    test.same(paths(view, "bottom"), {"C:/Old"})
    test.same(actions, {{"collapsed", "group:older", false}})
  end)

  test.it("shows each Terminal Session's live title", function()
    local view = SidebarView(function() end)
    view:set_size(240, 800)
    view:set_model({project(1, "C:/P", 60, "ready",
      {{id="a",title="[40 s] \u{03C0} - GLP4",cwd="C:/P",state="running",busy=1,activity=now},
       {id="b",title="",cwd="C:/P",state="running",busy=0,activity=now}})})
    local text = joined(drawn_texts(view, 240, 800))
    test.ok(text:find("[40 s] \u{03C0} - GLP4", 1, true), "The live title is missing")
    test.ok(text:find("Terminal", 1, true), "An untitled Terminal Session has no label")
  end)

  test.it("shortens a long Project name with an ellipsis inside a narrow Sidebar", function()
    local view = SidebarView(function() end)
    view:set_model({project(1, "C:/Israel Mallo Mart\u{00ED}nez - ManualSistemas", 60, "ready", {})})
    local label
    for _, item in ipairs(drawn_texts(view, 170, 800)) do if item.text:find("^Israel") then label = item end end
    test.not_nil(label, "The Project name is missing")
    test.ok(label.text:find("\u{2026}$"), "The long name is not shortened: " .. label.text)
    test.ok(label.right <= 170, "The shortened name runs past the Sidebar's edge")
  end)
end)

test.describe("Sidebar Terminal spinners", function()
  local now = os.time()

  local function view_with(title)
    local view = SidebarView(function() end)
    view:set_model({{row_id=1,id=1,path="C:/P",state="ready",exists=true,activity=now,terminals={
      {id="t",title=title,cwd="C:/P",state="running",busy=1,activity=now}}}})
    return view
  end

  -- The Terminal title the view draws at the clock time `time`.
  local function title_at(view, time)
    local old_time = system.get_time
    system.get_time = function() return time end
    local ok, texts = pcall(drawn_texts, view, 400, 800)
    system.get_time = old_time
    if not ok then error(texts, 0) end
    local title
    for _, item in ipairs(texts) do if item.text:find("GLP4") then title = item.text end end
    return test.not_nil(title, "The Terminal title is missing")
  end

  test.it("turns a working Terminal's braille spinner between title reports", function()
    local view = view_with("\u{280B} [17 s] \u{03C0} - GLP4")
    local first = title_at(view, 100)
    local delay = test.not_nil(view:animation_delay(100), "The Sidebar does not ask for the spinner's next frame")
    local second = title_at(view, 100 + delay)
    test.ok(first ~= second, "The spinner did not turn: " .. first)
    test.equal(first:sub(4), " [17 s] \u{03C0} - GLP4")
    test.equal(second:sub(4), " [17 s] \u{03C0} - GLP4")
  end)

  test.it("leaves a Terminal title without a spinner still", function()
    local view = view_with("\u{03C0} - GLP4")
    test.equal(title_at(view, 100), "\u{03C0} - GLP4")
    test.equal(view:animation_delay(100), nil)
  end)
end)

test.describe("Sidebar agent status", function()
  local style = require "core.style"
  local now = os.time()

  local drawn, find = drawn_texts, find_text

  -- A loaded Project whose second Pane shows the Terminal Session "a". The first Pane is active.
  local function model(agent, active)
    local session = {id="a",title="\u{03C0} - GLP4",cwd="C:/P",state="running",busy=1,activity=now}
    for key, value in pairs(agent) do session[key] = value end
    return {{row_id=1,id=1,path="C:/P",state="ready",window_id=1,exists=true,activity=now,terminals={session},
      panes={active=active or 1,visible=1,
        {id="pane-1",group=1,name="init.lua"},
        {id="pane-2",group=2,name="\u{03C0} - GLP4",terminal={session="a",state="running",busy=true}}}},
      windows={{id=1,selected_project=1}}}
  end

  test.it("shows the agent's current step and how long it runs below its Tab", function()
    local view = SidebarView(function() end)
    view:set_model(model({agent_state="working",agent_message="GLP4",agent_since=now-300,
      agent_step="bash: npm test",agent_step_since=now-42}), 1)
    -- The clock stays at the model's time, so the step's age cannot pass another second.
    local old_time = os.time
    os.time = function(date) return date and old_time(date) or now end
    local ok, texts = pcall(drawn, view)
    os.time = old_time
    if not ok then error(texts, 0) end
    test.ok(find(texts, "bash: npm test"), "The step is missing: " .. joined(texts))
    test.ok(find(texts, "42s"), "The step's time is missing: " .. joined(texts))
    test.not_nil(view:animation_delay(0), "The step's time does not count on")
  end)

  test.it("shows what a waiting agent asks for", function()
    local view = SidebarView(function() end)
    view:set_model(model({agent_state="blocked",agent_kind="permission",agent_message="Allow write?",agent_since=now}), 1)
    local item = find(drawn(view), "Needs you: Allow write?")
    test.not_nil(item, "The question is missing")
    test.same(item.color, style.warn)
  end)

  test.it("marks an agent's result until its Tab was active", function()
    local view = SidebarView(function() end)
    local result = {agent_state="done",agent_message="GLP4",agent_since=now-120}
    view:set_model(model(result, 1), 1)
    local unseen = test.not_nil(find(drawn(view), "Done"), "The result is missing")
    view:set_model(model(result, 2), 1)
    view:set_model(model(result, 1), 1)
    local seen = test.not_nil(find(drawn(view), "Done"), "The seen result is missing")
    test.ok(unseen.color ~= seen.color, "The result looks the same before and after its Tab was active")
    test.same(seen.color, style.dim)
  end)

  test.it("counts agents that need an answer in an unloaded Project's hint", function()
    local view = SidebarView(function() end, {["group:week"]=false})
    local function terminal(id, fields)
      local item = {id=id,title=id,cwd="C:/P",state="running",busy=1,activity=now}
      for key, value in pairs(fields) do item[key] = value end
      return item
    end
    view:set_model({{row_id=1,path="C:/P",state="dormant",exists=true,activity=now,terminals={
      terminal("a", {agent_state="blocked",agent_since=now}),
      terminal("b", {agent_state="working",agent_since=now}),
      terminal("c", {agent_state="idle",agent_since=now})}}})
    local texts = drawn(view)
    test.ok(find(texts, "3 terminals, 1 busy, 1 needs you"), "The hint is wrong: " .. joined(texts))
  end)
end)

test.describe("Sidebar unread results", function()
  local now = os.time()

  local function session(id, fields)
    local item = {id=id,title=id,cwd="C:/P",state="running",busy=1,activity=now}
    for key, value in pairs(fields or {}) do item[key] = value end
    return item
  end

  -- Project P shows a file and one Terminal Tab for each session that is not detached. Project Q is the Window's
  -- Selected Project unless `opts.selected` is set. `opts.active` is P's active Pane.
  local function model(sessions, opts)
    opts = opts or {}
    local panes = {active=opts.active or 1,visible=1,{id="file",group=1,name="init.lua"}}
    local records = {}
    for index, item in ipairs(sessions) do
      local record = {}
      for key, value in pairs(item) do record[key] = value end
      record.detached, record.bell = nil, nil
      records[#records + 1] = record
      if not item.detached then
        panes[#panes + 1] = {id=item.id,group=index + 1,name=item.id,
          terminal={session=item.id,state="running",busy=true,bell=item.bell}}
      end
    end
    return {{row_id=1,id=1,path="C:/P",state="ready",window_id=1,terminals=records,panes=panes},
      {row_id=2,id=2,path="C:/Q",state="ready",window_id=1,terminals={},panes={active=1,visible=1,
        {id="q",group=1,name="q.lua"}}},
      windows={{id=1,selected_project=opts.selected and 1 or 2}}}
  end

  local function shown(view)
    local names = {}
    for _, row in ipairs(view.rows) do
      if (row.kind == "tab" or row.kind == "terminal") and row.project.path == "C:/P" then
        names[#names + 1] = row.tab.name
      end
    end
    return table.concat(names, ",")
  end

  -- The colours of the small round dots that a draw shows.
  local function dots(view)
    local colors = {}
    with_renderer({draw_rounded_rect = function(_, _, w, h, _, color)
      if w == h and w <= 10 * SCALE then colors[#colors + 1] = color end
    end}, function() view:draw(400, 800) end)
    return colors
  end

  test.it("keeps a collapsed Project's Terminals with unread results or questions visible", function()
    local view = SidebarView(function() end, {["project:C:/P"]=true}, {})
    view:set_model(model({
      session("done", {agent_state="done",agent_since=now - 60}),
      session("failed", {agent_state="error",agent_since=now - 60}),
      session("asks", {agent_state="blocked",agent_since=now - 60}),
      session("works", {agent_state="working",agent_since=now - 60}),
      session("waits", {agent_state="idle",agent_since=now - 60}),
      session("rang", {bell=now - 30}),
      session("command", {command_started=now - 60,command_finished=now - 50,command_exit=0}),
      session("detached", {detached=true,agent_state="done",agent_since=now - 60}),
    }), 1)
    test.equal(shown(view), "done,failed,asks,rang,detached")
    test.equal(#dots(view), 5, "Each shown Terminal does not have one dot")
  end)

  test.it("draws no dot for a Terminal that does not need the user", function()
    local view = SidebarView(function() end, {}, {})
    view:set_model(model({session("works", {agent_state="working",agent_since=now - 60}),
      session("idle", {busy=0}), session("waits", {agent_state="idle",agent_since=now - 60})}), 1)
    test.equal(shown(view), "init.lua,works,idle,waits")
    test.same(dots(view), {})
  end)

  test.it("marks a result read once its Tab was active, for every Window and the next Sidebar", function()
    local actions, action = recorder()
    local seen = {}
    local done = session("done", {agent_state="done",agent_since=now - 60})
    local view = SidebarView(action, {["project:C:/P"]=true}, seen)
    view:set_model(model({done}, {selected=true, active=2}), 1)
    test.same(actions, {{"seen", "done"}})
    -- Another Window's Sidebar, or the next Sidebar process, starts from the same table.
    local other = SidebarView(function() end, {["project:C:/P"]=true}, seen)
    other:set_model(model({done}), 1)
    test.equal(shown(other), "", "A read result stays under the collapsed Project")
    -- A later result is unread again.
    other:set_model(model({session("done", {agent_state="done",agent_since=now + 3600})}), 1)
    test.equal(shown(other), "done")
  end)
end)

test.describe("Sidebar search field", function()
  local style = require "core.style"
  test.it("shows the search field only while a query is typed", function()
    local view = SidebarView(function() end)
    view:set_model({{row_id=1,path="C:/Alpha",state="ready",terminals={}},
      {row_id=2,path="C:/Beta",state="ready",terminals={}}})
    local function search_icon(texts)
      for _, item in ipairs(texts) do
        if item.text == "L" and item.color == style.accent then return item end
      end
    end
    local idle = drawn_texts(view)
    test.is_nil(search_icon(idle), "An unfocused Sidebar shows the search field")
    local alpha_y = test.not_nil(find_text(idle, "Alpha")).y
    view:on_focus(true)
    test.is_nil(search_icon(drawn_texts(view)), "A focused Sidebar without a query shows the search field")
    view:on_text_input("al")
    local searching = drawn_texts(view)
    test.not_nil(search_icon(searching), "The search field does not show while a query is typed")
    test.not_nil(find_text(searching, "al"), "The query is not drawn")
    test.ok(test.not_nil(find_text(searching, "Alpha")).y > alpha_y, "The list does not make room for the field")
    view:edit("backspace")
    view:edit("backspace")
    local cleared = drawn_texts(view)
    test.is_nil(search_icon(cleared), "The search field stays after the query is erased")
    test.equal(test.not_nil(find_text(cleared, "Alpha")).y, alpha_y)
  end)
end)

test.describe("Sidebar search editing", function()
  local style = require "core.style"

  local function searching(text)
    local view = SidebarView(function() end)
    view:set_model({{row_id=1,id=1,path="C:/Alpha",state="ready",terminals={}}})
    view:on_focus(true)
    if text then view:on_text_input(text) end
    return view
  end

  -- Runs `fn` with a fake system clipboard, and returns what it holds afterwards.
  local function with_clipboard(content, fn)
    local get, set = system.get_clipboard, system.set_clipboard
    system.get_clipboard = function() return content end
    system.set_clipboard = function(text) content = text end
    local ok, err = pcall(fn)
    system.get_clipboard, system.set_clipboard = get, set
    if not ok then error(err, 0) end
    return content
  end

  test.it("replaces the selected part of the query with typed text", function()
    local view = searching("alpha beta")
    test.ok(view:edit("select_to_previous_word_start"))
    view:on_text_input("gamma")
    test.equal(view.query, "alpha gamma")
    view:edit("move_to_start_of_indentation")
    view:edit("select_to_next_word_end")
    view:on_text_input("x")
    test.equal(view.query, "x gamma")
    view:edit("move_to_end_of_line")
    view:edit("select_to_start_of_indentation")
    view:on_text_input("y")
    test.equal(view.query, "y")
    view:edit("select_all")
    view:edit("backspace")
    test.equal(view.query, "")
    test.not_ok(view:search_open(), "Erasing the selected query leaves the search field open")
  end)

  test.it("moves the caret and deletes around it a whole UTF-8 character at a time", function()
    local view = searching("a\u{00E9}b")
    view:edit("move_to_previous_char")
    view:edit("backspace")
    test.equal(view.query, "ab")
    view:edit("delete")
    test.equal(view.query, "a")
    -- A caret move ends a selection at the selection's edge.
    view = searching("abc")
    view:edit("select_all")
    view:edit("move_to_previous_char")
    view:on_text_input("x")
    test.equal(view.query, "xabc")
  end)

  test.it("deletes words with the editor's word rule", function()
    local view = searching("foo.bar baz")
    local steps = {}
    for _ = 1, 4 do
      view:edit("delete_to_previous_word_start")
      steps[#steps + 1] = view.query
    end
    test.same(steps, {"foo.bar ", "foo.", "foo", ""})
  end)

  test.it("copies, cuts and pastes one line through the clipboard", function()
    local clipboard = with_clipboard("", function()
      local view = searching("alpha beta")
      view:edit("select_to_previous_word_start")
      view:edit("cut")
      test.equal(view.query, "alpha ")
      view:edit("move_to_start_of_indentation")
      view:edit("paste")
      test.equal(view.query, "betaalpha ")
    end)
    test.equal(clipboard, "beta")
    with_clipboard("one\r\ntwo", function()
      local view = searching("x")
      view:edit("select_all")
      view:edit("paste")
      test.equal(view.query, "one two")
    end)
  end)

  test.it("leaves caret keys to the list while no query is typed, and pastes to start a search", function()
    local view = searching()
    test.not_ok(view:edit("move_to_previous_char"))
    test.not_ok(view:edit("move_to_start_of_indentation"))
    test.not_ok(view:edit("backspace"))
    with_clipboard("alp", function() test.ok(view:edit("paste")) end)
    test.equal(view.query, "alp")
  end)

  test.it("places the caret and selects with the pointer in the search field", function()
    local view = searching("alpha")
    view:set_size(300, 600)
    local m = view:metrics()
    local y = m.search_y + m.search / 2
    view:on_mouse_pressed("left", m.pad + 2, y)
    view:on_text_input("x")
    test.equal(view.query, "xalpha")
    view:on_mouse_pressed("left", 300 - m.pad - 2, y)
    view:on_mouse_moved(m.pad + 2, y)
    view:on_mouse_released("left", m.pad + 2, y)
    view:on_text_input("z")
    test.equal(view.query, "z")
  end)

  test.it("scrolls a long query to keep the caret in the field", function()
    local view = searching(string.rep("long query ", 8))
    local function caret_x()
      local x
      with_renderer({draw_rect = function(left, y, w, h, color)
        if color == style.accent and w < 4 * SCALE then x = left end
      end}, function() view:draw(240, 600) end)
      return x
    end
    local left, _, width = view:search_box()
    local at_end = test.not_nil(caret_x())
    test.ok(at_end >= left and at_end <= left + width, "The caret at the end is outside the field")
    view:edit("move_to_start_of_indentation")
    local at_start = test.not_nil(caret_x())
    test.ok(at_start >= left and at_start < at_end, "The caret at the start is outside the field")
  end)

  test.it("highlights the selected text", function()
    local view = searching("alpha")
    local function highlights()
      local found = 0
      with_renderer({draw_rect = function(x, y, w, h, color)
        if color == style.selection then found = found + 1 end
      end}, function() view:draw(300, 600) end)
      return found
    end
    test.equal(highlights(), 0)
    view:edit("select_all")
    test.equal(highlights(), 1)
  end)
end)

test.describe("Sidebar pending Pane numbers", function()
  -- Two Projects in two Windows. `stamped` gives the Panes pending results.
  local function model(stamped)
    local function at(time) return stamped and time or nil end
    return {
      {row_id=1,id=1,path="C:/A",state="ready",window_id=1,terminals={},panes={active=1,visible=1,
        {id="a1",group=1,name="current.lua",focused=at(30)},{id="a2",group=2,name="never.lua"}}},
      {row_id=2,id=2,path="C:/B",state="ready",window_id=2,terminals={},panes={visible=1,
        {id="b1",group=1,name="older.lua",terminal={session="old",state="running",bell=at(10)}},
        {id="b2",group=2,name="previous.lua",terminal={session="new",state="running",bell=at(20)}}}},
      windows={{id=1,selected_project=1},{id=2,selected_project=2}}}
  end

  test.it("numbers pending Tabs FIFO across Windows", function()
    local view = SidebarView(function() end)
    view:set_model(model(true), 1)
    local texts = drawn_texts(view, 400, 800)
    local numbers = {}
    for _, item in ipairs(texts) do
      if item.text:match("^%d$") then
        -- The number and the name of one Tab share a row.
        for _, name in ipairs(texts) do
          if name.text:match("%.lua$") and math.abs(name.y - item.y) < 4 then numbers[name.text] = item.text end
        end
      end
    end
    test.same(numbers, {["older.lua"] = "1", ["previous.lua"] = "2"})
  end)

  test.it("draws the numbers beside the Tabs, so they move no row content", function()
    local view = SidebarView(function() end)
    view:set_model(model(false), 1)
    local plain = drawn_texts(view, 400, 800)
    view:set_model(model(true), 1)
    local numbered = drawn_texts(view, 400, 800)
    for _, name in ipairs {"current.lua", "never.lua", "older.lua", "previous.lua"} do
      test.equal(find_text(numbered, name).x, find_text(plain, name).x, name .. " moved for the numbers")
    end
    test.ok(find_text(numbered, "1").right <= view:metrics().tab_left, "The number is inside its Tab's row")
  end)
end)

test.describe("Sidebar Project badges", function()
  local style = require "core.style"
  test.it("centres the badge letter's ink in its badge", function()
    local old_font = style.font
    local ok, err = pcall(function()
      for size = 12, 20 do
        style.font = renderer.font.load(DATADIR .. "/fonts/FiraSans-Regular.ttf", size * SCALE)
        local view = SidebarView(function() end)
        view:set_model({{row_id=1,id=1,path="C:/Projects/programming",state="ready",terminals={}}})
        local badge_size, badge, letter = view:metrics().badge
        with_renderer({
          draw_rounded_rect = function(x, y, w, h)
            if w == badge_size and h == badge_size then badge = {x = x, y = y} end
          end,
          draw_text = function(font, text, x, y)
            if text == "P" then letter = {font = font, y = y} end
          end,
        }, function() view:draw(400, 800) end)
        test.not_nil(badge, "No badge is drawn")
        test.not_nil(letter, "No badge letter is drawn")
        local top, bottom = letter.font:get_ink_extent("P")
        local offset = letter.y + (top + bottom) / 2 - (badge.y + badge_size / 2)
        test.ok(math.abs(offset) <= 0.5,
          ("At size %d the letter's centre is %.2f px from the badge's centre"):format(size, offset))
      end
    end)
    style.font = old_font
    if not ok then error(err, 0) end
  end)
end)

test.describe("Sidebar motion", function()
  local config = require "core.config"
  local style = require "core.style"

  local function project(id, name)
    return {row_id=id,id=id,path="C:/" .. name,state="ready",terminals={}}
  end

  -- Runs `fn` with transitions on or off and a clock that only `advance` moves, so each draw is one frame. Lua
  -- tests run with transitions off.
  local function with_clock(transitions, fn)
    local old_time, old_transitions, time = system.get_time, config.transitions, 100
    system.get_time = function() return time end
    config.transitions = transitions
    local ok, err = pcall(fn, function(seconds) time = time + seconds; return time end)
    system.get_time, config.transitions = old_time, old_transitions
    if not ok then error(err, 0) end
  end

  local function text_y(view, label)
    return test.not_nil(find_text(drawn_texts(view), label), label .. " is not drawn").y
  end

  test.it("slides a row to its new place when a Project above it loads", function()
    with_clock(true, function(advance)
      local view = SidebarView(function() end)
      view:set_model({project(2, "Beta")})
      local start = text_y(view, "Beta")
      local fresh = SidebarView(function() end)
      fresh:set_model({project(1, "Alpha"), project(2, "Beta")})
      local target = text_y(fresh, "Beta")
      test.ok(target > start, "The new Project does not take the place above")
      view:set_model({project(1, "Alpha"), project(2, "Beta")})
      local now = advance(1 / 60)
      local moving = text_y(view, "Beta")
      test.ok(moving > start and moving < target, ("The row did not slide: %s to %s, at %s"):format(start, target, moving))
      test.not_nil(view:animation_delay(now), "The Sidebar does not ask for the next frame")
      for _ = 1, 60 do advance(1 / 30); drawn_texts(view) end
      test.equal(text_y(view, "Beta"), target)
      test.is_nil(view:animation_delay(advance(0)), "The Sidebar keeps drawing after the row arrived")
    end)
  end)

  test.it("shimmers the status line of a working Terminal only", function()
    with_clock(true, function(advance)
      local function sidebar(agent_state, step)
        local view = SidebarView(function() end)
        view:set_model({{row_id=1,id=1,path="C:/A",state="ready",window_id=1,
          terminals={{id="s",title="pwsh",state="running",busy=1,agent_state=agent_state,agent_step=step}},
          panes={active=1,visible=1,{id="p",name="pwsh",group=1,
            terminal={session="s",state="running",busy=true}}}}, windows={{id=1,selected_project=1}}}, 1)
        -- Let the rows arrive.
        for _ = 1, 90 do advance(1 / 30); drawn_texts(view) end
        return view
      end
      -- Watches five seconds of frames. Returns the colours of the drawn parts of `line`, and the shortest frame delay.
      local function watch(view, line)
        local colors, shortest = {}, nil
        for _ = 1, 150 do
          with_renderer({draw_text = function(_, text, _, _, color)
            if text ~= "" and line:find(text, 1, true) then
              colors[table.concat(color, ",")] = true
            end
          end}, function() view:draw(400, 800) end)
          local delay = view:animation_delay(advance(0))
          if delay then shortest = math.min(shortest or delay, delay) end
          advance(1 / 30)
        end
        local count = 0
        for _ in pairs(colors) do count = count + 1 end
        return count, shortest
      end
      local count, delay = watch(sidebar("working", "Thinking"), "Thinking")
      test.ok(count > 1, "A working agent's step does not shimmer")
      test.ok(delay and delay <= 1 / 30, "A working agent does not ask for the next frame")
      -- An agent waiting at its prompt keeps its shell busy, but it does not work.
      count, delay = watch(sidebar("idle"), "Idle")
      test.equal(count, 1, "An agent at its prompt shimmers")
      test.is_nil(delay, "An agent at its prompt keeps the Sidebar drawing")
    end)
  end)

  test.it("places rows at once when transitions are off", function()
    with_clock(false, function(advance)
      local view = SidebarView(function() end)
      view:set_model({project(2, "Beta")})
      drawn_texts(view)
      local fresh = SidebarView(function() end)
      fresh:set_model({project(1, "Alpha"), project(2, "Beta")})
      local target = text_y(fresh, "Beta")
      view:set_model({project(1, "Alpha"), project(2, "Beta")})
      advance(1 / 60)
      test.equal(text_y(view, "Beta"), target)
    end)
  end)

  test.it("glides the keyboard cursor's highlight to the next row", function()
    with_clock(true, function(advance)
      local view = SidebarView(function() end)
      view:set_model({project(1, "Alpha"), project(2, "Beta")})
      view:on_focus(true)
      -- The cursor's highlight is the only box in the row selection colour while the Sidebar has focus.
      local function highlight_y()
        local y
        with_renderer({draw_rounded_rect = function(_, top, _, _, _, color)
          if color == style.row_selection then y = top end
        end}, function() view:draw(400, 800) end)
        return test.not_nil(y, "The cursor has no highlight")
      end
      local first = highlight_y()
      view:on_key_pressed("down")
      test.equal(view:get_cursor().project.row_id, 2)
      advance(1 / 60)
      local moving = highlight_y()
      for _ = 1, 60 do advance(1 / 30); highlight_y() end
      local last = highlight_y()
      test.ok(moving > first and moving < last, ("The highlight did not glide: %s to %s, at %s"):format(first, last, moving))
      test.equal(last - first, view:row_y(2) - view:row_y(1))
    end)
  end)
end)

test.describe("Sidebar drag and drop", function()
  -- Project A has a one-Pane group, a two-Pane group, another one-Pane group and a Terminal's group.
  local function model()
    return {
      {row_id=1,id=11,path="C:/A",state="ready",window_id=5,terminals={{id="s1",title="pwsh",state="running"}},
        panes={active=1,visible=1,
          {id="pane-1",group=1,name="one.lua"},
          {id="pane-2",group=2,name="two.lua"},
          {id="pane-3",group=2,name="three.lua"},
          {id="pane-4",group=3,name="four.lua"},
          {id="pane-5",group=4,name="pwsh",terminal={session="s1",state="running"}}}},
      {row_id=2,id=12,path="C:/B",state="ready",window_id=5,terminals={},panes={active=1,visible=1,
        {id="pane-8",group=1,name="b.lua"}}},
      {row_id=3,path="C:/C",state="dormant",exists=true,activity=os.time(),terminals={}},
      windows={{id=5,selected_project=11}},
    }
  end

  local function sidebar(projects)
    local actions, action = recorder()
    local view = SidebarView(action, {["group:week"]=false})
    view:set_size(300, 800)
    view:set_model(projects or model(), 5)
    return view, actions
  end

  -- A point at `part` of a row's height, from its top.
  local function tab_y(view, id, part)
    for index, row in ipairs(view.rows) do
      if row.kind == "tab" and row.tab.id == id then return view:row_y(index) + row.h * part end
    end
    error("no Tab " .. id)
  end

  local function project_y(view, path)
    for index, row in ipairs(view.rows) do
      if row.kind == "project" and row.project.path == path then return view:row_y(index) + row.h / 2 end
    end
    error("no Project " .. path)
  end

  -- Drags a Tab from its middle and releases it at (x, y). Returns the actions after the press's focus request.
  local function drag(view, actions, id, y, x)
    local first = #actions + 2
    local start = tab_y(view, id, 0.5)
    view:on_mouse_pressed("left", 60, start)
    view:on_mouse_moved(60, start + 10 * SCALE)
    view:on_mouse_moved(x or 60, y)
    view:on_mouse_released("left", x or 60, y)
    return {table.unpack(actions, first)}
  end

  local function move(id, target)
    return {"request", "direct", "C:/A", {action = "move", pane = id, target = target}}
  end

  test.it("moves a Tab dropped between two Tabs into a new Pane Group there", function()
    local view, actions = sidebar()
    test.same(drag(view, actions, "pane-1", tab_y(view, "pane-4", 0.25)),
      {move("pane-1", {mode = "group", anchor = "pane-4", side = "before"})})
  end)

  test.it("adds a Tab dropped between a Pane Group's Tabs to that group", function()
    local view, actions = sidebar()
    test.same(drag(view, actions, "pane-4", tab_y(view, "pane-2", 0.75)),
      {move("pane-4", {mode = "join", anchor = "pane-2", side = "after"})})
  end)

  test.it("places a new Pane Group beside a group at the group's outer edge", function()
    local view, actions = sidebar()
    test.same(drag(view, actions, "pane-1", tab_y(view, "pane-3", 0.75)),
      {move("pane-1", {mode = "join", anchor = "pane-3", side = "after"})})
    test.same(drag(view, actions, "pane-1", tab_y(view, "pane-3", 0.95)),
      {move("pane-1", {mode = "group", anchor = "pane-3", side = "after"})})
  end)

  test.it("places a Tab dropped below a Project's last Tab after it", function()
    local view, actions = sidebar()
    local gap_y = tab_y(view, "pane-5", 1) + view:metrics().project_gap / 2
    test.same(drag(view, actions, "pane-1", gap_y),
      {move("pane-1", {mode = "group", anchor = "pane-5", side = "after"})})
  end)

  test.it("moves a Tab out of its Pane Group into a group of its own", function()
    local view, actions = sidebar()
    test.same(drag(view, actions, "pane-3", tab_y(view, "pane-3", 0.95)),
      {move("pane-3", {mode = "group", anchor = "pane-3", side = "after"})})
  end)

  test.it("adds a Tab dropped on another Tab's middle to that Tab's Pane Group", function()
    local view, actions = sidebar()
    test.same(drag(view, actions, "pane-1", tab_y(view, "pane-4", 0.5)),
      {move("pane-1", {mode = "join", anchor = "pane-4", side = "after"})})
  end)

  test.it("sends nothing for a drop that leaves the layout as it is", function()
    local view, actions = sidebar()
    test.same(drag(view, actions, "pane-1", tab_y(view, "pane-1", 0.5)), {}, "Its own row")
    test.same(drag(view, actions, "pane-4", tab_y(view, "pane-3", 0.95)), {}, "After the group before its own")
    test.same(drag(view, actions, "pane-3", tab_y(view, "pane-2", 0.75)), {}, "Its own place in its group")
    test.same(drag(view, actions, "pane-1", tab_y(view, "pane-4", 0.5), -20), {}, "A release left of the Sidebar")
  end)

  test.it("keeps a short press a click", function()
    local view, actions = sidebar()
    local y = tab_y(view, "pane-2", 0.5)
    view:on_mouse_pressed("left", 60, y)
    view:on_mouse_moved(62, y + 2)
    view:on_mouse_released("left", 62, y + 2)
    test.same(actions, {{"request", "select", "C:/A", {action = "focus", pane = "pane-2"}}})
  end)

  test.it("continues a drag right of the Sidebar in the Selected Project's work area", function()
    local view, actions = sidebar()
    local function work(phase, x, y)
      return {"request", "pointer", nil, {action = "drag", phase = phase, source = "C:/A", pane = "pane-2"}, x, y}
    end
    local start = tab_y(view, "pane-2", 0.5)
    view:on_mouse_pressed("left", 60, start)
    view:on_mouse_moved(60, start + 10)
    view:on_mouse_moved(400, 200)
    view:on_mouse_moved(60, 210)
    view:on_mouse_moved(450, 220)
    view:on_mouse_released("left", 450, 220)
    test.same({table.unpack(actions, 2)},
      {work("move", 400, 200), work("leave", 60, 210), work("move", 450, 220), work("drop", 450, 220)})
  end)

  test.it("ends a work-area drag when the pointer leaves the Window", function()
    local view, actions = sidebar()
    local start = tab_y(view, "pane-2", 0.5)
    view:on_mouse_pressed("left", 60, start)
    view:on_mouse_moved(60, start + 10)
    view:on_mouse_moved(400, 200)
    view:on_mouse_left()
    test.same(actions[#actions][4], {action = "drag", phase = "leave", source = "C:/A", pane = "pane-2"})
  end)

  test.it("asks the source Project to move a Tab dropped on another Project", function()
    local view, actions = sidebar()
    for _, path in ipairs({"C:/B", "C:/C"}) do
      local sent = drag(view, actions, "pane-1", project_y(view, path))
      test.equal(#sent, 1)
      local route, from, request = sent[1][2], sent[1][3], sent[1][4]
      test.same({route, from, request.action, request.pane, request.to}, {"direct", "C:/A", "export", "pane-1", path})
      test.same(request.target, {mode = "group"})
      test.equal(type(request.transfer), "string")
    end
  end)

  test.it("places a Tab moved to another Project beside that Project's Tabs", function()
    local view, actions = sidebar()
    local sent = drag(view, actions, "pane-1", tab_y(view, "pane-8", 0.5))
    test.equal(sent[1][4].to, "C:/B")
    test.same(sent[1][4].target, {mode = "join", anchor = "pane-8", side = "after"})
  end)

  test.it("keeps a Terminal's Tab in its Project", function()
    local view, actions = sidebar()
    test.same(drag(view, actions, "pane-5", project_y(view, "C:/B")), {})
    test.same(drag(view, actions, "pane-5", tab_y(view, "pane-1", 0.25)),
      {move("pane-5", {mode = "group", anchor = "pane-1", side = "before"})})
  end)

  test.it("scrolls the list while a dragged Tab waits near its edge", function()
    local panes = {active=1,visible=1}
    for i = 1, 60 do panes[i] = {id="pane-" .. i,group=i,name="file" .. i .. ".lua"} end
    local view, actions = sidebar({{row_id=1,id=11,path="C:/A",state="ready",terminals={},panes=panes},
      windows={{id=5,selected_project=11}}})
    view:set_size(300, 400)
    local old_time, time = system.get_time, 100
    system.get_time = function() return time end
    local ok, err = pcall(function()
      with_renderer({}, function() view:draw(300, 400) end)
      local edge = 398
      local _, before = view:row_at(edge)
      local start = tab_y(view, "pane-1", 0.5)
      view:on_mouse_pressed("left", 60, start)
      view:on_mouse_moved(60, start + 10 * SCALE)
      view:on_mouse_moved(60, edge)
      for _ = 1, 10 do
        time = time + 1 / 30
        with_renderer({}, function() view:draw(300, 400) end)
      end
      local row, after = view:row_at(edge)
      test.ok(after > before, "The list did not scroll")
      view:on_mouse_released("left", 60, edge)
      test.equal(actions[#actions][4].target.anchor, row.tab.id)
    end)
    system.get_time = old_time
    if not ok then error(err, 0) end
  end)
end)

test.describe("Sidebar drops from other applications", function()
  local function sidebar()
    local actions, action = recorder()
    local view = SidebarView(action, {["group:week"]=false})
    view:set_size(300, 800)
    view:set_model({{row_id=1,id=11,path="C:/A",state="ready",window_id=5,terminals={},panes={active=1,visible=1,
      {id="pane-1",group=1,name="one.lua"},{id="pane-2",group=2,name="two.lua"}}},
      {row_id=3,path="C:/C",state="dormant",exists=true,activity=os.time(),terminals={}},
      windows={{id=5,selected_project=11}}}, 5)
    return view, actions
  end

  local function point(view, kind, id, part)
    for index, row in ipairs(view.rows) do
      if row.kind == kind and (row.tab and row.tab.id or row.project.path) == id then
        return view:row_y(index) + row.h * part
      end
    end
    error("no row " .. id)
  end

  test.it("opens files dropped between Tabs in a new Pane Group there", function()
    local view, actions = sidebar()
    view:on_drop_begin()
    local y = point(view, "tab", "pane-2", 0.25)
    view:on_file_dropped("C:/notes/a.md", 60, y)
    view:on_file_dropped("C:/notes/b.png", 60, y)
    test.ok(view:on_drop_complete())
    test.same(actions, {{"request", "select", "C:/A", {action = "open", files = {"C:/notes/a.md", "C:/notes/b.png"},
      target = {mode = "group", anchor = "pane-2", side = "before"}}}})
  end)

  test.it("gives text dropped on a Tab's middle to its Pane", function()
    local view, actions = sidebar()
    view:on_drop_begin()
    view:on_text_dropped("one\r\ntwo", 60, point(view, "tab", "pane-1", 0.5))
    view:on_drop_complete()
    test.same(actions, {{"request", "select", "C:/A", {action = "drop", pane = "pane-1", text = "one\ntwo"}}})
  end)

  test.it("opens a drop on a Project's row in that Project, also when it is unloaded", function()
    local view, actions = sidebar()
    view:on_drop_begin()
    view:on_file_dropped("C:/notes/a.md", 60, point(view, "project", "C:/C", 0.5))
    view:on_drop_complete()
    test.same(actions, {{"request", "select", "C:/C", {action = "open", files = {"C:/notes/a.md"},
      target = {mode = "group"}}}})
  end)

  test.it("ignores a drop that moved out of the Sidebar", function()
    local view, actions = sidebar()
    view:on_drop_begin()
    view:on_drop_moved(60, point(view, "tab", "pane-1", 0.5))
    view:on_drop_moved(-1, -1)
    test.ok(not view:on_drop_complete())
    test.same(actions, {})
  end)
end)
