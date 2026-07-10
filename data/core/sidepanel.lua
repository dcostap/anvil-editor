-- Core right-side panel manager.
--
-- The side panel is a persistent, locked right-side leaf node. It behaves like
-- a hidden-tab container: multiple views can live in the node, while only one
-- is active/visible at a time. This keeps side Editors in the normal root node
-- tree so document lifetime, autosave, autoreload, conflict checks, and close
-- handling continue to work like ordinary editor tabs.

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local keymap = require "core.keymap"
local Node = require "core.node"
local View = require "core.view"
local DocView = require "core.docview"
local ImageView = require "core.imageview"
local file_context = require "core.file_context"

local M = core.sidepanel or {}
core.sidepanel = M

M.panels = M.panels or {}
M.side_views = M.side_views or setmetatable({}, { __mode = "k" })
M.visible = M.visible or false
M.current_panel = M.current_panel
M.last_main_panel_view = M.last_main_panel_view
M.main_focus_views = M.main_focus_views or setmetatable({}, { __mode = "k" })
M.last_side_focus_view = M.last_side_focus_view
M.last_side_focus_owner = M.last_side_focus_owner
M.side_focus_views = M.side_focus_views or setmetatable({}, { __mode = "k" })
M.last_editor_focus_owner = M.last_editor_focus_owner
M.side_node = M.side_node
M.main_node = M.main_node
M.container_node = M.container_node
M.file_view = M.file_view
M.file_view_path = M.file_view_path
M.instant_size = M.instant_size
M.width_ratio = M.width_ratio or 0.5
M.side_editor_slot_visible = M.side_editor_slot_visible or false

local function has_no_locked_children(node)
  if not node or node.locked then return false end
  if node.type == "leaf" then return true end
  return has_no_locked_children(node.a) and has_no_locked_children(node.b)
end

local function get_unlocked_root(node)
  if not node then return nil end
  if node.type == "leaf" then
    return not node.locked and node or nil
  end
  if has_no_locked_children(node) then return node end
  return get_unlocked_root(node.a) or get_unlocked_root(node.b)
end

local function find_side_node(node)
  if not node then return nil end
  if node.__sidepanel_side_node then return node end
  if node.type ~= "leaf" then
    return find_side_node(node.a) or find_side_node(node.b)
  end
end

local function side_placeholder()
  local view = M.placeholder
  if not view then
    view = View()
    view.__sidepanel_placeholder = true
    view.size.x = 0
    M.placeholder = view
  end
  return view
end

local function view_index(node, view)
  if not node or not view then return nil end
  for i, item in ipairs(node.views or {}) do
    if item == view then return i end
  end
end

local function ensure_placeholder_in_node(node)
  if not node then return end
  local placeholder = side_placeholder()
  if not view_index(node, placeholder) then
    table.insert(node.views, 1, placeholder)
  end
  if not node.active_view or not view_index(node, node.active_view) then
    node.active_view = placeholder
  end
end

local function attach_locked_side_node(container)
  local placeholder = side_placeholder()
  M.attaching_side_node = true
  local main = Node()
  main:consume(container)

  container:consume(Node("hsplit"))
  container.a = main
  container.b = Node()
  container.b.__sidepanel_side_node = true
  container.__sidepanel_container_node = true

  M.container_node = container
  M.main_node = main
  M.side_node = container.b
  container.b:add_view(placeholder)
  container.b.locked = { x = true }
  container.b.resizable = false
  M.attaching_side_node = false
  return M.side_node
end

function M.ensure_side_node()
  local root = core.root_panel and core.root_panel.root_node
  if not root then return nil end

  if M.side_node and M.side_node.__sidepanel_side_node then
    ensure_placeholder_in_node(M.side_node)
    return M.side_node
  end

  local existing = find_side_node(root)
  if existing then
    M.side_node = existing
    M.container_node = existing:get_parent_node(root)
    M.main_node = M.container_node and M.container_node.a or nil
    ensure_placeholder_in_node(existing)
    return existing
  end

  local workbench = get_unlocked_root(root)
  if not workbench then return nil end
  return attach_locked_side_node(workbench)
end

function M.is_side_view(view)
  return not not (view and M.side_views and M.side_views[view])
end

local function is_docview(view)
  return view and view.extends and view:extends(DocView)
end

function M.is_side_editor(view)
  return M.is_side_view(view) and file_context.is_editor_view(view)
end

local function is_side_editor(view)
  return M.is_side_editor(view)
end

local function side_focus_owner(view)
  if M.is_side_view(view) then return view end
  local owner = view and view.__sidepanel_focus_owner
  if M.is_side_view(owner) then return owner end
end

function M.side_focus_owner(view)
  return side_focus_owner(view)
end

local restorable_focus_view

