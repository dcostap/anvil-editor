-- Two-pane view model.
--
-- The Left Pane is permanent and the Right Pane is hideable. Both panes own
-- ordinary top-level views; the Title Bar is their shared tab presentation.

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local DocView = require "core.docview"
local EmptyView = require "core.emptyview"
local ImageView = require "core.imageview"
local common = require "core.common"
local Node = require "core.node"
local file_context = require "core.file_context"

local M = core.panes or {}
core.panes = M
M.selection_mru = M.selection_mru or { left = {}, right = {} }
M.registered_views = M.registered_views or {}
M.git_sessions = M.git_sessions or {}
M.right_shown = M.right_shown or false
M.width_ratio = M.width_ratio or 0.5

local function has_no_locked_children(node)
  if not node or node.locked then return false end
  if node.type == "leaf" then return true end
  return has_no_locked_children(node.a) and has_no_locked_children(node.b)
end

local function get_unlocked_root(node)
  if not node then return nil end
  if node.type == "leaf" then return not node.locked and node or nil end
  if has_no_locked_children(node) then return node end
  return get_unlocked_root(node.a) or get_unlocked_root(node.b)
end

function M.ensure_nodes()
  if M.left_node and M.right_node then return M.left_node, M.right_node end
  local root = core.root_panel and core.root_panel.root_node
  if not root then return nil end
  local container = get_unlocked_root(root)
  if not container then return nil end
  M.attaching = true
  local left, right, split = Node(), Node(), Node("hsplit")
  left:consume(container)
  container:consume(split)
  container.a, container.b = left, right
  container.__pane_container = true
  left.pane_id, right.pane_id = "left", "right"
  right.locked = { x = true }
  right.resizable = false
  right.views[1].__pane_placeholder = true
  M.container_node, M.left_node, M.right_node = container, left, right
  M.attaching = false
  return left, right
end

local function right_parent_width()
  local node = M.right_node
  local parent = node and core.root_panel.root_node and node:get_parent_node(core.root_panel.root_node)
  return math.max(0, parent and parent.size.x or core.root_panel and core.root_panel.size.x or 0)
end

function M.target_right_width()
  return M.right_shown and math.floor(right_parent_width() * M.width_ratio) or 0
end

function M.update_right_view_size(view)
  if view then view.size.x = M.target_right_width() end
end

local function attach_right_view(view, id)
  if id then view.__pane_view_id = id; M.registered_views[id] = view end
  if view.__pane_size_wrapped then return view end
  view.__pane_size_wrapped = true
  view.__pane_original_update = view.update
  function view:update(...)
    M.update_right_view_size(self)
    return self.__pane_original_update(self, ...)
  end
  return view
end

local function valid_pane(pane)
  assert(pane == "left" or pane == "right", "pane must be 'left' or 'right'")
  return pane
end

function M.node(pane)
  pane = valid_pane(pane)
  M.ensure_nodes()
  return pane == "right" and M.right_node or M.left_node
end

function M.is_placeholder(view)
  return not not (view and (view.__pane_placeholder or (view.is and view:is(EmptyView))))
end

function M.pane_for_view(view)
  if not view then return nil end
  local owner = view.__pane_focus_owner or view.git_owner_view or view.diff_view_parent
  local root = core.root_panel and core.root_panel.root_node
  local node = root and root:get_node_for_view(owner or view)
  if node == M.node("right") then return "right", owner or view end
  if node == M.node("left") then return "left", owner or view end
end

function M.focused_pane()
  return M.pane_for_view(core.active_view)
end

function M.opposite(pane)
  return pane == "right" and "left" or "right"
end

function M.resolve_target(opts)
  opts = opts or {}
  if opts.pane then return valid_pane(opts.pane) end
  local source = opts.source_view or opts.view
  local pane = source and M.pane_for_view(source) or M.pane_for_view(core.active_view)
  pane = pane or "left"
  if opts.opposite then pane = M.opposite(pane) end
  return pane
end

function M.contains_view(pane, view)
  local node = M.node(pane)
  if not (node and view) then return false end
  for _, candidate in ipairs(node.views or {}) do
    if candidate == view then return true end
  end
  return false
end

function M.selected_view(pane)
  local node = M.node(pane)
  return node and node.active_view
end

