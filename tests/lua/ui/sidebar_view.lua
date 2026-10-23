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

-- Each text that a draw of the view at `width` x `height` shows, with its position and colour.
local function drawn_texts(view, width, height)
  local texts = {}
  with_renderer({draw_text = function(font, text, x, y, color)
    texts[#texts + 1] = {text = text, x = x, y = y, color = color, right = x + font:get_width(text)}
  end}, function() view:draw(width or 400, height or 800) end)
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
      {id="pane-1",number=1,name=name,terminal={session="shown",state="running"}}}}})
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
    local view = SidebarView(action)
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
    local view = SidebarView(action)
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

  test.it("selects a Project clicked anywhere on its row", function()
    local actions, action = recorder()
    local view = SidebarView(action)
    view:set_model({{row_id=7,path="C:/B",state="ready",terminals={}},
                    {row_id=9,path="C:/A",state="dormant",exists=true,activity=os.time(),terminals={}}})
    view:on_mouse_pressed("left", 20, row_y(view, "project", 2), 240)
    view:on_mouse_moved(230, row_y(view, "project", 1), 240)
    view:on_mouse_pressed("left", 230, row_y(view, "project", 1), 240)
    test.same(actions, {{"select", 9}, {"select", 7}})
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
          {id="pane-1",number=1,group=1,name="first.lua"},{id="pane-2",number=2,group=1,name="second.lua"}}},
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

  test.it("lists a loaded Project's Tabs in Pane order and acts on a clicked Tab", function()
    local actions, action = recorder()
    local view = SidebarView(action)
    view:set_model({{row_id=7,id=31,path="C:/A",state="ready",window_id=5,terminals={},panes={active=1,visible=1,
      {id="pane-4",number=1,group=1,name="init.lua"},{id="pane-9",number=2,group=2,name="notes.md"}}}}, 5)
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
      {id="shown",title="pwsh",cwd="C:/A",state="running",busy=0,bell=-1,activity=os.time()},
      {id="detached",title="server",cwd="C:/A",state="running",busy=1,bell=-1,activity=os.time()}},
      panes={active=1,visible=1,{id="pane-1",number=1,group=1,name="pwsh",
        terminal={session="shown",state="running",busy=false,activity=os.time()}}}}}, 5)
    test.equal(count(view, "tab"), 1)
    test.equal(count(view, "terminal"), 1)
    for _, row in ipairs(view.rows) do
      if row.kind == "terminal" then test.equal(row.terminal.id, "detached") end
    end
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

test.describe("Sidebar age groups", function()
  local now = os.time()
  local function project(id, path, age, state, terminals)
    return {row_id=id,id=id,path=path,state=state or "dormant",exists=true,
      activity=age and now - age or 0,terminals=terminals or {}}
  end

  test.it("keeps loaded Projects on top and groups unloaded Projects by age at the bottom", function()
    local view = SidebarView(function() end)
    view:set_size(240, 800)
    view:set_model({project(1, "C:/Week", DAY), project(2, "C:/Month", 10 * DAY), project(3, "C:/Old", 60 * DAY),
      project(4, "C:/Loaded", 90 * DAY, "ready"), project(5, "C:/Unknown")})
    test.same(paths(view, "main"), {"C:/Loaded"})
    -- Every group starts open.
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
    local view = SidebarView(function() end)
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
    local view = SidebarView(function() end)
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
    local view = SidebarView(action)
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
    local function terminal(title, age, bell)
      return {id=title,title=title,cwd="C:/P",state="running",busy=0,bell=bell and 1 or 0,activity=now - age}
    end
    view:set_model({project(1, "C:/P", 60, "ready", {terminal("recent", 20 * 60), terminal("days", 3 * DAY),
      terminal("week", 10 * DAY), terminal("month", 40 * DAY), terminal("bell", 40 * DAY, true)})})
    -- A ringing Terminal Session stays visible however old it is.
    test.same(titles(view), {"recent", "days", "bell"})
    local index = row_index(view, function(row) return row.kind == "terminal_group" and row.bucket == "older" end)
    view:on_mouse_pressed("left", 20, view:row_y(index) + 2, 240)
    test.same(titles(view), {"recent", "days", "bell", "month"})
  end)

  test.it("shows an unloaded Project's running Terminal Sessions as a hint on its row", function()
    local view = SidebarView(function() end)
    view:set_size(400, 800)
    local function terminal(id, state, busy)
      return {id=id,title=id,cwd="C:/P",state=state,busy=busy,bell=-1,activity=now}
    end
    view:set_model({project(1, "C:/P", DAY, "dormant", {terminal("a", "running", 1), terminal("b", "running", 0),
      terminal("c", "exited", 0)})})
    test.equal(count(view, "terminal"), 0, "An unloaded Project lists its Terminal Sessions")
    local text = joined(drawn_texts(view, 400, 800))
    test.ok(text:find("2 terminals, 1 busy", 1, true), "The hint is missing: " .. text)
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
      {{id="a",title="[40 s] \u{03C0} - GLP4",cwd="C:/P",state="running",busy=1,bell=0,activity=now},
       {id="b",title="",cwd="C:/P",state="running",busy=0,bell=0,activity=now}})})
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
      {id="t",title=title,cwd="C:/P",state="running",busy=1,bell=0,activity=now}}}})
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
    local session = {id="a",title="\u{03C0} - GLP4",cwd="C:/P",state="running",busy=1,bell=-1,activity=now}
    for key, value in pairs(agent) do session[key] = value end
    return {{row_id=1,id=1,path="C:/P",state="ready",window_id=1,exists=true,activity=now,terminals={session},
      panes={active=active or 1,visible=1,
        {id="pane-1",number=1,group=1,name="init.lua"},
        {id="pane-2",number=2,group=2,name="\u{03C0} - GLP4",terminal={session="a",state="running",busy=true}}}},
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
    local view = SidebarView(function() end)
    local function terminal(id, fields)
      local item = {id=id,title=id,cwd="C:/P",state="running",busy=1,bell=-1,activity=now}
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
    view:on_key_pressed("backspace")
    view:on_key_pressed("backspace")
    local cleared = drawn_texts(view)
    test.is_nil(search_icon(cleared), "The search field stays after the query is erased")
    test.equal(test.not_nil(find_text(cleared, "Alpha")).y, alpha_y)
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
          {id="pane-1",number=1,group=1,name="one.lua"},
          {id="pane-2",number=2,group=2,name="two.lua"},
          {id="pane-3",number=3,group=2,name="three.lua"},
          {id="pane-4",number=4,group=3,name="four.lua"},
          {id="pane-5",number=5,group=4,name="pwsh",terminal={session="s1",state="running"}}}},
      {row_id=2,id=12,path="C:/B",state="ready",window_id=5,terminals={},panes={active=1,visible=1,
        {id="pane-8",number=1,group=1,name="b.lua"}}},
      {row_id=3,path="C:/C",state="dormant",exists=true,activity=os.time(),terminals={}},
      windows={{id=5,selected_project=11}},
    }
  end

  local function sidebar(projects)
    local actions, action = recorder()
    local view = SidebarView(action)
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
    for i = 1, 60 do panes[i] = {id="pane-" .. i,number=i,group=i,name="file" .. i .. ".lua"} end
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
    local view = SidebarView(action)
    view:set_size(300, 800)
    view:set_model({{row_id=1,id=11,path="C:/A",state="ready",window_id=5,terminals={},panes={active=1,visible=1,
      {id="pane-1",number=1,group=1,name="one.lua"},{id="pane-2",number=2,group=2,name="two.lua"}}},
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
