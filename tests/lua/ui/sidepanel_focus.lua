local core = require "core"
local command = require "core.command"
local file_context = require "core.file_context"
local sidepanel = require "core.sidepanel"
local test = require "core.test"
local Editor = require "core.docview"
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

local function open_main_editor(context, text)
  local doc = new_doc(context, text)
  local view = track(context, "views", core.root_panel:open_doc(doc))
  return view, doc
end

local function open_side_editor(context, text, restore_focus)
  local doc = new_doc(context, text)
  local view = track(context, "side_views", sidepanel.open_doc_in_side(doc, {
    focus = false,
    restore_focus = restore_focus,
  }))
  track(context, "views", view)
  return view, doc
end

local function setup_main_and_side(context)
  local main_view = open_main_editor(context, "main alpha beta\n")
  main_view.__test_name = "main Editor"
  core.set_active_view(main_view)
  local side_view = open_side_editor(context, "side alpha beta\n", main_view)
  side_view.__test_name = "side Editor"
  test.equal(core.active_view, main_view)
  return main_view, side_view
end

local function register_side_editor(context, name, text)
  local doc = new_doc(context, text)
  local view = track(context, "side_views", Editor(doc))
  view.__test_name = name .. " Editor"
  file_context.mark_editor_view(view)
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

local function save_restorable_view(view)
  local state = view and view.get_state and view:get_state()
  local module = view and view.get_module and view:get_module()
  if state and module then
    return {
      module = module,
      active = core.active_view == view,
      state = state,
    }
  end
end

