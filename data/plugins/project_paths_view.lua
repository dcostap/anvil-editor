-- mod-version:3
-- Project Paths management view and commands.

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local view_icons = require "core.view_icons"
local project_paths = require "core.project_paths"
local panes = require "core.panes"

local ProjectPathsView = TextView:extend()
ProjectPathsView.view_icon = view_icons.register("project_paths", view_icons.ui("l"))
ProjectPathsView.context = "application"

local view

local ROLE_LABELS = {
  root = "Root",
  external = "External",
  vendored = "Vendored",
}

local ROLE_FROM_LABEL = {
  root = "root",
  external = "external",
  vendored = "vendored",
}

local function path_key(path)
  return common.path_compare_key(path) or tostring(path)
end

local function root_path()
  local project = core.root_project and core.root_project()
  return project and project.path
end

local function relative_or_home(path)
  local root = root_path()
  if root and (common.path_equals(path, root) or common.path_belongs_to(path, root)) then
    return common.relative_path(root, path)
  end
  return common.home_encode(path)
end

local function role_label(role)
  return ROLE_LABELS[role] or tostring(role or "")
end

local function find_effective_entry(id_or_path)
  local normalized_path = type(id_or_path) == "string"
    and common.normalize_path(system.absolute_path(common.home_expand(id_or_path)) or common.home_expand(id_or_path))
  local key = normalized_path and path_key(normalized_path)
  for _, entry in ipairs(project_paths.entries({ include_root = false })) do
    if entry.id == id_or_path or (key and path_key(entry.path) == key) then return entry end
  end
end

local function set_buffer_lines(buffer, lines)
  buffer:reset()
  buffer.lines = #lines > 0 and lines or { "\n" }
  buffer.clean_lines = {}
  buffer.highlighter:soft_reset()
  buffer:clear_undo_redo()
  buffer:clean()
  buffer:set_selection(1, 1)
end

local function refresh_surfaces()
  if view then view:refresh() end
  local ok, filetree = pcall(require, "plugins.filetree")
  if ok and filetree and filetree.refresh_preserving_selection_paths then
    filetree:refresh_preserving_selection_paths(true)
  end
end

local function persist_workspace()
  if core.save_workspace then
    core.save_workspace()
  else
    core.log_quiet("Project Paths: workspace save hook is unavailable; local Project Path will persist on normal exit")
  end
  return true
end

