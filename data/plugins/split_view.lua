-- mod-version:3 priority:50
-- Shared right-side split panel for local workflows.

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local keymap = require "core.keymap"
local Node = require "core.node"
local View = require "core.view"
local DocView = require "core.docview"
local ImageView = require "core.imageview"
local file_context = require "plugins.file_context"

local M = core.split_view or {}
core.split_view = M

M.panels = M.panels or {}
M.side_views = M.side_views or setmetatable({}, { __mode = "k" })
M.visible = M.visible or false
M.current_panel = M.current_panel
M.last_main_view = M.last_main_view
M.side_node = M.side_node
M.main_node = M.main_node
M.container_node = M.container_node
M.file_view = M.file_view
M.file_view_path = M.file_view_path
M.instant_size = M.instant_size

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
  if node.__split_view_side_node then return node end
  if node.type ~= "leaf" then
    return find_side_node(node.a) or find_side_node(node.b)
  end
end

local function side_placeholder()
  local view = M.placeholder
  if not view then
    view = View()
    view.__split_view_placeholder = true
    view.size.x = 0
    M.placeholder = view
  end
  return view
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
  container.b.__split_view_side_node = true
  container.__split_view_container_node = true

  M.container_node = container
  M.main_node = main
  M.side_node = container.b
  return M.side_node
end

function M.ensure_side_node()
  local root = core.root_view and core.root_view.root_node
  if not root then return nil end

  if M.side_node and M.side_node.__split_view_side_node then
    return M.side_node
  end

  local existing = find_side_node(root)
  if existing then
    M.side_node = existing
    M.container_node = existing:get_parent_node(root)
    M.main_node = M.container_node and M.container_node.a or nil
    return existing
  end

  local workbench = get_unlocked_root(root)
  if not workbench then return nil end
  return attach_locked_side_node(workbench)
end

function M.is_side_view(view)
  return not not (view and M.side_views and M.side_views[view])
end

function M.is_main_view(view)
  return file_context.is_main_view(view) and not M.is_side_view(view)
end

function M.remember_main_view(view)
  if M.is_main_view(view) then
    M.last_main_view = view
  end
end

local function side_parent_width()
  local side = M.ensure_side_node()
  local root = core.root_view and core.root_view.root_node
  local parent = side and side:get_parent_node(root)
  local w = parent and parent.size and parent.size.x or (core.root_view and core.root_view.size.x) or 0
  return math.max(0, w)
end

function M.target_width()
  if not M.visible then return 0 end
  return math.floor(side_parent_width() / 2)
end

function M.update_side_view_size(view)
  if not view then return end
  local dest = M.target_width()
  if M.instant_size then
    view.size.x = dest
    M.instant_size = false
  elseif math.abs((view.size.x or 0) - dest) > 0.5 then
    view:move_towards(view.size, "x", dest, nil, "split_view")
    view.size.x = common.round(view.size.x)
    if math.abs(dest - view.size.x) < 2 then view.size.x = dest end
  else
    view.size.x = dest
  end
end

function M.attach_view(name, view)
  if not view then return end
  if name then
    view.__split_view_panel_name = name
  end
  M.side_views[view] = true
  file_context.exclude_main_view(view)

  if view.__split_view_size_wrapped then return view end
  view.__split_view_size_wrapped = true
  view.__split_view_original_update = view.update
  function view:update(...)
    local manager = core.split_view
    if manager and manager.update_side_view_size then
      manager.update_side_view_size(self)
    end
    return self.__split_view_original_update(self, ...)
  end
  return view
end

function M.register_panel(name, view)
  assert(type(name) == "string" and name ~= "", "split_view panel name expected")
  assert(view, "split_view panel view expected")
  M.panels[name] = view
  M.attach_view(name, view)
  M.ensure_side_node()
  return view
end

function M.active_side_view()
  local side = M.ensure_side_node()
  return side and side.active_view
end

function M.set_side_view(view, focus)
  local side = M.ensure_side_node()
  if not side or not view then return end

  M.attach_view(view.__split_view_panel_name, view)
  local old = side.active_view
  if old ~= view and old and old.__split_view_placeholder ~= true then
    old.visible = false
    if old.on_mouse_left then old:on_mouse_left() end
  end

  side.views = { view }
  side.active_view = view
  view.visible = M.visible
  M.update_side_view_size(view)

  if focus then
    core.set_active_view(view)
  elseif core.active_view == old and old ~= view then
    M.focus_main(false)
  end

  if core.root_view and core.root_view.root_node then
    core.root_view.root_node:update_layout()
  end
  return view
end

function M.show(name, opts)
  opts = opts or {}
  local view = type(name) == "table" and name or M.panels[name]
  if not view then return nil end
  local panel_name = type(name) == "string" and name or view.__split_view_panel_name
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
  if focus_main ~= false and M.is_side_view(core.active_view) then
    M.focus_main(false)
  end
  return true
