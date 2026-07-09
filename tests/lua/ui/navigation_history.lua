local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local test = require "core.test"
local sidepanel = require "core.sidepanel"
local file_context = require "core.file_context"
local DocView = require "core.docview"

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

local function open_side_editor(context, name, text)
  local doc = track(context, "docs", core.open_doc())
  if text and text ~= "" then doc:text_input(text) end
  local view = track(context, "side_views", file_context.mark_editor_view(DocView(doc)))
  sidepanel.register_panel(name, view)
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
    for _, view in ipairs(context.side_views or {}) do
      if sidepanel.contains_view(view) then sidepanel.remove_view(view, false) end
    end
    if sidepanel.file_view and sidepanel.contains_view(sidepanel.file_view) then
      sidepanel.remove_view(sidepanel.file_view, false)
    end
    sidepanel.file_view = nil
    sidepanel.file_view_path = nil
    sidepanel.current_panel = nil
    sidepanel.hide(false)

    for _, view in ipairs(context.views or {}) do
      local node = root:get_node_for_view(view)
      if node then node:remove_view(root, view) end
    end
    for _, doc in ipairs(context.docs or {}) do
      if doc:is_dirty() then doc:clean() end
      remove_doc(doc)
    end
    navigation_history.clear_history()
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
    local editor = open_editor(context, "one")
    navigation_history.clear_history()

    local filetree = require "plugins.filetree"
    core.set_active_view(filetree)
    test.equal(core.active_view, filetree)
    test.ok(navigation_history.is_back_available())

    test.ok(press_alt_key("left"))
    test.equal(core.active_view, editor)
  end)

  test.it("uses global forward shortcut while file tree is focused", function(context)
    local first = open_editor(context, "one")
    local second = open_editor(context, "two")
    local filetree = require "plugins.filetree"

    core.set_active_view(first)
    navigation_history.clear_history()
    core.set_active_view(filetree)
    core.set_active_view(second)
    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, filetree)
    test.ok(navigation_history.is_forward_available())

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

  test.it("restoring a main editor place does not hide or blank a visible side panel", function(context)
    local main = open_editor(context, "main one\nmain two")
    local side_doc = track(context, "docs", core.open_doc())
    side_doc:text_input("side one\nside two")
    local side_view = track(context, "side_views", sidepanel.open_doc_in_side(side_doc, {
      source_view = main,
      focus = false,
    }))
    sidepanel.show("file", { focus = true })
    test.equal(sidepanel.visible, true)
    test.equal(sidepanel.active_side_view(), side_view)

    set_caret(main, 2, 3)
    set_caret(side_view, 1, 4)
    core.set_active_view(main)
    navigation_history.clear_history()

    core.set_active_view(side_view)
    test.ok(navigation_history.is_back_available())

    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, main)
    test.equal(sidepanel.visible, true)
    test.equal(sidepanel.active_side_view(), side_view)
    local line, col = caret(main)
    test.equal(line, 2)
    test.equal(col, 3)
  end)

  test.it("restoring a side editor place keeps side panel visibility as-is", function(context)
    local main = open_editor(context, "main one\nmain two")
    local side_doc = track(context, "docs", core.open_doc())
    side_doc:text_input("side one\nside two")
    local side_view = track(context, "side_views", sidepanel.open_doc_in_side(side_doc, {
      source_view = main,
      focus = false,
    }))
    sidepanel.show("file", { focus = true })
    test.equal(sidepanel.visible, true)

    set_caret(main, 1, 6)
    set_caret(side_view, 2, 5)
    core.set_active_view(side_view)
    navigation_history.clear_history()

    core.set_active_view(main)
    test.ok(navigation_history.is_back_available())

    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, side_view)
    test.equal(sidepanel.visible, true)
    test.equal(sidepanel.active_side_view(), side_view)
    local line, col = caret(side_view)
    test.equal(line, 2)
    test.equal(col, 5)
  end)

  test.it("restoring an accessible Side Editor Slot keeps it in slot mode", function(context)
    local main = open_editor(context, "main one\nmain two")
    local side_doc = track(context, "docs", core.open_doc())
    side_doc:text_input("side one\nside two")
    local side_view = track(context, "side_views", sidepanel.open_doc_in_side(side_doc, {
      source_view = main,
      focus = true,
    }))
    set_caret(side_view, 2, 3)
    test.equal(sidepanel.visible, false)
    test.equal(sidepanel.side_editor_slot_visible, true)
    navigation_history.clear_history()

    core.set_active_view(main)
    test.ok(navigation_history.is_back_available())

    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, side_view)
    test.equal(sidepanel.visible, false)
    test.equal(sidepanel.side_editor_slot_visible, true)
    test.equal(sidepanel.active_side_view(), side_view)
    local line, col = caret(side_view)
    test.equal(line, 2)
    test.equal(col, 3)
  end)

  test.it("restores a replaced Side Editor place on the side", function(context)
    local main = open_editor(context, "main")
    local first_doc = track(context, "docs", core.open_doc())
    first_doc:text_input("first one\nfirst two")
    first_doc:clean()
    local first_side = track(context, "side_views", sidepanel.open_doc_in_side(first_doc, {
      source_view = main,
      focus = true,
    }))
    set_caret(first_side, 2, 4)
    local first_place = navigation_history.capture_place(first_side)

    local second_doc = track(context, "docs", core.open_doc())
    second_doc:text_input("second")
    second_doc:clean()
    local second_side = track(context, "side_views", sidepanel.open_doc_in_side(second_doc, {
      source_view = main,
      focus = true,
    }))
    set_caret(second_side, 1, 5)
    test.ok(not sidepanel.contains_view(first_side))
    navigation_history.clear_history()
    test.ok(navigation_history.record_place(first_place, { check_current = false }))

    test.ok(command.perform("navigation:back"))
    local restored = core.active_view
    test.ok(restored ~= first_side)
    test.ok(sidepanel.is_side_editor(restored))
    test.equal(sidepanel.file_view, restored)
    test.equal(sidepanel.active_side_view(), restored)
    test.equal(restored.doc, first_doc)
    test.equal(sidepanel.visible, false)
    test.equal(sidepanel.side_editor_slot_visible, true)
    local line, col = caret(restored)
    test.equal(line, 2)
    test.equal(col, 4)

    test.ok(command.perform("navigation:forward"))
    restored = core.active_view
    test.ok(restored ~= second_side)
    test.ok(sidepanel.is_side_editor(restored))
    test.equal(sidepanel.file_view, restored)
    test.equal(sidepanel.active_side_view(), restored)
    test.equal(restored.doc, second_doc)
    test.equal(sidepanel.visible, false)
    test.equal(sidepanel.side_editor_slot_visible, true)
    line, col = caret(restored)
    test.equal(line, 1)
    test.equal(col, 5)
  end)

  test.it("restoring a side editor place from a hidden side panel shows the side panel", function(context)
    local main = open_editor(context, "main one\nmain two")
    local side_view = open_side_editor(context, "history side", "side one\nside two")
    sidepanel.show("history side", { focus = true })
    set_caret(side_view, 2, 3)
    navigation_history.clear_history()

    core.set_active_view(main)
    sidepanel.hide(false)
    test.equal(sidepanel.visible, false)
    test.ok(navigation_history.is_back_available())

    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, side_view)
    test.equal(sidepanel.visible, true)
    test.equal(sidepanel.active_side_view(), side_view)
    local line, col = caret(side_view)
    test.equal(line, 2)
    test.equal(col, 3)
  end)

  test.it("restoring between main editors keeps a visible side panel unchanged", function(context)
    local first = open_editor(context, "first one\nfirst two")
    local second = open_editor(context, "second one\nsecond two")
    local side_view = open_side_editor(context, "persistent side", "side")
    sidepanel.show("persistent side", { focus = false })
    test.equal(sidepanel.visible, true)
    test.equal(sidepanel.active_side_view(), side_view)

    set_caret(first, 2, 2)
    set_caret(second, 1, 4)
    core.set_active_view(first)
    navigation_history.clear_history()

    core.set_active_view(second)
    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, first)
    test.equal(sidepanel.visible, true)
    test.equal(sidepanel.active_side_view(), side_view)
    local line, col = caret(first)
    test.equal(line, 2)
    test.equal(col, 2)
  end)

  test.it("restoring between main editors keeps a hidden side panel hidden", function(context)
    local first = open_editor(context, "first")
    local second = open_editor(context, "second")
    local side_view = open_side_editor(context, "hidden side", "side")
    sidepanel.show("hidden side", { focus = false })
    sidepanel.hide(false)
    test.equal(sidepanel.visible, false)

    core.set_active_view(first)
    navigation_history.clear_history()
    core.set_active_view(second)

    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, first)
    test.equal(sidepanel.visible, false)
    test.equal(sidepanel.active_side_view(), side_view)
  end)

  test.it("restoring between side editors switches side view and keeps side panel visible", function(context)
    local main = open_editor(context, "main")
    local side_a = open_side_editor(context, "side A", "alpha\nbeta")
    local side_b = open_side_editor(context, "side B", "gamma\ndelta")

    sidepanel.show("side A", { focus = true })
    set_caret(side_a, 2, 2)
    set_caret(side_b, 1, 3)
    navigation_history.clear_history()

    sidepanel.show("side B", { focus = true })
    test.ok(navigation_history.is_back_available())

    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, side_a)
    test.equal(sidepanel.visible, true)
    test.equal(sidepanel.active_side_view(), side_a)
    local line, col = caret(side_a)
    test.equal(line, 2)
    test.equal(col, 2)

    core.set_active_view(main)
  end)
end)
