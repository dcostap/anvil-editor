-- mod-version:3
-- Project Paths: the commands and changes behind the Project Paths Dialog and the File Tree.
-- Each change saves the Workspace at once and refreshes the File Tree.

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local project_paths = require "core.project_paths"
local panes = require "core.panes"

local M = {}

local ROLE_LABELS = {
  root = "Root",
  external = "External",
  vendored = "Vendored",
}

function M.role_label(role)
  return ROLE_LABELS[role] or tostring(role or "")
end

local function normalize(path)
  path = common.home_expand(path)
  return common.normalize_path(system.absolute_path(path) or path)
end

local function root_path()
  local project = core.root_project and core.root_project()
  return project and project.path
end

local function find_entry(id_or_path)
  local key = type(id_or_path) == "string" and common.path_compare_key(normalize(id_or_path))
  for _, entry in ipairs(project_paths.entries()) do
    if entry.id == id_or_path or (key and common.path_compare_key(entry.path) == key) then return entry end
  end
end
M.find_entry = find_entry

---True when `path` is the Root Project's folder or inside it.
function M.inside_root(path)
  local root = root_path()
  return root ~= nil and (common.path_equals(path, root) or common.path_belongs_to(path, root))
end

---The roles that a folder can have. A folder inside the Root Project can only be Vendored.
function M.roles_for(path)
  if M.inside_root(path) then return { "vendored" } end
  return { "external", "vendored" }
end

local function allows_role(path, role)
  for _, allowed in ipairs(M.roles_for(path)) do
    if allowed == role then return true end
  end
  return false
end

local function changed()
  if core.save_workspace then
    core.save_workspace()
  else
    core.log_quiet("Project Paths: Workspace save is unavailable; the change saves on exit")
  end
  local ok, filetree = pcall(require, "plugins.filetree")
  if ok and filetree and filetree.refresh_preserving_selection_paths then
    filetree:refresh_preserving_selection_paths(true)
  end
end

---Whether `label` can name the entry `id`. Returns false and a message when it cannot.
function M.check_label(label, id)
  if not project_paths.valid_label(label) then
    return false, "Use one folder name, without / \\ or :"
  end
  local lower = label:lower()
  for _, entry in ipairs(project_paths.entries({ include_root = false })) do
    if entry.id ~= id and (entry.label or ""):lower() == lower then
      return false, "Another Project Path has this label"
    end
  end
  return true
end

---Add a folder as a Project Path. Returns its entry, or nil and a message.
---A folder that is already a Project Path keeps its entry.
---@param path string
---@param options? { role: string?, label: string? }
function M.add(path, options)
  options = options or {}
  if type(path) ~= "string" or path == "" then return nil, "No folder" end
  path = normalize(path)
  local info = system.get_file_info(path)
  if not (info and info.type == "dir") then return nil, "Not a folder: " .. common.home_encode(path) end
  local root = root_path()
  if root and common.path_equals(path, root) then return nil, "This folder is the Root Project" end
  local existing = find_entry(path)
  if existing then return existing end
  local role = options.role or M.roles_for(path)[1]
  if not allows_role(path, role) then return nil, "A folder in the Root Project can only be Vendored" end
  local label = options.label or common.basename(path)
  if not M.check_label(label) then
    -- A taken folder name gets a number, as the File Tree shows it.
    local base, n = label, 2
    repeat
      label = base .. "-" .. n
      n = n + 1
    until M.check_label(label)
  end
  local entry = project_paths.add_external({ path = path, label = label, role = role })
  if not entry then return nil, "Could not add " .. common.home_encode(path) end
  core.log_quiet("Project Paths: added %s as %s, label %s", common.home_encode(path), role, label)
  changed()
  return find_entry(path) or entry
end

---Remove a Project Path. Its folder stays on disk.
function M.remove(id)
  local entry = find_entry(id)
  if not entry or entry.role == "root" then return false end
  if not project_paths.remove_entry(entry.id) then return false end
  core.log_quiet("Project Paths: removed %s", common.home_encode(entry.path))
  changed()
  return true
end

---Change a Project Path's label. Returns false and a message when the label cannot name it.
function M.set_label(id, label)
  local entry = find_entry(id)
  if not entry or entry.role == "root" then return false, "The Root Project's label is its folder name" end
  if entry.label == label then return true end
  local ok, message = M.check_label(label, entry.id)
  if not ok then return false, message end
  if not project_paths.set_label(entry.id, label) then return false, "Could not change the label" end
  core.log_quiet("Project Paths: label of %s is now %s", common.home_encode(entry.path), label)
  changed()
  return true
end

---Change a Project Path's role.
function M.set_role(id, role)
  local entry = find_entry(id)
  if not entry or entry.role == "root" then return false end
  if entry.role == role then return true end
  if not allows_role(entry.path, role) then return false end
  if not project_paths.change_role(entry.id, role) then return false end
  core.log_quiet("Project Paths: role of %s is now %s", common.home_encode(entry.path), role)
  changed()
  return true
end

---Open the Project Paths Dialog.
---@param options? { select: string?, rename: boolean? } `select` is a path or an entry ID to select.
---`rename` puts keyboard focus in its label.
function M.open(options)
  return require("plugins.project_paths.dialog").open(options)
end

---Ask for a folder with the File Picker, add it, and show it in the Dialog with its label ready to change.
local function pick_folder()
  local reopen = require("core.ui.dialog").current() ~= nil
  local context = command.get_invocation_context() or {}
  local source_view = context.source_view or core.active_view
  return require("plugins.file_picker").open {
    select = "folder",
    label = "Add Project Path",
    source_view = source_view,
    source_pane = panes.find(context.source_pane) or panes.pane_for_view(source_view) or panes.active(),
    submit = function(path) command.perform("project_paths:add", path) end,
    cancel = function() if reopen then M.open() end end,
  }
end

command.add(nil, {
  ["project_paths:manage"] = command.palette(function()
    M.open()
  end, {
    keywords = { "external", "vendored", "folders", "directories", "roots" },
  }),
  ["project_paths:add"] = command.palette(function(path)
    if not path then
      local open_dialog = require("core.ui.dialog").current()
      if open_dialog then open_dialog:close() end
      return pick_folder()
    end
    local entry, message = M.add(path)
    if not entry then
      core.error("Project Paths: %s", message)
      return false
    end
    M.open({ select = entry.path, rename = entry.role ~= "root" })
    return true
  end, {
    keywords = { "external", "vendored", "folder", "directory", "attach" },
  }),
})

return M