function M.open_views(pane)
  local views = {}
  local node = M.node(pane)
  for _, view in ipairs(node and node.views or {}) do
    if not M.is_placeholder(view) then views[#views + 1] = view end
  end
  return views
end

local function remember_selected(pane, view)
  if not (pane and view and not M.is_placeholder(view)) then return end
  local mru = M.selection_mru[pane]
  for i = #mru, 1, -1 do if mru[i] == view then table.remove(mru, i) end end
  table.insert(mru, 1, view)
end

local function most_recent_open_view(pane, excluding)
  for _, view in ipairs(M.selection_mru[pane]) do
    if view ~= excluding and M.contains_view(pane, view) then return view end
  end
  for _, view in ipairs(M.open_views(pane)) do if view ~= excluding then return view end end
end

function M.remember_focus(owner, view)
  if not (owner and view) then return end
  M.focus_by_owner = M.focus_by_owner or setmetatable({}, { __mode = "k" })
  M.focus_by_owner[owner] = view
end

function M.switch(pane, delta)
  pane = pane or M.focused_pane() or "left"
  local views = M.open_views(pane)
  if #views == 0 then return nil end
  local selected = M.selected_view(pane)
  local index = 1
  for i, view in ipairs(views) do if view == selected then index = i; break end end
  index = ((index - 1 + delta) % #views) + 1
  local view = views[index]
  M.node(pane):set_active_view(view)
  M.show(pane, { view = view, focus = true })
  return view
end

function M.switch_to_index(pane, index)
  pane = pane or M.focused_pane() or "left"
  local view = M.open_views(pane)[index]
  if not view then return nil end
  M.node(pane):set_active_view(view)
  M.show(pane, { view = view, focus = true })
  return view
end

function M.singleton_editor(pane)
  for _, view in ipairs(M.open_views(pane)) do
    if view.__pane_singleton_editor then return view end
  end
end

function M.right_visible()
  return M.right_shown == true
end

function M.show(pane, opts)
  pane = valid_pane(pane)
  opts = opts or {}
  if pane == "left" then
    M.focus_intent = "left"
    local view = opts.view or M.selected_view("left")
    if opts.view and M.contains_view("left", opts.view) then M.node("left").active_view = opts.view end
    remember_selected("left", view)
    if opts.focus ~= false and view then core.set_active_view(view) end
    return view
  end

  M.focus_intent = "right"
  M.force_right_hidden = false
  local view = opts.view or M.selected_view("right")
  if M.is_placeholder(view) then view = M.open_views("right")[1] end
  if view and not M.is_placeholder(view) then
    remember_selected("right", view)
    M.right_shown = true
    local node = M.node("right")
    local old = node.active_view
    if old and old ~= view then old.visible = false end
    node.active_view = view
    view.visible = true
    M.update_right_view_size(view)
    if opts.focus ~= false then
      local focus = M.focus_by_owner and M.focus_by_owner[view]
      core.set_active_view(focus or (view.get_focus_view and view:get_focus_view()) or view)
    end
  end
  if core.root_panel and core.root_panel.root_node then core.root_panel.root_node:update_layout() end
  return view
end

function M.hide_right(focus_left)
  M.force_right_hidden = true
  M.focus_intent = "left"
  M.right_shown = false
  local active = M.selected_view("right")
  if active then
    active.visible = false
    M.update_right_view_size(active)
  end
  if focus_left ~= false then
    local left = M.selected_view("left")
    if left then core.set_active_view(left) end
  end
  if core.root_panel and core.root_panel.root_node then core.root_panel.root_node:update_layout() end
  return true
end

local function copy_position(source, target)
  if not (source and target and source.doc and source.doc == target.doc) then return end
  if source.get_selection_state and target.set_selection_state then
    target:set_selection_state(source:get_selection_state())
  end
  target.scroll.x, target.scroll.to.x = source.scroll.x or 0, source.scroll.to.x or source.scroll.x or 0
  target.scroll.y, target.scroll.to.y = source.scroll.y or 0, source.scroll.to.y or source.scroll.y or 0
end

local function apply_location(view, opts)
  if not (view and view.doc and opts and opts.line) then return end
  local col = opts.col or 1
  local line2, col2 = opts.line2 or opts.line, opts.col2 or col
  local function select()
    if view.expand_folds_covering_range then
      view:expand_folds_covering_range(opts.line, col, line2, col2, "pane-open")
    end
    view.doc:set_selection(opts.line, col, line2, col2)
  end
  if view.with_selection_state then view:with_selection_state(select) else select() end
  if view.scroll_to_make_visible then view:scroll_to_make_visible(opts.line, col) end
end

local function remove_from_node(node, view)
  if not (node and view) then return false end
  for i, candidate in ipairs(node.views or {}) do
    if candidate == view then
      table.remove(node.views, i)
      if node.active_view == view then node.active_view = node.views[i] or node.views[i - 1] end
      return true
    end
  end
  return false
end

local function remove_right_view(view)
  if view and view.on_mouse_left then view:on_mouse_left() end
  view.visible = false
  remove_from_node(M.node("right"), view)
  for id, candidate in pairs(M.registered_views) do
    if candidate == view then M.registered_views[id] = nil end
  end
end

local function ensure_left_placeholder()
  local node = M.node("left")
  if #M.open_views("left") > 0 then return node.active_view end
  for _, view in ipairs(node.views or {}) do if M.is_placeholder(view) then node.active_view = view; return view end end
  local view = EmptyView()
  view.__pane_placeholder = true
  function view:get_name() return "Editor" end
  node.views = { view }
  node.active_view = view
  return view
end

M.ensure_left_placeholder = ensure_left_placeholder

local function add_view_to_pane(pane, view)
  local node = M.node(pane)
  local removed_active = false
  for i = #node.views, 1, -1 do
    if M.is_placeholder(node.views[i]) then
      removed_active = removed_active or node.active_view == node.views[i]
      table.remove(node.views, i)
    end
  end
  if pane == "right" then
    attach_right_view(view)
    table.insert(node.views, view)
    view.node = node
    view.visible = M.right_shown and (removed_active or not node.active_view)
  else
    table.insert(node.views, view)
    view.node = node
  end
  if removed_active or not node.active_view then node.active_view = view end
  return node
end

local function select_view(pane, view, focus)
  local node = M.node(pane)
  node.active_view = view
  remember_selected(pane, view)
  if pane == "right" then
    M.show("right", { view = view, focus = focus ~= false })
  elseif focus ~= false then
    node:set_active_view(view)
  end
  if core.root_panel and core.root_panel.root_node then core.root_panel.root_node:update_layout() end
end

function M.open_doc(doc, opts)
  opts = opts or {}
  local pane = M.resolve_target(opts)
  if pane == "right" then
    M.force_right_hidden = false
    M.focus_intent = "right"
  end
  local source = opts.source_view
  local view
  local singleton
  local navigation_anchor
  for _, candidate in ipairs(M.open_views(pane)) do
    if candidate.__pane_singleton_editor then singleton = candidate end
    if candidate.doc == doc and (not doc.abs_filename or not candidate.__pane_singleton_editor) then
      view = candidate
      break
    end
  end

  if doc.abs_filename and not view then
    if singleton and singleton.doc == doc then
      view = singleton
    else
      if singleton then
        local dirty = singleton.doc and singleton.doc.is_dirty and singleton.doc:is_dirty()
        if dirty then
          singleton.__pane_singleton_editor = nil
        else
          local history = core.navigation_history
          if M.selected_view(pane) == singleton and history and history.capture_place then
            local ok, place = pcall(history.capture_place, singleton)
            if ok then navigation_anchor = place end
          end
          if singleton.release_owned_features then singleton:release_owned_features("pane-editor-replace") end
          remove_from_node(M.node(pane), singleton)
        end
      end
      view = file_context.mark_editor_view(DocView(doc))
      view.__pane_singleton_editor = true
      add_view_to_pane(pane, view)
    end
  elseif not view then
    view = file_context.mark_editor_view(DocView(doc))
    add_view_to_pane(pane, view)
  end
  if source then copy_position(source, view) end
  apply_location(view, opts)
  select_view(pane, view, opts.focus ~= false)
  if navigation_anchor and core.navigation_history and core.navigation_history.record_place then
    core.navigation_history.record_place(navigation_anchor, { reason = "pane-editor-replace" })
  end
  local restore = opts.preserve_focus and (opts.restore_focus or source) or opts.restore_focus
  if opts.focus == false and restore then core.set_active_view(restore) end
  return view
end

function M.open_view(view, opts)
  opts = opts or {}
  local pane = M.resolve_target(opts)
  if pane == "right" then M.force_right_hidden = false; M.focus_intent = "right" end
  if not M.contains_view(pane, view) then add_view_to_pane(pane, view) end
  select_view(pane, view, opts.focus ~= false)
  return view
end

function M.register_view(pane, id, view, opts)
  opts = opts or {}
  pane = valid_pane(pane)
  if opts.permanent then view.__pane_permanent = true end
  if pane == "right" then
    attach_right_view(view, id)
    if not M.contains_view("right", view) then add_view_to_pane("right", view) end
  else
    M.open_view(view, { pane = "left", focus = false })
  end
  return view
end

function M.open_path(path, opts)
  opts = opts or {}
  local pane = M.resolve_target(opts)
  path = path and common.normalize_path(path)
  if not path then return nil end
  if ImageView.is_supported(path) then
    path = core.root_project():absolute_path(path)
    for _, candidate in ipairs(M.open_views(pane)) do
      if candidate.path and common.path_equals(candidate.path, path) then
        M.node(pane):set_active_view(candidate)
        M.show(pane, { view = candidate, focus = opts.focus ~= false })
        return candidate
      end
    end
    local view = ImageView(path)
    if not view.image then
      core.error("Image could not be loaded.%s", view.errmsg and " Error: " .. view.errmsg or "")
      return nil
    end
    return M.open_view(view, { pane = pane, focus = opts.focus ~= false })
  end
  local ok, doc = core.try(core.open_doc, path)
  if ok and doc then return M.open_doc(doc, opts) end
end

function M.move_view_to_pane(view, target_pane)
  local source_pane, owner = M.pane_for_view(view)
  view = owner or view
  target_pane = valid_pane(target_pane)
  if target_pane == "right" then
    M.force_right_hidden = false
    M.focus_intent = "right"
  end
  if not source_pane or source_pane == target_pane or not file_context.is_editor_view(view) then return nil end
  local existing
  local target_singleton
  for _, candidate in ipairs(M.open_views(target_pane)) do
    if candidate.doc == view.doc then existing = candidate end
    if candidate.__pane_singleton_editor then target_singleton = candidate end
  end

  local function detach_source(release)
    if release and view.release_owned_features then view:release_owned_features("pane-editor-move-duplicate") end
    if source_pane == "right" then remove_right_view(view)
    else remove_from_node(M.node("left"), view) end
    if source_pane == "left" then
      local next_view = most_recent_open_view("left", view) or ensure_left_placeholder()
      M.node("left").active_view = next_view
    end
  end

  if existing then
    copy_position(view, existing)
    detach_source(true)
    select_view(target_pane, existing, true)
    return existing
  end

  if view.doc and view.doc.abs_filename and target_singleton then
    local dirty = target_singleton.doc and target_singleton.doc.is_dirty and target_singleton.doc:is_dirty()
    if dirty then
      target_singleton.__pane_singleton_editor = nil
    else
      if target_singleton.release_owned_features then target_singleton:release_owned_features("pane-editor-move-replace") end
      if target_pane == "right" then remove_right_view(target_singleton)
      else remove_from_node(M.node("left"), target_singleton) end
    end
  end

  detach_source(false)
  if view.doc and view.doc.abs_filename then view.__pane_singleton_editor = true end
  add_view_to_pane(target_pane, view)
  select_view(target_pane, view, true)
  return view
end

function M.close_view(view)
  local pane, owner = M.pane_for_view(view)
  view = owner or view
  if not pane or not view or view.__pane_permanent then return false end
  local function close()
    if pane == "right" then
      local was_visible = M.right_visible()
      remove_right_view(view)
      local next_view = most_recent_open_view("right", view)
      if next_view then
        M.show("right", { view = next_view, focus = was_visible })
      else
        M.hide_right(true)
      end
    else
      remove_from_node(M.node("left"), view)
      local next_view = most_recent_open_view("left", view) or ensure_left_placeholder()
      M.node("left").active_view = next_view
      core.set_active_view(next_view)
    end
  end
  if view.try_close then view:try_close(close) else close() end
  return true
end

function M.remove_view(view, opts)
  opts = opts or {}
  local pane, owner = M.pane_for_view(view)
  view = owner or view
  if not pane or not view or (view.__pane_permanent and not opts.force) then return false end
  if view.release_owned_features then view:release_owned_features("pane-view-remove") end
  if pane == "right" then
    local was_visible = M.right_visible()
    remove_right_view(view)
    local next_view = most_recent_open_view("right", view)
    if next_view then M.show("right", { view = next_view, focus = was_visible and opts.focus_left ~= false })
    else M.hide_right(opts.focus_left ~= false) end
  else
    remove_from_node(M.node("left"), view)
    ensure_left_placeholder()
  end
  return true
end

function M.save_workspace_state(save_view)
  local state = {
    right_visible = M.right_visible(),
    focused_pane = M.focused_pane() or M.focus_intent or "left",
    panes = {},
  }
  for _, pane in ipairs({ "left", "right" }) do
    local pane_state = { views = {} }
    local selected = M.selected_view(pane)
    for _, view in ipairs(M.open_views(pane)) do
      local item
      if view.__pane_permanent then
        item = { permanent_id = view.__pane_view_id }
      elseif save_view then
        item = save_view(view)
      end
      if item then
        item.pane_singleton_editor = M.singleton_editor(pane) == view or nil
        pane_state.views[#pane_state.views + 1] = item
        if view == selected then pane_state.selected = #pane_state.views end
      end
    end
    state.panes[pane] = pane_state
  end
  return state
end

function M.restore_workspace_state(state, load_view)
  if type(state) ~= "table" then return false end
  local pane_states = state.panes or {}
  for _, pane in ipairs({ "left", "right" }) do
    for _, view in ipairs(M.open_views(pane)) do
      if not view.__pane_permanent then M.remove_view(view, { force = true, focus_left = false }) end
    end
    local restored = {}
    for _, item in ipairs((pane_states[pane] and pane_states[pane].views) or {}) do
      local view
      if item.permanent_id and pane == "right" then
        view = M.registered_views[item.permanent_id]
      elseif load_view then
        view = load_view(item)
      end
      if view then
        if item.pane_singleton_editor then view.__pane_singleton_editor = true end
        M.open_view(view, { pane = pane, focus = false })
        restored[#restored + 1] = view
      end
    end
    local selected = restored[(pane_states[pane] and pane_states[pane].selected) or 1]
    if selected then M.node(pane).active_view = selected end
  end
  ensure_left_placeholder()
  if state.right_visible then
    M.show("right", { focus = false })
  else
    M.hide_right(false)
  end
  local focus_pane = state.focused_pane == "right" and state.right_visible and "right" or "left"
  M.show(focus_pane, { focus = true })
  return true
end

function M.reset_for_tests()
  local left = M.node("left")
  for i = #(left and left.views or {}), 1, -1 do
    local view = left.views[i]
    if view.release_owned_features then view:release_owned_features("pane-test-reset") end
    table.remove(left.views, i)
  end
  ensure_left_placeholder()

  local right = M.node("right")
  for i = #(right and right.views or {}), 1, -1 do
    local view = right.views[i]
    if not M.is_placeholder(view) and not view.__pane_permanent then remove_right_view(view) end
  end
  M.hide_right(false)
  local selected = M.selected_view("left")
  if selected then core.set_active_view(selected) end
end

command.add(nil, {
  ["pane:focus-left-and-hide-right"] = function()
    return M.hide_right(true)
  end,
  ["pane:toggle-focus"] = function()
    if M.focused_pane() == "right" then
      return M.show("left", { focus = true })
    end
    return M.show("right", { focus = true })
  end,
  ["pane:open-current-file-opposite"] = function()
    local pane, owner = M.pane_for_view(core.active_view)
    local view = owner or core.active_view
    if not (pane and view and file_context.is_editor_view(view) and view.doc) then return false end
    M.open_doc(view.doc, { pane = M.opposite(pane), source_view = view, focus = true })
    return true
  end,
  ["pane:move-current-file-opposite"] = function()
    local pane, owner = M.pane_for_view(core.active_view)
    local view = owner or core.active_view
    if not (pane and view and file_context.is_editor_view(view) and view.doc) then return false end
    return M.move_view_to_pane(view, M.opposite(pane)) ~= nil
  end,
})

command.add(function()
  local pane, owner = M.pane_for_view(core.active_view)
  local view = owner or core.active_view
  return pane ~= nil and view ~= nil and not view.__pane_permanent, view
end, {
  ["pane:close-current"] = function(view)
    M.close_view(view)
  end,
})

keymap.add_direct({
  ["ctrl+w"] = "pane:close-current",
  ["alt+1"] = "pane:focus-left-and-hide-right",
  ["alt+º"] = "pane:toggle-focus",
  ["alt+grave"] = "pane:toggle-focus",
  ["alt+`"] = "pane:toggle-focus",
  ["ctrl+0"] = "pane:open-current-file-opposite",
  ["ctrl+9"] = "pane:move-current-file-opposite",
})

local base_set_active_view = core.panes_base_set_active_view or core.set_active_view
core.panes_base_set_active_view = base_set_active_view
function core.set_active_view(view)
  if M.attaching then return base_set_active_view(view) end
  local pane, owner = M.pane_for_view(view)
  if pane then
    M.focus_intent = pane
    if owner and owner ~= view then
      M.focus_by_owner = M.focus_by_owner or setmetatable({}, { __mode = "k" })
      M.focus_by_owner[owner] = view
    end
    if pane == "left" and (owner or view).__hide_right_pane_on_focus then
      M.hide_right(false)
    end
  end
  return base_set_active_view(view)
end

return M
