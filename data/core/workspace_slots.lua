local common = require "core.common"
local storage = require "core.storage"
local slots = {}

function slots.for_project(project)
  local basename = common.basename(project)
  local entries = {}
  for _, key in ipairs(storage.keys("ws")) do
    local prefix = key:sub(1, #basename)
    if prefix == basename or PATHSEP == "\\" and prefix:lower() == basename:lower() then
      local id = tonumber(key:sub(#basename + 1):match("^-(%d+)$"))
      if id then entries[#entries + 1] = {key = key, id = id} end
    end
  end
  table.sort(entries, function(a, b) return a.id < b.id end)
  return entries
end

function slots.count_views(node)
  return type(node) == "table" and type(node.panes) == "table" and #node.panes or 0
end

function slots.matching(project, load_slot)
  local entries = {}
  for _, entry in ipairs(slots.for_project(project)) do
    local workspace = load_slot("ws", entry.key)
    if type(workspace) == "table" and common.path_equals(workspace.path, project) then
      entry.workspace = workspace
      entry.saved_view_count = slots.count_views(workspace.pane_state)
      entries[#entries + 1] = entry
    end
  end
  table.sort(entries, function(a, b)
    if a.saved_view_count ~= b.saved_view_count then return a.saved_view_count > b.saved_view_count end
    return a.id < b.id
  end)
  return entries
end

return slots
