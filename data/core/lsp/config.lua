local core = require "core"
local common = require "core.common"
local uri = require "core.lsp.uri"

local lsp_config = {}

lsp_config.TRUST_POLICY = {
  workspace_executable_configs = "disabled",
  require_explicit_opt_in = true,
}

lsp_config.DEFAULT_REQUEST_TIMEOUT = 10
lsp_config.DEFAULT_CWD_POLICY = "root"

lsp_config.DEFAULT_SERVER_DEFINITIONS = {
  clangd = {
    id = "clangd",
    command = { "clangd", "--background-index" },
    language_id = "cpp",
    file_patterns = {
      "%.c$", "%.h$", "%.cc$", "%.cpp$", "%.cxx$", "%.hpp$", "%.hxx$",
    },
    root_markers = { "compile_commands.json", ".clangd", ".git" },
    initialization_options = {},
    settings = {},
    env = {},
    cwd_policy = "root",
    request_timeout = 10,
    source = "bundled",
  },
  ols = {
    id = "ols",
    command = { "ols" },
    language_id = "odin",
    file_patterns = { "%.odin$" },
    root_markers = { "ols.json", ".git" },
    initialization_options = {},
    settings = {},
    env = {},
    cwd_policy = "root",
    request_timeout = 10,
    source = "bundled",
  },
}

local function quiet_log(...)
  if core and core.log_quiet then
    core.log_quiet(...)
  end
end

local function shallow_copy(value)
  local out = {}
  if type(value) == "table" then
    for key, item in pairs(value) do out[key] = item end
  end
  return out
end

local function copy_array(value)
  local out = {}
  if type(value) == "table" then
    for i, item in ipairs(value) do out[i] = item end
  end
  return out
end

local function normalize_array(value, field, default)
  if value == nil then return copy_array(default or {}) end
  if type(value) ~= "table" then
    return nil, field .. " must be a table"
  end
  local out = {}
  for i, item in ipairs(value) do
    if type(item) ~= "string" or item == "" then
      return nil, field .. " entries must be non-empty strings"
    end
    out[i] = item
  end
  return out
end

local function normalize_map(value, field)
  if value == nil then return {} end
  if type(value) ~= "table" then
    return nil, field .. " must be a table"
  end
  return shallow_copy(value)
end

local function command_program(command)
  if type(command) == "table" then
    return command[1]
  end
  return command
end

local function command_contains_separator(command)
  return command:find("/", 1, true) or command:find("\\", 1, true)
end

