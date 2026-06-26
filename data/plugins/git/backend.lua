-- mod-version:3
-- Shared first-party Git backend helpers for Git View, File Tree status,
-- and editor Git change affordances.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local process = require "core.process"

local backend = {}

backend.EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
backend.WORKING_TREE = "WORKING_TREE"
backend.LOG_RECORD_SEPARATOR = "\30"
backend.LOG_FIELD_SEPARATOR = "\0"
backend.DEFAULT_LOG_LIMIT = 500
backend.DEFAULT_MAX_OUTPUT = 16 * 1024 * 1024

local next_job_id = 1

local function git_config()
  local value = config.plugins.git
  if value == false then return nil end
  if type(value) ~= "table" then
    value = {}
    config.plugins.git = value
  end
  return value
end

local function disabled_error()
  return { kind = "disabled", message = "Git integration is disabled" }
end

function backend.is_enabled()
  return config.plugins.git ~= false
end

local function default_log_limit()
  local cfg = git_config()
  return (cfg and cfg.log_page_size) or backend.DEFAULT_LOG_LIMIT
end

function backend.git_path()
  local cfg = git_config()
  if not cfg then return nil end
  return cfg.git_path or "git"
end

local function split_char(text, sep)
  local result = {}
  if not text or text == "" then return result end
  local start = 1
  while true do
    local pos = text:find(sep, start, true)
    if not pos then
      result[#result + 1] = text:sub(start)
      break
    end
    result[#result + 1] = text:sub(start, pos - 1)
    start = pos + #sep
  end
  return result
end

local function split_nul(text)
  local fields = split_char(text or "", "\0")
  if fields[#fields] == "" then fields[#fields] = nil end
  return fields
end

local function normalize_relpath(path)
  if not path or path == "" then return path end
  return path:gsub("\\", "/")
end

local function git_arg_path(path)
  return path and path:gsub("\\", "/") or path
end

local function from_git_output_path(path)
  path = tostring(path or "")
  if PLATFORM == "Windows" then
    local drive, rest = path:match("^/([a-zA-Z])/(.*)$")
    if drive then
      return drive:upper() .. ":/" .. rest
    end
  end
  return path
end

local function status_from_name_token(token)
  local code = token and token:sub(1, 1) or ""
  if code == "M" then return "modified" end
  if code == "A" then return "added" end
  if code == "D" then return "deleted" end
  if code == "R" then return "renamed" end
  if code == "C" then return "copied" end
  if code == "T" then return "typechange" end
  if code == "U" then return "unmerged" end
  return "unknown"
end

local function score_from_token(token)
  local value = token and token:match("^[RC](%d+)$")
  return value and tonumber(value) or nil
end

---Parse NUL-delimited `git diff/show --name-status -z` style records.
---@param output string
---@return table[] records
function backend.parse_name_status_z(output)
  local fields = split_nul(output)
  local records = {}
  local i = 1
  while i <= #fields do
    local token = fields[i]
    i = i + 1
    if token and token ~= "" then
      local status = status_from_name_token(token)
      local record = {
        raw_status = token,
        status = status,
        score = score_from_token(token),
      }
      if status == "renamed" or status == "copied" then
        record.old_path = normalize_relpath(fields[i])
        record.new_path = normalize_relpath(fields[i + 1])
        i = i + 2
      else
        local path = normalize_relpath(fields[i])
        i = i + 1
        if status == "added" then
          record.old_path = nil
          record.new_path = path
        elseif status == "deleted" then
          record.old_path = path
          record.new_path = nil
        else
          record.old_path = path
          record.new_path = path
        end
      end
      records[#records + 1] = record
    end
  end
  return records
end

local UNMERGED_STATUS = {
  DD = true, AU = true, UD = true, UA = true,
  DU = true, AA = true, UU = true,
}

local function status_kind(xy)
  if xy == "??" then return "untracked" end
  if xy == "!!" then return "ignored" end
  if UNMERGED_STATUS[xy] then return "unmerged" end
  if xy:find("R", 1, true) then return "renamed" end
  if xy:find("C", 1, true) then return "copied" end
  if xy:find("U", 1, true) then return "unmerged" end
  if xy:find("A", 1, true) then return "added" end
  if xy:find("D", 1, true) then return "deleted" end
  if xy:find("M", 1, true) then return "modified" end
  return "unknown"
end

---Parse NUL-delimited `git status --porcelain=v1 -z` output.
---@param output string
---@return table[] records
function backend.parse_status_z(output)
  local fields = split_nul(output)
  local records = {}
  local i = 1
  while i <= #fields do
    local field = fields[i]
    i = i + 1
    if field and field ~= "" then
      local xy = field:sub(1, 2)
      local path = normalize_relpath(field:sub(4))
      local kind = status_kind(xy)
      local record = { xy = xy, kind = kind, path = path }
      if kind == "renamed" or kind == "copied" then
        -- Porcelain v1 -z reverses rename order to: "XY to\0from\0".
        record.old_path = normalize_relpath(fields[i])
        record.new_path = path
        i = i + 1
      end
      records[#records + 1] = record
    end
  end
  return records
end

local function parse_parents(text)
  local parents = {}
  for hash in tostring(text or ""):gmatch("%S+") do
    parents[#parents + 1] = hash
  end
  return parents
end

local function parse_log_record(record)
  record = tostring(record or ""):gsub("^\r?\n", "")
  if record == "" or record:match("^%s*$") then return nil end
  local fields = split_nul(record)
  if #fields == 0 or not fields[1] or fields[1] == "" then return nil end
  return {
    hash = fields[1],
    parents = parse_parents(fields[2]),
    author_name = fields[3] or "",
    author_email = fields[4] or "",
    author_time = tonumber(fields[5]) or 0,
    refs = fields[6] or "",
    subject = fields[7] or "",
    body = fields[8] or "",
  }
end

---Parse one page of custom Git log output.
---The caller normally requests limit+1 records; the extra record indicates more.
---@param output string
---@param opts table?
---@return table page
function backend.parse_log_page(output, opts)
  opts = opts or {}
  local limit = opts.limit or default_log_limit()
  local commits = {}
  for _, raw in ipairs(split_char(output or "", backend.LOG_RECORD_SEPARATOR)) do
    local commit = parse_log_record(raw)
    if commit then commits[#commits + 1] = commit end
  end

  local has_more = #commits > limit
  while #commits > limit do commits[#commits] = nil end

  local offset = opts.offset or 0
  return {
    commits = commits,
    has_more = has_more,
    next_offset = has_more and (offset + #commits) or nil,
    next_cursor = has_more and commits[#commits] and commits[#commits].hash or nil,
  }
end

function backend._contains_arg(args, expected)
  for _, arg in ipairs(args or {}) do
    if arg == expected then return true end
  end
  return false
end

local LOG_FORMAT = table.concat({
  "%H", "%P", "%an", "%ae", "%at", "%D", "%s"
}, "%x00") .. "%x00%x1e"

local LOG_FORMAT_WITH_BODY = table.concat({
  "%H", "%P", "%an", "%ae", "%at", "%D", "%s", "%b"
}, "%x00") .. "%x00%x1e"

local function build_base_log_args(opts)
  opts = opts or {}
  local limit = opts.limit or default_log_limit()
  return {
    "log",
    "--date-order",
    "--max-count=" .. tostring(limit + 1),
    "--format=" .. (opts.include_body and LOG_FORMAT_WITH_BODY or LOG_FORMAT),
  }, limit
end

function backend.build_log_args(opts)
  opts = opts or {}
  local args = build_base_log_args(opts)
  if opts.offset and opts.offset > 0 then
    args[#args + 1] = "--skip=" .. tostring(opts.offset)
  end
  if opts.revisions then
    for _, rev in ipairs(opts.revisions) do args[#args + 1] = rev end
  end
  if opts.relpath then
    args[#args + 1] = "--"
    args[#args + 1] = normalize_relpath(opts.relpath)
  end
  return args
end

function backend.build_file_history_args(relpath, opts)
  opts = opts or {}
  local args = build_base_log_args(opts)
  if opts.follow ~= false then args[#args + 1] = "--follow" end
  if opts.offset and opts.offset > 0 then args[#args + 1] = "--skip=" .. tostring(opts.offset) end
  args[#args + 1] = "--"
  args[#args + 1] = normalize_relpath(relpath)
  return args
end

function backend.file_history(repo, relpath, opts, callback)
  opts = opts or {}
  return backend.run_git(repo, backend.build_file_history_args(relpath, opts), opts, function(result, err)
    if not result then
      if callback then callback(nil, err) end
      return
    end
    if callback then callback(backend.parse_log_page(result.stdout, opts), nil) end
  end)
end

function backend.build_selection_history_args(relpath, start_line, end_line, opts)
  opts = opts or {}
  local args = build_base_log_args(opts)
  args[#args + 1] = "--no-patch"
  if opts.offset and opts.offset > 0 then args[#args + 1] = "--skip=" .. tostring(opts.offset) end
  args[#args + 1] = "-L"
  args[#args + 1] = string.format("%d,%d:%s", start_line, end_line, normalize_relpath(relpath))
  return args
end

function backend.selection_history(repo, relpath, start_line, end_line, opts, callback)
  opts = opts or {}
  return backend.run_git(repo, backend.build_selection_history_args(relpath, start_line, end_line, opts), opts, function(result, err)
    if not result then
      if callback then callback(nil, err) end
      return
    end
    if callback then callback(backend.parse_log_page(result.stdout, opts), nil) end
  end)
end

function backend.path_status(repo, relpath, opts, callback)
  opts = opts or {}
  local args = { "status", "--porcelain=v1", "-z" }
  if opts.ignored then args[#args + 1] = "--ignored" end
  args[#args + 1] = "--"
  args[#args + 1] = normalize_relpath(relpath)
  return backend.run_git(repo, args, opts, function(result, err)
    if not result then
      if callback then callback(nil, err) end
      return
    end
    if callback then callback(backend.parse_status_z(result.stdout), nil) end
  end)
end

function backend.diff_endpoint_for_commit(commit)
  local parents = commit and commit.parents or nil
  return {
    left = parents and parents[1] or backend.EMPTY_TREE,
    right = commit and commit.hash or nil,
  }
end

function backend.diff_endpoint_for_working_tree(repo_state)
  return {
    left = repo_state and repo_state.head or backend.EMPTY_TREE,
    right = backend.WORKING_TREE,
  }
end

function backend.build_changed_files_args(left, right, opts)
  opts = opts or {}
  local args = { "diff", "--name-status", "-z" }
  if opts.ignore_whitespace then args[#args + 1] = "--ignore-all-space" end
  if right == backend.WORKING_TREE then
    if left and left ~= "" then args[#args + 1] = left end
  else
    if left and left ~= "" then args[#args + 1] = left end
    if right and right ~= "" then args[#args + 1] = right end
  end
  if opts.relpath then
    args[#args + 1] = "--"
    args[#args + 1] = normalize_relpath(opts.relpath)
  end
  return args
end

function backend.changed_files(repo, left, right, opts, callback)
  opts = opts or {}
  return backend.run_git(repo, backend.build_changed_files_args(left, right, opts), opts, function(result, err)
    if not result then
      if callback then callback(nil, err) end
      return
    end
    if callback then callback(backend.parse_name_status_z(result.stdout), nil) end
  end)
end

local function read_file_contents(filename, max_output)
  local info = system.get_file_info(filename)
  if info and max_output and info.size and info.size > max_output then
    return nil, { kind = "output_too_large", message = "output too large" }
  end
  local fp, err = io.open(filename, "rb")
  if not fp then return nil, { kind = "read_failed", message = err or "failed to read file" } end
  local text = fp:read("*a") or ""
  fp:close()
  if max_output and #text > max_output then
    return nil, { kind = "output_too_large", message = "output too large" }
  end
  return text, nil
end

function backend.file_at(repo, rev, relpath, opts, callback)
  opts = opts or {}
  if rev == nil or rev == "" then
    if callback then callback("", nil) end
    return nil
  end
  if rev == backend.WORKING_TREE then
    local root = type(repo) == "table" and repo.root or repo
    local text, err = read_file_contents(root .. PATHSEP .. relpath, opts.max_output or backend.DEFAULT_MAX_OUTPUT)
    if callback then callback(text, err) end
    return nil
  end
  return backend.run_git(repo, { "show", tostring(rev) .. ":" .. git_arg_path(relpath) }, opts, function(result, err)
    if not result then
      if callback then callback(nil, err) end
      return
    end
    if callback then callback(result.stdout or "", nil) end
  end)
end

local function append_args(dst, src)
  for _, value in ipairs(src or {}) do dst[#dst + 1] = value end
end

local function read_available(proc, stream, chunks, cap)
  while true do
    local chunk, errmsg, errcode = proc:read(stream, 8192)
    if chunk and #chunk > 0 then
      chunks[#chunks + 1] = chunk
      cap.total = cap.total + #chunk
      if cap.total > cap.max then return false, "output too large" end
    elseif errcode == process.ERROR_WOULDBLOCK or chunk == "" then
      return true
    elseif not chunk then
      if errcode == process.ERROR_PIPE or (errmsg == nil and errcode == nil) then return true end
      return false, errmsg or "process read failed"
    else
      return true
    end
  end
end

local function callback_once(job, callback, result, err)
  if job.callback_done then return end
  job.callback_done = true
  if callback then callback(result, err) end
end

---Run git asynchronously. Callback receives `(result, err)`.
---@param repo table|string|nil Repo table with `root`, cwd string, or nil.
---@param args string[] Git subcommand arguments, excluding git executable.
---@param opts table?
---@param callback fun(result:table?, err:table?)?
---@return table job
function backend.run_git(repo, args, opts, callback)
  opts = opts or {}
  local root = type(repo) == "table" and repo.root or repo
  local cfg = git_config()
  local max_output = opts.max_output or (cfg and cfg.max_output) or backend.DEFAULT_MAX_OUTPUT
  local job = {
    id = next_job_id,
    generation = opts.generation or next_job_id,
    cancelled = false,
  }
  next_job_id = next_job_id + 1

  core.add_thread(function()
    if not backend.is_enabled() then
      callback_once(job, callback, nil, disabled_error())
      return
    end
    local executable = opts.git_path or backend.git_path()
    if not executable then
      callback_once(job, callback, nil, disabled_error())
      return
    end
    local command = { executable }
    if root and root ~= "" then
      command[#command + 1] = "-C"
      command[#command + 1] = git_arg_path(root)
    end
    append_args(command, args)
    core.log_quiet("Git backend: start job=%s cwd=%s args=%s", tostring(job.id), tostring(root), table.concat(args or {}, " "))
    local proc, start_err, start_code = process.start(command, {
      stdin = process.REDIRECT_DISCARD,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE,
    })
    if not proc then
      callback_once(job, callback, nil, {
        kind = "start_failed",
        message = start_err or "process start failed",
        code = start_code,
      })
      return
    end

    job.proc = proc
    local stdout, stderr = {}, {}
    local out_cap = { total = 0, max = max_output }
    local err_cap = { total = 0, max = opts.max_stderr or 512 * 1024 }

    while proc:running() do
      if job.cancelled then
        if proc.terminate then proc:terminate() end
        callback_once(job, callback, nil, { kind = "cancelled", message = "Git job cancelled" })
        return
      end
      local ok, err = read_available(proc, process.STREAM_STDOUT, stdout, out_cap)
      if not ok then
        if proc.terminate then proc:terminate() end
        callback_once(job, callback, nil, { kind = "output_too_large", message = err })
        return
      end
      ok, err = read_available(proc, process.STREAM_STDERR, stderr, err_cap)
      if not ok then
        if proc.terminate then proc:terminate() end
        callback_once(job, callback, nil, { kind = "stderr_too_large", message = err })
        return
      end
      coroutine.yield(opts.scan or 0.01)
    end

    if job.cancelled then
      callback_once(job, callback, nil, { kind = "cancelled", message = "Git job cancelled" })
      return
    end

    local ok, drain_err = read_available(proc, process.STREAM_STDOUT, stdout, out_cap)
    if not ok then
      callback_once(job, callback, nil, { kind = "output_too_large", message = drain_err })
      return
    end
    ok, drain_err = read_available(proc, process.STREAM_STDERR, stderr, err_cap)
    if not ok then
      callback_once(job, callback, nil, { kind = "stderr_too_large", message = drain_err })
      return
    end
    local code = proc:wait(process.WAIT_INFINITE, opts.scan or 0.01)
    local result = {
      job_id = job.id,
      generation = job.generation,
      code = code,
      stdout = table.concat(stdout),
      stderr = table.concat(stderr),
    }
    if code == 0 then
      callback_once(job, callback, result, nil)
    else
      callback_once(job, callback, nil, {
        kind = "exit",
        code = code,
        stdout = result.stdout,
        stderr = result.stderr,
        message = result.stderr ~= "" and result.stderr or ("git exited " .. tostring(code)),
      })
    end
  end)

  function job:cancel()
    self.cancelled = true
    if self.proc and self.proc.terminate then self.proc:terminate() end
  end

  return job
end

local function trim(text)
  return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function find_git_marker_root(cwd)
  local dir = cwd
  while dir and dir ~= "" do
    if system.get_file_info(dir .. PATHSEP .. ".git") then
      return dir
    end
    local parent = common.dirname(dir)
    if not parent or parent == dir then break end
    dir = parent
  end
end

local function run_git_sync(cwd, args, max_output)
  local executable = backend.git_path()
  if not executable then return nil, disabled_error() end
  local command = { executable }
  if cwd and cwd ~= "" then
    command[#command + 1] = "-C"
    command[#command + 1] = git_arg_path(cwd)
  end
  append_args(command, args)
  local proc, err, errcode = process.start(command, {
    stdin = process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  if not proc then return nil, { kind = "start_failed", message = err, code = errcode } end

  local code = proc:wait(process.WAIT_INFINITE, 0.01)
  local stdout = proc.stdout:read("all") or ""
  local stderr = proc.stderr:read("all") or ""
  if max_output and #stdout > max_output then
    return nil, { kind = "output_too_large", message = "output too large" }
  end
  if code ~= 0 then
    return nil, { kind = "exit", code = code, stderr = stderr, message = stderr ~= "" and stderr or ("git exited " .. tostring(code)) }
  end
  return stdout, nil
end

local function repo_input_for_path(path)
  local abs = system.absolute_path(path)
  if not abs then return nil, { kind = "invalid_path", message = "invalid path" } end
  abs = common.normalize_path(abs)
  local info = system.get_file_info(abs)
  local cwd = info and info.type == "dir" and abs or common.dirname(abs)
  if not cwd or cwd == "" then cwd = system.getcwd() end
  return { abs = abs, info = info, cwd = cwd }
end

local function repo_from_rev_parse(input, out)
  local root = common.normalize_path(from_git_output_path(trim(out)))
  if root == PATHSEP or root == "\\" or not common.path_belongs_to(input.abs, root) then
    root = find_git_marker_root(input.cwd) or root
  end
  local relpath
  if input.info and input.info.type ~= "dir" then
    relpath = common.relative_path(root, input.abs)
  elseif common.path_belongs_to(input.abs, root) and not common.path_equals(input.abs, root) then
    relpath = common.relative_path(root, input.abs)
  end
  return { root = root, relpath = relpath, input_path = input.abs }
end

function backend.repo_for_path(path)
  if not backend.is_enabled() then return nil, disabled_error() end
  local input, input_err = repo_input_for_path(path)
  if not input then return nil, input_err end

  local out, err = run_git_sync(input.cwd, { "rev-parse", "--show-toplevel" }, 1024 * 1024)
  if not out then
    if err and err.kind == "exit" then
      err.kind = "not_in_repository"
    end
    return nil, err
  end

  return repo_from_rev_parse(input, out)
end

function backend.repo_for_path_async(path, callback)
  if not backend.is_enabled() then
    if callback then callback(nil, disabled_error()) end
    return nil
  end
  local input, input_err = repo_input_for_path(path)
  if not input then
    if callback then callback(nil, input_err) end
    return nil
  end
  return backend.run_git(input.cwd, { "rev-parse", "--show-toplevel" }, { max_output = 1024 * 1024 }, function(result, err)
    if not result then
      if err and err.kind == "exit" then err.kind = "not_in_repository" end
      if callback then callback(nil, err) end
      return
    end
    if callback then callback(repo_from_rev_parse(input, result.stdout), nil) end
  end)
end

return backend
