-- Core right-side panel manager.
--
-- The side panel is a persistent, locked right-side leaf node. It behaves like
-- a hidden-tab container: multiple views can live in the node, while only one
-- is active/visible at a time. This keeps side DocViews in the normal root node
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
M.last_docview_focus_owner = M.last_docview_focus_owner
M.side_node = M.side_node
M.main_node = M.main_node
M.container_node = M.container_node
M.file_view = M.file_view
M.file_view_path = M.file_view_path
M.instant_size = M.instant_size
M.width_ratio = M.width_ratio or 0.5

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
  local main = Node()
  main:consume(container)

  container:consume(Node("hsplit"))
  container.a = main
  container.b = Node()
  container.b:add_view(placeholder)
  container.b.locked = { x = true }
  container.b.resizable = false
  container.b.__sidepanel_side_node = true
  container.__sidepanel_container_node = true

  M.container_node = container
  M.main_node = main
  M.side_node = container.b
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

local function is_side_docview(view)
  return is_docview(view) and view.__sidepanel_docview == true
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
    if not (state and state.visible and state.input_active) then return nil end
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

local function docview_focus_owner(view)
  return main_focus_owner(view) or side_focus_owner(view)
end

function M.remember_docview_focus_owner(view)
  local owner = docview_focus_owner(view)
  if owner and (M.is_main_panel_view(owner) or is_side_docview(owner)) then
    M.last_docview_focus_owner = owner
  end
  return owner
end

function M.last_restorable_docview_focus_owner()
  local owner = M.last_docview_focus_owner
  if owner and M.is_side_view(owner) then
    if is_side_docview(owner) and M.contains_view(owner) then return owner end
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

function M.target_width()
  if not M.visible then return 0 end
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

function M.restorable_side_docview()
  M.prune_stale_views()
  local side = M.ensure_side_node()
  local active = side and side.active_view
  if is_side_docview(active) and M.is_side_view(active) then return active end
  if is_side_docview(M.last_side_focus_owner) and M.contains_view(M.last_side_focus_owner) then
    return M.last_side_focus_owner
  end
  if is_side_docview(M.file_view) and M.contains_view(M.file_view) then return M.file_view end
  if side then
    -- Side DocViews are removable panels; if a non-DocView panel is active,
    -- Alt+1 can still restore the newest remaining Side DocView instead of
    -- treating the Side Panel as only a persistent tool panel.
    for i = #(side.views or {}), 1, -1 do
      local view = side.views[i]
      if is_side_docview(view) and M.is_side_view(view) then return view end
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
  view.visible = M.visible
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

function M.show(name, opts)
  opts = opts or {}
  M.prune_stale_views()
  local view = type(name) == "table" and name or M.panels[name]
  if not view then return nil end
  local panel_name = type(name) == "string" and name or view.__sidepanel_panel_name
  if panel_name then M.current_panel = panel_name end
  M.visible = true
  M.ensure_side_node()
  M.set_side_view(view, opts.focus == true)
  return view
end

function M.hide(focus_main)
  M.visible = false
  local view = M.active_side_view()
  if view then
    view.visible = false
    M.update_side_view_size(view)
  end
  if focus_main ~= false and M.remember_side_focus_view(core.active_view) then
    M.focus_main(false)
  end
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

function M.focus_docview_or_restore_side()
  local prompt_owner = side_focus_owner(core.active_view) or main_focus_owner(core.active_view)
  if core.active_view and core.active_view.local_find_input and prompt_owner then
    -- Alt+1 from a DocView Prompt Bar is equivalent to closing that prompt:
    -- focus returns to its owning DocView, regardless of Main/Side location.
    command.perform("user:find-close")
    return prompt_owner
  end

  M.prune_stale_views()
  local side_docview = M.restorable_side_docview()
  local focus_owner = M.last_restorable_docview_focus_owner()

  local should_hide_side_panel = not side_docview
  if side_docview then
    M.visible = true
    M.set_side_view(side_docview, false)
  else
    -- Alt+1 is a DocView-focus command. Persistent non-DocView Side Panel
    -- tools should get out of the way when there is no Side DocView to keep.
    M.hide(false)
  end

  if not focus_owner then
    focus_owner = M.current_main_panel_view(M.last_main_panel_view)
      or (core.root_panel and core.root_panel:get_main_panel() and core.root_panel:get_main_panel().active_view)
      or side_docview
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

