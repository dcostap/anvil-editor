local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local sidepanel = require "core.sidepanel"
local test = require "core.test"
local DocView = require "core.docview"
local View = require "core.view"

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
  view.__sidepanel_docview = true
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

    local side_node = sidepanel.ensure_side_node()
    if side_node then
      for i = #(side_node.views or {}), 1, -1 do
        local view = side_node.views[i]
        if view and not view.__sidepanel_placeholder then
          sidepanel.remove_view(view, false)
        end
      end
    end

    for _, doc in ipairs(context.docs or {}) do
      remove_doc(doc)
    end

    sidepanel.file_view = nil
    sidepanel.file_view_path = nil
    sidepanel.current_panel = nil
    sidepanel.last_side_focus_view = nil
    sidepanel.last_side_focus_owner = nil
    sidepanel.side_focus_views = setmetatable({}, { __mode = "k" })
    sidepanel.last_docview_focus_owner = nil
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

  test.it("closes a side DocView prompt bar when toggling focus back to main", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected side DocView before opening side find input")

    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")
    set_selection(side_find, 1, 2, 1, 6)
    local expected_selection = selection_state(side_find)

    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(main_view, "expected sidepanel toggle from side find input to focus main DocView")
    test.equal(side_find.local_find_state.visible, false)
    test.equal(side_find:get_text(), "side-query")
    test.same(selection_state(side_find), expected_selection)
  end)

  test.it("does not restore side or main prompt bars after focus leaves them", function(context)
    local main_view, side_view = setup_main_and_side(context)

    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")
    set_selection(side_find, 1, 2, 1, 6)
    local expected_side_selection = selection_state(side_find)

    core.set_active_view(main_view)
    test.equal(side_find.local_find_state.visible, false)

    local main_find = open_find_input(main_view)
    type_into_active_view("main-query")

    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(side_view, "expected toggle from main find input to close it and focus the Side DocView")
    test.equal(side_find:get_text(), "side-query")
    test.same(selection_state(side_find), expected_side_selection)
    test.equal(main_find.local_find_state.visible, false)
    test.equal(main_find:get_text(), "main-query")
  end)

  test.it("does not restore the side DocView replace input field after focus leaves it", function(context)
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
    assert_active_view(side_view, "expected toggling back to restore side DocView, not the closed replace input")
    test.equal(side_find:get_text(), "side-query")
    test.equal(side_replace:get_text(), "replacement")
    test.same(selection_state(side_replace), expected_replace_selection)
  end)

  test.it("alt+1 closes a Side DocView prompt bar and focuses its owner", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")

    test.ok(command.perform("sidepanel:focus-main-and-hide"))

    test.equal(sidepanel.visible, true)
    test.equal(sidepanel.active_side_view(), side_view)
    assert_active_view(side_view, "expected alt+1 from side find input to close it and focus its Side DocView")
    test.equal(side_find.local_find_state.visible, false)
    test.equal(side_find:get_text(), "side-query")
  end)

  test.it("hide closes a side prompt bar and focuses the main panel", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")

    test.ok(command.perform("sidepanel:hide"))

    test.equal(sidepanel.visible, false)
    assert_active_view(main_view, "expected sidepanel hide from side find input to focus main DocView")
    test.equal(side_find.local_find_state.visible, false)
    test.equal(side_find:get_text(), "side-query")
  end)

  test.it("focus-side restores the Side DocView after its prompt bar closed", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")

    test.ok(command.perform("sidepanel:hide"))
    assert_active_view(main_view, "expected sidepanel hide before focusing side again")

    test.ok(command.perform("sidepanel:focus-side"))

    test.equal(sidepanel.visible, true)
    assert_active_view(side_view, "expected focus-side to restore Side DocView, not the closed side find input")
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

  test.it("switching side views focuses their DocViews after prompt bars close", function(context)
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
    assert_active_view(side_a, "expected switching to side A to focus side A DocView")
    test.equal(find_a:get_text(), "alpha")

    sidepanel.switch_side_view(1)
    assert_active_view(side_b, "expected switching back to side B to focus side B DocView")
    test.equal(find_b:get_text(), "beta")
  end)

  test.it("does not restore a closed side find input", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")

    test.ok(command.perform("user:find-close"))
    assert_active_view(side_view, "expected closing side find to focus its owning DocView")
    test.equal(side_find.local_find_state.visible, false)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected toggle from side DocView to focus main DocView")
    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(side_view, "expected toggling back to restore side DocView, not its closed find input")
    test.equal(side_find.local_find_state.visible, false)
  end)

  test.it("alt+1 does not restore a Side DocView prompt bar after closing it", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")
    set_selection(side_find, 1, 3, 1, 8)
    local expected_selection = selection_state(side_find)

    test.ok(command.perform("sidepanel:focus-main-and-hide"))
    test.equal(sidepanel.visible, true)
    assert_active_view(side_view, "expected alt+1 to close the side find input and focus its owner")
    test.equal(side_find.local_find_state.visible, false)

    test.ok(command.perform("sidepanel:focus-side"))

    test.equal(sidepanel.visible, true)
    assert_active_view(side_view, "expected focus-side not to restore a closed side find input")
    test.equal(side_find:get_text(), "side-query")
    test.same(selection_state(side_find), expected_selection)
  end)

  test.it("alt+1 restores a hidden Side DocView instead of hiding a non-DocView side panel", function(context)
    local main_view = open_main_docview(context, "main alpha beta\n")
    main_view.__test_name = "main DocView"
    core.set_active_view(main_view)

    local side_view = register_side_docview(context, "side doc", "side alpha beta\n")
    local tool_view = track(context, "side_views", View())
    tool_view.__test_name = "persistent side tool"
    sidepanel.register_panel("test tool", tool_view)

    sidepanel.show("side doc", { focus = true })
    assert_active_view(side_view, "expected Side DocView to become last focused DocView")
    core.set_active_view(main_view)
    sidepanel.show("test tool", { focus = true })
    assert_active_view(tool_view, "expected non-DocView side tool before alt+1")

    test.ok(command.perform("sidepanel:focus-main-and-hide"))

    test.equal(sidepanel.visible, true)
    test.equal(sidepanel.active_side_view(), side_view)
    assert_active_view(main_view, "expected alt+1 to restore Side DocView but keep last main DocView focus")
  end)

  test.it("alt+1 hides a non-DocView side panel when no Side DocView is restorable", function(context)
    local main_view = open_main_docview(context, "main alpha beta\n")
    main_view.__test_name = "main DocView"
    core.set_active_view(main_view)

    local tool_view = track(context, "side_views", View())
    tool_view.__test_name = "persistent side tool"
    sidepanel.register_panel("test tool", tool_view)
    sidepanel.show("test tool", { focus = true })
    test.equal(sidepanel.restorable_side_docview(), nil)

    test.ok(command.perform("sidepanel:focus-main-and-hide"))

    test.equal(sidepanel.visible, false)
    assert_active_view(main_view, "expected alt+1 to hide side tool and focus main DocView")
  end)

  test.it("ctrl+w closes and hides the focused Side DocView", function(context)
    local main_view = open_main_docview(context, "main alpha beta\n")
    main_view.__test_name = "main DocView"
    core.set_active_view(main_view)
    local side_view = open_side_docview(context, "", main_view)
    side_view.__test_name = "clean Side DocView"

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected Side DocView before ctrl+w")
    test.equal(side_view.doc:is_dirty(), false)

    test.ok(command.perform("sidepanel:hide-active"))

    test.equal(sidepanel.visible, false)
    test.ok(not sidepanel.contains_view(side_view), "expected ctrl+w to remove the Side DocView from the Side Panel")
    assert_active_view(main_view, "expected ctrl+w to return focus to the main DocView")
  end)

  test.it("ctrl+w closes a Side DocView from its local find input", function(context)
    local main_view = open_main_docview(context, "main alpha beta\n")
    main_view.__test_name = "main DocView"
    core.set_active_view(main_view)
    local side_view = open_side_docview(context, "", main_view)
    side_view.__test_name = "clean Side DocView"

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")
    assert_active_view(side_find, "expected side find input before ctrl+w")
    side_view.doc:clean()
    test.equal(side_view.doc:is_dirty(), false)

    test.ok(command.perform("sidepanel:hide-active"))

    test.equal(sidepanel.visible, false)
    test.ok(not sidepanel.contains_view(side_view), "expected ctrl+w from side find to remove its owning Side DocView")
    assert_active_view(main_view, "expected ctrl+w from side find to return focus to the main DocView")
  end)

  test.it("ctrl+w removes a dirty shared Side DocView without prompting because the Document remains open in main", function(context)
    local doc = new_doc(context, "shared alpha beta\n")
    local main_view = track(context, "views", core.root_panel:open_doc(doc))
    main_view.__test_name = "main shared DocView"
    core.set_active_view(main_view)

    local side_view = track(context, "side_views", sidepanel.open_doc_in_side(doc, {
      focus = true,
      restore_focus = main_view,
    }))
    side_view.__test_name = "side shared DocView"
    track(context, "views", side_view)
    doc:text_input("dirty")
    test.ok(doc:is_dirty(), "expected shared Document to be dirty before closing duplicate Side DocView")

    test.ok(command.perform("sidepanel:hide-active"))

    test.equal(sidepanel.visible, false)
    test.ok(not sidepanel.contains_view(side_view), "expected duplicate Side DocView to be removed")
    test.ok(doc:is_dirty(), "expected dirty shared Document to remain open and dirty in main")
    assert_active_view(main_view, "expected focus to return to the remaining main DocView")
  end)

  test.it("ctrl+w prompts instead of removing the last dirty Side DocView", function(context)
    local main_view = open_main_docview(context, "main alpha beta\n")
    main_view.__test_name = "main DocView"
    core.set_active_view(main_view)

    local side_view = register_side_docview(context, "side only", "side alpha beta\n")
    sidepanel.show("side only", { focus = true })
    side_view.doc:text_input("dirty")
    test.ok(side_view.doc:is_dirty(), "expected side-only Document to be dirty before close")

    test.ok(command.perform("sidepanel:hide-active"))

    test.ok(sidepanel.contains_view(side_view), "expected dirty last Side DocView to stay open until close is confirmed")
    test.equal(sidepanel.visible, true)
    assert_active_view(core.global_prompt_bar, "expected dirty last Side DocView close to show the unsaved-changes prompt")
    core.global_prompt_bar:exit(false)
  end)

  test.it("replacing the side file panel clears stale local find focus", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local old_side_find = open_find_input(side_view)
    type_into_active_view("old-query")
    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected main DocView before replacing side file panel")

    local replacement_view = open_side_docview(context, "replacement alpha beta\n", main_view)
    replacement_view.__test_name = "replacement side DocView"

    test.equal(sidepanel.side_focus_owner(old_side_find), nil)
    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(replacement_view, "expected toggle to focus replacement side DocView, not old side find input")
  end)

  test.it("root tab switching from a side find input closes it and switches side-panel views", function(context)
    local main_view = open_main_docview(context, "main alpha beta\n")
    main_view.__test_name = "main DocView"
    core.set_active_view(main_view)

    local side_a = register_side_docview(context, "side A", "side A alpha beta\n")
    local side_b = register_side_docview(context, "side B", "side B alpha beta\n")

    sidepanel.show("side A", { focus = true })
    local find_a = open_find_input(side_a)
    find_a.__test_name = "local find input for side A DocView"
    type_into_active_view("alpha")

    sidepanel.show("side B", { focus = true })
    local find_b = open_find_input(side_b)
    find_b.__test_name = "local find input for side B DocView"
    type_into_active_view("beta")

    assert_active_view(find_b, "expected side B find input before root tab switch")
    test.ok(command.perform("root:switch-to-previous-tab"))

    assert_active_view(side_a, "expected previous-tab from side find input to close it and switch to side A DocView")
    test.equal(find_a:get_text(), "alpha")
  end)

  test.it("does not restore a submitted side find input as focused", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")

    test.ok(command.perform("user:find-submit-or-replace"))
    assert_active_view(side_view, "expected submitting side find to return focus to the side DocView")
    test.equal(side_find.local_find_state.visible, false)
    test.equal(side_find.local_find_state.input_active, false)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected toggle from side DocView to focus main DocView")
    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(side_view, "expected toggling back to restore side DocView, not inactive side find input")
    test.equal(side_find.local_find_state.input_active, false)
  end)

  test.it("side and main local find inputs stay independent for the same document", function(context)
    local doc = new_doc(context, "shared alpha beta\nshared gamma\n")
    local main_view = track(context, "views", core.root_panel:open_doc(doc))
    main_view.__test_name = "main shared DocView"
    core.set_active_view(main_view)

    local side_view = track(context, "side_views", sidepanel.open_doc_in_side(doc, {
      focus = false,
      restore_focus = main_view,
    }))
    side_view.__test_name = "side shared DocView"
    track(context, "views", side_view)

    local main_find = open_find_input(main_view)
    main_find.__test_name = "local find input for main shared DocView"
    type_into_active_view("main-query")
    set_selection(main_find, 1, 2, 1, 7)
    local expected_main_selection = selection_state(main_find)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected toggle to focus side shared DocView")
    local side_find = open_find_input(side_view)
    side_find.__test_name = "local find input for side shared DocView"
    type_into_active_view("side-query")
    set_selection(side_find, 1, 3, 1, 8)
    local expected_side_selection = selection_state(side_find)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected toggling to main to focus main shared DocView")
    test.equal(main_find:get_text(), "main-query")
    test.same(selection_state(main_find), expected_main_selection)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected toggling to side to focus side shared DocView")
    test.equal(side_find:get_text(), "side-query")
    test.same(selection_state(side_find), expected_side_selection)
  end)

  test.it("sidepanel open-current-file copies main selection and scroll", function(context)
    local main_view = open_main_docview(context, "one\ntwo alpha\nthree\n")
    main_view.__test_name = "main DocView"
    core.set_active_view(main_view)
    set_selection(main_view, 2, 5, 2, 10)
    main_view.scroll.x, main_view.scroll.to.x = 11, 11
    main_view.scroll.y, main_view.scroll.to.y = 22, 22
    local expected_selection = main_view:get_selection_state()

    test.ok(command.perform("sidepanel:open-current-file"))
    local side_view = sidepanel.file_view
    side_view.__test_name = "side file DocView"
    track(context, "side_views", side_view)
    track(context, "views", side_view)

    assert_active_view(side_view, "expected open-current-file to focus the side file DocView")
    test.ok(side_view.doc == main_view.doc, "expected side file DocView to share the main document")
    test.same(side_view:get_selection_state(), expected_selection)
    test.equal(side_view.scroll.x, 11)
    test.equal(side_view.scroll.y, 22)
  end)

  test.it("open-current-file from side DocView opens it in main and copies position", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected side DocView before opening in main")
    set_selection(side_view, 1, 6, 1, 11)
    side_view.scroll.x, side_view.scroll.to.x = 17, 17
    side_view.scroll.y, side_view.scroll.to.y = 31, 31
    local expected_selection = side_view:get_selection_state()

    test.ok(command.perform("sidepanel:open-current-file"))
    local opened = core.active_view
    opened.__test_name = "main copy of side DocView"
    track(context, "views", opened)

    test.equal(sidepanel.visible, true)
    test.ok(not sidepanel.is_side_view(opened), "expected opened view to be in the main panel")
    test.ok(opened.doc == side_view.doc, "expected opened main DocView to share the side document")
    test.same(opened:get_selection_state(), expected_selection)
    test.equal(opened.scroll.x, 17)
    test.equal(opened.scroll.y, 31)
    test.ok(opened ~= main_view, "expected side document to open as a main panel tab")
  end)

  test.it("open-current-file from side find input opens owner in main", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("alpha")
    set_selection(side_view, 1, 7, 1, 11)
    local expected_selection = side_view:get_selection_state()

    test.ok(command.perform("sidepanel:open-current-file"))
    local opened = core.active_view
    opened.__test_name = "main copy of side find owner"
    track(context, "views", opened)

    test.ok(not opened.local_find_input, "expected command to focus the main DocView, not a find input")
    test.ok(opened.doc == side_view.doc, "expected opened main DocView to share the side find owner document")
    test.same(opened:get_selection_state(), expected_selection)
    test.equal(side_find.local_find_state.visible, false)
    test.equal(side_find:get_text(), "alpha")
    test.ok(opened ~= main_view, "expected side document to open as a main panel tab")
  end)

  test.it("open-current-file from side DocView reuses existing main view and copies position", function(context)
    local doc = new_doc(context, "shared one\nshared two\n")
    local main_view = track(context, "views", core.root_panel:open_doc(doc))
    main_view.__test_name = "existing main shared DocView"
    core.set_active_view(main_view)

    local side_view = track(context, "side_views", sidepanel.open_doc_in_side(doc, {
      focus = true,
      restore_focus = main_view,
    }))
    side_view.__test_name = "side shared DocView"
    track(context, "views", side_view)

    set_selection(side_view, 2, 3, 2, 9)
    side_view.scroll.x, side_view.scroll.to.x = 23, 23
    side_view.scroll.y, side_view.scroll.to.y = 47, 47
    local expected_selection = side_view:get_selection_state()

    test.ok(command.perform("sidepanel:open-current-file"))

    assert_active_view(main_view, "expected command to reuse and focus existing main DocView")
    test.same(main_view:get_selection_state(), expected_selection)
    test.equal(main_view.scroll.x, 23)
    test.equal(main_view.scroll.y, 47)
  end)

  test.it("closes a side find field after focus switches", function(context)
    local main_view, side_view = setup_main_and_side(context)
    side_view.doc:remove(1, 1, math.huge, math.huge)
    side_view.doc:text_input("alpha beta alpha gamma alpha\n")

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("al")
    test.equal(side_find:get_text(), "al")
    local side_initial_match = side_find.local_find_state.current
    test.ok(side_initial_match > 0, "expected side find to select an initial match")
    local side_navigated_match = (side_initial_match % 3) + 1

    test.ok(command.perform("user:find-field-next"))
    test.equal(side_find.local_find_state.current, side_navigated_match)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected toggle away from side find to focus main DocView")
    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected toggling back to focus side DocView, not the closed find field")
    test.equal(side_find.local_find_state.visible, false)
    test.equal(side_find:get_text(), "al")
    test.equal(side_find.local_find_state.current, 0)
  end)

  test.it("closes a main find field after side focus switches", function(context)
    local main_view, side_view = setup_main_and_side(context)
    main_view.doc:remove(1, 1, math.huge, math.huge)
    main_view.doc:text_input("alpha beta alpha gamma alpha\n")

    local main_find = open_find_input(main_view)
    main_find.__test_name = "local find input for main DocView"
    type_into_active_view("alp")
    test.equal(main_find:get_text(), "alp")
    local main_initial_match = main_find.local_find_state.current
    test.ok(main_initial_match > 0, "expected main find to select an initial match")
    local main_navigated_match = (main_initial_match % 3) + 1

    test.ok(command.perform("user:find-field-next"))
    test.equal(main_find.local_find_state.current, main_navigated_match)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected toggle away from main find to focus side DocView")
    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected toggling back to focus main DocView, not the closed find field")
    test.equal(main_find.local_find_state.visible, false)
    test.equal(main_find:get_text(), "alp")
    test.equal(main_find.local_find_state.current, 0)
  end)

  test.it("does not restore main replace input after side focus switches", function(context)
    local main_view, side_view = setup_main_and_side(context)

    core.set_active_view(main_view)
    test.ok(command.perform("find-replace:replace"))
    local main_find = active_find_input_for(main_view)
    main_find.__test_name = "local find input for main DocView"
    type_into_active_view("alpha")

    test.ok(command.perform("user:find-toggle-replace-field"))
    local main_replace = active_find_input_for(main_view)
    main_replace.__test_name = "local replace input for main DocView"
    test.equal(main_replace.local_find_field, "replace")
    type_into_active_view("omega")
    set_selection(main_replace, 1, 2, 1, 5)
    local expected_replace_selection = selection_state(main_replace)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected toggle away from main replace input to focus side DocView")
    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(main_view, "expected toggling back to focus main DocView, not closed replace input")
    test.equal(main_find:get_text(), "alpha")
    test.equal(main_replace:get_text(), "omega")
    test.same(selection_state(main_replace), expected_replace_selection)
  end)

  test.it("main and side find options remain independent for the same document", function(context)
    local doc = new_doc(context, "Alpha alpha beta\n")
    local main_view = track(context, "views", core.root_panel:open_doc(doc))
    main_view.__test_name = "main shared DocView"
    core.set_active_view(main_view)

    local side_view = track(context, "side_views", sidepanel.open_doc_in_side(doc, {
      focus = false,
      restore_focus = main_view,
    }))
    side_view.__test_name = "side shared DocView"
    track(context, "views", side_view)

    local main_find = open_find_input(main_view)
    main_find.__test_name = "local find input for main shared DocView"
    type_into_active_view("alpha")
    test.equal(main_find.local_find_state.case_sensitive, false)
    test.equal(main_find.local_find_state.regex, false)
    test.ok(command.perform("find-replace:toggle-sensitivity"))
    test.ok(command.perform("find-replace:toggle-regex"))
    test.equal(main_find.local_find_state.case_sensitive, true)
    test.equal(main_find.local_find_state.regex, true)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected toggle to focus side shared DocView")
    local side_find = open_find_input(side_view)
    side_find.__test_name = "local find input for side shared DocView"
    type_into_active_view("alpha")

    test.equal(side_find.local_find_state.case_sensitive, false)
    test.equal(side_find.local_find_state.regex, false)
    test.equal(main_find.local_find_state.case_sensitive, true)
    test.equal(main_find.local_find_state.regex, true)
  end)

  test.it("closing a main find input prevents it from being restored after side focus", function(context)
    local main_view, side_view = setup_main_and_side(context)

    local main_find = open_find_input(main_view)
    main_find.__test_name = "local find input for main DocView"
    type_into_active_view("alpha")

    test.ok(command.perform("user:find-close"))
    assert_active_view(main_view, "expected closing main find to focus its owning DocView")
    test.equal(main_find.local_find_state.visible, false)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected toggle from main DocView to focus side DocView")
    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(main_view, "expected toggling back to restore main DocView, not its closed find input")
    test.equal(main_find.local_find_state.visible, false)
  end)

  test.it("alt+1 hides the Editree file tree and focuses the main DocView", function(context)
    local main_view = open_main_docview(context, "main alpha beta\n")
    main_view.__test_name = "main DocView"
    core.set_active_view(main_view)

    local editree = require "plugins.editree"
    track(context, "side_views", editree)
    editree.__test_name = "Editree file tree"
    sidepanel.register_panel("editree", editree)
    sidepanel.show("editree", { focus = true })
    assert_active_view(editree, "expected Editree file tree before alt+1")

    keymap.modkeys.alt = true
    local performed = keymap.on_key_pressed("1")
    keymap.modkeys.alt = false

    test.ok(performed, "expected alt+1 keymap to perform a command")
    test.equal(sidepanel.visible, false)
    assert_active_view(main_view, "expected alt+1 to hide Editree and focus the main DocView")
  end)
end)
