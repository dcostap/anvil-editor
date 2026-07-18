-- Shared helpers for commands that operate on the current file or Pane View.

local core = require "core"
local command = require "core.command"
local common = require "core.common"

local M = core.file_context or {}
core.file_context = M

function M.view_file_path(view)
  if type(view) == "string" and view ~= "" then return common.normalize_path(view) end
  local doc = view and view.doc
  local path = doc and doc.abs_filename
  if not path and view and type(view.path) == "string" then path = view.path end
  if path and path ~= "" then return common.normalize_path(path) end
end

M.excluded_content_views = M.excluded_content_views or setmetatable({}, { __mode = "k" })
M.editor_views = M.editor_views or setmetatable({}, { __mode = "k" })

function M.exclude_content_view(view)
  if view then M.excluded_content_views[view] = true end
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

function M.is_content_view(view)
  if not view or M.excluded_content_views[view] then return false end
  if view == core.global_prompt_bar or view == core.nag_view or view == core.status_bar or view == core.title_bar then return false end
  return M.is_editor_view(view) or view.context == "workspace" or view.context == "session" or M.is_file_view(view)
end

function M.active_file_path()
  return M.view_file_path(core.active_view)
end

function M.left_pane_file_view()
  local panes = core.panes or package.loaded["core.panes"]
  local view = panes and panes.selected_view("left")
  if M.is_file_view(view) then return view end
end

function M.left_pane_file_path()
  return M.view_file_path(M.left_pane_file_view())
end

function M.current_file_path(fallback_view)
  return M.active_file_path() or M.left_pane_file_path() or M.view_file_path(fallback_view)
end

function M.current_file_view(fallback_view)
  if M.is_file_view(core.active_view) then return core.active_view end
  return M.left_pane_file_view() or (M.is_file_view(fallback_view) and fallback_view or nil)
end

function M.selected_left_content_view()
  local panes = core.panes or package.loaded["core.panes"]
  local view = panes and panes.selected_view("left")
  if M.is_content_view(view) then return view end
end

function M.current_content_view(fallback_view)
  if M.is_content_view(core.active_view) then return core.active_view end
  if M.is_content_view(fallback_view) then return fallback_view end
  return M.selected_left_content_view()
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

local function collect_other_dirty_docs(node, keep_view, dirty_docs, seen)
  if not node then return end
  if node.type == "leaf" then
    for _, view in ipairs(node.views or {}) do
      local doc = view ~= keep_view and view.doc
      if doc and not seen[doc] and doc:is_dirty() then
        seen[doc] = true
        dirty_docs[#dirty_docs + 1] = doc
      end
    end
  else
    collect_other_dirty_docs(node.a, keep_view, dirty_docs, seen)
    collect_other_dirty_docs(node.b, keep_view, dirty_docs, seen)
  end
end

command.add(nil, {
  ["root:close-all-others"] = function()
    local root = core.root_panel and core.root_panel.root_node
    local dirty_docs = {}
    collect_other_dirty_docs(root, core.active_view, dirty_docs, {})
    core.confirm_close_docs(dirty_docs, core.root_panel.close_all_views, core.root_panel, core.active_view)
  end,
})

return M
