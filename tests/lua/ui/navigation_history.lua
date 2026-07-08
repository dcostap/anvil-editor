local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local test = require "core.test"

local navigation_history = require "plugins.navigation_history"

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function remove_doc(doc)
  for i = #core.docs, 1, -1 do
    if core.docs[i] == doc then
      table.remove(core.docs, i)
      doc:on_close()
      return
    end
  end
end

local function open_editor(context, text)
  local doc = track(context, "docs", core.open_doc())
  if text and text ~= "" then doc:text_input(text) end
  local view = track(context, "views", core.root_panel:open_doc(doc))
  core.set_active_view(view)
  return view, doc
end

local function set_caret(view, line, col)
  view:with_selection_state(function()
    view.doc:set_selection(line, col, line, col)
  end)
end

local function caret(view)
  return view:with_selection_state(function()
    local line, col = view.doc:get_selection()
    return line, col
  end)
end

local function press_alt_key(key)
  local previous_alt = keymap.modkeys.alt
  keymap.modkeys.alt = true
  local ok, result = xpcall(function()
    return keymap.on_key_pressed(key)
  end, debug.traceback)
  keymap.modkeys.alt = previous_alt
  if not ok then error(result, 0) end
  return result
end

test.describe("IntelliJ-style navigation history", function()
  test.after_each(function(context)
    navigation_history.clear_history()

    local root = core.root_panel.root_node
    for _, view in ipairs(context.views or {}) do
      local node = root:get_node_for_view(view)
      if node then node:remove_view(root, view) end
    end
    for _, doc in ipairs(context.docs or {}) do
      if doc:is_dirty() then doc:clean() end
      remove_doc(doc)
    end
  end)

  test.it("goes back and forward between editor places recorded by tab navigation", function(context)
    local first = open_editor(context, "one\ntwo\nthree")
    local second = open_editor(context, "alpha\nbeta\ngamma")
    local node = core.root_panel.root_node:get_node_for_view(first)

    set_caret(first, 2, 1)
    set_caret(second, 3, 1)
    node:set_active_view(first)
    navigation_history.clear_history()

    node:set_active_view(second)
    test.ok(navigation_history.is_back_available())

    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, first)
    local line, col = caret(first)
    test.equal(line, 2)
    test.equal(col, 1)
    test.ok(navigation_history.is_forward_available())

    test.ok(command.perform("navigation:forward"))
    test.equal(core.active_view, second)
    line, col = caret(second)
    test.equal(line, 3)
    test.equal(col, 1)
  end)

  test.it("uses global back shortcut while file tree is focused", function(context)
    local first = open_editor(context, "one")
    local second = open_editor(context, "two")
    local node = core.root_panel.root_node:get_node_for_view(first)

    node:set_active_view(first)
    navigation_history.clear_history()
    node:set_active_view(second)
    test.ok(navigation_history.is_back_available())

    local filetree = require "plugins.filetree"
    core.set_active_view(filetree)
    test.equal(core.active_view, filetree)

    test.ok(press_alt_key("left"))
    test.equal(core.active_view, first)
  end)

  test.it("uses global forward shortcut while file tree is focused", function(context)
    local first = open_editor(context, "one")
    local second = open_editor(context, "two")
    local node = core.root_panel.root_node:get_node_for_view(first)

    node:set_active_view(first)
    navigation_history.clear_history()
    node:set_active_view(second)
    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, first)
    test.ok(navigation_history.is_forward_available())

    local filetree = require "plugins.filetree"
    core.set_active_view(filetree)
    test.equal(core.active_view, filetree)

    test.ok(press_alt_key("right"))
    test.equal(core.active_view, second)
  end)

  test.it("records editor mouse-style cursor jumps through document commands", function(context)
    local view = open_editor(context, "one\ntwo\nthree\nfour")
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 600
    set_caret(view, 1, 1)
    navigation_history.clear_history()

    local x, y = view:get_line_screen_position(3, 1)
    test.ok(command.perform("doc:set-cursor", x + 1, y + math.floor(view:get_line_height() / 2)))
    local line = caret(view)
    test.equal(line, 3)
    test.ok(navigation_history.is_back_available())

    test.ok(command.perform("navigation:back"))
    line = caret(view)
    test.equal(line, 1)
  end)

  test.it("records same-line editor cursor jumps", function(context)
    local view = open_editor(context, "alpha beta gamma")
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 600
    set_caret(view, 1, 1)
    navigation_history.clear_history()

    local x, y = view:get_line_screen_position(1, 13)
    test.ok(command.perform("doc:set-cursor", x + 1, y + math.floor(view:get_line_height() / 2)))
    local line, col = caret(view)
    test.equal(line, 1)
    test.ok(col > 5)
    test.ok(navigation_history.is_back_available())

    test.ok(command.perform("navigation:back"))
    line, col = caret(view)
    test.equal(line, 1)
    test.equal(col, 1)
  end)

  test.it("keeps automatic tracking connected after plugin reload", function(context)
    local first = open_editor(context, "one")
    local second = open_editor(context, "two")
    local node = core.root_panel.root_node:get_node_for_view(first)

    node:set_active_view(first)
    core.reload_module("plugins.navigation_history")
    navigation_history = require "plugins.navigation_history"
    navigation_history.clear_history()

    node:set_active_view(second)
    test.ok(navigation_history.is_back_available())
    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, first)
  end)

  test.it("clears forward history after a new navigation", function(context)
    local first = open_editor(context, "one")
    local second = open_editor(context, "two")
    local third = open_editor(context, "three")
    local node = core.root_panel.root_node:get_node_for_view(first)

    node:set_active_view(first)
    navigation_history.clear_history()

    node:set_active_view(second)
    test.ok(command.perform("navigation:back"))
    test.ok(navigation_history.is_forward_available())

    node:set_active_view(third)
    test.ok(not navigation_history.is_forward_available())
  end)
end)