local function load_restorable_view(t)
  if not (t and t.module) then return nil end
  local ViewClass = require(t.module)
  return ViewClass and ViewClass.from_state and ViewClass.from_state(t.state)
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
    sidepanel.last_editor_focus_owner = nil
    sidepanel.hide(false)
    local main_panel = core.root_panel:get_main_panel()
    if main_panel and main_panel.active_view then
      core.set_active_view(main_panel.active_view)
      sidepanel.last_main_panel_view = main_panel.active_view
    else
      sidepanel.last_main_panel_view = nil
    end
  end)

  test.it("saves and restores the Side Editor file view", function(context)
    local main_view = open_main_editor(context, "main alpha beta\n")
    main_view.__test_name = "main Editor"
    core.set_active_view(main_view)
    local side_view, side_doc = open_side_editor(context, "side alpha beta\n", main_view)
    side_view.__test_name = "side Editor"
    set_selection(side_view, 1, 6, 1, 10)
    side_view.scroll.x, side_view.scroll.to.x = 3, 3
    side_view.scroll.y, side_view.scroll.to.y = 7, 7

    local state = sidepanel.save_workspace_state(save_restorable_view)
    test.type(state, "table")
    test.type(state.file_view, "table")
    test.equal(state.visible, false)
    test.equal(state.side_editor_slot_visible, true)

    side_doc:clean()
    sidepanel.remove_view(side_view, false)
    sidepanel.file_view = nil
    sidepanel.file_view_path = nil
    remove_doc(side_doc)

    local restored = sidepanel.restore_workspace_state(state, load_restorable_view)
    local restored_view = sidepanel.file_view
    track(context, "side_views", restored_view)
    track(context, "views", restored_view)
    track(context, "docs", restored_view.doc)
    restored_view.__test_name = "restored side Editor"

    test.ok(restored, "expected Side Panel Workspace state to restore")
    test.ok(sidepanel.contains_view(restored_view), "expected restored Side Editor in Side Panel")
    test.ok(sidepanel.is_side_editor(restored_view), "expected restored view to be a Side Editor")
    test.equal(restored_view.doc:get_text(1, 1, math.huge, math.huge), "side alpha beta\n")
    test.same(selection_state(restored_view), { 1, 6, 1, 10 })
    test.equal(restored_view.scroll.to.x, 3)
    test.equal(restored_view.scroll.to.y, 7)
    test.equal(sidepanel.visible, false)
    test.equal(sidepanel.side_editor_slot_visible, true)
  end)

  test.it("focuses the existing side Editor from the main panel", function(context)
    local main_view, side_view = setup_main_and_side(context)

    assert_active_view(main_view, "expected main Editor before toggling to side panel")
    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(side_view, "expected side Editor after toggling from main panel")
  end)

  test.it("focuses the main Editor from the side Editor", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected side Editor before toggling back to main panel")
    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(main_view, "expected main Editor after toggling from side Editor")
  end)

  test.it("surface focus command alternates Editing Surface and Side Editor Slot without turning it into Side Panel", function(context)
    local main_view, side_view = setup_main_and_side(context)
    core.set_active_view(main_view)

    test.ok(command.perform("surface:focus-next-target-or-sidepanel"))
    test.equal(sidepanel.visible, false)
    test.equal(sidepanel.side_editor_slot_visible, true)
    test.equal(sidepanel.active_side_view(), side_view)
    assert_active_view(side_view, "expected surface focus command to enter Side Editor Slot")

    test.ok(command.perform("surface:focus-next-target-or-sidepanel"))
    test.equal(sidepanel.visible, false)
    test.equal(sidepanel.side_editor_slot_visible, true)
    test.equal(sidepanel.active_side_view(), side_view)
    assert_active_view(main_view, "expected surface focus command to return to main Editor")

    test.ok(command.perform("surface:focus-next-target-or-sidepanel"))
    test.equal(sidepanel.visible, false)
    test.equal(sidepanel.side_editor_slot_visible, true)
    test.equal(sidepanel.active_side_view(), side_view)
    assert_active_view(side_view, "expected repeated surface focus command to keep Side Editor Slot drawable")
  end)

  test.it("deactivates a side Editor prompt bar when toggling focus back to main", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected side Editor before opening side find input")

    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")
    set_selection(side_find, 1, 2, 1, 6)
    local expected_selection = selection_state(side_find)

    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(main_view, "expected sidepanel toggle from side find input to focus main Editor")
    test.equal(side_find.local_find_state.visible, true)
    test.equal(side_find.local_find_state.input_active, false)
    test.equal(side_find:get_text(), "side-query")
    test.same(selection_state(side_find), expected_selection)
  end)

  test.it("restores the side prompt bar focus while deactivating the main prompt bar", function(context)
    local main_view, side_view = setup_main_and_side(context)

    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")
    set_selection(side_find, 1, 2, 1, 6)
    local expected_side_selection = selection_state(side_find)

    core.set_active_view(main_view)
    test.equal(side_find.local_find_state.visible, true)
    test.equal(side_find.local_find_state.input_active, false)

    local main_find = open_find_input(main_view)
    type_into_active_view("main-query")

    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(side_view, "expected toggle from main find input to focus the Side Editor")
    test.equal(side_find.local_find_state.input_active, false)
    test.equal(side_find:get_text(), "side-query")
    test.same(selection_state(side_find), expected_side_selection)
    test.equal(main_find.local_find_state.visible, true)
    test.equal(main_find.local_find_state.input_active, false)
    test.equal(main_find:get_text(), "main-query")
  end)

  test.it("restores the side Editor replace input field after focus leaves it", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected side Editor before opening replace input")

    test.ok(command.perform("find-replace:replace"))
    local side_find = active_find_input_for(side_view)
    test.equal(side_find.local_find_field, "find")
    type_into_active_view("side-query")

    test.ok(command.perform("user:find-toggle-replace-field"))
    local side_replace = active_find_input_for(side_view)
    side_replace.__test_name = "local replace input for side Editor"
    test.equal(side_replace.local_find_field, "replace")
    type_into_active_view("replacement")
    set_selection(side_replace, 1, 2, 1, 7)
    local expected_replace_selection = selection_state(side_replace)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected toggle from side replace input to focus main Editor")

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_replace, "expected toggling back to restore side replace input")
    test.equal(side_replace.local_find_state.input_active, true)
    test.equal(side_find:get_text(), "side-query")
    test.equal(side_replace:get_text(), "replacement")
    test.same(selection_state(side_replace), expected_replace_selection)
  end)

  test.it("focus-main-and-hide closes a Side Editor prompt bar without treating it as a Side Panel tool", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")

    test.ok(command.perform("sidepanel:focus-main-and-hide"))

    test.equal(sidepanel.visible, true)
    assert_active_view(side_view, "expected focus-main-and-hide from side find input to close it and focus its Side Editor")
    test.equal(side_find.local_find_state.visible, false)
    test.equal(side_find:get_text(), "side-query")
  end)

  test.it("hide does not steal focus from the Side Editor Slot", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")

    test.ok(command.perform("sidepanel:hide"))

    test.equal(sidepanel.visible, false)
    test.equal(sidepanel.side_editor_slot_visible, true)
    assert_active_view(side_find, "expected sidepanel hide from side find input to leave Side Editor Slot focus alone")
    test.equal(side_find.local_find_state.visible, true)
    test.equal(side_find.local_find_state.input_active, true)
    test.equal(side_find:get_text(), "side-query")
  end)

  test.it("focus-side restores the Side Editor prompt bar focus after it deactivated", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")

    test.ok(command.perform("sidepanel:hide"))
    assert_active_view(side_find, "expected sidepanel hide to leave side find focused")

    test.ok(command.perform("sidepanel:focus-side"))

    test.equal(sidepanel.visible, true)
    assert_active_view(side_find, "expected focus-side to restore the inactive side find input")
    test.equal(side_find.local_find_state.input_active, true)
    test.equal(side_find:get_text(), "side-query")
  end)

  test.it("does not restore a stale side find input after the side view is removed", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")
    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected main Editor before removing side view")

    sidepanel.remove_view(side_view, false)

    test.equal(sidepanel.last_side_focus_view, nil)
    test.equal(sidepanel.last_side_focus_owner, nil)
    test.equal(sidepanel.side_focus_views[side_view], nil)
    test.equal(sidepanel.side_focus_owner(side_find), nil)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected toggle not to restore removed side find input")
  end)

  test.it("switching side views restores each visible prompt bar focus", function(context)
    local main_view = open_main_editor(context, "main alpha beta\n")
    main_view.__test_name = "main Editor"
    core.set_active_view(main_view)

    local side_a = register_side_editor(context, "side A", "side A alpha beta\n")
    local side_b = register_side_editor(context, "side B", "side B alpha beta\n")

    sidepanel.show("side A", { focus = true })
    assert_active_view(side_a, "expected side A before opening its find input")
    local find_a = open_find_input(side_a)
    find_a.__test_name = "local find input for side A Editor"
    type_into_active_view("alpha")

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected main Editor before opening side B")

    sidepanel.show("side B", { focus = true })
    assert_active_view(side_b, "expected side B before opening its find input")
    local find_b = open_find_input(side_b)
    find_b.__test_name = "local find input for side B Editor"
    type_into_active_view("beta")

    sidepanel.switch_side_view(-1)
    assert_active_view(find_a, "expected switching to side A to restore side A prompt focus")
    test.equal(find_a.local_find_state.input_active, true)
    test.equal(find_a:get_text(), "alpha")

    sidepanel.switch_side_view(1)
    assert_active_view(find_b, "expected switching back to side B to restore side B prompt focus")
    test.equal(find_b.local_find_state.input_active, true)
    test.equal(find_b:get_text(), "beta")
  end)

  test.it("does not restore a closed side find input", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")

    test.ok(command.perform("user:find-close"))
    assert_active_view(side_view, "expected closing side find to focus its owning Editor")
    test.equal(side_find.local_find_state.visible, false)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected toggle from side Editor to focus main Editor")
    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(side_view, "expected toggling back to restore side Editor, not its closed find input")
    test.equal(side_find.local_find_state.visible, false)
  end)

  test.it("focus-main-and-hide does not restore a Side Editor prompt bar after closing it", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")
    set_selection(side_find, 1, 3, 1, 8)
    local expected_selection = selection_state(side_find)

    test.ok(command.perform("sidepanel:focus-main-and-hide"))
    test.equal(sidepanel.visible, true)
    assert_active_view(side_view, "expected focus-main-and-hide to close the side find input and focus its owner")
    test.equal(side_find.local_find_state.visible, false)

    test.ok(command.perform("sidepanel:focus-side"))

    test.equal(sidepanel.visible, true)
    assert_active_view(side_view, "expected focus-side not to restore a closed side find input")
    test.equal(side_find:get_text(), "side-query")
    test.same(selection_state(side_find), expected_selection)
  end)

  test.it("focus-main-and-hide restores a hidden Side Editor instead of hiding a non-Editor side panel", function(context)
    local main_view = open_main_editor(context, "main alpha beta\n")
    main_view.__test_name = "main Editor"
    core.set_active_view(main_view)

    local side_view = register_side_editor(context, "side doc", "side alpha beta\n")
    local tool_view = track(context, "side_views", View())
    tool_view.__test_name = "persistent side tool"
    sidepanel.register_panel("test tool", tool_view)

    sidepanel.show("side doc", { focus = true })
    assert_active_view(side_view, "expected Side Editor to become last focused Editor")
    core.set_active_view(main_view)
    sidepanel.show("test tool", { focus = true })
    assert_active_view(tool_view, "expected non-Editor side tool before focus-main-and-hide")

    test.ok(command.perform("sidepanel:focus-main-and-hide"))

    test.equal(sidepanel.visible, true)
    test.equal(sidepanel.active_side_view(), side_view)
    assert_active_view(main_view, "expected focus-main-and-hide to restore Side Editor but keep last main Editor focus")
  end)

  test.it("focus-main-and-hide hides a non-Editor side panel when no Side Editor is restorable", function(context)
    local main_view = open_main_editor(context, "main alpha beta\n")
    main_view.__test_name = "main Editor"
    core.set_active_view(main_view)

    local tool_view = track(context, "side_views", View())
    tool_view.__test_name = "persistent side tool"
    sidepanel.register_panel("test tool", tool_view)
    sidepanel.show("test tool", { focus = true })
    test.equal(sidepanel.restorable_side_editor(), nil)

    test.ok(command.perform("sidepanel:focus-main-and-hide"))

    test.equal(sidepanel.visible, false)
    assert_active_view(main_view, "expected focus-main-and-hide to hide side tool and focus main Editor")
  end)

  test.it("hide-active closes and hides the focused Side Editor", function(context)
    local main_view = open_main_editor(context, "main alpha beta\n")
    main_view.__test_name = "main Editor"
    core.set_active_view(main_view)
    local side_view = open_side_editor(context, "", main_view)
    side_view.__test_name = "clean Side Editor"

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected Side Editor before hide-active")
    test.equal(side_view.doc:is_dirty(), false)

    test.ok(command.perform("sidepanel:hide-active"))

    test.equal(sidepanel.visible, false)
    test.ok(not sidepanel.contains_view(side_view), "expected hide-active to remove the Side Editor from the Side Panel")
    assert_active_view(main_view, "expected hide-active to return focus to the main Editor")
  end)

  test.it("hide-active closes a Side Editor from its local find input", function(context)
    local main_view = open_main_editor(context, "main alpha beta\n")
    main_view.__test_name = "main Editor"
    core.set_active_view(main_view)
    local side_view = open_side_editor(context, "", main_view)
    side_view.__test_name = "clean Side Editor"

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")
    assert_active_view(side_find, "expected side find input before hide-active")
    side_view.doc:clean()
    test.equal(side_view.doc:is_dirty(), false)

    test.ok(command.perform("sidepanel:hide-active"))

    test.equal(sidepanel.visible, false)
    test.ok(not sidepanel.contains_view(side_view), "expected hide-active from side find to remove its owning Side Editor")
    assert_active_view(main_view, "expected hide-active from side find to return focus to the main Editor")
  end)

  test.it("hide-active removes a dirty shared Side Editor without prompting because the Document remains open in main", function(context)
    local doc = new_doc(context, "shared alpha beta\n")
    local main_view = track(context, "views", core.root_panel:open_doc(doc))
    main_view.__test_name = "main shared Editor"
    core.set_active_view(main_view)

    local side_view = track(context, "side_views", sidepanel.open_doc_in_side(doc, {
      focus = true,
      restore_focus = main_view,
    }))
    side_view.__test_name = "side shared Editor"
    track(context, "views", side_view)
    doc:text_input("dirty")
    test.ok(doc:is_dirty(), "expected shared Document to be dirty before closing duplicate Side Editor")

    test.ok(command.perform("sidepanel:hide-active"))

    test.equal(sidepanel.visible, false)
    test.ok(not sidepanel.contains_view(side_view), "expected duplicate Side Editor to be removed")
    test.ok(doc:is_dirty(), "expected dirty shared Document to remain open and dirty in main")
    assert_active_view(main_view, "expected focus to return to the remaining main Editor")
  end)

  test.it("hide-active prompts instead of removing the last dirty Side Editor", function(context)
    local main_view = open_main_editor(context, "main alpha beta\n")
    main_view.__test_name = "main Editor"
    core.set_active_view(main_view)

    local side_view = register_side_editor(context, "side only", "side alpha beta\n")
    sidepanel.show("side only", { focus = true })
    side_view.doc:text_input("dirty")
    test.ok(side_view.doc:is_dirty(), "expected side-only Document to be dirty before close")

    test.ok(command.perform("sidepanel:hide-active"))

    test.ok(sidepanel.contains_view(side_view), "expected dirty last Side Editor to stay open until close is confirmed")
    test.equal(sidepanel.visible, true)
    assert_active_view(core.global_prompt_bar, "expected dirty last Side Editor close to show the unsaved-changes prompt")
    core.global_prompt_bar:exit(false)
  end)

  test.it("replacing the side file panel clears stale local find focus", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local old_side_find = open_find_input(side_view)
    type_into_active_view("old-query")
    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected main Editor before replacing side file panel")

    local replacement_view = open_side_editor(context, "replacement alpha beta\n", main_view)
    replacement_view.__test_name = "replacement side Editor"

    test.equal(sidepanel.side_focus_owner(old_side_find), nil)
    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(replacement_view, "expected toggle to focus replacement side Editor, not old side find input")
  end)

  test.it("root tab switching is not a global Side Panel content switch", function(context)
    local main_view = open_main_editor(context, "main alpha beta\n")
    main_view.__test_name = "main Editor"
    core.set_active_view(main_view)

    local side_a = register_side_editor(context, "side A", "side A alpha beta\n")
    local side_b = register_side_editor(context, "side B", "side B alpha beta\n")

    sidepanel.show("side A", { focus = true })
    local find_a = open_find_input(side_a)
    find_a.__test_name = "local find input for side A Editor"
    type_into_active_view("alpha")

    sidepanel.show("side B", { focus = true })
    local find_b = open_find_input(side_b)
    find_b.__test_name = "local find input for side B Editor"
    type_into_active_view("beta")

    assert_active_view(find_b, "expected side B find input before root tab switch")
    test.ok(command.perform("root:switch-to-previous-tab"))

    test.equal(sidepanel.active_side_view(), side_b)
    test.equal(find_b.local_find_state.input_active, false)
    test.equal(find_b:get_text(), "beta")
    test.equal(find_a.local_find_state.input_active, false)
    test.equal(find_a:get_text(), "alpha")
  end)

  test.it("does not restore a submitted side find input as focused", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    local side_find = open_find_input(side_view)
    type_into_active_view("side-query")

    test.ok(command.perform("user:find-submit-or-replace"))
    assert_active_view(side_view, "expected submitting side find to return focus to the side Editor")
    test.equal(side_find.local_find_state.visible, false)
    test.equal(side_find.local_find_state.input_active, false)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected toggle from side Editor to focus main Editor")
    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(side_view, "expected toggling back to restore side Editor, not inactive side find input")
    test.equal(side_find.local_find_state.input_active, false)
  end)

  test.it("side and main local find inputs stay independent for the same document", function(context)
    local doc = new_doc(context, "shared alpha beta\nshared gamma\n")
    local main_view = track(context, "views", core.root_panel:open_doc(doc))
    main_view.__test_name = "main shared Editor"
    core.set_active_view(main_view)

    local side_view = track(context, "side_views", sidepanel.open_doc_in_side(doc, {
      focus = false,
      restore_focus = main_view,
    }))
    side_view.__test_name = "side shared Editor"
    track(context, "views", side_view)

    local main_find = open_find_input(main_view)
    main_find.__test_name = "local find input for main shared Editor"
    type_into_active_view("main-query")
    set_selection(main_find, 1, 2, 1, 7)
    local expected_main_selection = selection_state(main_find)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected toggle to focus side shared Editor")
    local side_find = open_find_input(side_view)
    side_find.__test_name = "local find input for side shared Editor"
    type_into_active_view("side-query")
    set_selection(side_find, 1, 3, 1, 8)
    local expected_side_selection = selection_state(side_find)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_find, "expected toggling to main to restore main shared prompt focus")
    test.equal(main_find.local_find_state.input_active, true)
    test.equal(main_find:get_text(), "main-query")
    test.same(selection_state(main_find), expected_main_selection)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_find, "expected toggling to side to restore side shared prompt focus")
    test.equal(side_find.local_find_state.input_active, true)
    test.equal(side_find:get_text(), "side-query")
    test.same(selection_state(side_find), expected_side_selection)
  end)

  test.it("sidepanel open-current-file copies main selection and scroll", function(context)
    local main_view = open_main_editor(context, "one\ntwo alpha\nthree\n")
    main_view.__test_name = "main Editor"
    core.set_active_view(main_view)
    set_selection(main_view, 2, 5, 2, 10)
    main_view.scroll.x, main_view.scroll.to.x = 11, 11
    main_view.scroll.y, main_view.scroll.to.y = 22, 22
    local expected_selection = main_view:get_selection_state()

    test.ok(command.perform("sidepanel:open-current-file"))
    local side_view = sidepanel.file_view
    side_view.__test_name = "side file Editor"
    track(context, "side_views", side_view)
    track(context, "views", side_view)

    assert_active_view(side_view, "expected open-current-file to focus the side file Editor")
    test.ok(side_view.doc == main_view.doc, "expected side file Editor to share the main document")
    test.same(side_view:get_selection_state(), expected_selection)
    test.equal(side_view.scroll.x, 11)
    test.equal(side_view.scroll.y, 22)
  end)

  test.it("open-current-file from side Editor opens it in main and copies position", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected side Editor before opening in main")
    set_selection(side_view, 1, 6, 1, 11)
    side_view.scroll.x, side_view.scroll.to.x = 17, 17
    side_view.scroll.y, side_view.scroll.to.y = 31, 31
    local expected_selection = side_view:get_selection_state()

    test.ok(command.perform("sidepanel:open-current-file"))
    local opened = core.active_view
    opened.__test_name = "main copy of side Editor"
    track(context, "views", opened)

    test.equal(sidepanel.visible, true)
    test.ok(not sidepanel.is_side_view(opened), "expected opened view to be in the main panel")
    test.ok(opened.doc == side_view.doc, "expected opened main Editor to share the side document")
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

    test.ok(not opened.local_find_input, "expected command to focus the main Editor, not a find input")
    test.ok(opened.doc == side_view.doc, "expected opened main Editor to share the side find owner document")
    test.same(opened:get_selection_state(), expected_selection)
    test.equal(side_find.local_find_state.visible, true)
    test.equal(side_find.local_find_state.input_active, false)
    test.equal(side_find:get_text(), "alpha")
    test.ok(opened ~= main_view, "expected side document to open as a main panel tab")
  end)

  test.it("open-current-file from side Editor reuses existing main view and copies position", function(context)
    local doc = new_doc(context, "shared one\nshared two\n")
    local main_view = track(context, "views", core.root_panel:open_doc(doc))
    main_view.__test_name = "existing main shared Editor"
    core.set_active_view(main_view)

    local side_view = track(context, "side_views", sidepanel.open_doc_in_side(doc, {
      focus = true,
      restore_focus = main_view,
    }))
    side_view.__test_name = "side shared Editor"
    track(context, "views", side_view)

    set_selection(side_view, 2, 3, 2, 9)
    side_view.scroll.x, side_view.scroll.to.x = 23, 23
    side_view.scroll.y, side_view.scroll.to.y = 47, 47
    local expected_selection = side_view:get_selection_state()

    test.ok(command.perform("sidepanel:open-current-file"))

    assert_active_view(main_view, "expected command to reuse and focus existing main Editor")
    test.same(main_view:get_selection_state(), expected_selection)
    test.equal(main_view.scroll.x, 23)
    test.equal(main_view.scroll.y, 47)
  end)

  test.it("restores a side find field after focus switches", function(context)
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
    assert_active_view(main_view, "expected toggle away from side find to focus main Editor")
    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_find, "expected toggling back to restore the side find field")
    test.equal(side_find.local_find_state.visible, true)
    test.equal(side_find.local_find_state.input_active, true)
    test.equal(side_find:get_text(), "al")
    test.equal(side_find.local_find_state.current, side_navigated_match)
  end)

  test.it("restores a main find field after side focus switches", function(context)
    local main_view, side_view = setup_main_and_side(context)
    main_view.doc:remove(1, 1, math.huge, math.huge)
    main_view.doc:text_input("alpha beta alpha gamma alpha\n")

    local main_find = open_find_input(main_view)
    main_find.__test_name = "local find input for main Editor"
    type_into_active_view("alp")
    test.equal(main_find:get_text(), "alp")
    local main_initial_match = main_find.local_find_state.current
    test.ok(main_initial_match > 0, "expected main find to select an initial match")
    local main_navigated_match = (main_initial_match % 3) + 1

    test.ok(command.perform("user:find-field-next"))
    test.equal(main_find.local_find_state.current, main_navigated_match)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected toggle away from main find to focus side Editor")
    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_find, "expected toggling back to restore the main find field")
    test.equal(main_find.local_find_state.visible, true)
    test.equal(main_find.local_find_state.input_active, true)
    test.equal(main_find:get_text(), "alp")
    test.equal(main_find.local_find_state.current, main_navigated_match)
  end)

  test.it("restores main replace input after side focus switches", function(context)
    local main_view, side_view = setup_main_and_side(context)

    core.set_active_view(main_view)
    test.ok(command.perform("find-replace:replace"))
    local main_find = active_find_input_for(main_view)
    main_find.__test_name = "local find input for main Editor"
    type_into_active_view("alpha")

    test.ok(command.perform("user:find-toggle-replace-field"))
    local main_replace = active_find_input_for(main_view)
    main_replace.__test_name = "local replace input for main Editor"
    test.equal(main_replace.local_find_field, "replace")
    type_into_active_view("omega")
    set_selection(main_replace, 1, 2, 1, 5)
    local expected_replace_selection = selection_state(main_replace)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected toggle away from main replace input to focus side Editor")
    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(main_replace, "expected toggling back to restore main replace input")
    test.equal(main_replace.local_find_state.input_active, true)
    test.equal(main_find:get_text(), "alpha")
    test.equal(main_replace:get_text(), "omega")
    test.same(selection_state(main_replace), expected_replace_selection)
  end)

  test.it("toggle-focus restores the side DocView prompt field when returning to the Side Editor", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected side Editor before opening replace prompt")
    test.ok(command.perform("find-replace:replace"))
    local side_find = active_find_input_for(side_view)
    side_find.__test_name = "local find input for side Editor"
    type_into_active_view("alpha")

    test.ok(command.perform("user:find-toggle-replace-field"))
    local side_replace = active_find_input_for(side_view)
    side_replace.__test_name = "local replace input for side Editor"
    test.equal(side_replace.local_find_field, "replace")
    type_into_active_view("omega")
    set_selection(side_replace, 1, 2, 1, 5)
    local expected_replace_selection = selection_state(side_replace)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(main_view, "expected toggle-focus away from side prompt to focus main Editor")
    test.equal(side_replace.local_find_state.visible, true)

    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(side_replace, "expected toggle-focus back to side to restore the prompt field that had keyboard focus")
    test.equal(side_replace.local_find_state.input_active, true)
    test.equal(side_replace.local_find_field, "replace")
    test.same(selection_state(side_replace), expected_replace_selection)
    type_into_active_view("!")
    test.equal(side_replace:get_text(), "o!a")
  end)

  test.it("toggle-focus restores the main DocView prompt field when returning from the Side Editor", function(context)
    local main_view, side_view = setup_main_and_side(context)

    test.ok(command.perform("find-replace:replace"))
    local main_find = active_find_input_for(main_view)
    main_find.__test_name = "local find input for main Editor"
    type_into_active_view("alpha")

    test.ok(command.perform("user:find-toggle-replace-field"))
    local main_replace = active_find_input_for(main_view)
    main_replace.__test_name = "local replace input for main Editor"
    test.equal(main_replace.local_find_field, "replace")
    type_into_active_view("omega")
    set_selection(main_replace, 1, 3, 1, 5)
    local expected_replace_selection = selection_state(main_replace)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected toggle-focus away from main prompt to focus Side Editor")
    test.equal(main_replace.local_find_state.visible, true)

    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(main_replace, "expected toggle-focus back to main to restore the prompt field that had keyboard focus")
    test.equal(main_replace.local_find_state.input_active, true)
    test.equal(main_replace.local_find_field, "replace")
    test.same(selection_state(main_replace), expected_replace_selection)
    type_into_active_view("!")
    test.equal(main_replace:get_text(), "om!a")
  end)

  test.it("main and side find options remain independent for the same document", function(context)
    local doc = new_doc(context, "Alpha alpha beta\n")
    local main_view = track(context, "views", core.root_panel:open_doc(doc))
    main_view.__test_name = "main shared Editor"
    core.set_active_view(main_view)

    local side_view = track(context, "side_views", sidepanel.open_doc_in_side(doc, {
      focus = false,
      restore_focus = main_view,
    }))
    side_view.__test_name = "side shared Editor"
    track(context, "views", side_view)

    local main_find = open_find_input(main_view)
    main_find.__test_name = "local find input for main shared Editor"
    type_into_active_view("alpha")
    test.equal(main_find.local_find_state.case_sensitive, false)
    test.equal(main_find.local_find_state.regex, false)
    test.ok(command.perform("find-replace:toggle-sensitivity"))
    test.ok(command.perform("find-replace:toggle-regex"))
    test.equal(main_find.local_find_state.case_sensitive, true)
    test.equal(main_find.local_find_state.regex, true)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected toggle to focus side shared Editor")
    local side_find = open_find_input(side_view)
    side_find.__test_name = "local find input for side shared Editor"
    type_into_active_view("alpha")

    test.equal(side_find.local_find_state.case_sensitive, false)
    test.equal(side_find.local_find_state.regex, false)
    test.equal(main_find.local_find_state.case_sensitive, true)
    test.equal(main_find.local_find_state.regex, true)
  end)

  test.it("closing a main find input prevents it from being restored after side focus", function(context)
    local main_view, side_view = setup_main_and_side(context)

    local main_find = open_find_input(main_view)
    main_find.__test_name = "local find input for main Editor"
    type_into_active_view("alpha")

    test.ok(command.perform("user:find-close"))
    assert_active_view(main_view, "expected closing main find to focus its owning Editor")
    test.equal(main_find.local_find_state.visible, false)

    test.ok(command.perform("sidepanel:toggle-focus"))
    assert_active_view(side_view, "expected toggle from main Editor to focus side Editor")
    test.ok(command.perform("sidepanel:toggle-focus"))

    assert_active_view(main_view, "expected toggling back to restore main Editor, not its closed find input")
    test.equal(main_find.local_find_state.visible, false)
  end)

  test.it("focus-main-and-hide hides the File Tree and focuses the main Editor", function(context)
    local main_view = open_main_editor(context, "main alpha beta\n")
    main_view.__test_name = "main Editor"
    core.set_active_view(main_view)

    local filetree = require "plugins.filetree"
    track(context, "side_views", filetree)
    filetree.__test_name = "File Tree"
    sidepanel.register_panel("filetree", filetree)
    sidepanel.show("filetree", { focus = true })
    assert_active_view(filetree, "expected File Tree before focus-main-and-hide")

    test.ok(command.perform("sidepanel:focus-main-and-hide"))
    test.equal(sidepanel.visible, false)
    assert_active_view(main_view, "expected focus-main-and-hide to hide the File Tree and focus the main Editor")
  end)

  test.it("focus-main-and-hide from a File Tree prompt bar hides the File Tree and focuses the main Editor", function(context)
    local main_view = open_main_editor(context, "main alpha beta\n")
    main_view.__test_name = "main Editor"
    core.set_active_view(main_view)

    local filetree = require "plugins.filetree"
    track(context, "side_views", filetree)
    filetree.__test_name = "File Tree"
    sidepanel.register_panel("filetree", filetree)
    sidepanel.show("filetree", { focus = true })
    local filetree_find = open_find_input(filetree)
    assert_active_view(filetree_find, "expected File Tree prompt bar before focus-main-and-hide")

    test.ok(command.perform("sidepanel:focus-main-and-hide"))

    test.equal(sidepanel.visible, false)
    assert_active_view(main_view, "expected focus-main-and-hide from File Tree prompt to hide the File Tree and focus the main Editor")
  end)

  test.it("open-current-file from File Tree opens the current main Editor, not the File Tree document", function(context)
    local main_view = open_main_editor(context, "main alpha beta\n")
    main_view.__test_name = "main Editor"
    core.set_active_view(main_view)

    local filetree = require "plugins.filetree"
    track(context, "side_views", filetree)
    filetree.__test_name = "File Tree"
    sidepanel.register_panel("filetree", filetree)
    sidepanel.show("filetree", { focus = true })
    assert_active_view(filetree, "expected File Tree before open-current-file")

    test.ok(command.perform("sidepanel:open-current-file"))
    local side_view = sidepanel.file_view
    side_view.__test_name = "side file Editor"
    track(context, "side_views", side_view)
    track(context, "views", side_view)

    test.ok(side_view.doc == main_view.doc, "expected open-current-file to use the current main Editor document")
    test.ok(side_view.doc ~= filetree.doc, "expected open-current-file not to use File Tree UI document")
    assert_active_view(side_view, "expected open-current-file from File Tree to focus the Side Editor")
  end)
end)
