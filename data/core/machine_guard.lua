-- In a Project process on another Machine, the Project's paths name the Machine's files. The guard
-- makes the raw file functions refuse those paths, so code cannot use the Client's disk by mistake.
-- It also refuses relative paths, because they resolve against this process's folder.
-- All other absolute paths are local state: the Machine serves only paths inside its Projects.
-- This guard stops mistakes. It is not a security boundary.
local machine_guard = {}

local windows = PLATFORM == "Windows"
local sep = windows and "\\" or "/"
local part_pattern = windows and "[^\\]+" or "[^/]+"

-- The Project's roots in normalized form while the guard is on, or nil.
local roots = nil
local restore = {}

-- Returns the path in one spelling for comparison, or nil for a relative path.
local function normalize(path)
  local prefix, rest
  if windows then
    path = path:gsub("^\\\\%?\\", ""):gsub("/", "\\"):lower()
    prefix, rest = path:match("^(%a:\\)(.*)$")
    if not prefix then prefix, rest = path:match("^(\\\\)(.*)$") end
  else
    prefix, rest = path:match("^(/)(.*)$")
  end
  if not prefix then return nil end
  local parts = {}
  for part in rest:gmatch(part_pattern) do
    if part == ".." then
      parts[#parts] = nil
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return prefix .. table.concat(parts, sep)
end

local function in_project(normalized)
  for _, root in ipairs(roots) do
    if normalized == root or normalized:sub(1, #root + 1) == root .. sep then return true end
  end
  return false
end

local function refuse(name, kind, path)
  error(string.format("%s refused %s in a Project on a Machine: %s", name, kind, path), 0)
end

local function check_path(name, path)
  if type(path) ~= "string" then return end
  local normalized = normalize(path)
  if not normalized then
    refuse(name, "a relative path", path)
  elseif in_project(normalized) then
    refuse(name, "a Project path", path)
  end
end

-- A command line or an argument can hold any text. Only absolute Project paths in it are refused.
local function check_text(name, text)
  if type(text) ~= "string" then return end
  local normalized = normalize(text)
  if normalized and in_project(normalized) then refuse(name, "a Project path", text) end
  local spelled = windows and text:gsub("/", "\\"):lower() or text
  for _, root in ipairs(roots) do
    local first, last = spelled:find(root, 1, true)
    while first do
      -- `C:\project-old` holds the text of the root `C:\project`, but it is not inside it.
      local after = spelled:sub(last + 1, last + 1)
      if after == "" or after == sep or after:match("[%s\"']") then refuse(name, "a Project path", text) end
      first, last = spelled:find(root, last + 1, true)
    end
  end
end

local function check_values(name, value, depth)
  if type(value) == "string" then
    if #value < 4096 and not value:find("\n", 1, true) then
      local normalized = normalize(value)
      if normalized and in_project(normalized) then refuse(name, "a Project path", value) end
    end
  elseif type(value) == "table" and depth < 8 then
    for _, item in pairs(value) do check_values(name, item, depth + 1) end
  end
end

local function path_args(count, optional)
  return function(name, ...)
    for i = 1, count do
      local path = select(i, ...)
      if not (optional and path == nil) then check_path(name, path) end
    end
  end
end

local first_path = path_args(1)
local first_path_if_any = path_args(1, true)
local two_paths = path_args(2)

local function process_args(name, command, options)
  if type(command) == "table" then
    for _, arg in ipairs(command) do check_text(name, arg) end
  else
    check_text(name, command)
  end
  if type(options) == "table" and options.cwd ~= nil then check_path(name, options.cwd) end
end

local function system_target(name, target)
  -- A URL, such as https://, is not a file.
  if type(target) == "string" and target:match("^%a[%w+.-]+:") then return end
  check_path(name, target)
end

local function method_path(name, _, path) check_path(name, path) end

local function options_cwd(name, options)
  if type(options) == "table" and options.cwd ~= nil then check_path(name, options.cwd) end
end

local function wrap(owner, owner_name, name, check)
  local original = type(owner) == "table" and rawget(owner, name)
  if type(original) ~= "function" then return end
  local full_name = owner_name .. "." .. name
  owner[name] = function(...)
    check(full_name, ...)
    return original(...)
  end
  restore[#restore + 1] = function() owner[name] = original end
end

-- `project_roots` lists the Project's paths, in the Machine's spelling.
function machine_guard.enable(project_roots)
  machine_guard.disable()
  roots = {}
  for _, root in ipairs(project_roots) do roots[#roots + 1] = assert(normalize(root), "A Project root must be absolute") end

  wrap(io, "io", "open", first_path)
  wrap(io, "io", "lines", first_path_if_any)
  wrap(io, "io", "input", first_path_if_any)
  wrap(io, "io", "output", first_path_if_any)
  wrap(io, "io", "popen", check_text)
  wrap(os, "os", "remove", first_path)
  wrap(os, "os", "rename", two_paths)
  wrap(os, "os", "execute", check_text)
  wrap(_G, "_G", "dofile", first_path_if_any)
  wrap(_G, "_G", "loadfile", first_path_if_any)
  for _, name in ipairs({ "get_file_info", "list_dir", "list_dir_info", "absolute_path", "mkdir", "rmdir",
      "chdir", "get_fs_type", "load_file", "show_in_folder", "load_native_plugin" }) do
    wrap(system, "system", name, first_path)
  end
  wrap(system, "system", "replace_file", two_paths)
  wrap(system, "system", "atomic_replace_file", two_paths)
  wrap(system, "system", "exec", check_text)
  wrap(system, "system", "open_in_system", system_target)
  wrap(process, "process", "start", process_args)
  wrap(encoding, "encoding", "detect", first_path)
  wrap(canvas, "canvas", "load_image", first_path)
  wrap(canvas, "canvas", "load_svg_image", first_path)
  wrap(canvas, "canvas", "open_animation", first_path)
  wrap(debug.getregistry().Canvas, "canvas", "save_image", method_path)
  wrap(renderer and renderer.font, "renderer.font", "load", first_path)
  wrap(rawget(_G, "terminal_native"), "terminal_native", "new", options_cwd)
end

function machine_guard.disable()
  for i = #restore, 1, -1 do restore[i]() end
  restore = {}
  roots = nil
end

-- Worker jobs read the paths in their payload. A job that names a Project path is refused.
function machine_guard.check_job(kind, payload)
  if roots then check_values("worker job " .. tostring(kind), payload, 0) end
end

return machine_guard