local function normalize_role_text(text)
  text = tostring(text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  return ROLE_FROM_LABEL[text] or text
end

local function remove_entry(id_or_path)
  local entry = find_effective_entry(id_or_path)
  if not entry then return false end
  if not project_paths.remove_entry(entry.id) then return false end
  persist_workspace()
  refresh_surfaces()
  return true
end

local function set_label(id_or_path, label)
  local entry = find_effective_entry(id_or_path)
  if not entry or entry.role == "root" then return false end
  if not project_paths.valid_label(label) then
    core.error("Project Paths: labels must be one path component")
    return false
  end
  if not project_paths.set_label(entry.id, label) then return false end
  persist_workspace()
  refresh_surfaces()
  return true
end

local function add_entry(path, role, label)
  if type(path) ~= "string" or path == "" then core.error("Project Paths: missing path"); return nil end
  path = common.normalize_path(system.absolute_path(common.home_expand(path)) or common.home_expand(path))
  local info = system.get_file_info(path)
  if not (info and info.type == "dir") then core.error("Project Paths: not a directory: %s", path); return nil end
  role = role or "external"
  label = label and label ~= "" and label or common.basename(path)
  if not project_paths.valid_label(label) then
    core.error("Project Paths: labels must be one path component")
    return nil
  end
  local entry = project_paths.add_external({ path = path, label = label, role = role })
  if entry and persist_workspace() then
    core.log("Project Paths: marked %s as %s", common.home_encode(path), role_label(role))
    refresh_surfaces()
    return entry
  end
end

local function selected_filetree_directory()
  local ok, filetree = pcall(require, "plugins.filetree")
  local view = ok and core.active_view
  if not (view and view.extends and view:extends(filetree.View)) then
    return nil, "select a folder in the File Tree first"
  end
  local line = view.buffer:get_selection(true)
  local entry, err = view:entry_for_line(line)
  if not entry then return nil, err or "no File Tree entry selected" end
  if entry.type ~= "dir" then return nil, "selected File Tree row is not a folder" end
  return entry.abs
end

local function prompt(label, options)
  core.global_prompt_bar:enter(label, options)
end

local function prompt_label(path, callback)
  prompt("Project Path Label", {
    text = common.basename(path),
    select_text = true,
    show_suggestions = false,
    submit = function(text) callback(text ~= "" and text or common.basename(path)) end,
  })
end

local function suggest_choices(choices, default_text)
  local default_lower = tostring(default_text or ""):lower()
  return function(text)
    local lower = tostring(text or ""):lower()
    if lower == "" or lower == default_lower then return choices end
    local result = {}
    for _, item in ipairs(choices) do
      if item.text:lower():find(lower, 1, true) then result[#result + 1] = item end
    end
    return result
  end
end

local function prompt_role(path, roles, callback)
  local choices = {}
  for _, role in ipairs(roles or { "external", "vendored" }) do
    choices[#choices + 1] = { text = role_label(role), role = role }
  end
  local default_text = choices[1] and choices[1].text or "External"
  prompt("Project Path Role", {
    text = default_text,
    suggest = suggest_choices(choices, default_text),
    submit = function(text, item)
      local role = (item and item.role) or normalize_role_text(text)
      if not role or role == "root" then core.error("Project Paths: unknown role: %s", tostring(text)); return end
      prompt_label(path, function(label) callback(role, label) end)
    end,
  })
end

local function removable_choices(text)
  local query = tostring(text or ""):lower()
  local choices = {}
  for _, entry in ipairs(project_paths.entries({ include_root = false })) do
    if entry.role == "external" or entry.role == "vendored" then
      local path = relative_or_home(entry.path)
      local search_text = table.concat({ entry.label or "", role_label(entry.role), path }, " "):lower()
      if query == "" or search_text:find(query, 1, true) then
        choices[#choices + 1] = {
          text = entry.label,
          info = role_label(entry.role) .. " — " .. path,
          entry_id = entry.id,
          role = entry.role,
        }
      end
    end
  end
  table.sort(choices, function(a, b) return a.text:lower() < b.text:lower() end)
  return choices
end

local function prompt_remove_directory()
  prompt("Remove Project Directory", {
    text = "",
    suggest = removable_choices,
    submit = function(_, item)
      if not (item and item.entry_id) then
        core.error("Project Paths: select a directory to remove")
        return
      end
      local entry = find_effective_entry(item.entry_id)
      if not entry then return end
      if remove_entry(entry.id) then
        core.log("Project Paths: removed %s", entry.label or common.home_encode(entry.path))
      end
    end,
  })
end

function ProjectPathsView:new()
  ProjectPathsView.super.new(self, Buffer())
  self:set_wrapping_enabled(false)
  self.buffer.read_only = true
  self.buffer.read_only_reason = "Project Paths is read-only"
  self.entries_by_line = {}
  self:refresh()
end

function ProjectPathsView:get_name()
  return "Project Paths"
end

function ProjectPathsView:refresh()
  local lines = {
    string.format("%-18s %-10s %s\n", "Alias", "Role", "Path"),
    "──────────────────────────────────────────────────────────────────────\n",
  }
  self.entries_by_line = {}
  for _, entry in ipairs(project_paths.entries()) do
    local line = string.format(
      "%-18s %-10s %s\n",
      entry.label or "",
      role_label(entry.role),
      relative_or_home(entry.path)
    )
    lines[#lines + 1] = line
    self.entries_by_line[#lines] = entry
  end
  set_buffer_lines(self.buffer, lines)
end

function ProjectPathsView:selected_entry()
  local line = self.buffer:get_selection(true)
  return self.entries_by_line[line]
end

function ProjectPathsView:open_selected()
  local entry = self:selected_entry()
  if not entry then return end
  command.perform("filetree:open_at_choose_path", entry.path)
end

function ProjectPathsView:rename_selected(label)
  local entry = self:selected_entry()
  if not entry or entry.role == "root" then return false end
  return set_label(entry.id, label)
end

function ProjectPathsView:change_selected_role(role)
  local entry = self:selected_entry()
  if not entry or entry.role == "root" then return false end
  if not project_paths.change_role(entry.id, role) then return false end
  persist_workspace()
  refresh_surfaces()
  return true
end

function ProjectPathsView:remove_selected()
  local entry = self:selected_entry()
  if not entry or entry.role == "root" then return false end
  return remove_entry(entry.id)
end

local function open_view()
  if not view then view = ProjectPathsView() end
  view:refresh()
  local pane = panes.pane_for_view(view)
  if pane then
    panes.present(view, { pane = pane, focus = true })
  else
    panes.place(function() return view end, {
      pane = panes.active(),
      placement = "current",
      focus = true,
      reason = "project-paths",
    })
  end
  return view
end

local function prompt_add_directory(path, default_role)
  if path then
    path = common.normalize_path(system.absolute_path(common.home_expand(path)) or common.home_expand(path))
  end
  local function with_path(target)
    if not target or target == "" then return end
    target = common.normalize_path(system.absolute_path(common.home_expand(target)) or common.home_expand(target))
    local roles = default_role and { default_role } or { "external", "vendored" }
    if default_role then
      prompt_label(target, function(label) add_entry(target, default_role, label) end)
    else
      prompt_role(target, roles, function(role, label) add_entry(target, role, label) end)
    end
  end
  if path then return with_path(path) end
  local context = command.get_invocation_context() or {}
  local source_view = context.source_view or core.active_view
  local source_pane = panes.find(context.source_pane) or panes.pane_for_view(source_view) or panes.active()
  return require("plugins.file_picker").open {
    select = "folder",
    label = "Add External Project Directory",
    source_view = source_view,
    source_pane = source_pane,
    submit = with_path,
  }
end

command.add(nil, {
  ["project_paths:open"] = command.palette(function()
    open_view()
  end, {
    keywords = { "external", "vendored", "folders", "directories" },
    opens_view = true,
  }),
  ["project_paths:add_external_directory"] = command.palette(function(path)
    prompt_add_directory(path, "external")
  end, {
    keywords = { "folder", "path", "attach" },
  }),
  ["project_paths:remove_directory"] = command.palette(function()
    prompt_remove_directory()
  end, {
    keywords = { "external", "vendored", "folders", "list" },
  }),
  ["project_paths:mark_selected_folder"] = command.palette(function()
    local path, err = selected_filetree_directory()
    if not path then core.error("Project Paths: %s", tostring(err)); return end
    local resolved = project_paths.resolve(path)
    if resolved and resolved.entry and not common.path_equals(resolved.entry.path, root_path()) and common.path_equals(resolved.entry.path, path) then
      open_view()
      return
    end
    local root = root_path()
    local roles = root and (common.path_equals(path, root) or common.path_belongs_to(path, root))
      and { "vendored" }
      or { "external", "vendored" }
    prompt_role(path, roles, function(role, label) add_entry(path, role, label) end)
  end),
})

command.add(function() return core.active_view == view end, {
  ["project_paths:open_selected"] = function() view:open_selected() end,
})

local M = {
  view_class = ProjectPathsView,
  open_view = open_view,
  add_entry = add_entry,
  remove_entry = remove_entry,
  set_label = set_label,
  _test = {
    open_view = open_view,
  },
}

return M
