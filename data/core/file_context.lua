-- Shared helpers for commands that operate on the current file or Pane View.

local core = require "core"
local command = require "core.command"
local common = require "core.common"

local M = core.file_context or {}
core.file_context = M

function M.view_file_path(view)
  if type(view) == "string" and view ~= "" then return common.normalize_path(view) end
  local buffer = view and view.buffer
  local path = buffer and buffer.abs_filename
  if not path and view and type(view.path) == "string" then path = view.path end
  if path and path ~= "" then return common.normalize_path(path) end
end

function M.view_context_path(view)
  local path = M.view_file_path(view)
  if path then return path end
  if view and view.get_context_path then path = view:get_context_path() end
  if type(path) == "string" and path ~= "" then return common.normalize_path(path) end
end

M.excluded_content_views = M.excluded_content_views or setmetatable({}, { __mode = "k" })
function M.exclude_content_view(view)
  if view then M.excluded_content_views[view] = true end
end

function M.is_editor_view(view)
  local Editor = require "core.editor"
  return not not (view and view.extends and view:extends(Editor))
end

function M.is_file_view(view)
  return M.view_file_path(view) ~= nil
end

function M.is_content_view(view)
  if not view or M.excluded_content_views[view] then return false end
  if view == core.global_prompt_bar or view == core.nag_view or view == core.status_bar or view == core.title_bar then return false end
  return M.is_editor_view(view) or view.context == "workspace" or view.context == "session" or M.is_file_view(view)
end

function M.active_file_path()
  return M.view_file_path(core.active_view)
end

local function current_pane_view()
  local panes = core.panes or package.loaded["core.panes"]
  local pane = panes and panes.active()
  return pane and pane.current_view or nil
end

function M.current_file_path(fallback_view)
  return M.active_file_path() or M.view_file_path(current_pane_view()) or M.view_file_path(fallback_view)
end

function M.current_context_path(fallback_view)
  return M.view_context_path(core.active_view)
    or M.view_context_path(current_pane_view())
    or M.view_context_path(fallback_view)
end

function M.current_file_view(fallback_view)
  if M.is_file_view(core.active_view) then return core.active_view end
  local pane_view = current_pane_view()
  return M.is_file_view(pane_view) and pane_view
    or (M.is_file_view(fallback_view) and fallback_view or nil)
end

function M.source_directory(view)
  local panes = core.panes or package.loaded["core.panes"]
  view = panes and panes.owner_for_view(view or core.active_view) or view or core.active_view
  if view then
    if view.get_cwd then
      local cwd = view:get_cwd()
      if cwd and cwd ~= "" then return common.normalize_path(cwd) end
    end
    if type(view.cwd) == "string" and view.cwd ~= "" then
      return common.normalize_path(view.cwd)
    end
    if type(view.current_dir) == "string" and view.current_dir ~= "" then
      return common.normalize_path(view.current_dir)
    end
    local path = M.view_file_path(view)
    if path then return common.dirname(path) end
  end
  local project = core.root_project and core.root_project()
  return project and project.path or nil
end

function M.resolve_path(path, view)
  local base = M.source_directory(view)
  if path == nil or path == "" or path == "." then return base end
  path = common.home_expand(path)
  if common.is_absolute_path and common.is_absolute_path(path) then
    return common.normalize_path(path)
  end
  return common.normalize_path((base and (base .. PATHSEP) or "") .. path)
end

function M.current_content_view(fallback_view)
  if M.is_content_view(core.active_view) then return core.active_view end
  if M.is_content_view(fallback_view) then return fallback_view end
  local view = current_pane_view()
  return M.is_content_view(view) and view or nil
end

function M.mark_visited(view)
  local path = M.view_file_path(view)
  if path and core.set_visited then core.set_visited(path) end
end

local set_active_view = core.file_context_set_active_view or core.set_active_view
core.file_context_set_active_view = set_active_view
function core.set_active_view(view, focus_context)
  focus_context = focus_context or core.focus_change_context(2)
  local result = set_active_view(view, focus_context)
  M.mark_visited(view)
  return result
end

return M
