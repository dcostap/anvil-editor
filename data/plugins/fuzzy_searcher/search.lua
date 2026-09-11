-- File searches with an explicit source, filter, or order.
local core = require "core"
local common = require "core.common"
local project_files = require "core.project_files"
local project_paths = require "core.project_paths"
local native = require "fuzzy"
local process = require "core.process"
local http = require "core.http"
local git = require "plugins.git.backend"
local modifiers = require "plugins.fuzzy_searcher.modifiers"

local search = {}

local function checkpoint(job)
  if job.cancelled then error(job, 0) end
  if system.get_time() >= job.deadline then
    coroutine.yield(0)
    job.deadline = system.get_time() + 0.002
    if job.cancelled then error(job, 0) end
  end
end

local function run(job, args, cwd, consume, allow_no_matches)
  checkpoint(job)
  local proc, err = process.start(args, {
    cwd = cwd, stdin = process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE,
    env = { GIT_NO_LAZY_FETCH = "1" },
  })
  if not proc then error(err or "Cannot start search process", 0) end
  job.proc = proc
  local errors, error_size = {}, 0
  local function drain(stream)
    while true do
      checkpoint(job)
      local chunk, message, code = proc:read(stream, 16384)
      if not chunk or chunk == "" then
        if message and code ~= process.ERROR_WOULDBLOCK and code ~= process.ERROR_PIPE then
          error(message, 0)
        end
        return
      end
      if stream == process.STREAM_STDOUT then consume(chunk)
      else
        error_size = error_size + #chunk
        if error_size > 512 * 1024 then error("Search error output is too large", 0) end
        errors[#errors + 1] = chunk
      end
    end
  end
  repeat
    local running = proc:running()
    drain(process.STREAM_STDOUT)
    drain(process.STREAM_STDERR)
    if not running then break end
    coroutine.yield(0.005)
  until false
  local code = proc:wait(process.WAIT_INFINITE, 0.005)
  job.proc = nil
  if code ~= 0 and not (allow_no_matches and code == 1) then
    error(table.concat(errors) ~= "" and table.concat(errors) or ("Search exited with code " .. tostring(code)), 0)
  end
end

local function await_git(job, start)
  local done, result, failure
  job.git_job = start(function(value, err) done, result, failure = true, value, err end)
  while not done do checkpoint(job); coroutine.yield(0.005) end
  job.git_job = nil
  checkpoint(job)
  if failure then error(failure.message or failure.kind, 0) end
  return result
end

local function revision_candidates(job, spec, visit)
  local cache = spec.history
  if not git.is_enabled() then error("Git integration is disabled", 0) end
  if cache.project ~= spec.project then
    cache.repo = await_git(job, function(callback) return git.repo_for_path_async(spec.project, callback) end)
    cache.project, cache.input, cache.revision, cache.files = spec.project, nil, nil, nil
  end
  if cache.input ~= spec.options.commit then
    local result = await_git(job, function(callback)
      return git.run_git(cache.repo, {
        "rev-parse", "--verify", "--end-of-options", spec.options.commit .. "^0",
      }, {}, callback)
    end)
    local revision = result.stdout:gsub("%s+$", "")
    if revision ~= cache.revision then cache.files = nil end
    cache.input, cache.revision = spec.options.commit, revision
  end
  if not cache.files then
    local files, pending = {}, ""
    run(job, { git.git_path(), "-C", cache.repo.root, "ls-tree", "-r", "-l", "-z", "--full-tree", cache.revision }, nil, function(chunk)
      pending = pending .. chunk
      local first = 1
      while true do
        local last = pending:find("\0", first, true)
        if not last then break end
        local _, kind, _, size, path = pending:sub(first, last - 1):match("^(%d+) (%w+) (%x+)%s+(%S+)\t(.*)$")
        if kind == "blob" then files[#files + 1] = { path = path, size = tonumber(size) } end
        first = last + 1
        checkpoint(job)
      end
      pending = pending:sub(first)
    end)
    cache.files = files
    core.log_quiet("Commit Search: loaded %d paths at %s in %s", #files, cache.revision, cache.repo.root)
  end
  for _, file in ipairs(cache.files) do
    checkpoint(job)
    local match = spec.base == "" and { score = 0, spans = {} }
      or native.match(file.path, spec.base, { mode = "path", spans = true })
    if match and modifiers.accepts(spec.options, { type = "file", size = file.size }) then
      local has_line = true
      if spec.line and spec.line > 1 then
        local text = await_git(job, function(callback)
          return git.file_at(cache.repo, cache.revision, file.path, {
            env = { GIT_NO_LAZY_FETCH = "1" },
          }, callback)
        end)
        local _, lines = text:gsub("\n", "")
        has_line = lines + (text:sub(-1) == "\n" and 0 or 1) >= spec.line
      end
      if has_line then
        visit {
          kind = "file", file = file.path, label = file.path, file_size = file.size,
          repo = cache.repo, revision = cache.revision, revision_path = file.path,
          score = match.score, match_spans = match.spans, base_query = spec.base, query = spec.base,
          line = spec.line or 1, col = spec.col or 1,
        }
      end
    end
  end
end

local function file_candidates(job, spec, visit)
  local seen = {}
  local function candidate(path, is_folder)
    checkpoint(job)
    local key = common.path_compare_key(path)
    if seen[key] then return end
    seen[key] = true
    local display = project_paths.display_path(path)
    local match = spec.base == "" and { score = 0, spans = {} }
      or native.match(display.text, spec.base, { mode = "path", spans = true })
    if not match then return end
    local info = spec.metadata[key]
    if not info then
      if spec.options.min_size or spec.options.sort == "size" or spec.options.sort == "date" then
        info = system.get_file_info(path)
        spec.metadata[key] = info
      else
        info = { type = is_folder and "dir" or "file" }
      end
    end
    if not modifiers.accepts(spec.options, info) then return end
    if is_folder and spec.line then return end
    if spec.line and spec.line > 1 then
      local file = io.open(path, "rb")
      local count = 0
      if file then
        job.file = file
        for _ in file:lines() do
          count = count + 1
          checkpoint(job)
          if count >= spec.line then break end
        end
        file:close()
        job.file = nil
      end
      if count < spec.line then return end
    end
    visit {
      kind = is_folder and "folder" or "file", is_folder = is_folder,
      file = display.text, label = display.text, path = path, abs_path = path, file_size = info.size,
      file_modified = info.modified, root_label = display.root_label,
      root_role = display.root_role, root_id = display.root_id,
      prefix_span = display.prefix_span, rank_penalty = display.rank_penalty,
      score = match.score - (display.rank_penalty or 0), match_spans = match.spans,
      base_query = spec.base, query = spec.base, line = spec.line or 1, col = spec.col or 1,
    }
  end
  for _, root in ipairs(project_paths.search_roots()) do
    local files, err, directories = project_files.list(root.path, {
      include_ignored = spec.include_ignored, refresh = spec.refresh_files,
    })
    if not files then error(err or "Cannot list Project files", 0) end
    for _, file in ipairs(files) do candidate(file.path, false) end
    if not spec.grep and not spec.options.min_size and spec.options.sort ~= "size" then
      for _, path in ipairs(directories or {}) do
        if not common.path_equals(path, root.path) then candidate(path, true) end
      end
    end
  end
end

local function path_candidates(job, spec, visit)
  local plan = spec.path_plan
  if spec.grep then error("Text Search requires Project files", 0) end
  local function result(path, info, match)
    if not modifiers.accepts(spec.options, info) then return end
    local folder = info.type == "dir"
    visit({
      kind = plan.project_scope and (folder and "folder" or "file") or "path",
      file = path, label = path, path = path, abs_path = path,
      project = not plan.project_scope and folder and path or nil,
      is_folder = folder, file_size = info.size, file_modified = info.modified,
      query = plan.query, match_spans = match and match.spans or {},
      score = match and match.score or 0, line = spec.line or 1, col = spec.col or 1,
    }, spec.everything_available)
  end
  if spec.everything_available then
    local text = plan.query
    if plan.scope then text = 'ancestor:"' .. plan.scope:gsub('"', '""') .. '" ' .. text end
    if spec.options.min_size or spec.options.sort == "size" then text = "file: " .. text end
    if spec.options.min_size then
      text = text .. string.format(" size:>=%.0f", spec.options.min_size)
      if spec.options.max_size < math.huge then
        text = text .. string.format(" size:<%.0f", spec.options.max_size)
      end
    end
    local done, data, failure
    http.get(spec.everything_endpoint, {
      json = "1", search = text, count = tostring(spec.limit + 1), offset = "0",
      path = "1", path_column = "1", size_column = "1", date_modified_column = "1",
      sort = spec.options.sort == "date" and "date_modified" or spec.options.sort or "path",
      ascending = (spec.options.sort == "date" or spec.options.sort == "size") and "0" or "1",
    }, {
      timeout = 2, is_cancelled = function() return job.cancelled end,
      on_done = function(ok, err, value)
        done, data, failure = true, ok and value, err
      end,
    })
    while not done do checkpoint(job); coroutine.yield(0.01) end
    checkpoint(job)
    if type(data) ~= "table" then error(failure or "Everything is unavailable", 0) end
    for _, item in ipairs(data.results or {}) do
      local path = common.normalize_path((item.path or "") .. PATHSEP .. (item.name or ""))
      local modified = tonumber(item.date_modified)
      result(path, {
        type = item.type == "folder" and "dir" or "file", size = tonumber(item.size),
        modified = modified and modified / 10000000 - 11644473600,
      })
      checkpoint(job)
    end
    return tonumber(data.totalResults)
  end
  if not plan.scope then error("Everything is unavailable. Enter an absolute folder path.", 0) end
  local entries, err = system.list_dir_info(plan.scope, 2147483647, nil, nil, true)
  if not entries then error(err or "Cannot list folder", 0) end
  for _, entry in ipairs(entries) do
    checkpoint(job)
    local match = plan.query == "" and { score = 0, spans = {} }
      or native.match(entry.name, plan.query, { mode = "path", spans = true })
    if match then
      local path = common.normalize_path(plan.scope .. PATHSEP .. entry.name)
      for _, span in ipairs(match.spans) do
        span[1], span[2] = span[1] + #path - #entry.name, span[2] + #path - #entry.name
      end
      result(path, entry, match)
    end
  end
end

local function grep_files(job, spec, candidates, visit)
  local batch, bytes = {}, 0
  local function flush()
    if #batch == 0 then return end
    local historical = spec.options.commit ~= nil
    local by_path, args = {}, {
      spec.rg, "--no-config", "--null", "--line-number", "--column", "--no-heading",
      "--with-filename", "--color", "never", "-i", "-F", "-e", spec.matcher.seed, "--",
    }
    if historical then
      args = {
        git.git_path(), "-C", spec.history.repo.root, "--literal-pathspecs", "grep",
        "--no-textconv", "--no-recurse-submodules", "--full-name", "-n", "--column", "-z",
        "--color=never", "-i", "-I", "-F", "-e", spec.matcher.seed, spec.history.revision, "--",
      }
    end
    for _, file in ipairs(batch) do
      local path = historical and file.revision_path or file.abs_path
      by_path[historical and path or common.path_compare_key(path)] = file
      args[#args + 1] = path
    end
    local pending = ""
    run(job, args, nil, function(chunk)
      pending = pending .. chunk
      local first = 1
      while true do
        local path_end = pending:find("\0", first, true)
        local last = path_end and pending:find("\n", path_end + 1, true)
        if not last then break end
        local path = pending:sub(first, path_end - 1)
        local pattern = historical and "^(%d+)%z(%d+)%z(.*)$" or "^(%d+):(%d+):(.*)$"
        local line, col, text = pending:sub(path_end + 1, last - 1):match(pattern)
        if historical then path = path:sub(#spec.history.revision + 2) end
        local source = by_path[historical and path or common.path_compare_key(path)]
        if source and line then
          text = text:gsub("\r$", "")
          local match = spec.matcher.match(text)
          if match then
            local result = common.merge(source, match)
            result.kind, result.text = "grep", text
            result.line, result.col = tonumber(line), tonumber(col)
            result.file_spans = source.match_spans
            result.path_score = source.score
            result.path_match_class = spec.path_match_class(spec.base, source.file)
            visit(result)
          end
        end
        first = last + 1
        checkpoint(job)
      end
      pending = pending:sub(first)
      if #pending > 16 * 1024 * 1024 then error("A search result line is too large", 0) end
    end, true)
    batch, bytes = {}, 0
  end
  for _, file in ipairs(candidates) do
    local length = #(file.revision_path or file.abs_path) * 2 + 4
    if #batch > 0 and bytes + length > 12000 then flush() end
    batch[#batch + 1], bytes = file, bytes + length
  end
  flush()
end

function search.start(spec, publish)
  local job = { cancelled = false, deadline = system.get_time() + 0.002 }
  function job:cancel()
    self.cancelled = true
    if self.proc then self.proc:terminate() end
    if self.git_job then self.git_job:cancel() end
  end
  core.add_thread(function()
    local ok, err = pcall(function()
      local results, count = {}, 0
      local less = spec.grep and not spec.options.sort and spec.grep_less
        or function(a, b) return modifiers.less(spec.options, a, b) end
      local last_publish = system.get_time()
      local function emit(done)
        local out = {}
        for i, result in ipairs(results) do out[i] = result end
        if spec.grep and not spec.options.sort then out = spec.grep_results(out) end
        publish(out, string.format("%d %s%s", count, count == 1 and "match" or "matches",
          done and "" or " — searching…"), count > #out, done)
        last_publish = system.get_time()
      end
      local function visit(result, ordered)
        checkpoint(job)
        count = count + 1
        -- Everything orders the complete result set before paging. Keep that order.
        local low, high = ordered and #results + 1 or 1, #results + 1
        while low < high do
          local mid = math.floor((low + high) / 2)
          if less(result, results[mid]) then high = mid else low = mid + 1 end
        end
        if low <= spec.limit then
          table.insert(results, low, result)
          if #results > spec.limit then table.remove(results) end
        end
        if system.get_time() - last_publish >= 0.1 then emit(false) end
      end
      local candidates_from = spec.options.commit and revision_candidates or file_candidates
      if spec.path_plan and (spec.path_plan.external or spec.path_plan.project_scope) then
        count = path_candidates(job, spec, visit) or count
      elseif spec.grep then
        if spec.matcher.seed == "" then
          publish({}, "Type text after # to search inside files", false, true)
          return
        end
        local candidates = {}
        candidates_from(job, spec, function(file) candidates[#candidates + 1] = file end)
        grep_files(job, spec, candidates, visit)
      else
        candidates_from(job, spec, visit)
      end
      checkpoint(job)
      emit(true)
      core.log_quiet("Search Modifiers: completed files=%d sort=%s", count, spec.options.sort or "match")
    end)
    if job.proc then job.proc:terminate(); job.proc = nil end
    if job.file then job.file:close(); job.file = nil end
    if not ok and not job.cancelled then
      core.log_quiet("Search Modifiers: failed: %s", tostring(err))
      publish({}, tostring(err), false, true)
    end
  end)
  return job
end

return search
