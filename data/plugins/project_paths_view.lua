-- mod-version:3
-- Project Paths management view and commands.

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local Doc = require "core.doc"
local DocView = require "core.docview"
local project_paths = require "core.project_paths"

local ProjectPathsView = DocView:extend()
ProjectPathsView.context = "application"

local view

local ROLE_LABELS = {
  root = "Root",
  external = "External",
  vendored = "Vendored",
  excluded = "Excluded",
}

local ROLE_FROM_LABEL = {
  root = "root",
  external = "external",
  vendored = "vendored",
  excluded = "excluded",
}

local STORAGE_LABELS = {
  implicit = "automatic",
  project = "project config",
  workspace = "local only",
}

local function path_key(path)
  return common.path_compare_key(path) or tostring(path)
end

local function root_path()
  local project = core.root_project and core.root_project()
  return project and project.path
end

local function project_file_path()
  local root = root_path()
  return root and (root .. PATHSEP .. ".anvil_project.lua")
end

local function quote(value)
  return string.format("%q", tostring(value or ""))
end

local function relative_or_home(path)
  local root = root_path()
  if root and (common.path_equals(path, root) or common.path_belongs_to(path, root)) then
    return common.relative_path(root, path)
  end
  return common.home_encode(path)
end

local function storage_label(entry)
  return STORAGE_LABELS[entry.source] or tostring(entry.source or "")
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

local function set_doc_lines(doc, lines)
  doc:reset()
  doc.lines = #lines > 0 and lines or { "\n" }
  doc.clean_lines = {}
  doc.highlighter:soft_reset()
  doc:clear_undo_redo()
  doc:clean()
  doc:set_selection(1, 1)
end