function M.remember_side_focus_view(view)
  local owner = side_focus_owner(view)
  if owner then
    M.side_focus_views[owner] = view
    M.last_side_focus_view = view
    M.last_side_focus_owner = owner
  end
  return owner
end

function M.restorable_side_focus_view(owner)
  if not owner or not M.contains_view(owner) then return nil end
  local view = restorable_focus_view(M.side_focus_views[owner], owner)
  if view and side_focus_owner(view) == owner then
    return view
  end
  if type(owner.get_focus_view) == "function" then
    view = restorable_focus_view(owner:get_focus_view(), owner)
    if view and side_focus_owner(view) == owner then
      return view
    end
  end
  return owner
end

local function clear_side_focus_for_owner(owner)
  if owner then M.side_focus_views[owner] = nil end
  if owner and (M.last_side_focus_owner == owner or M.last_side_focus_view == owner) then
    M.last_side_focus_view = nil
    M.last_side_focus_owner = nil
  end
end

function M.is_main_panel_view(view)
  return file_context.is_main_panel_view(view) and not M.is_side_view(view)
end

local function main_focus_owner(view)
  if M.is_main_panel_view(view) then return view end
  local owner = view and view.__sidepanel_focus_owner
  if M.is_main_panel_view(owner) then return owner end
end

function restorable_focus_view(view, owner)
  if view and view.local_find_input then
    local state = view.local_find_state
    if not (state and state.visible) then return nil end
    if owner and state.owner_view and state.owner_view ~= owner then return nil end
    state.input_active = true
    state.focus = view.local_find_field or state.focus
  end
  if owner and view and view.__sidepanel_focus_owner and view.__sidepanel_focus_owner ~= owner then return nil end
  return view
end

function M.remember_main_panel_view(view)
  local owner = main_focus_owner(view)
  if owner then
    M.last_main_panel_view = owner
    if view ~= owner then
      M.main_focus_views[owner] = view
    end
  end
end

function M.restorable_main_focus_view(owner)
  if not owner then return nil end
  return restorable_focus_view(M.main_focus_views[owner], owner) or owner
end

local function editor_focus_owner(view)
  return main_focus_owner(view) or side_focus_owner(view)
end

function M.remember_editor_focus_owner(view)
  local owner = editor_focus_owner(view)
  if owner and (M.is_main_panel_view(owner) or is_side_editor(owner)) then
    M.last_editor_focus_owner = owner
  end
  return owner
end

function M.last_restorable_editor_focus_owner()
  local owner = M.last_editor_focus_owner
  if owner and M.is_side_view(owner) then
    if is_side_editor(owner) and M.contains_view(owner) then return owner end
  elseif owner and is_docview(owner) then
    return file_context.current_main_panel_view(owner) or owner
  end
end

local function side_parent_width()
  local side = M.ensure_side_node()
  local root = core.root_panel and core.root_panel.root_node
  local parent = side and side:get_parent_node(root)
  local w = parent and parent.size and parent.size.x or (core.root_panel and core.root_panel.size.x) or 0
  return math.max(0, w)
end

local function active_main_surface_allows_side_editor()
  local main_tabs = core.main_tabs
  if not main_tabs then return false end
  local active = core.active_view
  local owner = side_focus_owner(active)
  if owner and is_side_editor(owner) then return true end
  local view = M.current_main_panel_view(active)
  return main_tabs.is_editor_surface and main_tabs.is_editor_surface(view)
end

local function should_show_side_editor_slot()
  return not M.visible and M.file_view and M.contains_view(M.file_view) and active_main_surface_allows_side_editor()
end

function M.update_side_editor_slot()
  if M.attaching_side_node then return false end
  local side = M.ensure_side_node()

  -- The Side Editor Slot is the hidden-side-panel presentation of M.file_view.
  -- When the full Side Panel is visible, focus/navigation updates must not
  -- replace its active view with the placeholder just because the slot itself
  -- should be disabled.  Side Panel visibility is controlled by explicit
  -- sidepanel commands and by restoring side-panel history targets, not by
  -- ordinary main-editor focus changes.
  if M.visible then
    M.side_editor_slot_visible = false
    if side and side.active_view then
      side.active_view.visible = true
      M.update_side_view_size(side.active_view)
    end
    return false
  end

  local show = should_show_side_editor_slot()
  M.side_editor_slot_visible = show and true or false
  if show then
    M.set_side_view(M.file_view, false)
  elseif side and side.active_view == M.file_view then
    M.file_view.visible = false
    side.active_view = side.views[1] or side_placeholder()
  elseif M.file_view then
    M.file_view.visible = false
  end
  if M.file_view then M.update_side_view_size(M.file_view) end
  if side and side.active_view then M.update_side_view_size(side.active_view) end
  return M.side_editor_slot_visible