local function split_path_list(path_list)
  local out = {}
  local sep = PLATFORM == "Windows" and ";" or ":"
  for item in tostring(path_list or ""):gmatch("([^" .. sep .. "]+)") do
    out[#out + 1] = item
  end
  return out
end

local function candidate_executable_names(command)
  if PLATFORM ~= "Windows" then return { command } end
  if command:match("%.[^/\\]+$") then return { command } end
  local candidates = { command }
  local pathext = os.getenv("PATHEXT") or ".COM;.EXE;.BAT;.CMD"
  for ext in pathext:gmatch("([^;]+)") do
    candidates[#candidates + 1] = command .. ext
    candidates[#candidates + 1] = command .. ext:lower()
  end
  return candidates
end

local function join_path(dir, child)
  if dir:sub(-1) == PATHSEP then return dir .. child end
  return dir .. PATHSEP .. child
end

local function dirname(path)
  return common.dirname(common.normalize_path(path))
end

local function path_exists(path)
  return system.get_file_info(path) ~= nil
end

local function marker_exists(dir, marker)
  return path_exists(join_path(dir, marker))
end

local function parent_dir(path)
  local parent = common.dirname(path)
  if not parent or parent == path then return nil end
  return parent
end

local function ancestors_from(start_dir)
  local dirs = {}
  local dir = common.normalize_path(start_dir)
  while dir do
    dirs[#dirs + 1] = dir
    local parent = parent_dir(dir)
    if not parent or parent == dir then break end
    dir = parent
  end
  return dirs
end

local function stable_serialize(value)
  return common.serialize(value, { sort = true })
end

local function fnv1a(text)
  local hash = 2166136261
  for i = 1, #text do
    hash = bit.bxor(hash, text:byte(i)) * 16777619 % 4294967296
  end
  return string.format("%08x", hash)
end

function lsp_config.normalize_server_definition(definition)
  if type(definition) ~= "table" then
    return nil, "server definition must be a table"
  end
  local id = definition.id
  if type(id) ~= "string" or id == "" then
    return nil, "server definition id must be a non-empty string"
  end
  local command = definition.command
  if type(command) ~= "string" and type(command) ~= "table" then
    return nil, "server definition command must be a string or table"
  end
  if type(command) == "table" then
    if type(command[1]) ~= "string" or command[1] == "" then
      return nil, "server definition command[1] must be a non-empty string"
    end
    command = copy_array(command)
  elseif command == "" then
    return nil, "server definition command must be non-empty"
  end

  local language_id = definition.language_id
  if type(language_id) ~= "string" or language_id == "" then
    return nil, "server definition language_id must be a non-empty string"
  end

  local file_patterns, err = normalize_array(definition.file_patterns, "file_patterns")
  if not file_patterns then return nil, err end
  local root_markers
  root_markers, err = normalize_array(definition.root_markers, "root_markers")
  if not root_markers then return nil, err end

  local initialization_options
  initialization_options, err = normalize_map(definition.initialization_options, "initialization_options")
  if not initialization_options then return nil, err end
  local settings
  settings, err = normalize_map(definition.settings, "settings")
  if not settings then return nil, err end
  local env
  env, err = normalize_map(definition.env, "env")
  if not env then return nil, err end

  local cwd_policy = definition.cwd_policy or definition.cwd or lsp_config.DEFAULT_CWD_POLICY
  if cwd_policy ~= "root" and cwd_policy ~= "document" and cwd_policy ~= "fixed" then
    return nil, "cwd_policy must be 'root', 'document', or 'fixed'"
  end
  local request_timeout = tonumber(definition.request_timeout or lsp_config.DEFAULT_REQUEST_TIMEOUT)
  if not request_timeout or request_timeout <= 0 then
    return nil, "request_timeout must be a positive number"
  end

  local source = definition.source or "user"
  if source ~= "bundled" and source ~= "user" and source ~= "workspace" then
    return nil, "source must be 'bundled', 'user', or 'workspace'"
  end

  return {
    id = id,
    command = command,
    language_id = language_id,
    file_patterns = file_patterns,
    root_markers = root_markers,
    initialization_options = initialization_options,
    settings = settings,
    env = env,
    cwd_policy = cwd_policy,
    fixed_cwd = definition.fixed_cwd,
    request_timeout = request_timeout,
    source = source,
    trust_policy = definition.trust_policy or lsp_config.TRUST_POLICY,
    toolchain = definition.toolchain,
  }
end

function lsp_config.normalize_server_definitions(definitions)
  local out = {}
  for key, definition in pairs(definitions or {}) do
    if type(definition) == "table" and definition.id == nil then
      definition = shallow_copy(definition)
      definition.id = type(key) == "string" and key or definition.id
    end
    local normalized, err = lsp_config.normalize_server_definition(definition)
    if not normalized then return nil, err end
    out[#out + 1] = normalized
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function lsp_config.matches_file(definition, path)
  local normalized, err = lsp_config.normalize_server_definition(definition)
  if not normalized then return false, err end
  path = tostring(path or "")
  for _, pattern in ipairs(normalized.file_patterns) do
    if path:match(pattern) then return true end
  end
  return false
end

function lsp_config.matching_servers(definitions, path)
  local normalized, err = lsp_config.normalize_server_definitions(definitions)
  if not normalized then return nil, err end
  local matches = {}
  for _, definition in ipairs(normalized) do
    if lsp_config.matches_file(definition, path) then
      matches[#matches + 1] = definition
    end
  end
  return matches
end

function lsp_config.executable_status(definition, options)
  options = options or {}
  local normalized, err = lsp_config.normalize_server_definition(definition)
  if not normalized then return nil, err end
  local program = command_program(normalized.command)
  if not program or program == "" then return nil, "missing command program" end

  local search_paths = options.path_entries or split_path_list(options.path or os.getenv("PATH"))
  local candidates = candidate_executable_names(program)
  if common.is_absolute_path(program) or command_contains_separator(program) then
    for _, candidate in ipairs(candidates) do
      if path_exists(candidate) then return { available = true, path = common.normalize_path(candidate) } end
    end
    quiet_log("LSP server %s unavailable: executable not found at %s", normalized.id, program)
    return { available = false, reason = "missing_executable", command = program }
  end

  for _, dir in ipairs(search_paths) do
    for _, candidate in ipairs(candidates) do
      local path = join_path(dir, candidate)
      if path_exists(path) then return { available = true, path = common.normalize_path(path) } end
    end
  end
  quiet_log("LSP server %s unavailable: executable %s not found on PATH", normalized.id, program)
  return { available = false, reason = "missing_executable", command = program }
end

function lsp_config.is_available(definition, options)
  local status, err = lsp_config.executable_status(definition, options)
  if not status then return false, err end
  return status.available, status.reason, status
end

local function within_root_boundaries(dir, boundaries)
  if #boundaries == 0 then return true end
  for _, boundary in ipairs(boundaries) do
    boundary = common.normalize_path(boundary)
    if common.path_equals(dir, boundary) or common.path_belongs_to(dir, boundary) then
      return true
    end
  end
  return false
end

function lsp_config.find_root(path, definition, options)
  options = options or {}
  local normalized = assert(lsp_config.normalize_server_definition(definition))
  local doc_path = common.normalize_path(path)
  local doc_dir = system.get_file_info(doc_path) and system.get_file_info(doc_path).type == "dir"
    and doc_path or dirname(doc_path)
  if not doc_dir then return nil, "document path has no directory" end

  local boundaries = options.root_boundaries or options.fallback_roots or {}
  if options.prefer_fallback_roots then
    for _, fallback in ipairs(options.fallback_roots or {}) do
      local root = common.normalize_path(fallback)
      if common.path_equals(doc_dir, root) or common.path_belongs_to(doc_dir, root) then
        return {
          root = root,
          marker = nil,
          source = "fallback_root",
          root_uri = uri.path_to_uri(root),
        }
      end
    end
  end

  local dirs = {}
  for _, dir in ipairs(ancestors_from(doc_dir)) do
    if within_root_boundaries(dir, boundaries) then
      dirs[#dirs + 1] = dir
    end
  end
  for _, marker in ipairs(normalized.root_markers) do
    for _, dir in ipairs(dirs) do
      if marker_exists(dir, marker) then
        return {
          root = dir,
          marker = marker,
          source = "marker",
          root_uri = uri.path_to_uri(dir),
        }
      end
    end
  end

  for _, fallback in ipairs(options.fallback_roots or {}) do
    local root = common.normalize_path(fallback)
    if common.path_equals(doc_dir, root) or common.path_belongs_to(doc_dir, root) then
      return {
        root = root,
        marker = nil,
        source = "fallback_root",
        root_uri = uri.path_to_uri(root),
      }
    end
  end

  return {
    root = doc_dir,
    marker = nil,
    source = "document_dir",
    root_uri = uri.path_to_uri(doc_dir),
  }
end

function lsp_config.config_fingerprint(definition)
  local normalized = assert(lsp_config.normalize_server_definition(definition))
  return fnv1a(stable_serialize({
    id = normalized.id,
    command = normalized.command,
    language_id = normalized.language_id,
    file_patterns = normalized.file_patterns,
    root_markers = normalized.root_markers,
    initialization_options = normalized.initialization_options,
    settings = normalized.settings,
    env = normalized.env,
    cwd_policy = normalized.cwd_policy,
    fixed_cwd = normalized.fixed_cwd,
    request_timeout = normalized.request_timeout,
    source = normalized.source,
    toolchain = normalized.toolchain,
  }))
end

function lsp_config.client_identity(definition, root_info, options)
  options = options or {}
  local normalized = assert(lsp_config.normalize_server_definition(definition))
  local root_uri = root_info and root_info.root_uri
    or (root_info and root_info.root and uri.path_to_uri(root_info.root))
    or options.root_uri
    or ""
  local settings_generation = options.settings_generation or 0
  local toolchain = options.toolchain or normalized.toolchain or normalized.language_id
  local fingerprint = options.config_fingerprint or lsp_config.config_fingerprint(normalized)
  local key = table.concat({
    normalized.id,
    fingerprint,
    root_uri,
    normalized.language_id,
    tostring(toolchain or ""),
    tostring(settings_generation),
  }, "|")
  return {
    key = key,
    server_id = normalized.id,
    config_fingerprint = fingerprint,
    root_uri = root_uri,
    language_id = normalized.language_id,
    toolchain = toolchain,
    settings_generation = settings_generation,
  }
end

function lsp_config.workspace_executable_config_allowed(policy, opts)
  policy = policy or lsp_config.TRUST_POLICY
  opts = opts or {}
  if policy.workspace_executable_configs == "disabled" then return false end
  if policy.require_explicit_opt_in and not opts.trusted then return false end
  return true
end

function lsp_config.select_for_path(definitions, path, options)
  options = options or {}
  local matches, err = lsp_config.matching_servers(definitions, path)
  if not matches then return nil, err end
  local selected = {}
  for _, definition in ipairs(matches) do
    if definition.source == "workspace"
      and not lsp_config.workspace_executable_config_allowed(definition.trust_policy, options)
    then
      quiet_log("LSP server %s skipped: workspace executable config is not trusted", definition.id)
    else
      local available, reason, status = lsp_config.is_available(definition, options.executable or options)
      if available then
        local root = lsp_config.find_root(path, definition, options)
        local identity = lsp_config.client_identity(definition, root, options)
        selected[#selected + 1] = {
          definition = definition,
          executable = status.path,
          root = root,
          identity = identity,
        }
      else
        selected[#selected + 1] = {
          definition = definition,
          available = false,
          reason = reason or (status and status.reason) or "unavailable",
          executable_status = status,
          command = status and status.command,
        }
      end
    end
  end
  return selected
end

return lsp_config
