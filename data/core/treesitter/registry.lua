local common = require "core.common"
local core = require "core"

local registry = {}

registry.languages = nil

local function log_quiet(...)
  if core and core.log_quiet then core.log_quiet(...) end
end

local function data_root()
  return DATADIR .. PATHSEP .. "treesitter" .. PATHSEP .. "languages"
end

local function language_dir(id)
  return data_root() .. PATHSEP .. id
end

local builtin_configs = {
  c = {
    id = "c",
    name = "C",
    grammar = "c",
    files = { "%.c$", "%.h$" },
    headers = {},
    line_comments = { "//" },
    block_comment = { "/*", "*/" },
    queries = {
      highlights = "highlights.scm",
      outline = "outline.scm",
      locals = "locals.scm",
    },
  },
  cpp = {
    id = "cpp",
    name = "C++",
    grammar = "cpp",
    files = {
      "%.cc$", "%.cpp$", "%.cxx$", "%.c%+%+$",
      "%.hh$", "%.hpp$", "%.hxx$", "%.h%+%+$", "%.inl$",
    },
    headers = {},
    line_comments = { "//" },
    block_comment = { "/*", "*/" },
    parse_timeout_ms = 5000,
    queries = {
      highlights = "highlights.scm",
      outline = "outline.scm",
      locals = "locals.scm",
    },
  },
}

local function copy_table(t)
  local out = {}
  for k, v in pairs(t) do
    if type(v) == "table" then
      local nested = {}
      for nk, nv in pairs(v) do nested[nk] = nv end
      out[k] = nested
    else
      out[k] = v
    end
  end
  return out
end

local function load_config(id)
  local path = language_dir(id) .. PATHSEP .. "config.lua"
  local chunk, err = loadfile(path)
  if not chunk then
    if builtin_configs[id] then
      log_quiet("Tree-sitter: using built-in %s config fallback because %s could not be loaded: %s", id, path, tostring(err))
      local config = copy_table(builtin_configs[id])
      config.path = language_dir(id)
      return config
    end
    log_quiet("Tree-sitter: could not load %s: %s", path, tostring(err))
    return nil
  end
  local ok, config_or_err = pcall(chunk)
  if not ok or type(config_or_err) ~= "table" then
    log_quiet("Tree-sitter: invalid %s: %s", path, tostring(config_or_err))
    return nil
  end
  local config = config_or_err
  config.id = config.id or id
  config.grammar = config.grammar or config.id
  config.files = config.files or {}
  config.headers = config.headers or {}
  config.queries = config.queries or {}
  config.path = language_dir(id)
  return config
end

local function load_queries(config)
  local queries = {}
  for kind, filename in pairs(config.queries or {}) do
    local path = config.path .. PATHSEP .. filename
    local fp = io.open(path, "rb")
    if fp then
      queries[kind] = fp:read("*a")
      fp:close()
    else
      log_quiet("Tree-sitter: missing %s query for %s at %s", tostring(kind), tostring(config.id), path)
    end
  end
  config.query_sources = queries
end

function registry.reload()
  local languages = {}
  local ids = { "c", "cpp" }
  for _, id in ipairs(ids) do
    local config = load_config(id)
    if config then
      load_queries(config)
      languages[#languages + 1] = config
    end
  end
  registry.languages = languages
  return languages
end

function registry.get_languages()
  return registry.languages or registry.reload()
end

local function find(text, field)
  if not text then return nil end
  local best_match = 0
  local best_language
  for i = #registry.get_languages(), 1, -1 do
    local language = registry.get_languages()[i]
    local s, e = common.match_pattern(text, language[field] or {})
    if s and e - s > best_match then
      best_match = e - s
      best_language = language
    end
  end
  return best_language
end

function registry.get(filename, header)
  return (filename and find(filename, "files"))
      or (header and find(header, "headers"))
end

return registry