end

function M.target_width()
  if not M.visible and not M.side_editor_slot_visible then return 0 end
  local parent_width = side_parent_width()
  return math.floor(parent_width * (tonumber(M.width_ratio) or 0.5))
end

function M.update_side_view_size(view)
  if not view then return end
  local dest = M.target_width(view)
  local resizing = core.window_resizing_until and system.get_time() < core.window_resizing_until
  if M.instant_size or resizing then
    view.size.x = dest
    M.instant_size = false
  elseif math.abs((view.size.x or 0) - dest) > 0.5 then
    view:move_towards(view.size, "x", dest, nil, "sidepanel")
    view.size.x = common.round(view.size.x)
    if math.abs(dest - view.size.x) < 2 then view.size.x = dest end
  else
    view.size.x = dest
  end
end

function M.attach_view(name, view)
  if not view then return end
  if name then
    view.__sidepanel_panel_name = name
  end
  M.side_views[view] = true
  file_context.exclude_main_panel_view(view)

  if view.__sidepanel_size_wrapped then return view end
  view.__sidepanel_size_wrapped = true
  view.__sidepanel_original_update = view.update
  function view:update(...)
    local manager = core.sidepanel
    if manager and manager.update_side_view_size then
      manager.update_side_view_size(self)
    end
    return self.__sidepanel_original_update(self, ...)
  end
  return view
end

function M.add_view(view)
  local side = M.ensure_side_node()
  if not side or not view then return nil end
  ensure_placeholder_in_node(side)
  if not view_index(side, view) then
    table.insert(side.views, view)
  end
  view.node = side
  return side
end

function M.contains_view(view)
  local side = M.ensure_side_node()
  return not not (side and view and view_index(side, view))
end

function M.prune_stale_views()
  local side = M.ensure_side_node()
  if not side then return end

  for name, view in pairs(M.panels) do
    if not view_index(side, view) then
      M.panels[name] = nil
      M.side_views[view] = nil
      if M.current_panel == name then M.current_panel = nil end
      if M.file_view == view then
        M.file_view = nil
        M.file_view_path = nil
      end
    end
  end

  if M.file_view and not view_index(side, M.file_view) then
    M.file_view = nil
    M.file_view_path = nil
  end

  if M.last_side_focus_owner and not view_index(side, M.last_side_focus_owner) then
    clear_side_focus_for_owner(M.last_side_focus_owner)
  end
end

function M.remove_view(view, focus_main)
  local side = M.ensure_side_node()
  if not side or not view then return false end

  if view.release_owned_features then view:release_owned_features("side-view-remove") end
  view.visible = false
  if view.on_mouse_left then view:on_mouse_left() end

  local idx = view_index(side, view)
  if idx then table.remove(side.views, idx) end
  M.side_views[view] = nil
  clear_side_focus_for_owner(view)

  for name, panel in pairs(M.panels) do
    if panel == view then
      M.panels[name] = nil
      if M.current_panel == name then M.current_panel = nil end
    end
  end

  ensure_placeholder_in_node(side)
  if side.active_view == view then
    side.active_view = side.views[1] or side_placeholder()
    side.active_view.visible = M.visible
    M.update_side_view_size(side.active_view)
  end

  if core.active_view == view then
    M.focus_main(false)
  elseif focus_main and M.is_side_view(core.active_view) then
    M.focus_main(false)
  end

  if core.root_panel and core.root_panel.root_node then
    core.root_panel.root_node:update_layout()
  end
  return true
end

function M.register_panel(name, view)
  assert(type(name) == "string" and name ~= "", "sidepanel panel name expected")
  assert(view, "sidepanel panel view expected")

  local old = M.panels[name]
  if old and old ~= view then
    M.remove_view(old, false)
  end

  M.panels[name] = view
  M.attach_view(name, view)
  M.add_view(view)
  return view
end

function M.active_side_view()
  local side = M.ensure_side_node()
  return side and side.active_view
end

function M.restorable_side_editor()
  M.prune_stale_views()
  local side = M.ensure_side_node()
  local active = side and side.active_view
  if is_side_editor(active) and M.is_side_view(active) then return active end
  if is_side_editor(M.last_side_focus_owner) and M.contains_view(M.last_side_focus_owner) then
    return M.last_side_focus_owner
  end
  if is_side_editor(M.file_view) and M.contains_view(M.file_view) then return M.file_view end
  if side then
    -- Side Editors are removable panels; if a non-Editor panel is active,
    -- Alt+1 can still restore the newest remaining Side Editor instead of
    -- treating the Side Panel as only a persistent tool panel.
    for i = #(side.views or {}), 1, -1 do
      local view = side.views[i]
      if is_side_editor(view) and M.is_side_view(view) then return view end
    end
  end