local function serialize_project_config_block()
  local state = project_paths.save_project_state()
  local by_role = { external = {}, vendored = {}, excluded = {} }
  for _, entry in ipairs(state.entries or {}) do
    if by_role[entry.role] then by_role[entry.role][#by_role[entry.role] + 1] = entry end
  end

  local lines = {
    "-- ANVIL PROJECT PATHS BEGIN\n",
    "local project_paths = require \"core.project_paths\"\n",
    "project_paths.configure_project {\n",
  }
  for _, role in ipairs({ "external", "vendored", "excluded" }) do
    lines[#lines + 1] = "  " .. role .. " = {\n"
    for _, entry in ipairs(by_role[role]) do
      local pieces = { "path = " .. quote(entry.path) }
      if entry.label and entry.label ~= "" then pieces[#pieces + 1] = "label = " .. quote(entry.label) end
      for _, field in ipairs({ "browsable", "searchable", "grep", "symbols", "usages", "autocomplete", "rank_penalty", "filetree_style" }) do
        if entry[field] ~= nil then
          local value = entry[field]
          local text = type(value) == "string" and quote(value) or tostring(value)
          pieces[#pieces + 1] = field .. " = " .. text
        end
      end
      lines[#lines + 1] = "    { " .. table.concat(pieces, ", ") .. " },\n"
    end
    lines[#lines + 1] = "  },\n"
  end
  lines[#lines + 1] = "}\n"
  lines[#lines + 1] = "-- ANVIL PROJECT PATHS END\n"
  return table.concat(lines)
end

local function read_file(path)
  local fp = io.open(path, "rb")
  if not fp then return "" end
  local text = fp:read("*a") or ""
  fp:close()
  return text
end

local function write_file(path, text)
  local fp, err = io.open(path, "wb")
  if not fp then return false, err end
  fp:write(text)
  fp:close()
  return true
end

local function write_project_config()
  local path = project_file_path()
  if not path then return false, "no Root Project" end
  local text = read_file(path)
  local block = serialize_project_config_block()
  local begin = "%-%- ANVIL PROJECT PATHS BEGIN"
  local finish = "%-%- ANVIL PROJECT PATHS END\n?"
  local pattern = begin .. ".-" .. finish
  if text:find(begin) then
    text = text:gsub(pattern, block, 1)
  else
    if text ~= "" and text:sub(-1) ~= "\n" then text = text .. "\n" end
    text = text .. (text ~= "" and "\n" or "") .. block
  end
  return write_file(path, text)
end

local function refresh_surfaces()
  if view then view:refresh() end
  local ok, filetree = pcall(require, "plugins.filetree")
  if ok and filetree and filetree.refresh_preserving_selection_paths then
    filetree:refresh_preserving_selection_paths(true)
  end
end

local function persist_workspace_if_needed(source)
  if source ~= "workspace" then return true end
  if core.save_workspace then
    core.save_workspace()
  else
    core.log_quiet("Project Paths: workspace save hook is unavailable; local Project Path will persist on normal exit")
  end
  return true
end

local function persist_sources(...)
  local needs_project = false
  local needs_workspace = false
  for i = 1, select("#", ...) do
    local source = select(i, ...)
    needs_project = needs_project or source == "project"
    needs_workspace = needs_workspace or source == "workspace"
  end
  if needs_project then
    local ok, err = write_project_config()
    if not ok then core.error("Project Paths: could not update .anvil_project.lua: %s", tostring(err)); return false end
  end
  if needs_workspace then persist_workspace_if_needed("workspace") end
  return true
end

local function persist_project_if_needed(source)
  return persist_sources(source)
end

local function normalize_role_text(text)
  text = tostring(text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  return ROLE_FROM_LABEL[text] or text
end

local function normalize_storage_text(text)
  text = tostring(text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if text == "project" or text == "project config" then return "project" end
  if text == "local" or text == "local only" or text == "workspace" then return "workspace" end
  return nil
end

local function remove_entry(id_or_path)
  local entry = find_effective_entry(id_or_path)
  if not entry then return false end
  local source = entry.source
  if not project_paths.remove_entry(entry.id) then return false end
  persist_sources(source)
  refresh_surfaces()
  return true
end

local function add_entry(path, role, source, label)
  if type(path) ~= "string" or path == "" then core.error("Project Paths: missing path"); return nil end
  path = common.normalize_path(system.absolute_path(common.home_expand(path)) or common.home_expand(path))
  local info = system.get_file_info(path)
  if not (info and info.type == "dir") then core.error("Project Paths: not a directory: %s", path); return nil end
  role = role or "external"
  source = source or "workspace"
  label = label and label ~= "" and label or common.basename(path)
  local existing = find_effective_entry(path)
  local old_source = existing and existing.source
  local entry = project_paths.add_external({ path = path, label = label, role = role }, { source = source })
  if entry and persist_sources(old_source, source) then
    core.log("Project Paths: marked %s as %s", common.home_encode(path), role_label(role))
    refresh_surfaces()
    return entry
  end
end

local function selected_filetree_directory()
  local ok, filetree = pcall(require, "plugins.filetree")
  if not (ok and core.active_view == filetree) then return nil, "select a folder in the File Tree first" end
  local line = filetree.doc:get_selection(true)
  local entry, err = filetree:entry_for_line(line)
  if not entry then return nil, err or "no File Tree entry selected" end
  if entry.type ~= "dir" then return nil, "selected File Tree row is not a folder" end
  return entry.abs
end

local function prompt(label, options)
  core.command_view:enter(label, options)
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

local function prompt_storage(callback)
  local choices = {
    { text = "Local only", source = "workspace" },
    { text = "Project config", source = "project" },
  }
  local default_text = choices[1].text
  prompt("Project Path Storage", {
    text = default_text,
    suggest = suggest_choices(choices, default_text),
    submit = function(text, item) callback((item and item.source) or normalize_storage_text(text) or "workspace") end,
  })
end

local function prompt_role(path, roles, callback)
  local choices = {}
  for _, role in ipairs(roles or { "external", "vendored", "excluded" }) do
    choices[#choices + 1] = { text = role_label(role), role = role }
  end
  local default_text = choices[1] and choices[1].text or "External"
  prompt("Project Path Role", {
    text = default_text,
    suggest = suggest_choices(choices, default_text),
    submit = function(text, item)
      local role = (item and item.role) or normalize_role_text(text)
      if not role or role == "root" then core.error("Project Paths: unknown role: %s", tostring(text)); return end
      prompt_label(path, function(label)
        prompt_storage(function(source)
          callback(role, label, source)
        end)
      end)
    end,
  })
end

function ProjectPathsView:new()
  ProjectPathsView.super.new(self, Doc())
  self.entries_by_line = {}
  self:refresh()
end

function ProjectPathsView:get_name()
  return "Project Paths"
end

function ProjectPathsView:refresh()
  local lines = {
    string.format("%-18s %-10s %-42s %s\n", "Alias", "Role", "Path", "Storage"),
    "────────────────────────────────────────────────────────────────────────────────\n",
  }
  self.entries_by_line = {}
  for _, entry in ipairs(project_paths.entries()) do
    local line = string.format(
      "%-18s %-10s %-42s %s\n",
      entry.label or "",
      role_label(entry.role),
      relative_or_home(entry.path),
      storage_label(entry)
    )
    lines[#lines + 1] = line
    self.entries_by_line[#lines] = entry
  end
  set_doc_lines(self.doc, lines)
end

function ProjectPathsView:selected_entry()
  local line = self.doc:get_selection(true)
  return self.entries_by_line[line]
end

function ProjectPathsView:open_selected()
  local entry = self:selected_entry()
  if not entry then return end
  command.perform("filetree:focus-file", entry.path)
end

function ProjectPathsView:rename_selected(label)
  local entry = self:selected_entry()
  if not entry or entry.role == "root" then return false end
  if not project_paths.set_label(entry.id, label) then return false end
  persist_project_if_needed(entry.source)
  refresh_surfaces()
  return true
end

function ProjectPathsView:change_selected_role(role)
  local entry = self:selected_entry()
  if not entry or entry.role == "root" then return false end
  if not project_paths.change_role(entry.id, role) then return false end
  persist_project_if_needed(entry.source)
  refresh_surfaces()
  return true
end

function ProjectPathsView:remove_selected()
  local entry = self:selected_entry()
  if not entry or entry.role == "root" then return false end
  return remove_entry(entry.id)
end

function ProjectPathsView:change_selected_storage(source)
  local entry = self:selected_entry()
  if not entry or entry.role == "root" then return false end
  local old_source = entry.source
  if not project_paths.change_storage(entry.id, source) then return false end
  persist_sources(old_source, source)
  refresh_surfaces()
  return true
end

local function open_view()
  if not view then view = ProjectPathsView() end
  view:refresh()
  local node = core.root_panel:get_active_node_default()
  if node then node:add_view(view) else core.set_active_view(view) end
  return view
end

local function prompt_add_directory(path, default_role, default_source)
  if path then
    path = common.normalize_path(system.absolute_path(common.home_expand(path)) or common.home_expand(path))
  end
  local function with_path(target)
    if not target or target == "" then return end
    target = common.normalize_path(system.absolute_path(common.home_expand(target)) or common.home_expand(target))
    local roles = default_role and { default_role } or { "external", "vendored", "excluded" }
    if default_role and default_source then
      prompt_label(target, function(label) add_entry(target, default_role, default_source, label) end)
    elseif default_role then
      prompt_label(target, function(label)
        prompt_storage(function(source) add_entry(target, default_role, source, label) end)
      end)
    else
      prompt_role(target, roles, function(role, label, source) add_entry(target, role, source, label) end)
    end
  end
  if path then return with_path(path) end
  prompt("Project Directory Path", {
    show_suggestions = false,
    submit = with_path,
  })
end

command.add(nil, {
  ["project-paths:manage"] = function()
    open_view()
  end,
  ["project-paths:add-external-directory"] = function(path)
    prompt_add_directory(path, "external")
  end,
  ["project-paths:add-external-directory-local"] = function(path)
    if path then return add_entry(path, "external", "workspace") end
    prompt_add_directory(nil, "external", "workspace")
  end,
  ["project-paths:add-external-directory-to-project-config"] = function(path)
    if path then return add_entry(path, "external", "project") end
    prompt_add_directory(nil, "external", "project")
  end,
  ["project-paths:add-excluded-project-path"] = function(path)
    if path then return add_entry(path, "excluded", "workspace") end
    prompt_add_directory(nil, "excluded")
  end,
  ["project-paths:remove-excluded-project-path"] = function(path)
    if path then return remove_entry(path) end
    if view then return view:remove_selected() end
  end,
  ["project-paths:mark-selected-folder"] = function()
    local path, err = selected_filetree_directory()
    if not path then core.error("Project Paths: %s", tostring(err)); return end
    local resolved = project_paths.resolve(path)
    if resolved and resolved.entry and not common.path_equals(resolved.entry.path, root_path()) and common.path_equals(resolved.entry.path, path) then
      open_view()
      return
    end
    local root = root_path()
    local roles = root and (common.path_equals(path, root) or common.path_belongs_to(path, root))
      and { "vendored", "excluded" }
      or { "external", "vendored", "excluded" }
    prompt_role(path, roles, function(role, label, source) add_entry(path, role, source, label) end)
  end,
})

command.add(function() return core.active_view == view end, {
  ["project-paths:open"] = function() view:open_selected() end,
  ["project-paths:remove-entry"] = function() view:remove_selected() end,
  ["project-paths:rename-label"] = function()
    local entry = view:selected_entry()
    if not entry or entry.role == "root" then return end
    prompt_label(entry.path, function(label) view:rename_selected(label) end)
  end,
  ["project-paths:change-role"] = function()
    local entry = view:selected_entry()
    if not entry or entry.role == "root" then return end
    prompt_role(entry.path, { "external", "vendored", "excluded" }, function(role)
      view:change_selected_role(role)
    end)
  end,
  ["project-paths:change-storage"] = function()
    prompt_storage(function(source) view:change_selected_storage(source) end)
  end,
})

local M = {
  view_class = ProjectPathsView,
  open_view = open_view,
  add_entry = add_entry,
  write_project_config = write_project_config,
  _test = {
    serialize_project_config_block = serialize_project_config_block,
    write_project_config = write_project_config,
    open_view = open_view,
  },
}

return M
