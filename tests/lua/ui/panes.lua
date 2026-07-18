local core = require "core"
local command = require "core.command"
local test = require "core.test"
local panes = require "core.panes"

local function track(context, key, value)
  context[key] = context[key] or {}
  context[key][#context[key] + 1] = value
  return value
end

local function write_file(path, text)
  local abs = core.root_project():absolute_path(path)
  local fp = assert(io.open(abs, "wb"))
  fp:write(text or "")
  fp:close()
end

local function cleanup(context)
  panes.reset_for_tests()
  for _, doc in ipairs(context.docs or {}) do
    for i = #core.docs, 1, -1 do
      if core.docs[i] == doc then table.remove(core.docs, i) end
    end
  end
end

test.describe("two-pane view model", function()
  test.before_each(function(context) cleanup(context) end)
  test.after_each(function(context) cleanup(context) end)

  test.it("keeps one replaceable named-file Editor in each pane", function(context)
    write_file("pane-a.txt", "a\n")
    write_file("pane-b.txt", "b\n")
    write_file("pane-c.txt", "c\n")
    local a = track(context, "docs", core.open_doc("pane-a.txt"))
    local b = track(context, "docs", core.open_doc("pane-b.txt"))
    local c = track(context, "docs", core.open_doc("pane-c.txt"))

    local left_a = panes.open_doc(a, { pane = "left" })
    local right_b = panes.open_doc(b, { pane = "right" })
    local left_c = panes.open_doc(c, { pane = "left" })

    test.equal(panes.pane_for_view(left_c), "left")
    test.equal(panes.pane_for_view(right_b), "right")
    test.ok(left_a ~= left_c)
    test.equal(panes.singleton_editor("left"), left_c)
    test.equal(panes.singleton_editor("right"), right_b)
  end)

  test.it("promotes dirty singleton Editors symmetrically before replacement", function(context)
    write_file("pane-dirty-a.txt", "a\n")
    write_file("pane-dirty-b.txt", "b\n")
    local a = track(context, "docs", core.open_doc("pane-dirty-a.txt"))
    local b = track(context, "docs", core.open_doc("pane-dirty-b.txt"))
    local first = panes.open_doc(a, { pane = "right" })
    first.doc:insert(1, 1, "dirty")

    local second = panes.open_doc(b, { pane = "right" })

    test.ok(panes.contains_view("right", first))
    test.ok(panes.contains_view("right", second))
    test.ok(not first.__pane_singleton_editor)
    test.equal(panes.singleton_editor("right"), second)
  end)

  test.it("creates untitled tabs in the focused pane", function(context)
    panes.show("right", { focus = true })
    local first = track(context, "docs", core.open_doc())
    local second = track(context, "docs", core.open_doc())
    local first_view = panes.open_doc(first)
    local second_view = panes.open_doc(second)

    test.equal(panes.pane_for_view(first_view), "right")
    test.equal(panes.pane_for_view(second_view), "right")
    test.ok(first_view ~= second_view)
    test.equal(panes.selected_view("right"), second_view)
  end)

  test.it("opens one Document in independent Editors across panes", function(context)
    write_file("pane-shared.txt", "one\ntwo\n")
    local doc = track(context, "docs", core.open_doc("pane-shared.txt"))
    local left = panes.open_doc(doc, { pane = "left" })
    left:set_selection_state({ selections = { 2, 2, 2, 2 }, last_selection = 1 })

    core.set_active_view(left)
    test.ok(command.perform("pane:open-current-file-opposite"))
    local right = panes.selected_view("right")

    test.ok(right ~= left)
    test.equal(right.doc, left.doc)
    test.same(right:get_selection_state(), left:get_selection_state())
    right:set_selection_state({ selections = { 1, 1, 1, 1 }, last_selection = 1 })
    test.ok(right:get_selection_state().selections[1] ~= left:get_selection_state().selections[1])
  end)

  test.it("moves the current Editor to the opposite pane", function(context)
    write_file("pane-move.txt", "move\n")
    local doc = track(context, "docs", core.open_doc("pane-move.txt"))
    local view = panes.open_doc(doc, { pane = "left" })
    core.set_active_view(view)

    test.ok(command.perform("pane:move-current-file-opposite"))
    local moved = panes.selected_view("right")
    test.equal(moved, view)
    test.equal(panes.pane_for_view(moved), "right")
    test.equal(moved.doc, doc)
    test.ok(not panes.contains_view("left", view))
    test.ok(panes.is_placeholder(panes.selected_view("left")))
  end)

  test.it("cycles Pane Tabs only in the focused pane", function(context)
    local left_doc = track(context, "docs", core.open_doc())
    local right_a = track(context, "docs", core.open_doc())
    local right_b = track(context, "docs", core.open_doc())
    local left = panes.open_doc(left_doc, { pane = "left" })
    local first = panes.open_doc(right_a, { pane = "right" })
    local second = panes.open_doc(right_b, { pane = "right" })
    core.set_active_view(second)

    test.ok(command.perform("root:switch-to-next-tab"))
    test.equal(panes.selected_view("right"), require("plugins.filetree"))
    test.equal(panes.selected_view("left"), left)
  end)

  test.it("closes one Right Pane tab and falls back to the File Tree", function(context)
    local filetree = require "plugins.filetree"
    local doc = track(context, "docs", core.open_doc())
    local editor = panes.open_doc(doc, { pane = "right", focus = true })

    test.ok(command.perform("pane:close-current"))
    test.ok(not panes.contains_view("right", editor))
    test.equal(panes.selected_view("right"), filetree)
    test.equal(panes.right_visible(), true)
    test.ok(not command.perform("pane:close-current"), "File Tree must remain uncloseable")
  end)

  test.it("Alt+1 behavior hides right and focuses left without closing tabs", function(context)
    write_file("pane-left.txt", "left\n")
    write_file("pane-right.txt", "right\n")
    local left_doc = track(context, "docs", core.open_doc("pane-left.txt"))
    local right_doc = track(context, "docs", core.open_doc("pane-right.txt"))
    local left = panes.open_doc(left_doc, { pane = "left" })
    local right = panes.open_doc(right_doc, { pane = "right" })
    core.set_active_view(right)

    test.ok(command.perform("pane:focus-left-and-hide-right"))
    test.equal(panes.right_visible(), false)
    test.equal(core.active_view, left)
    test.ok(panes.contains_view("right", right))
  end)

  test.it("round-trips open tabs, selection, focus, and Right Pane visibility", function(context)
    write_file("pane-workspace-left.txt", "left\n")
    local left_doc = track(context, "docs", core.open_doc("pane-workspace-left.txt"))
    local right_doc = track(context, "docs", core.open_doc())
    panes.open_doc(left_doc, { pane = "left" })
    local right = panes.open_doc(right_doc, { pane = "right", focus = true })
    right:set_selection_state({ selections = { 1, 1, 1, 1 }, last_selection = 1 })

    local state = panes.save_workspace_state(function(view)
      return { module = view:get_module(), state = view:get_state() }
    end)
    panes.reset_for_tests()

    test.ok(panes.restore_workspace_state(state, function(saved)
      local ViewClass = require(saved.module)
      return ViewClass.from_state(saved.state)
    end))
    test.equal(panes.right_visible(), true)
    test.equal(panes.focused_pane(), "right")
    test.is_nil(panes.selected_view("right").doc.abs_filename)
    test.equal(panes.selected_view("left").doc, left_doc)
  end)
end)
