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
  test.it("asks the shell for a Project's actions menu at a right-click", function()
    local actions, action = recorder()
    local view = SidebarView(action)
    view:set_model({{row_id=7,id=31,path="C:/A",state="ready",window_id=5,terminals={}},
      {row_id=9,path="C:/B",state="dormant",exists=true,activity=os.time(),terminals={}},
      windows={{id=5,selected_project=31},{id=8,selected_project=0}}}, 8)
    local y = row_y(view, "project", 1)
    view:on_mouse_pressed("right", 20, y, 240)
    test.same(actions, {{"menu", 7, 20, y}})
    -- A Dormant Project has a menu too, and the right-click neither selects nor unloads.
    local dormant_y = row_y(view, "project", 2)
    view:on_mouse_pressed("right", 230, dormant_y, 240)
    test.same(actions[2], {"menu", 9, 230, dormant_y})
    test.equal(#actions, 2)
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

  test.it("highlights the focused Terminal Session of the Window's Selected Project instead of the Project", function()
    local style = require "core.style"
    local function model(focused)
      return {
        {row_id=1,id=11,path="C:/A",state="ready",window_id=7,focused_terminal=focused,terminals={
          {id="a",title="first",cwd="C:/A",state="running",busy=0,bell=0,activity=os.time()},
          {id="b",title="second",cwd="C:/A",state="running",busy=0,bell=0,activity=os.time()}}},
        windows={{id=7,selected_project=11},{id=9,selected_project=0}},
      }
    end
    local old_rect, old_rounded, old_text, old_clip =
      renderer.draw_rect, renderer.draw_rounded_rect, renderer.draw_text, renderer.set_clip_rect
    local function highlighted(view)
      local selected, titles = {}, {}
      renderer.draw_rect, renderer.set_clip_rect = function() end, function() end
      renderer.draw_rounded_rect = function(_, y, _, h, _, color)
        if color == style.selection then selected[#selected + 1] = {y, y + h} end
      end
      -- Each highlighted row's first label is its name.
      renderer.draw_text = function(_, text, _, y)
        for _, band in ipairs(selected) do
          if y >= band[1] and y < band[2] and not band.named then titles[#titles + 1], band.named = text, true end
        end
      end
      view:draw(600, 1000)
      return table.concat(titles, ",")
    end
    local ok, err = pcall(function()
      local view = SidebarView(function() end)
      view:set_model(model("b"), 7)
      test.equal(highlighted(view), "second")
      -- No focused Terminal Session: the Project row shows the selection.
      view:set_model(model(""), 7)
      test.equal(highlighted(view), "A")
      -- Another Window's Sidebar highlights neither.
      local other = SidebarView(function() end)
      other:set_model(model("b"), 9)
      test.equal(highlighted(other), "")
    end)
    renderer.draw_rect, renderer.draw_rounded_rect, renderer.draw_text, renderer.set_clip_rect =
      old_rect, old_rounded, old_text, old_clip
    if not ok then error(err) end
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

  test.it("keeps recent and loaded Projects on top and groups older Projects at the bottom", function()
    local view = SidebarView(function() end)
    view:set_size(240, 800)
    view:set_model({project(1, "C:/Week", DAY), project(2, "C:/Month", 10 * DAY), project(3, "C:/Old", 60 * DAY),
      project(4, "C:/Loaded", 90 * DAY, "ready"), project(5, "C:/Unknown")})
    test.same(paths(view, "main"), {"C:/Week", "C:/Loaded"})
    -- Older groups start collapsed except the newest one.
    test.same(paths(view, "bottom"), {"C:/Month"})
    local index = row_index(view, function(row) return row.kind == "group" and row.bucket == "older" end)
    view:on_mouse_pressed("left", 20, view:row_y(index) + 2, 240)
    test.same(paths(view, "bottom"), {"C:/Month", "C:/Old", "C:/Unknown"})
  end)

  test.it("aligns the groups to the bottom, below a gap after the main list", function()
    local view = SidebarView(function() end)
    view:set_size(240, 800)
    view:set_model({project(1, "C:/Week", DAY), project(2, "C:/Month", 10 * DAY)})
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
    local model = {project(100, "C:/Week", DAY)}
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

  test.it("restores collapsed groups and reports changes for the next Sidebar", function()
    local actions, action = recorder()
    local view = SidebarView(action, {["group:older"] = false})
    view:set_size(240, 800)
    view:set_model({project(1, "C:/Old", 60 * DAY)})
    test.same(paths(view, "bottom"), {"C:/Old"})
    local index = row_index(view, function(row) return row.kind == "group" and row.bucket == "older" end)
    view:on_mouse_pressed("left", 20, view:row_y(index) + 2, 240)
    test.same(paths(view, "bottom"), {})
    test.same(actions, {{"collapsed", "group:older", true}})
  end)

  test.it("shows each Terminal Session's live title", function()
    local view = SidebarView(function() end)
    view:set_size(240, 800)
    view:set_model({project(1, "C:/P", 60, "ready",
      {{id="a",title="[40 s] \u{03C0} - GLP4",cwd="C:/P",state="running",busy=1,bell=0,activity=now},
       {id="b",title="",cwd="C:/P",state="running",busy=0,bell=0,activity=now}})})
    local old_rect, old_rounded, old_text, old_clip =
      renderer.draw_rect, renderer.draw_rounded_rect, renderer.draw_text, renderer.set_clip_rect
    local labels = {}
    renderer.draw_rect, renderer.draw_rounded_rect, renderer.set_clip_rect = function() end, function() end, function() end
    renderer.draw_text = function(_, text) labels[#labels + 1] = text end
    local ok, err = pcall(view.draw, view, 240, 800)
    renderer.draw_rect, renderer.draw_rounded_rect, renderer.draw_text, renderer.set_clip_rect =
      old_rect, old_rounded, old_text, old_clip
    if not ok then error(err) end
    local text = table.concat(labels, "\n")
    test.ok(text:find("[40 s] \u{03C0} - GLP4", 1, true), "The live title is missing")
    test.ok(text:find("Terminal", 1, true), "An untitled Terminal Session has no label")
  end)

  test.it("shortens a long Project name with an ellipsis inside a narrow Sidebar", function()
    local view = SidebarView(function() end)
    view:set_model({project(1, "C:/Israel Mallo Mart\u{00ED}nez - ManualSistemas", 60, "ready", {})})
    local old_rect, old_rounded, old_text, old_clip =
      renderer.draw_rect, renderer.draw_rounded_rect, renderer.draw_text, renderer.set_clip_rect
    local drawn = {}
    renderer.draw_rect, renderer.draw_rounded_rect, renderer.set_clip_rect = function() end, function() end, function() end
    renderer.draw_text = function(font, text, x) drawn[#drawn + 1] = {text = text, right = x + font:get_width(text)} end
    local ok, err = pcall(view.draw, view, 170, 800)
    renderer.draw_rect, renderer.draw_rounded_rect, renderer.draw_text, renderer.set_clip_rect =
      old_rect, old_rounded, old_text, old_clip
    if not ok then error(err) end
    local label
    for _, item in ipairs(drawn) do if item.text:find("^Israel") then label = item end end
    test.not_nil(label, "The Project name is missing")
    test.ok(label.text:find("\u{2026}$"), "The long name is not shortened: " .. label.text)
    test.ok(label.right <= 170, "The shortened name runs past the Sidebar's edge")
  end)
end)
