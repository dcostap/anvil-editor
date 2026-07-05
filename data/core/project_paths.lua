local core = require "core"
local common = require "core.common"

local project_paths = {}

local project_entries = {}
local workspace_entries = {}
local project_config_snapshot
local generation = 0

local ROLE_ORDER = {
  root = 0,
  external = 1,
  vendored = 2,
  excluded = 3,
}

local SOURCE_ORDER = {
  implicit = 0,
  project = 1,
  workspace = 2,
}

local KIND_FIELD = {
  files = "searchable",
  file = "searchable",
  search = "searchable",
  fuzzy = "searchable",
  grep = "grep",
  symbols = "symbols",
  symbol = "symbols",
  usages = "usages",
  usage = "usages",
  autocomplete = "autocomplete",
  browsable = "browsable",
  filetree = "browsable",
}

local ROLE_DEFAULTS = {
  root = {
    browsable = true,
    searchable = true,
    grep = true,
    symbols = true,
    usages = true,
    autocomplete = true,
    rank_penalty = 0,
    filetree_style = "root",
  },
  external = {
    browsable = true,
    searchable = true,
    grep = true,
    symbols = true,
    usages = true,
    autocomplete = true,
    rank_penalty = 150,
    filetree_style = "external",
  },
  vendored = {
    browsable = true,
    searchable = true,
    grep = true,
    symbols = true,
    usages = true,
    autocomplete = true,
    rank_penalty = 75,
    filetree_style = "vendored",
  },
  excluded = {
    browsable = true,
    searchable = false,
    grep = false,
    symbols = false,
    usages = false,
    autocomplete = false,
    rank_penalty = 0,
    filetree_style = "excluded",
  },
}

local function root_project()
  return core.root_project and core.root_project() or core.projects and core.projects[1]
end

local function root_path()
  local project = root_project()
  return project and project.path
end

local function normalize_abs(path, base)
  if type(path) ~= "string" or path == "" then return nil end
  path = common.home_expand(path)
  local ok, normalized = pcall(common.normalize_path, path)
  path = ok and normalized or path
  if not common.is_absolute_path(path) then
    base = base or root_path() or system.getcwd()
    path = common.normalize_path(base .. PATHSEP .. path)
  end
  return common.normalize_volume(common.normalize_path(path) or path)
end

local function path_key(path)
  return common.path_compare_key(path)
end

local function path_matches(filename, parent)
  return common.path_equals(filename, parent) or common.path_belongs_to(filename, parent)
end

local function relpath(parent, filename)
  if common.path_equals(parent, filename) then return "" end
  return common.relative_path(parent, filename)
end

local function copy_entry(entry)
  local copy = {}
  for key, value in pairs(entry) do copy[key] = value end
  return copy
end

local function copy_list(entries)
  local result = {}
  for i, entry in ipairs(entries or {}) do
    result[i] = copy_entry(entry)
  end
  return result
end

local function invalidate(reason)
  generation = generation + 1
  if core.log_quiet then
    core.log_quiet("Project paths: invalidated generation=%d reason=%s", generation, tostring(reason or "updated"))
  end
end

local function defaults_for_role(role)
  return ROLE_DEFAULTS[role] or ROLE_DEFAULTS.external
end

local function label_for(path, label)
  if type(label) == "string" and label ~= "" then return label end
  return common.basename(path)
end

local function make_id(source, role, path)
  return string.format("%s:%s:%s", source or "workspace", role or "external", path_key(path) or tostring(path))
end

local function normalize_entry(entry, defaults)
  if type(entry) ~= "table" then return nil end
  defaults = defaults or {}
  local role = entry.role or defaults.role or "external"
  local source = entry.source or defaults.source or "workspace"
  local base = defaults.base or root_path()
  local abs = normalize_abs(entry.path, base)
  if not abs then return nil end

  local normalized = {}
  local role_defaults = defaults_for_role(role)
  for key, value in pairs(role_defaults) do normalized[key] = value end
  for key, value in pairs(entry) do normalized[key] = value end
  normalized.path = abs
  normalized.label = label_for(abs, entry.label)
  normalized.role = role
  normalized.source = source
  normalized.id = entry.id or make_id(source, role, abs)
  normalized.exists = system.get_file_info(abs) ~= nil
  return normalized
