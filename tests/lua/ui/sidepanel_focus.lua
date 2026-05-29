local core = require "core"
local command = require "core.command"
local sidepanel = require "core.sidepanel"
local test = require "core.test"
local DocView = require "core.docview"

require "plugins.intellij_find"

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function new_doc(context, text)
  local doc = track(context, "docs", core.open_doc())
  if text and text ~= "" then
    doc:text_input(text)
  end
  return doc
end

local function open_main_docview(context, text)
  local doc = new_doc(context, text)
  local view = track(context, "views", core.root_panel:open_doc(doc))
  return view, doc
end

local function open_side_docview(context, text, restore_focus)
  local doc = new_doc(context, text)
  local view = track(context, "side_views", sidepanel.open_doc_in_side(doc, {
    focus = false,
    restore_focus = restore_focus,
  }))
  track(context, "views", view)
  return view, doc
end

local function setup_main_and_side(context)
  local main_view = open_main_docview(context, "main alpha beta\n")
  main_view.__test_name = "main DocView"
  core.set_active_view(main_view)
  local side_view = open_side_docview(context, "side alpha beta\n", main_view)
  side_view.__test_name = "side DocView"
  test.equal(core.active_view, main_view)
  return main_view, side_view
end

local function register_side_docview(context, name, text)
  local doc = new_doc(context, text)
  local view = track(context, "side_views", DocView(doc))
  view.__test_name = name .. " DocView"
  sidepanel.register_panel(name, view)
  track(context, "views", view)
  return view, doc
end

local function active_find_input_for(owner_view)
  local view = core.active_view
  test.ok(view and view.local_find_input, "expected a local find input to be focused")
  test.equal(view.local_find_state and view.local_find_state.owner_view, owner_view)
  return view
end

local function open_find_input(owner_view)
  core.set_active_view(owner_view)
  test.ok(command.perform("find-replace:find"))
  local input = active_find_input_for(owner_view)
  input.__test_name = "local find input for " .. (owner_view.__test_name or tostring(owner_view))
  return input
end

local function type_into_active_view(text)
  core.root_panel:on_text_input(text)
end

local function set_selection(view, line1, col1, line2, col2)
  view:with_selection_state(function()
    view.doc:set_selection(line1, col1, line2, col2)
  end)
end

local function selection_state(view)
  return view:get_selection_state().selections
end

local function view_name(view)
  if not view then return "nil" end
  if view.__test_name then return view.__test_name end
  if view.local_find_input then
    local owner = view.local_find_state and view.local_find_state.owner_view
    return tostring(view) .. " for " .. view_name(owner)
  end
  return tostring(view)
end

local function assert_active_view(expected, message)
  test.ok(
    core.active_view == expected,
    string.format("%s; expected %s, got %s", message, view_name(expected), view_name(core.active_view))
  )
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

