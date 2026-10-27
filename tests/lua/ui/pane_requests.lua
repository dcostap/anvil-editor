local core = require "core"
local common = require "core.common"
local panes = require "core.panes"
local RootPanel = require "core.rootpanel"
local TitleBar = require "core.titlebar"
local layout = require "core.pane_layout"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local View = require "core.view"
local test = require "core.test"

-- Seam: shell requests delivered through the public event handler.
local function request(value, x, y)
  core.on_event("panerequest", common.serialize(value, {escape = true}), x or -1, y or -1, 0)
end
local function create()
  return panes.create {factory = function() return View() end}
end
local function move(pane, mode, anchor, side)
  request {action = "move", pane = pane.id,
    target = {mode = mode, anchor = anchor and anchor.id, side = side or "after"}}
end

test.describe("Pane requests", function()
  local saved, folder
  test.before_each(function()
    panes.reset_for_tests()
    saved = {root = core.root_panel, focus = core.set_active_view, active = core.active_view,
      title = core.title_bar, projects = core.projects}
    core.set_active_view = function(view) core.active_view = view end
    core.root_panel = RootPanel()
  end)
  test.after_each(function()
    panes.reset_for_tests()
    core.root_panel, core.set_active_view, core.active_view = saved.root, saved.focus, saved.active
    core.title_bar, core.projects = saved.title, saved.projects
    if folder then test.ok(test.remove_tree(folder)); folder = nil end
  end)

  test.it("focuses and closes named Panes", function()
    local a, b = create(), create()
    request {action = "focus", pane = a.id}
    test.equal(panes.active(), a)
    test.equal(panes.visible_group(), a.group)
    request {action = "close", pane = b.id}
    test.same(panes.ordered(), {a})
  end)

  test.it("closes a Sidebar keyboard target using normal Pane Group selection", function()
    local outside, left = create(), create()
    local right = panes.split(left, "right", {factory = function() return View() end})
    panes.focus(outside)
    request {action = "close", pane = right.id, focus = true}
    test.is_nil(panes.find(right.id))
    test.equal(panes.active(), left)
    test.equal(panes.visible_group(), left.group)
  end)

  test.it("moves groups before, after, and to the end", function()
    local a, b, c = create(), create(), create()
    move(c, "group", a, "before")
    test.same(panes.ordered(), {c, a, b})
    move(c, "group", a, "after")
    test.same(panes.ordered(), {a, c, b})
    move(a, "group")
    test.same(panes.ordered(), {c, b, a})
    test.equal(panes.active(), a)
    test.equal(panes.visible_group(), a.group)
  end)

  test.it("moves a Pane to the end for a target with no anchor or side", function()
    local a, b = create(), create()
    request {action = "move", pane = a.id, target = {mode = "group"}}
    test.same(panes.ordered(), {b, a})
  end)

  test.it("drops a Tab dragged from the Project Sidebar like a Title Bar Pane drag", function()
    core.title_bar, core.projects = TitleBar(), {{path = "C:/Project"}}
    local source, target = create(), create()
    layout.update_rects(target.group.root, {x = 0, y = 50, w = 200, h = 100})
    local function drag(phase, path)
      request({action = "drag", phase = phase, source = path, pane = source.id}, 195, 100)
    end
    drag("drop", "C:/Other")
    test.same(panes.ordered(), {source, target}, "A Tab of another Project has the same Pane IDs")
    test.not_equal(source.group, target.group)
    drag("move", "C:/Project")
    test.equal(core.title_bar.dragged_pane, source)
    drag("leave", "C:/Project")
    test.is_nil(core.title_bar.dragged_pane)
    drag("move", "C:/Project")
    drag("drop", "C:/Project")
    test.is_nil(core.title_bar.dragged_pane)
    test.equal(source.group, target.group)
    test.same(panes.ordered(), {target, source})
  end)

  test.it("joins groups and reorders their Panes before and after anchors", function()
    local a, b, c = create(), create(), create()
    move(c, "join", a, "before")
    test.same(panes.ordered(), {c, a, b})
    test.equal(c.group, a.group)
    move(c, "join", a, "after")
    test.same(panes.ordered(), {a, c, b})
    move(b, "join", a, "before")
    test.same(panes.ordered(), {b, a, c})
    test.equal(b.group, a.group)
    move(a, "group", c, "after")
    test.same(panes.ordered(), {b, c, a})
    test.not_equal(a.group, c.group)
  end)

  test.it("leaves layout geometry unchanged for an unchanged target", function()
    local a = create()
    local b = panes.split(a, "down", {factory = function() return View() end})
    a.group.root.ratio = 0.3
    move(b, "join", a, "after")
    test.same(panes.ordered(), {a, b})
    test.equal(a.group.root.ratio, 0.3)
    test.equal(panes.active(), b)
  end)

  test.it("opens files and text in new Panes at a target in order", function()
    folder = USERDIR .. "/pane-request-" .. tostring(system.get_time()):gsub("%.", "-")
    test.ok(system.mkdir(folder))
    local path = folder .. "/file.txt"
    local file = assert(io.open(path, "wb")); file:write("File content"); file:close()
    local a = create()
    request {action = "open", files = {path}, text = "Untitled text",
      target = {mode = "join", anchor = a.id, side = "before"}}
    local ordered = panes.ordered()
    test.equal(#ordered, 3)
    test.equal(ordered[3], a)
    test.equal(ordered[1].current_view.buffer.abs_filename, system.absolute_path(path))
    test.equal(ordered[2].current_view.buffer:get_text(1, 1, 1, math.huge), "Untitled text")
    test.equal(ordered[2].group, a.group)
    test.equal(panes.active(), ordered[2])
  end)

  test.it("opens launched files, including new files, in new Panes", function()
    folder = USERDIR .. "/pane-request-" .. tostring(system.get_time()):gsub("%.", "-")
    test.ok(system.mkdir(folder))
    local existing, new = folder .. "/existing.txt", folder .. "/new.txt"
    local file = assert(io.open(existing, "wb")); file:write("Existing content"); file:close()
    local a = create()
    request {action = "launch", files = {existing, new}}
    local opened = {}
    for _, pane in ipairs(panes.ordered()) do
      if pane ~= a then opened[#opened + 1] = pane.current_view.buffer.abs_filename end
    end
    test.same(opened, {system.absolute_path(existing), common.normalize_path(new)})
    test.equal(panes.active().current_view.buffer.abs_filename, common.normalize_path(new))
    test.is_nil(system.get_file_info(new), "opening a new file does not create it")
  end)

  test.it("drops text at the Editor caret without pointer coordinates", function()
    local pane = panes.create {factory = function() return Editor(Buffer(nil, nil, true)) end}
    local view = pane.current_view
    view.buffer:insert(1, 1, "abcd")
    view:set_selection_state {selections = {1, 3, 1, 3}, last_selection = 1}
    request {action = "drop", pane = pane.id, text = "X"}
    test.equal(view.buffer:get_text(1, 1, 1, math.huge), "abXcd")
    test.equal(panes.count(), 1)
  end)

  test.it("rejects invalid requests without changing Panes", function()
    local a, b = create(), create()
    for _, value in ipairs {
      {action = "unknown", pane = a.id}, {action = "focus", pane = 1},
      {action = "close", pane = "missing"},
      {action = "move", pane = a.id, target = {mode = "join", side = "after"}},
      {action = "open", files = {"relative.txt"}, target = {mode = "group", side = "after"}},
      {action = "drop", pane = a.id, text = false},
      {action = "focus", pane = a.id, surprise = true},
    } do request(value) end
    core.on_event("panerequest", "not valid Lua", -1, -1, 0)
    test.same(panes.ordered(), {a, b})
    test.equal(panes.active(), b)
  end)
end)