end

function M.set_side_view(view, focus)
  local side = M.ensure_side_node()
  if not side or not view then return end

  M.attach_view(view.__sidepanel_panel_name, view)
  M.add_view(view)
  if view.__sidepanel_panel_name then M.current_panel = view.__sidepanel_panel_name end

  local old = side.active_view
  if old ~= view and old and old.__sidepanel_placeholder ~= true then
    old.visible = false
    if old.on_mouse_left then old:on_mouse_left() end
  end

  side.active_view = view
  view.visible = M.visible or (view == M.file_view and M.side_editor_slot_visible)
  M.update_side_view_size(view)

  if focus then
    core.set_active_view(view)
  elseif core.active_view == old and old ~= view then
    M.focus_main(false)
  end

  if core.root_panel and core.root_panel.root_node then
    core.root_panel.root_node:update_layout()
  end
  return view
end

local function default_save_workspace_view(view)
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

local function load_workspace_view(saved, load_view)
  if type(saved) ~= "table" then return nil end
  local loader = load_view or function(t)
    if not t.module then return nil end
    local ViewClass = require(t.module)
    return ViewClass and ViewClass.from_state and ViewClass.from_state(t.state)
  end
  local ok, view = pcall(loader, saved)
  if ok then return view end
  if core.log_quiet then
    core.log_quiet("Side Panel Workspace: failed to restore view: %s", tostring(view))
  end
end

local function save_workspace_view(view, save_view)
  local saver = save_view or default_save_workspace_view
  local ok, saved = pcall(saver, view)
  if ok then return saved end
  if core.log_quiet then
    core.log_quiet("Side Panel Workspace: failed to save view: %s", tostring(saved))
  end
end

local function sidepanel_owner_panel_name(owner)
  if not owner then return nil end
  if owner == M.file_view then return "file" end
  return owner.__sidepanel_panel_name
end

function M.save_workspace_state(save_view)
  local side = M.side_node
  if not (side and side.views) then return nil end

  local state = {
    visible = M.visible == true,
    side_editor_slot_visible = M.side_editor_slot_visible == true,
    current_panel = M.current_panel,
    width_ratio = M.width_ratio,
  }

  local active = side.active_view
  if active and not active.__sidepanel_placeholder then
    state.active_panel = sidepanel_owner_panel_name(active)
  end

  local focus_owner = side_focus_owner(core.active_view)
  if focus_owner then
    state.focus_panel = sidepanel_owner_panel_name(focus_owner)
  end

  if M.file_view and view_index(side, M.file_view) then
    local saved = save_workspace_view(M.file_view, save_view)
    if saved then
      state.file_view = saved
      state.file_view_path = M.file_view_path
    end
  end

  if not state.file_view then
    if state.current_panel == "file" then state.current_panel = nil end
    if state.active_panel == "file" then state.active_panel = nil end
    if state.focus_panel == "file" then state.focus_panel = nil end
  end

  if not state.file_view
  and not state.visible
  and not state.current_panel
  and not state.active_panel
  and not state.focus_panel then
    return nil
  end

  if core.log_quiet then
    core.log_quiet(
      "Side Panel Workspace: saved visible=%s current=%s active=%s file=%s",
      tostring(state.visible),
      tostring(state.current_panel),
      tostring(state.active_panel),
      state.file_view and "yes" or "no"
    )
  end
  return state
end

function M.restore_workspace_state(state, load_view)
  if type(state) ~= "table" then return false end

  if type(state.width_ratio) == "number" and state.width_ratio > 0 then
    M.width_ratio = state.width_ratio
  end

  local restored_file
  if type(state.file_view) == "table" then
    restored_file = load_workspace_view(state.file_view, load_view)
    if restored_file then
      if M.file_view and M.file_view ~= restored_file and M.contains_view(M.file_view) then
        M.remove_view(M.file_view, false)
      end
      M.file_view = restored_file
      M.file_view_path = state.file_view_path
        or (state.file_view.state and (state.file_view.state.filename or state.file_view.state.path))
        or (restored_file.doc and (restored_file.doc.abs_filename or restored_file.doc.filename))
        or restored_file.path
      if restored_file.doc then file_context.mark_editor_view(restored_file) end
      M.register_panel("file", restored_file)
    elseif core.log_quiet then
      core.log_quiet("Side Panel Workspace: skipped missing Side Editor file view")
    end
  end

  local target_panel = state.active_panel or state.current_panel or (restored_file and "file")
  if target_panel == "file" and not restored_file then target_panel = nil end
  local target = target_panel and M.panels[target_panel]
  local restored = restored_file ~= nil

  if target then
    local focus = state.focus_panel == target_panel
      or (target == restored_file and state.file_view and state.file_view.active == true)
    if state.visible then
      M.side_editor_slot_visible = false
      M.show(target_panel, { focus = focus })
    else
      M.visible = false
      M.side_editor_slot_visible = state.side_editor_slot_visible == true
      M.set_side_view(target, focus)
      M.update_side_editor_slot()
    end
    restored = true
  elseif state.current_panel and core.log_quiet then
    core.log_quiet("Side Panel Workspace: saved panel %s is not registered", tostring(state.current_panel))
  end

  if core.root_panel and core.root_panel.root_node then
    core.root_panel.root_node:update_layout()
  end
  if core.log_quiet then
    core.log_quiet("Side Panel Workspace: restore %s", restored and "completed" or "had no restorable views")
  end
  return restored