end

function M.current_main_view(fallback)
  return file_context.current_main_view(fallback or M.last_main_view)
end

function M.focus_main(hide)
  if hide then M.hide(false) end
  local view = M.current_main_view(M.last_main_view)
  if not view then
    local primary = core.root_view and core.root_view:get_primary_node()
    view = primary and primary.active_view
  end
  if view then core.set_active_view(view) end
  return view
end

function M.focus_side()
  local side = M.ensure_side_node()
  local view = side and side.active_view
  if not view or view.__split_view_placeholder then
    view = M.current_panel and M.panels[M.current_panel]
  end
  if view then
    if not M.visible then M.visible = true end
    M.set_side_view(view, true)
  end
  return view
end

function M.toggle_focus()
  if M.is_side_view(core.active_view) then
    return M.focus_main(false)
  end
  if M.visible then
    return M.focus_side()
  end
  if M.current_panel then
    return M.show(M.current_panel, { focus = true })
  end
end

local function copy_docview_position(src, dst)
  if not src or not dst or not src.doc or src.doc ~= dst.doc then return end
  dst.scroll.x, dst.scroll.to.x = src.scroll.x or 0, src.scroll.to.x or src.scroll.x or 0
  dst.scroll.y, dst.scroll.to.y = src.scroll.y or 0, src.scroll.to.y or src.scroll.y or 0
  dst.last_line1, dst.last_col1, dst.last_line2, dst.last_col2 = src.doc:get_selection()
end

local function side_file_needs_preserve(doc)
  local old = M.file_view
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
  core.root_view:open_doc(old.doc)
  if restore and core.active_view ~= restore then
    core.set_active_view(restore)
  end
  core.log("Split view: kept dirty side file open in main before replacing")
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
  if not view or view.doc ~= doc then
    view = DocView(doc)
    M.file_view = view
    M.file_view_path = doc.abs_filename
    M.register_panel("file", view)
  else
    M.attach_view("file", view)
  end

  copy_docview_position(source, view)
  M.show("file", { focus = opts.focus == true })

  if opts.line then
    local col = opts.col or 1
    doc:set_selection(opts.line, col, opts.line, col)
    view:scroll_to_make_visible(opts.line, col)
  end

  if opts.focus == false and opts.restore_focus then
    core.set_active_view(opts.restore_focus)
  elseif opts.focus ~= true and source and core.active_view ~= source and not M.is_side_view(source) then
    core.set_active_view(source)
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
    end
    M.show("file", { focus = opts.focus == true })
    if opts.focus == false and opts.restore_focus then
      core.set_active_view(opts.restore_focus)
    elseif opts.focus ~= true and source and not M.is_side_view(source) then
      core.set_active_view(source)
    end
    return view
  end

  local ok, doc = core.try(core.open_doc, path)
  if ok and doc then
    return M.open_doc_in_side(doc, opts)
  end
end

function M.open_path_in_main(path, opts)
  opts = opts or {}
  local restore = opts.preserve_focus and core.active_view or opts.restore_focus
  local view = core.open_file(path)
  if opts.line and view and view.doc then
    local col = opts.col or 1
    view.doc:set_selection(opts.line, col, opts.line, col)
    view:scroll_to_make_visible(opts.line, col)
  end
  if restore and opts.preserve_focus ~= false then
    core.set_active_view(restore)
  end
  return view
end

local base_set_active_view = core.split_view_base_set_active_view or core.set_active_view
core.split_view_base_set_active_view = base_set_active_view
function core.set_active_view(view)
  local result = base_set_active_view(view)
  if core.split_view then core.split_view.remember_main_view(view) end
  return result
end

command.add(nil, {
  ["split-view:focus-main-and-hide"] = function()
    M.focus_main(true)
  end,
  ["split-view:toggle-focus"] = function()
    M.toggle_focus()
  end,
  ["split-view:focus-side"] = function()
    M.focus_side()
  end,
  ["split-view:hide"] = function()
    M.hide(true)
  end,
  ["split-view:open-current-file"] = function()
    local view = M.current_main_view(core.active_view)
    if not view or not view.extends or not view:extends(DocView) or not view.doc then return false end
    M.open_doc_in_side(view.doc, { source_view = view, focus = false })
    return true
  end,
})

command.add(function()
  return M.is_side_view(core.active_view)
end, {
  ["split-view:hide-active-side"] = function()
    M.hide(true)
  end,
})

local function install_keymaps()
  keymap.add({
    ["ctrl+w"] = "split-view:hide-active-side",
  })
  keymap.add_direct({
    ["alt+1"] = "split-view:focus-main-and-hide",
    ["alt+º"] = "split-view:toggle-focus",
    ["alt+grave"] = "split-view:toggle-focus",
    ["alt+`"] = "split-view:toggle-focus",
    ["ctrl+0"] = "split-view:open-current-file",
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