function M.close_active_side_docview_or_hide()
  local owner = side_focus_owner(core.active_view)
  if is_side_docview(owner) and M.contains_view(owner) then
    local function close_side_docview()
      core.log_quiet("Side panel: closed Side DocView")
      M.remove_view(owner, false)
      M.hide(false)
      M.focus_main(false)
      M.hide(false)
    end

    -- Side DocViews are removed when closed. Use the normal DocView close path
    -- only when this is the last dirty view, so save/conflict prompts remain
    -- identical to ordinary DocViews without prompting for duplicate views.
    local refs = owner.doc and core.get_views_referencing_doc and core.get_views_referencing_doc(owner.doc) or {}
    if not (owner.doc and owner.doc.is_dirty and owner.doc:is_dirty()) or #refs > 1 then
      close_side_docview()
    else
      owner:try_close(close_side_docview)
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
    view = DocView(doc)
    view.__sidepanel_docview = true
    M.file_view = view
    M.file_view_path = doc.abs_filename
    M.register_panel("file", view)
  else
    view.__sidepanel_docview = true
    M.attach_view("file", view)
    M.add_view(view)
  end

  copy_docview_position(source, view)
  M.show("file", { focus = opts.focus == true })

  if opts.line then
    local col = opts.col or 1
    view:with_selection_state(function()
      doc:set_selection(opts.line, col, opts.line, col)
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
    if not view or view.path ~= path then
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
    M.show("file", { focus = opts.focus == true })
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

  local view = core.root_panel:open_doc(doc, { node = main_panel, source_view = opts.source_view })
  if opts.source_view then
    copy_docview_position(opts.source_view, view)
  end

  if opts.line then
    local col = opts.col or 1
    if view.with_selection_state then
      view:with_selection_state(function()
        view.doc:set_selection(opts.line, col, opts.line, col)
      end)
    else
      view.doc:set_selection(opts.line, col, opts.line, col)
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
        focus = opts.preserve_focus == true and false or true,
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
    core.sidepanel.remember_docview_focus_owner(view)
  end
  return result
end

command.add(nil, {
  ["sidepanel:focus-main-and-hide"] = function()
    M.focus_docview_or_restore_side()
  end,
  ["sidepanel:toggle-focus"] = function()
    M.toggle_focus()
  end,
  ["sidepanel:focus-side"] = function()
    M.focus_side()
  end,
  ["sidepanel:hide"] = function()
    M.hide(true)
  end,
  ["sidepanel:open-current-file"] = function()
    local active = core.active_view
    local side_owner = side_focus_owner(active)
    if side_owner and side_owner.extends and side_owner:extends(DocView) and side_owner.doc then
      M.open_doc_in_main(side_owner.doc, { source_view = side_owner, focus = true })
      return true
    end

    local view = M.current_main_panel_view(active)
    if not view or not view.extends or not view:extends(DocView) or not view.doc then return false end
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
    M.close_active_side_docview_or_hide()
  end,
  ["sidepanel:switch-to-next-view"] = function()
    M.switch_side_view(1)
  end,
  ["sidepanel:switch-to-previous-view"] = function()
    M.switch_side_view(-1)
  end,
})

local function wrap_root_tab_switch(name, delta)
  local base = command.map[name]
  if not base or base.__sidepanel_wrapped then return end

  command.add(function(...)
    if M.is_side_view(core.active_view) or side_focus_owner(core.active_view) then return true, "sidepanel" end
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
        M.switch_side_view(delta)
      elseif base then
        base.perform(...)
      end
    end,
  })
  command.map[name].__sidepanel_wrapped = true
end

wrap_root_tab_switch("root:switch-to-next-tab", 1)
wrap_root_tab_switch("root:switch-to-previous-tab", -1)

local function install_keymaps()
  keymap.add({
    ["ctrl+w"] = "sidepanel:hide-active",
  })
  keymap.add_direct({
    ["alt+1"] = "sidepanel:focus-main-and-hide",
    ["alt+º"] = "sidepanel:toggle-focus",
    ["alt+grave"] = "sidepanel:toggle-focus",
    ["alt+`"] = "sidepanel:toggle-focus",
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