end

function M.show(name, opts)
  opts = opts or {}
  M.prune_stale_views()
  local view = type(name) == "table" and name or M.panels[name]
  if not view then return nil end
  local panel_name = type(name) == "string" and name or view.__sidepanel_panel_name
  if panel_name then M.current_panel = panel_name end
  M.visible = true
  M.side_editor_slot_visible = false
  if M.file_view then M.file_view.visible = false end
  M.ensure_side_node()
  M.set_side_view(view, opts.focus == true)
  return view
end

-- Make an existing side view drawable without changing presentation when the
-- Side Editor Slot can already host it. Other side views require the full Side
-- Panel because they have no slot presentation.
function M.make_view_visible(view)
  M.prune_stale_views()
  if not (view and M.contains_view(view)) then return nil end

  if view == M.file_view and not M.visible then
    M.side_editor_slot_visible = true
    M.set_side_view(view, false)
  else
    M.show(view, { focus = false })
  end
  return view
end

function M.hide(focus_main)
  local active_side_owner = side_focus_owner(core.active_view)
  M.visible = false
  local view = M.active_side_view()
  if view and view ~= M.file_view then
    view.visible = false
    M.update_side_view_size(view)
  end
  if focus_main ~= false and M.remember_side_focus_view(core.active_view) then
    M.focus_main(false)
  elseif active_side_owner and active_side_owner ~= M.file_view then
    M.remember_side_focus_view(core.active_view)
    M.focus_main(false)
  end
  M.update_side_editor_slot()
  return true
end

function M.current_main_panel_view(fallback)
  return file_context.current_main_panel_view(fallback or M.last_main_panel_view)
end

function M.focus_main(hide)
  if hide then M.hide(false) end
  local view = M.current_main_panel_view(M.last_main_panel_view)
  if not view then
    local main_panel = core.root_panel and core.root_panel:get_main_panel()
    view = main_panel and main_panel.active_view
  end
  if view then core.set_active_view(M.restorable_main_focus_view(view) or view) end
  return view
end

function M.focus_side()
  M.prune_stale_views()
  local side = M.ensure_side_node()
  local view = side and side.active_view
  if not view or view.__sidepanel_placeholder then
    view = M.current_panel and M.panels[M.current_panel]
  end
  if view then
    if not M.visible then M.visible = true end
    M.set_side_view(view, false)
    core.set_active_view(M.restorable_side_focus_view(view) or view)
  end
  return view
end

function M.toggle_focus()
  if M.remember_side_focus_view(core.active_view) then
    return M.focus_main(false)
  end
  if M.visible then
    return M.focus_side()
  end
  if M.current_panel then
    return M.show(M.current_panel, { focus = true })
  end
end

function M.focus_editor_or_restore_side()
  local prompt_owner = side_focus_owner(core.active_view) or main_focus_owner(core.active_view)
  if prompt_owner and not (M.is_main_panel_view(prompt_owner) or is_side_editor(prompt_owner)) then
    prompt_owner = nil
  end
  if core.active_view and core.active_view.local_find_input and prompt_owner then
    -- Alt+1 from a DocView Prompt Bar is equivalent to closing that prompt,
    -- but only when the prompt belongs to a real Editor.
    command.perform("user:find-close")
    return prompt_owner
  end

  M.prune_stale_views()
  local side_editor = M.restorable_side_editor()
  local focus_owner = M.last_restorable_editor_focus_owner()

  local should_hide_side_panel = not side_editor
  if side_editor then
    M.visible = true
    M.set_side_view(side_editor, false)
  else
    -- Alt+1 is an Editor-focus command. Persistent non-Editor Side Panel
    -- tools should get out of the way when there is no Side Editor to keep.
    M.hide(false)
  end

  if not focus_owner then
    focus_owner = M.current_main_panel_view(M.last_main_panel_view)
      or (core.root_panel and core.root_panel:get_main_panel() and core.root_panel:get_main_panel().active_view)
      or side_editor
  end

  if focus_owner then
    if M.is_side_view(focus_owner) then
      core.set_active_view(M.restorable_side_focus_view(focus_owner) or focus_owner)
    elseif M.is_main_panel_view(focus_owner) then
      core.set_active_view(M.restorable_main_focus_view(focus_owner) or focus_owner)
    else
      core.set_active_view(focus_owner)
    end
  end
  if should_hide_side_panel then M.hide(false) end
  return focus_owner
