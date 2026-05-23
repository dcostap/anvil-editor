-- mod-version:3
-- Shared helpers for commands that operate on the current file/view.

local core = require "core"
local command = require "core.command"
local common = require "core.common"

local M = {}

function M.view_file_path(view)
  if type(view) == "string" and view ~= "" then
    return common.normalize_path(view)
  end

  local doc = view and view.doc
  local path = doc and doc.abs_filename
  if not path and view and type(view.path) == "string" then
    path = view.path
  end
  if path and path ~= "" then return common.normalize_path(path) end
end

local excluded_main_views = setmetatable({}, { __mode = "k" })

function M.exclude_main_view(view)
  if view then excluded_main_views[view] = true end
end

function M.is_file_view(view)
  return M.view_file_path(view) ~= nil
end

function M.is_main_view(view)
  if not view or excluded_main_views[view] then return false end
  if view == core.command_view or view == core.nag_view or view == core.status_view or view == core.title_view then return false end
  return view.context == "session" or M.is_file_view(view)
end

function M.active_file_path()
  return M.view_file_path(core.active_view)
end

function M.primary_file_view()
  local node = core.root_view and core.root_view:get_primary_node()
  local view = node and node.active_view
  if M.is_file_view(view) then return view end
end

function M.primary_file_path()
  return M.view_file_path(M.primary_file_view())
end

function M.current_file_path(fallback_view)
  return M.active_file_path()
      or M.primary_file_path()
      or M.view_file_path(fallback_view)
end

function M.current_file_view(fallback_view)
  if M.is_file_view(core.active_view) then return core.active_view end
  return M.primary_file_view()
      or (M.is_file_view(fallback_view) and fallback_view or nil)
end

function M.primary_main_view()
  local node = core.root_view and core.root_view:get_primary_node()
  local view = node and node.active_view
  if M.is_main_view(view) then return view end
end

function M.current_main_view(fallback_view)
  if M.is_main_view(core.active_view) then return core.active_view end
  if M.is_main_view(fallback_view) then return fallback_view end
  return M.primary_main_view()
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

local function closable_other_view(view, active_view)
  if view == active_view then return false end
  return M.is_main_view(view)
end

local function collect_other_dirty_docs(node, dirty_docs, seen)
  if not node then return end
  if node.type == "leaf" then
    for _, view in ipairs(node.views or {}) do
      if closable_other_view(view, node.active_view) then
        local doc = view.doc
        if doc and not seen[doc] and doc:is_dirty() then
          seen[doc] = true
          dirty_docs[#dirty_docs + 1] = doc
        end
      end
    end
  else
    collect_other_dirty_docs(node.a, dirty_docs, seen)
    collect_other_dirty_docs(node.b, dirty_docs, seen)
  end
end

local function close_other_views(node)
  if not node then return end
  if node.type == "leaf" then
    local i = 1
    while i <= #(node.views or {}) do
      if closable_other_view(node.views[i], node.active_view) then
        table.remove(node.views, i)
      else
        i = i + 1
      end
    end
    node.tab_offset = 1
  else
    close_other_views(node.a)
    close_other_views(node.b)
  end
end

command.add(nil, {
  ["root:close-all-others"] = function()
    local root = core.root_view and core.root_view.root_node
    local dirty_docs = {}
    collect_other_dirty_docs(root, dirty_docs, {})
    core.confirm_close_docs(dirty_docs, function()
      close_other_views(root)
    end)
  end,
})

return M