test.describe("sidepanel focus", function()
  test.after_each(function(context)
    for _, doc in ipairs(context.docs or {}) do
      if doc:is_dirty() then doc:clean() end
    end

    for _, view in ipairs(context.side_views or {}) do
      if sidepanel.file_view == view then
        sidepanel.file_view = nil
        sidepanel.file_view_path = nil
      end
      if view then
        sidepanel.remove_view(view, false)
      end
    end

    local root = core.root_panel.root_node
    for _, view in ipairs(context.views or {}) do
      local node = root:get_node_for_view(view)
      if node then
        node:remove_view(root, view)
      end
    end

    for _, doc in ipairs(context.docs or {}) do
      remove_doc(doc)
    end

    sidepanel.last_side_focus_view = nil
    sidepanel.last_side_focus_owner = nil
    sidepanel.side_focus_views = setmetatable({}, { __mode = "k" })
    sidepanel.hide(false)
    local main_panel = core.root_panel:get_main_panel()
    if main_panel and main_panel.active_view then
      core.set_active_view(main_panel.active_view)
      sidepanel.last_main_panel_view = main_panel.active_view
    else
      sidepanel.last_main_panel_view = nil
    end
  end)

  test.it("focuses the existing side DocView from the main panel", function(context)
    local main_view, side_view = setup_main_and_side(context)

    assert_active_view(main_view, "expected main DocView before toggling to side panel")
    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(side_view, "expected side DocView after toggling from main panel")
  end)

  test.it("focuses the main DocView from the side DocView", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected side DocView before toggling back to main panel")
    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(main_view, "expected main DocView after toggling from side DocView")
  end)

  test.it("leaves a side DocView find input open when toggling focus back to main", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected side DocView before opening side find input")

    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")
    set_selection(side_find, 1, 2, 1, 6)
    local expected_selection = selection_state(side_find)

    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(main_view, "expected sidepanel toggle from side find input to focus main DocView")
    test.equal(side_find.local_find_state.visible, true)
    test.equal(side_find:get_text(), "side-query")
    test.same(selection_state(side_find), expected_selection)
  end)

  test.it("restores the side DocView find input when toggling back from main find", function(context)
    local main_view, side_view = setup_main_and_side(context)

    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")
    set_selection(side_find, 1, 2, 1, 6)
    local expected_side_selection = selection_state(side_find)

    -- This simulates the desired state after toggling away from the side panel:
    -- the side find bar is still visible and stateful, while focus is in main.
    core.set_active_view(main_view)
    test.equal(side_find.local_find_state.visible, true)

    local main_find = open_find_input(main_view)
    type_into_active_view("main-query")

    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(side_find, "expected sidepanel toggle from main find input to restore side find input")
    test.equal(side_find:get_text(), "side-query")
    test.same(selection_state(side_find), expected_side_selection)
    test.equal(main_find.local_find_state.visible, true)
    test.equal(main_find:get_text(), "main-query")
  end)

  test.it("restores the side DocView replace input field", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected side DocView before opening replace input")

    test.ok(command.perform("find-replace:replace"))
    local side_find = active_find_input_for(side_view)
    test.equal(side_find.local_find_field, "find")
    type_into_active_view("side-query")

    test.ok(command.perform("user:find-toggle-replace-field"))
    local side_replace = active_find_input_for(side_view)
    side_replace.__test_name = "local replace input for side DocView"
    test.equal(side_replace.local_find_field, "replace")
    type_into_active_view("replacement")
    set_selection(side_replace, 1, 2, 1, 7)
    local expected_replace_selection = selection_state(side_replace)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected toggle from side replace input to focus main DocView")

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_replace, "expected toggling back to restore side replace input")
    test.equal(side_find:get_text(), "side-query")
    test.equal(side_replace:get_text(), "replacement")
    test.same(selection_state(side_replace), expected_replace_selection)
  end)

  test.it("focus-main-and-hide hides the side panel from a side find input", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")

    test.ok(command.perform("sidepanel:focus-main-and-hide"))

    test.equal(sidepanel.visible, false)
    assert_active_view(main_view, "expected focus-main-and-hide from side find input to focus main DocView")
    test.equal(side_find.local_find_state.visible, true)
    test.equal(side_find:get_text(), "side-query")
  end)

  test.it("hide focuses the main panel from a side find input", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")

    test.ok(command.perform("sidepanel:hide"))

    test.equal(sidepanel.visible, false)
    assert_active_view(main_view, "expected sidepanel hide from side find input to focus main DocView")
    test.equal(side_find.local_find_state.visible, true)
    test.equal(side_find:get_text(), "side-query")
  end)

  test.it("focus-side restores a hidden side find input", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")

    test.ok(command.perform("sidepanel:hide"))
    assert_active_view(main_view, "expected sidepanel hide before focusing side again")

    test.ok(command.perform("sidepanel:focus-side"))

    test.equal(sidepanel.visible, true)
    assert_active_view(side_find, "expected focus-side to restore hidden side find input")
    test.equal(side_find:get_text(), "side-query")
  end)

  test.it("does not restore a stale side find input after the side view is removed", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")
    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected main DocView before removing side view")

    sidepanel.remove_view(side_view, false)

    test.equal(sidepanel.last_side_focus_view, nil)
    test.equal(sidepanel.last_side_focus_owner, nil)
    test.equal(sidepanel.side_focus_views[side_view], nil)
    test.equal(sidepanel.side_focus_owner(side_find), nil)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected toggle not to restore removed side find input")
  end)

  test.it("switching side views restores each view's local find input", function(context)
    local main_view = open_main_docview(context, "main alpha beta\n")
    main_view.__test_name = "main DocView"
    core.set_active_view(main_view)

    local side_a = register_side_docview(context, "side A", "side A alpha beta\n")
    local side_b = register_side_docview(context, "side B", "side B alpha beta\n")

    sidepanel.show("side A", { focus = true })
    assert_active_view(side_a, "expected side A before opening its find input")
    local find_a = open_find_input(side_a)
    find_a.__test_name = "local find input for side A DocView"
    type_into_active_view("alpha")

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected main DocView before opening side B")

    sidepanel.show("side B", { focus = true })
    assert_active_view(side_b, "expected side B before opening its find input")
    local find_b = open_find_input(side_b)
    find_b.__test_name = "local find input for side B DocView"
    type_into_active_view("beta")

    sidepanel.switch_side_view(-1)
    assert_active_view(find_a, "expected switching to side A to restore side A find input")
    test.equal(find_a:get_text(), "alpha")

    sidepanel.switch_side_view(1)
    assert_active_view(find_b, "expected switching back to side B to restore side B find input")
    test.equal(find_b:get_text(), "beta")
  end)
end)