end

function M.close_active_side_editor_or_hide()
  local owner = side_focus_owner(core.active_view)
  if is_side_editor(owner) and M.contains_view(owner) then
    local function close_side_editor()
      core.log_quiet("Side panel: closed Side Editor")
      M.remove_view(owner, false)
      M.hide(false)
      M.focus_main(false)
      M.hide(false)
    end

    -- Side Editors are removed when closed. Use the normal Editor close path
    -- only when this is the last dirty view, so save/conflict prompts remain
    -- identical to ordinary DocViews without prompting for duplicate views.
    local refs = owner.doc and core.get_views_referencing_doc and core.get_views_referencing_doc(owner.doc) or {}
    if not (owner.doc and owner.doc.is_dirty and owner.doc:is_dirty()) or #refs > 1 then
      close_side_editor()
    else
      owner:try_close(close_side_editor)
    end
    return owner
  end
  M.hide(true)
end

function M.switch_side_view(delta)
  local side = M.ensure_side_node()
  if not side then return nil end

  local views = {}
  for _, view in ipairs(side.views or {}) do
    if not view.__sidepanel_placeholder then
      views[#views + 1] = view
    end
  end
  if #views == 0 then return nil end

  local index = 1
  for i, view in ipairs(views) do
    if view == side.active_view then
      index = i
      break
    end
  end
  index = ((index - 1 + delta) % #views) + 1

  M.visible = true
  local view = M.set_side_view(views[index], false)
  if view then
    core.set_active_view(M.restorable_side_focus_view(view) or view)
  end
  return view
end

local function copy_docview_position(src, dst)
  if not src or not dst or not src.doc or src.doc ~= dst.doc then return end
  if src.get_selection_state and dst.set_selection_state then
    dst:set_selection_state(src:get_selection_state())
  end
  dst.scroll.x, dst.scroll.to.x = src.scroll.x or 0, src.scroll.to.x or src.scroll.x or 0
  dst.scroll.y, dst.scroll.to.y = src.scroll.y or 0, src.scroll.to.y or src.scroll.y or 0
  if dst.selection_state then
    dst.last_line1, dst.last_col1, dst.last_line2, dst.last_col2 = table.unpack(dst.selection_state.selections, 1, 4)
  else
    dst.last_line1, dst.last_col1, dst.last_line2, dst.last_col2 = src.doc:get_selection()
  end
end

local function side_file_needs_preserve(doc)
  local old = M.file_view
  if old and not M.contains_view(old) then
    M.file_view = nil
    M.file_view_path = nil
    old = nil
  end
  if not old or not old.doc or old.doc == doc then return false end
  if not old.doc:is_dirty() then return false end
  local refs = core.get_views_referencing_doc and core.get_views_referencing_doc(old.doc) or {}
  for _, ref in ipairs(refs) do
    if ref ~= old then return false end
  end
  return true
end

local function preserve_dirty_side_file()
  local old = M.file_view
  if not old or not old.doc then return end
  local restore = core.active_view
  core.root_panel:open_doc(old.doc)
  if restore and core.active_view ~= restore then
    core.set_active_view(restore)
  end
  core.log("Side panel: kept dirty side file open in main before replacing")
end

local function set_side_file_doc(doc, opts)
  opts = opts or {}
  if not doc then return nil end

  if side_file_needs_preserve(doc) then
    preserve_dirty_side_file()
  end

  local source = opts.source_view
  if not source and core.active_view and core.active_view.extends and core.active_view:extends(DocView) then
    source = core.active_view
  end

  local view = M.file_view
  if view and not M.contains_view(view) then view = nil end
  if not view or view.doc ~= doc then
    view = file_context.mark_editor_view(DocView(doc))
    M.file_view = view
    M.file_view_path = doc.abs_filename
    M.register_panel("file", view)
  else
    file_context.mark_editor_view(view)
    M.attach_view("file", view)
    M.add_view(view)
  end

  copy_docview_position(source, view)
  M.visible = false
  M.side_editor_slot_visible = should_show_side_editor_slot()
  M.set_side_view(view, opts.focus == true)

  if opts.line then
    local col = opts.col or 1
    local line2, col2 = opts.line2 or opts.line, opts.col2 or col
    view:with_selection_state(function()
      if view.expand_folds_covering_range then view:expand_folds_covering_range(opts.line, col, line2, col2, "sidepanel") end
      doc:set_selection(opts.line, col, line2, col2)
    end)
    view:scroll_to_make_visible(opts.line, col)
  end

  if opts.focus == false and opts.restore_focus and not M.is_side_view(opts.restore_focus) then
    core.set_active_view(opts.restore_focus)
  elseif opts.focus ~= true and source and core.active_view ~= source and not M.is_side_view(source) then
    core.set_active_view(source)
  elseif opts.focus ~= true and M.is_side_view(core.active_view) then
    M.focus_main(false)
  end

  return view
end

function M.open_doc_in_side(doc, opts)
  return set_side_file_doc(doc, opts)
end

function M.open_path_in_side(path, opts)
  opts = opts or {}
  path = path and common.normalize_path(path)
  if not path then return nil end

  if ImageView.is_supported(path) then
    if side_file_needs_preserve(nil) then
      preserve_dirty_side_file()
    end

    local source = opts.source_view or core.active_view
    local view = M.file_view
    if view and not M.contains_view(view) then view = nil end
    if not view or not common.path_equals(view.path, path) then
      view = ImageView(path)
      if not view.image then
        core.error("Image could not be loaded.%s", view.errmsg and " Error: " .. view.errmsg or "")
        return nil
      end
      M.file_view = view
      M.file_view_path = path
      M.register_panel("file", view)
    else
      M.attach_view("file", view)
      M.add_view(view)
    end
    M.visible = false
    M.side_editor_slot_visible = should_show_side_editor_slot()
    M.set_side_view(view, opts.focus == true)
    if opts.focus == false and opts.restore_focus and not M.is_side_view(opts.restore_focus) then
      core.set_active_view(opts.restore_focus)
    elseif opts.focus ~= true and source and not M.is_side_view(source) then
      core.set_active_view(source)
    elseif opts.focus ~= true and M.is_side_view(core.active_view) then
      M.focus_main(false)
    end
    return view
  end

  local ok, doc = core.try(core.open_doc, path)
  if ok and doc then
    return M.open_doc_in_side(doc, opts)
  end
end

function M.open_doc_in_main(doc, opts)
  opts = opts or {}
  if not doc then return nil end

  local main_panel = core.root_panel and core.root_panel:get_main_panel()
  if not main_panel then return nil end

  local view = core.root_panel:open_doc(doc, {
    node = main_panel,
    source_view = opts.source_view,
    replace_dirty_singleton = opts.replace_dirty_singleton == true,
  })
  if opts.source_view then
    copy_docview_position(opts.source_view, view)
  end

  if opts.line then
    local col = opts.col or 1
    local line2, col2 = opts.line2 or opts.line, opts.col2 or col
    if view.with_selection_state then
      view:with_selection_state(function()
        if view.expand_folds_covering_range then view:expand_folds_covering_range(opts.line, col, line2, col2, "sidepanel") end
        view.doc:set_selection(opts.line, col, line2, col2)
      end)
    else
      view.doc:set_selection(opts.line, col, line2, col2)
    end
    view:scroll_to_make_visible(opts.line, col)
  end

  if opts.focus ~= false then
    core.set_active_view(view)
  end
  return view
end

function M.open_path_in_main(path, opts)
  opts = opts or {}
  local restore = opts.preserve_focus and core.active_view or opts.restore_focus
  local view
  if ImageView.is_supported(path) then
    view = core.open_file(path)
  else
    local ok, doc = core.try(core.open_doc, path)
    if ok and doc then
      view = M.open_doc_in_main(doc, {
        source_view = opts.source_view,
        line = opts.line,
        col = opts.col,
        line2 = opts.line2,
        col2 = opts.col2,
        focus = opts.preserve_focus == true and false or true,
        replace_dirty_singleton = opts.replace_dirty_singleton == true,
      })
    else
      view = core.open_file(path)
    end
  end
  if restore and opts.preserve_focus ~= false then
    core.set_active_view(restore)
  end
  return view
end

local base_set_active_view = core.sidepanel_base_set_active_view or core.set_active_view
core.sidepanel_base_set_active_view = base_set_active_view
function core.set_active_view(view)
  local result = base_set_active_view(view)
  if core.sidepanel then
    core.sidepanel.remember_main_panel_view(view)
    core.sidepanel.remember_side_focus_view(view)
    core.sidepanel.remember_editor_focus_owner(view)
    if core.sidepanel.update_side_editor_slot then core.sidepanel.update_side_editor_slot() end
  end
  return result
end

local function active_main_surface_focus_owner()
  local main = core.root_panel and core.root_panel.get_main_panel and core.root_panel:get_main_panel()
  local view = main and main.active_view
  if core.active_view and core.active_view.git_owner_view == view then return view end
  return view
end

local function main_surface_can_cycle_focus(view)
  return view
     and type(view.can_focus_next_pane) == "function"
     and type(view.focus_next_pane) == "function"
     and view:can_focus_next_pane()
end

function M.focus_next_surface_target_or_sidepanel()
  local surface = active_main_surface_focus_owner()
  if main_surface_can_cycle_focus(surface) then
    if M.visible then
      M.hide(false)
      core.set_active_view(surface)
    end
    core.log_quiet("Main surface focus: cycling Surface Focus Target for %s", surface.get_name and surface:get_name() or tostring(surface))
    return surface:focus_next_pane()
  end

  if M.file_view and M.contains_view(M.file_view) and active_main_surface_allows_side_editor() then
    if M.visible then M.hide(false) end
    M.side_editor_slot_visible = true
    M.set_side_view(M.file_view, false)
    if side_focus_owner(core.active_view) == M.file_view then
      M.focus_main(false)
    else
      core.set_active_view(M.restorable_side_focus_view(M.file_view) or M.file_view)
    end
    core.log_quiet("Main surface focus: cycled between Editing Surface and Side Editor Slot")
    return true
  end

  return M.toggle_focus()
end

command.add(nil, {
  ["sidepanel:focus-main-and-hide"] = function()
    M.focus_editor_or_restore_side()
  end,
  ["sidepanel:toggle-focus"] = function()
    M.toggle_focus()
  end,
  ["surface:focus-next-target-or-sidepanel"] = function()
    M.focus_next_surface_target_or_sidepanel()
  end,
  ["sidepanel:focus-side"] = function()
    M.focus_side()
  end,
  ["sidepanel:hide"] = function()
    M.hide(false)
  end,
  ["sidepanel:open-current-file"] = function()
    local active = core.active_view
    local side_owner = side_focus_owner(active)
    if is_side_editor(side_owner) and side_owner.doc then
      M.open_doc_in_main(side_owner.doc, { source_view = side_owner, focus = true })
      return true
    end

    local view = M.current_main_panel_view(active)
    if not file_context.is_editor_view(view) or not view.doc then return false end
    M.open_doc_in_side(view.doc, { source_view = view, focus = true })
    return true
  end,
})

command.add(function()
  local owner = side_focus_owner(core.active_view)
  if owner then return true, owner end
  return M.is_side_view(core.active_view)
end, {
  ["sidepanel:hide-active"] = function()
    M.close_active_side_editor_or_hide()
  end,
  ["sidepanel:switch-to-next-view"] = function()
    M.switch_side_view(1)
  end,
  ["sidepanel:switch-to-previous-view"] = function()
    M.switch_side_view(-1)
  end,
})

local function side_internal_tab_owner()
  local owner = side_focus_owner(core.active_view)
  if owner then return owner end
  if M.is_side_view(core.active_view) then return core.active_view end
end

local function switch_side_internal_tab(owner, delta)
  if owner and type(owner.switch_tab) == "function" then
    return owner:switch_tab(delta)
  end
end

local function wrap_root_tab_switch(name, delta)
  local base = command.map[name]
  if not base or base.__sidepanel_wrapped then return end

  command.add(function(...)
    local explicit_node = select(1, ...)
    local owner = not Node:is_extended_by(explicit_node) and side_internal_tab_owner()
    if owner then
      if type(owner.switch_tab) == "function" then
        return true, "sidepanel", owner
      end
      return false
    end
    local result = { base.predicate(...) }
    if table.remove(result, 1) then
      if #result > 0 then
        return true, "base", table.unpack(result)
      end
      return true, "base", ...
    end
    return false
  end, {
    [name] = function(mode, ...)
      if mode == "sidepanel" then
        switch_side_internal_tab(..., delta)
      elseif base then
        base.perform(...)
      end
    end,
  })
  command.map[name].__sidepanel_wrapped = true
end

-- Ctrl+Tab now cycles global Main Tabs. Side Panel internal tab cycling should
-- use explicit sidepanel commands instead of wrapping root tab commands.

local function install_keymaps()
  keymap.add({
    ["ctrl+w"] = "sidepanel:hide-active",
  })
  keymap.add_direct({
    ["alt+1"] = "sidepanel:hide",
    ["alt+º"] = "surface:focus-next-target-or-sidepanel",
    ["alt+grave"] = "surface:focus-next-target-or-sidepanel",
    ["alt+`"] = "surface:focus-next-target-or-sidepanel",
    ["ctrl+0"] = "sidepanel:open-current-file",
  })
end

M.install_keymaps = install_keymaps
install_keymaps()

core.add_thread(function()
  coroutine.yield(0.1)
  install_keymaps()
end)

M.ensure_side_node()

return M