end

local function normalize_entries(entries, defaults)
  local result = {}
  for _, entry in ipairs(entries or {}) do
    local normalized = normalize_entry(entry, defaults)
    if normalized then result[#result + 1] = normalized end
  end
  return result
end

local function role_entries_from_spec(spec, role)
  local list = {}
  for _, entry in ipairs(spec and spec[role] or {}) do
    if type(entry) == "table" then
      local copy = copy_entry(entry)
      copy.role = copy.role or role
      list[#list + 1] = copy
    end
  end
  return list
end

local function root_entry()
  local path = root_path() or system.getcwd()
  return normalize_entry({
    id = "root",
    path = path,
    label = common.basename(path),
    role = "root",
    source = "implicit",
  }, { role = "root", source = "implicit" })
end

local function label_with_suffix(base_label, seen)
  local label = base_label
  local count = seen[label] or 0
  if count > 0 then label = base_label .. "-" .. tostring(count + 1) end
  seen[base_label] = count + 1
  seen[label] = math.max(seen[label] or 0, 1)
  return label
end

local function entry_sort(a, b)
  local source_a = SOURCE_ORDER[a.source] or 99
  local source_b = SOURCE_ORDER[b.source] or 99
  if source_a ~= source_b then return source_a < source_b end
  local role_a = ROLE_ORDER[a.role] or 99
  local role_b = ROLE_ORDER[b.role] or 99
  if role_a ~= role_b then return role_a < role_b end
  return (a.path or "") < (b.path or "")
end

local function merged_entries()
  local root = root_entry()
  local ordered = { root }
  for _, entry in ipairs(project_entries) do ordered[#ordered + 1] = entry end
  for _, entry in ipairs(workspace_entries) do ordered[#ordered + 1] = entry end
  table.sort(ordered, entry_sort)

  local by_path = {}
  local deduped = {}
  for _, entry in ipairs(ordered) do
    local key = path_key(entry.path)
    if key and not by_path[key] then
      local copy = copy_entry(entry)
      by_path[key] = copy
      deduped[#deduped + 1] = copy
    end
  end

  table.sort(deduped, entry_sort)
  local seen_labels = {}
  for _, entry in ipairs(deduped) do
    entry.label = label_with_suffix(label_for(entry.path, entry.label), seen_labels)
  end
  return deduped
end

local function positive_entries(entries)
  local result = {}
  for _, entry in ipairs(entries or merged_entries()) do
    if entry.role ~= "excluded" then result[#result + 1] = entry end
  end
  return result
end

local function excluded_entries(entries)
  local result = {}
  for _, entry in ipairs(entries or merged_entries()) do
    if entry.role == "excluded" then result[#result + 1] = entry end
  end
  return result
end

local function longest_match(path, entries)
  local best
  local best_len = -1
  for _, entry in ipairs(entries) do
    if path_matches(path, entry.path) then
      local len = #(path_key(entry.path) or entry.path)
      if len > best_len then
        best = entry
        best_len = len
      end
    end
  end
  return best
end

local function flags_for(entry, path, entries)
  local flags = {}
  for key, value in pairs(entry or {}) do
    if key == "browsable" or key == "searchable" or key == "grep"
    or key == "symbols" or key == "usages" or key == "autocomplete"
    or key == "rank_penalty" or key == "filetree_style" then
      flags[key] = value
    end
  end
  local excluded = longest_match(path, excluded_entries(entries))
  if excluded then
    for _, key in ipairs({ "browsable", "searchable", "grep", "symbols", "usages", "autocomplete" }) do
      if excluded[key] ~= nil then flags[key] = excluded[key] end
    end
    flags.excluded_entry = excluded
  end
  return flags
end

local function kind_field(kind)
  return KIND_FIELD[kind or "files"] or kind
end

function project_paths.entries(opts)
  opts = opts or {}
  local entries = merged_entries()
  if opts.include_root == false then
    local filtered = {}
    for _, entry in ipairs(entries) do
      if entry.role ~= "root" then filtered[#filtered + 1] = entry end
    end
    return filtered
  end
  return entries
end

function project_paths.search_roots(kind)
  local field = kind_field(kind or "files")
  local roots = {}
  local enabled_roots = {}
  for _, entry in ipairs(positive_entries()) do
    if entry.exists and entry[field] ~= false and not project_paths.is_excluded(entry.path, kind) then
      local contained = false
      for _, prior in ipairs(enabled_roots) do
        if path_matches(entry.path, prior.path) and not common.path_equals(entry.path, prior.path) then
          contained = true
          break
        end
      end
      if not contained then
        enabled_roots[#enabled_roots + 1] = entry
        roots[#roots + 1] = entry
      end
    end
  end
  return roots
end

function project_paths.resolve(path)
  local abs = normalize_abs(path)
  if not abs then return nil end
  local entries = merged_entries()
  local best = longest_match(abs, entries)
  if not best then return nil end
  return {
    entry = best,
    relpath = relpath(best.path, abs),
    flags = flags_for(best, abs, entries),
  }
end

function project_paths.display_path(path, opts)
  opts = opts or {}
  local abs = normalize_abs(path)
  if not abs then return nil end
  local resolved = project_paths.resolve(abs)
  if not resolved then
    local text = opts.home_encode == false and abs or common.home_encode(abs)
    return {
      text = text,
      abs_path = abs,
      relpath = abs,
    }
  end

  local entry = resolved.entry
  local rel = resolved.relpath
  local text
  local prefix_span
  if entry.role == "root" then
    text = rel ~= "" and rel or "."
  else
    text = rel ~= "" and (entry.label .. PATHSEP .. rel) or entry.label
    prefix_span = { 1, #entry.label }
  end
  return {
    text = text,
    root_label = entry.label,
    root_role = entry.role,
    root_id = entry.id,
    prefix_span = prefix_span,
    relpath = rel,
    abs_path = abs,
    rank_penalty = project_paths.rank_penalty(abs, opts.kind),
    flags = resolved.flags,
  }
end

function project_paths.absolute_path(display)
  if type(display) ~= "string" or display == "" then return nil end
  local normalized = common.normalize_path(common.home_expand(display))
  if common.is_absolute_path(normalized) then
    return common.normalize_volume(normalized)
  end

  local first, rest = normalized:match("^([^" .. PATHSEP .. "]+)" .. PATHSEP .. "?(.*)$")
  for _, entry in ipairs(project_paths.entries()) do
    if entry.role ~= "root" and entry.label == first then
      return rest and rest ~= ""
        and common.normalize_path(entry.path .. PATHSEP .. rest)
        or entry.path
    end
  end

  local project = root_project()
  return project and project:absolute_path(normalized) or normalize_abs(normalized)
end

function project_paths.is_excluded(path, kind)
  local abs = normalize_abs(path)
  if not abs then return false end
  local excluded = longest_match(abs, excluded_entries())
  if not excluded then return false end
  if not kind then return true end
  local field = kind_field(kind)
  return excluded[field] == false
end

function project_paths.rank_penalty(path, kind)
  local resolved = project_paths.resolve(path)
  if not resolved then return 0 end
  local field = kind_field(kind)
  if field and resolved.flags[field] == false then return math.huge end
  return tonumber(resolved.entry.rank_penalty) or 0
end

function project_paths.configure_project(spec)
  spec = spec or {}
  local entries = {}
  for _, role in ipairs({ "external", "vendored", "excluded" }) do
    for _, entry in ipairs(role_entries_from_spec(spec, role)) do
      entries[#entries + 1] = entry
    end
  end
  project_entries = normalize_entries(entries, { source = "project", base = root_path() })
  invalidate("project config")
  return project_paths.entries()
end

function project_paths.begin_project_config_load()
  project_config_snapshot = copy_list(project_entries)
  project_entries = {}
end

function project_paths.commit_project_config_load()
  project_config_snapshot = nil
  invalidate("project config reload")
end

function project_paths.rollback_project_config_load()
  if project_config_snapshot then
    project_entries = project_config_snapshot
    project_config_snapshot = nil
    invalidate("project config rollback")
  end
end

function project_paths.add_external(entry, opts)
  opts = opts or {}
  local copy = copy_entry(entry or {})
  copy.role = copy.role or "external"
  copy.source = opts.source or copy.source or "workspace"
  local normalized = normalize_entry(copy, { source = copy.source, role = copy.role, base = root_path() })
  if not normalized then return nil end
  local target = normalized.source == "project" and project_entries or workspace_entries
  local key = path_key(normalized.path)
  for i = #target, 1, -1 do
    if path_key(target[i].path) == key then table.remove(target, i) end
  end
  target[#target + 1] = normalized
  invalidate("add " .. normalized.role)
  return normalized
end

function project_paths.add_excluded_path(entry, opts)
  local copy = copy_entry(entry or {})
  copy.role = "excluded"
  return project_paths.add_external(copy, opts)
end

local function find_mutable_entry(id_or_path)
  local normalized_path = type(id_or_path) == "string" and normalize_abs(id_or_path) or nil
  local normalized_key = normalized_path and path_key(normalized_path)
  for _, list in ipairs({ project_entries, workspace_entries }) do
    for index, entry in ipairs(list) do
      if entry.id == id_or_path or (normalized_key and path_key(entry.path) == normalized_key) then
        return list, index, entry
      end
    end
  end
end

function project_paths.remove_entry(id_or_path)
  local list, index, entry = find_mutable_entry(id_or_path)
  if not list then return false end
  table.remove(list, index)
  invalidate("remove " .. tostring(entry.id))
  return true
end

function project_paths.set_label(id_or_path, label)
  if type(label) ~= "string" or label == "" then return false end
  local _, _, entry = find_mutable_entry(id_or_path)
  if not entry then return false end
  entry.label = label
  invalidate("set label")
  return true
end

function project_paths.load_workspace_state(state, legacy_directories)
  local entries = {}
  if type(state) == "table" then
    for _, entry in ipairs(state.entries or state) do
      if type(entry) == "table" then
        local copy = copy_entry(entry)
        copy.source = "workspace"
        entries[#entries + 1] = copy
      end
    end
  end
  for _, path in ipairs(legacy_directories or {}) do
    if type(path) == "string" and path ~= "" then
      entries[#entries + 1] = {
        path = path,
        label = common.basename(common.normalize_path(path) or path),
        role = "external",
        source = "workspace",
      }
    end
  end
  workspace_entries = normalize_entries(entries, { source = "workspace", base = root_path() })
  invalidate("workspace load")
  return project_paths.entries()
end

function project_paths.save_workspace_state()
  local entries = {}
  local root = root_path()
  local seen = {}
  local function save_entry(entry)
    local key = path_key(entry.path)
    if not key or seen[key] then return end
    seen[key] = true
    local saved = {
      path = root and common.relative_path(root, entry.path) or entry.path,
      label = entry.label,
      role = entry.role,
    }
    local defaults = ROLE_DEFAULTS[entry.role] or {}
    for _, field in ipairs({ "browsable", "searchable", "grep", "symbols", "usages", "autocomplete", "rank_penalty", "filetree_style" }) do
      if entry[field] ~= defaults[field] then saved[field] = entry[field] end
    end
    entries[#entries + 1] = saved
  end

  for _, entry in ipairs(workspace_entries) do save_entry(entry) end
  for i = 2, #(core.projects or {}) do
    local project = core.projects[i]
    if project and project.path then
      save_entry(normalize_entry({
        path = project.path,
        label = common.basename(project.path),
        role = "external",
        source = "workspace",
      }, { source = "workspace", role = "external", base = root }))
    end
  end
  return { entries = entries }
end

function project_paths.generation()
  return generation
end

project_paths.invalidate = invalidate

return project_paths
