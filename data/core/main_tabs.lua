-- Global Main Tab / Main Surface manager.
--
-- Main Tabs are represented by the ordered views in the Main Panel leaf.  The
-- normal file-backed Main Editor is a singleton tab: opening another ordinary
-- file replaces that tab's Editor view instead of adding another file tab.
-- Untitled documents, dirty file-backed documents that must survive a switch,
-- and tool surfaces such as Git views are independent Main Tabs.

local core = _G.core or require "core"
local common = require "core.common"
local EmptyView = require "core.emptyview"
local DocView = require "core.docview"
local file_context = require "core.file_context"

local M = core.main_tabs or {}
core.main_tabs = M

M.editor_doc_state = M.editor_doc_state or setmetatable({}, { __mode = "k" })
M.git_sessions = M.git_sessions or {}

local function main_panel()
  return core.root_panel and core.root_panel:get_main_panel()
end

local function view_index(node, view)
  if not node or not view then return nil end
  for i, item in ipairs(node.views or {}) do
    if item == view then return i end
  end
end

local function remove_view_raw(node, view)
  local idx = view_index(node, view)
  if idx then table.remove(node.views, idx) end
  return idx
end

function M.is_main_panel_node(node)
  return node and (node.is_main_panel_node or node.is_primary_node)
end

function M.is_blank_editor_view(view)
  return not not (view and view.__main_tabs_blank_editor)
end

function M.is_singleton_editor_view(view)
  return not not (view and view.__main_tabs_singleton_editor)
end

function M.is_editor_surface(view)
  return M.is_blank_editor_view(view) or file_context.is_editor_view(view)
end

local function make_blank_editor_view()
  local view = EmptyView()
  view.__main_tabs_blank_editor = true
  view.__main_tabs_singleton_editor = true
  function view:get_name()
    return "Editor"
  end
  return view
end

local function mark_singleton_editor(view)
  if not view then return view end
  view.__main_tabs_singleton_editor = true
  view.__main_tabs_blank_editor = nil
  file_context.mark_editor_view(view)
  return view
end

local function clear_singleton_marker(view)
  if view then view.__main_tabs_singleton_editor = nil end
end

local function is_named_file_doc(doc)
  return doc and doc.abs_filename and doc.abs_filename ~= ""
end

local function is_untitled_doc(doc)
  return doc and not is_named_file_doc(doc)
end

local function docview_for_doc(node, doc, exclude_singleton)
  if not node or not doc then return nil end
  for _, view in ipairs(node.views or {}) do
    if view.doc == doc and not (exclude_singleton and M.is_singleton_editor_view(view)) then
      return view
    end
  end
end

local function capture_editor_state(view)
  if not (view and view.doc and view.get_selection_state) then return end
  M.editor_doc_state[view.doc] = {
    selection_state = view:get_selection_state(),
    scroll = {
      x = view.scroll and (view.scroll.to.x or view.scroll.x) or 0,
      y = view.scroll and (view.scroll.to.y or view.scroll.y) or 0,
    },
  }
end

local function apply_editor_state(view, source_view)
  if not (view and view.doc) then return end
  if source_view and source_view.doc == view.doc and source_view.get_selection_state then
    view:set_selection_state(source_view:get_selection_state())
    view.scroll.x = source_view.scroll.x or 0
    view.scroll.to.x = source_view.scroll.to.x or source_view.scroll.x or 0
    view.scroll.y = source_view.scroll.y or 0
    view.scroll.to.y = source_view.scroll.to.y or source_view.scroll.y or 0
    return
  end
  local state = M.editor_doc_state[view.doc]
  if state then
    if state.selection_state then view:set_selection_state(state.selection_state) end
    if state.scroll then
      view.scroll.x, view.scroll.to.x = state.scroll.x or 0, state.scroll.x or 0
      view.scroll.y, view.scroll.to.y = state.scroll.y or 0, state.scroll.y or 0
    end
  end
end

function M.ensure_main_editor()
  local node = main_panel()
  if not node then return nil end
  for _, view in ipairs(node.views or {}) do
    if M.is_singleton_editor_view(view) then return view end
  end
  for _, view in ipairs(node.views or {}) do
    if view and view.doc and is_named_file_doc(view.doc) and file_context.is_editor_view(view) then
      mark_singleton_editor(view)
      core.log_quiet("Main tabs: adopted restored file-backed Editor as singleton Main Editor: %s", tostring(view.doc.abs_filename or view.doc.filename))
      return view
    end
  end
  local view = make_blank_editor_view()
  if node.views[1] and node.views[1].is and node.views[1]:is(EmptyView) then
    node.views[1] = view
    node.active_view = view
  else
    table.insert(node.views, 1, view)
  end
  if not node.active_view then node.active_view = view end
  return view
