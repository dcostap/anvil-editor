-- Shared helpers for commands that operate on the current file/view.

local core = require "core"
local command = require "core.command"
local common = require "core.common"

local M = core.file_context or {}
core.file_context = M

function M.view_file_path(view)
  if type(view) == "string" and view ~= "" then
    return common.normalize_path(view)
  end

  local path = core.view_file_path and core.view_file_path(view)
  if not path and view and type(view.path) == "string" then
    path = view.path
  end
  if path and path ~= "" then return common.normalize_path(path) end
end

M.excluded_main_panel_views = M.excluded_main_panel_views or M.excluded_main_views or setmetatable({}, { __mode = "k" })
M.excluded_main_views = M.excluded_main_panel_views -- deprecated compatibility alias
M.editor_views = M.editor_views or setmetatable({}, { __mode = "k" })

function M.exclude_main_panel_view(view)
  if view then M.excluded_main_panel_views[view] = true end
end

function M.mark_editor_view(view)
  if view then M.editor_views[view] = true end
  return view
end

function M.is_editor_view(view)
  return not not (view and M.editor_views[view])
end

function M.is_file_view(view)
  return M.view_file_path(view) ~= nil
end

function M.is_main_panel_view(view)
  if not view or M.excluded_main_panel_views[view] then return false end
  if view == core.global_prompt_bar or view == core.nag_view or view == core.status_bar or view == core.title_bar then return false end
  return M.is_editor_view(view) or view.context == "workspace" or view.context == "session" or M.is_file_view(view)
end

function M.active_file_path()
  return M.view_file_path(core.active_view)
end

function M.main_panel_file_view()
  local node = core.root_panel and core.root_panel:get_main_panel()
  local view = node and node.active_view
  if M.is_file_view(view) then return view end
end

function M.main_panel_file_path()
  return M.view_file_path(M.main_panel_file_view())
end

function M.current_file_path(fallback_view)
  return M.active_file_path()
      or M.main_panel_file_path()
      or M.view_file_path(fallback_view)
end

function M.current_file_view(fallback_view)
  if M.is_file_view(core.active_view) then return core.active_view end
  return M.main_panel_file_view()
      or (M.is_file_view(fallback_view) and fallback_view or nil)
end

function M.main_panel_view()
  local node = core.root_panel and core.root_panel:get_main_panel()
  local view = node and node.active_view
  if M.is_main_panel_view(view) then return view end
end

function M.current_main_panel_view(fallback_view)
  if M.is_main_panel_view(core.active_view) then return core.active_view end
  if M.is_main_panel_view(fallback_view) then return fallback_view end
  return M.main_panel_view()
end

---@deprecated Use `exclude_main_panel_view` instead.
function M.exclude_main_view(view)
  core.deprecation_log("file_context.exclude_main_view")
  return M.exclude_main_panel_view(view)
end

---@deprecated Use `is_main_panel_view` instead.
function M.is_main_view(view)
  core.deprecation_log("file_context.is_main_view")
  return M.is_main_panel_view(view)
end

---@deprecated Use `main_panel_file_view` instead.
function M.primary_file_view()
  core.deprecation_log("file_context.primary_file_view")
  return M.main_panel_file_view()
end

---@deprecated Use `main_panel_file_path` instead.
function M.primary_file_path()
  core.deprecation_log("file_context.primary_file_path")
  return M.main_panel_file_path()
end

---@deprecated Use `main_panel_view` instead.
function M.primary_main_view()
  core.deprecation_log("file_context.primary_main_view")
  return M.main_panel_view()
end

---@deprecated Use `current_main_panel_view` instead.
function M.current_main_view(fallback_view)
  core.deprecation_log("file_context.current_main_view")
  return M.current_main_panel_view(fallback_view)
end

function M.mark_visited(view)
  local path = M.view_file_path(view)
  if path and core.set_visited then core.set_visited(path) end
end

local set_active_view = core.file_context_set_active_view or core.set_active_view
core.file_context_set_active_view = set_active_view
function core.set_active_view(view)
  local result = set_active_view(view)
  M.mark_visited(view)
  return result
end

local function collect_other_dirty_views(node, keep_view, dirty_views, seen)
  if not node then return end
  if node.type == "leaf" then
    for _, view in ipairs(node.views or {}) do
      local owner = view ~= keep_view and core.view_is_dirty and core.view_is_dirty(view) and (view.doc or view.buffer or view)
      if owner and not seen[owner] then
        seen[owner] = true
        dirty_views[#dirty_views + 1] = view
      end
    end
  else
    collect_other_dirty_views(node.a, keep_view, dirty_views, seen)
    collect_other_dirty_views(node.b, keep_view, dirty_views, seen)
  end
end

command.add(nil, {
  ["root:close-all-others"] = function()
    local root = core.root_panel and core.root_panel.root_node
    local dirty_views = {}
    collect_other_dirty_views(root, core.active_view, dirty_views, {})
    core.confirm_close_views(dirty_views, core.root_panel.close_all_views, core.root_panel, core.active_view)
  end,
})

return M
