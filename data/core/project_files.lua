local common = require "core.common"
local process = require "core.process"

local project_files = {}
local cache = {}

local function ripgrep_path()
  if PLATFORM ~= "Windows" then return "rg" end
  local bundled = DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "fuzzy_searcher" .. PATHSEP .. "rg.exe"
  if system.get_file_info(bundled) then return bundled end
  return "rg"
end

function project_files.add_filter_arguments(args, include_ignored)
  if include_ignored then args[#args + 1] = "-u" end
  return args
end

function project_files.scan_command(include_ignored)
  local args = { ripgrep_path(), "--files", "--null" }
  project_files.add_filter_arguments(args, include_ignored)
  args[#args + 1] = "."
  return args
end

local function scan(root, include_ignored)
  local proc, start_error = process.start(project_files.scan_command(include_ignored), {
    cwd = root,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
    stdin = process.REDIRECT_DISCARD,
  })
  if not proc then return nil, start_error or "could not start ripgrep" end

  local files, pending = {}, ""
  local progress_deadline = system.get_time() + 30
  while true do
    if system.get_time() >= progress_deadline then
      if proc:running() then pcall(function() proc:kill() end) end
      proc:wait(process.WAIT_DEADLINE)
      return nil, "ripgrep file scan timed out"
    end
    local ok, chunk_or_error = pcall(
      proc.stdout.read, proc.stdout, 256 * 1024, { scan = 0.001, timeout = 0.1 }
    )
    if ok and chunk_or_error then
      progress_deadline = system.get_time() + 30
      local text = pending .. chunk_or_error
      local start = 1
      while true do
        local stop = text:find("\0", start, true)
        if not stop then break end
        local relative = text:sub(start, stop - 1):gsub("^%.[/\\]", "")
        if relative ~= "" then
          files[#files + 1] = {
            relative = relative,
            path = common.normalize_path(root .. PATHSEP .. relative),
          }
        end
        start = stop + 1
      end
      pending = text:sub(start)
    elseif not ok and not tostring(chunk_or_error):find("timeout expired", 1, true) then
      if proc:running() then pcall(function() proc:kill() end) end
      proc:wait(process.WAIT_DEADLINE)
      return nil, tostring(chunk_or_error)
    elseif not proc:running() then
      break
    end
    coroutine.yield(0.001)
  end

  local exit_code = proc:wait(process.WAIT_DEADLINE)
  if exit_code ~= 0 and exit_code ~= 1 then
    local error_text = ""
    pcall(function() error_text = proc.stderr:read() or "" end)
    return nil, error_text ~= "" and error_text or ("ripgrep exited with code " .. tostring(exit_code))
  end
  if pending ~= "" then
    pending = pending:gsub("^%.[/\\]", "")
    files[#files + 1] = {
      relative = pending,
      path = common.normalize_path(root .. PATHSEP .. pending),
    }
  end
  table.sort(files, function(a, b) return a.relative < b.relative end)
  return files
end

local function cache_key(root, include_ignored)
  return common.path_compare_key(common.normalize_path(root)) .. (include_ignored and "\1" or "\0")
end

local function index_paths(entry, root)
  entry.paths, entry.directories = {}, {}
  local root_key = common.path_compare_key(root)
  entry.directories[root_key] = root
  for _, file in ipairs(entry.files or {}) do
    entry.paths[common.path_compare_key(file.path)] = true
    local directory = common.dirname(file.path)
    while directory and common.path_belongs_to(directory, root) do
      local key = common.path_compare_key(directory)
      if entry.directories[key] then break end
      entry.directories[key] = directory
      if common.path_equals(directory, root) then break end
      directory = common.dirname(directory)
    end
  end
  entry.directory_list = {}
  for _, directory in pairs(entry.directories) do
    entry.directory_list[#entry.directory_list + 1] = directory
  end
  table.sort(entry.directory_list)
end

function project_files.list(root, opts)
  opts = opts or {}
  root = common.normalize_path(root)
  local key = cache_key(root, opts.include_ignored == true)
  local entry = cache[key]
  if entry and entry.files and not opts.refresh then return entry.files end
  if entry and entry.scanning then
    while entry.scanning do coroutine.yield(0.005) end
    return entry.files, entry.error
  end

  entry = entry or {}
  cache[key] = entry
  entry.scanning = true
  local files, err = scan(root, opts.include_ignored == true)
  entry.scanning = false
  entry.files = files
  entry.error = err
  if files then index_paths(entry, root) end
  if not files then cache[key] = nil end
  return files, err
end

function project_files.contains(root, path, kind)
  root = common.normalize_path(root)
  path = common.normalize_path(path)
  local entry = cache[cache_key(root, false)]
  if not entry or not entry.files then return nil end
  local key = common.path_compare_key(path)
  if kind == "dir" then return entry.directories[key] ~= nil end
  return entry.paths[key] == true
end

function project_files.directories(root, opts)
  opts = opts or {}
  local entry = cache[cache_key(root, opts.include_ignored == true)]
  return entry and entry.directory_list or nil
end

function project_files.invalidate(root)
  if not root then
    cache = {}
    return
  end
  root = common.normalize_path(root)
  cache[cache_key(root, false)] = nil
  cache[cache_key(root, true)] = nil
end

function project_files.cached(root, opts)
  opts = opts or {}
  local entry = cache[cache_key(root, opts.include_ignored == true)]
  return entry and entry.files or nil
end

return project_files