end

function M.blank_main_editor(focus)
  local node = main_panel()
  if not node then return nil end
  local old = M.ensure_main_editor()
  if old then capture_editor_state(old) end
  local idx = view_index(node, old) or 1
  local blank = make_blank_editor_view()
  node.views[idx] = blank
  if focus ~= false or node.active_view == old then
    node:set_active_view(blank)
  end
  if core.root_panel and core.root_panel.root_node then core.root_panel.root_node:update_layout() end
  return blank
end

local function promote_dirty_singleton_if_needed(node, editor)
  if not (editor and editor.doc and is_named_file_doc(editor.doc)) then return false end
  if not (editor.doc.is_dirty and editor.doc:is_dirty()) then return false end
  clear_singleton_marker(editor)
  core.log_quiet("Main tabs: promoted dirty file-backed document %s to its own Main Tab", tostring(editor.doc.abs_filename or editor.doc.filename))
  return true
end

function M.open_doc(doc, opts)
  opts = opts or {}
  if not doc then return nil end
  local node = opts.node or main_panel()
  if not node then return nil end

  -- Non-Main-Panel callers keep the traditional Node tab behavior.
  if not M.is_main_panel_node(node) then return nil end

  if is_untitled_doc(doc) then
    local existing = docview_for_doc(node, doc, false)
    if existing then
      node:set_active_view(existing)
      return existing
    end
    local view = file_context.mark_editor_view(DocView(doc))
    if opts.source_view then apply_editor_state(view, opts.source_view) end
    node:add_view(view)
    if core.root_panel and core.root_panel.root_node then core.root_panel.root_node:update_layout() end
    return view
  end

  -- If this named document already owns a promoted/dedicated Main Tab, use it.
  local dedicated = docview_for_doc(node, doc, true)
  if dedicated then
    node:set_active_view(dedicated)
    return dedicated
  end

  local editor = M.ensure_main_editor()
  local old_idx = view_index(node, editor) or 1
  if editor and editor.doc == doc then
    node:set_active_view(editor)
    return editor
  end

  local insert_idx = old_idx
  if promote_dirty_singleton_if_needed(node, editor) then
    insert_idx = old_idx + 1
  else
    remove_view_raw(node, editor)
  end

  if editor then capture_editor_state(editor) end
  local view = mark_singleton_editor(DocView(doc))
  apply_editor_state(view, opts.source_view)
  table.insert(node.views, math.min(insert_idx, #node.views + 1), view)
  node:set_active_view(view)
  if core.root_panel and core.root_panel.root_node then core.root_panel.root_node:update_layout() end
  local line = view.selection_state and view.selection_state.selections[1] or view.doc:get_selection()
  view:scroll_to_line(line, true, true)
  core.log_quiet("Main tabs: singleton Main Editor opened %s", tostring(doc.abs_filename or doc.filename))
  return view
end

function M.open_view(view, opts)
  opts = opts or {}
  if not view then return nil end
  local node = opts.node or main_panel()
  if not node then return nil end
  local idx = view_index(node, view)
  if not idx then
    if node.views[1] and node.views[1].is and node.views[1]:is(EmptyView) then
      table.remove(node.views, 1)
    end
    table.insert(node.views, view)
  end
  if opts.focus ~= false then node:set_active_view(view) end
  if core.root_panel and core.root_panel.root_node then core.root_panel.root_node:update_layout() end
  return view
end

function M.close_view(node, root, view)
  if not (M.is_main_panel_node(node) and view) then return false end
  if M.is_singleton_editor_view(view) then
    local function do_close()
      M.blank_main_editor(true)
    end
    if view.try_close then view:try_close(do_close) else do_close() end
    return true
  end
  return false
end

function M.switch(delta)
  local node = main_panel()
  if not (node and node.views and #node.views > 0) then return nil end
  local idx = view_index(node, node.active_view) or 1
  idx = ((idx - 1 + delta) % #node.views) + 1
  node:set_active_view(node.views[idx])
  return node.views[idx]
end

function M.switch_to_index(idx)
  local node = main_panel()
  local view = node and node.views and node.views[idx]
  if view then node:set_active_view(view) end
  return view
end

function M.main_tab_count()
  local node = main_panel()
  return node and node.views and #node.views or 0
end

return M
