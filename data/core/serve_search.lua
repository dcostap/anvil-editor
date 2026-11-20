-- The Search service of the Machine server (`core.serve`): ripgrep in a Project, for Text Search on a Client.
-- The Client sends the ripgrep arguments. Each option must be on a fixed list, and each path must be in a Project.
-- The server runs its own ripgrep, not the program that the Client names.
local core = require "core"
local common = require "core.common"
local process_stream = require "core.process_stream"

local search = {}

-- The options that the server accepts, with the number of values each takes. Options that run programs or
-- write files, such as `--pre`, are not on the list.
local OPTIONS = {
  ["--no-config"] = 0, ["--null"] = 0, ["--line-number"] = 0, ["--column"] = 0, ["--no-heading"] = 0,
  ["--with-filename"] = 0, ["-i"] = 0, ["-F"] = 0, ["-u"] = 0, ["--color"] = 1, ["--max-columns"] = 1, ["-e"] = 1,
}

-- ripgrep omits a line longer than this many bytes, so one line cannot fill the memory. A Client value
-- above it, or 0 (no limit), becomes this value.
local MAX_COLUMNS = 64 * 1024

-- Returns the indexes of the path arguments, or nil and an error. `args[1]` is the program. It sets each
-- `--max-columns` value to at most MAX_COLUMNS.
local function path_indexes(args)
  local paths, i, filenames = {}, 2, false
  while i <= #args do
    local arg = args[i]
    if type(arg) ~= "string" then return nil, "Each argument must be text" end
    if arg == "--" then
      for j = i + 1, #args do
        if type(args[j]) ~= "string" then return nil, "Each argument must be text" end
        paths[#paths + 1] = j
      end
      break
    end
    local count = OPTIONS[arg]
    if count then
      if arg == "--with-filename" then filenames = true end
      local value = args[i + 1]
      if count == 1 and type(value) ~= "string" then return nil, arg .. " needs a value" end
      if arg == "--color" and value ~= "never" then return nil, "--color must be never" end
      if arg == "--max-columns" and not value:match("^%d+$") then return nil, "--max-columns must be a number" end
      if arg == "--max-columns" and (tonumber(value) == 0 or tonumber(value) > MAX_COLUMNS) then
        args[i + 1] = tostring(MAX_COLUMNS)
      end
      i = i + count
    elseif arg:sub(1, 1) == "-" then
      return nil, "The Machine does not run ripgrep with " .. arg
    else
      paths[#paths + 1] = i
    end
    i = i + 1
  end
  return paths, nil, filenames
end
-- A reply carries at most CHUNK bytes. A search stops reading ripgrep while it holds that much unread output.
local CHUNK, MAX_SEARCHES, IDLE_SECONDS = 1024 * 1024, 16, 30

-- A glob reads [ ] { } * ? as patterns. A character class holds each one as itself. A backslash does not
-- escape on Windows, where it separates folders.
local function glob_literal(text)
  return (text:gsub("[%[%]{}%*%?]", "[%0]"))
end

local function ripgrep_path()
  if PLATFORM ~= "Windows" then return "rg" end
  local bundled = DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "fuzzy_searcher" .. PATHSEP .. "rg.exe"
  if system.get_file_info(bundled) then return bundled end
  return "rg"
end

-- `server` gives: reply, fail, check_path, private and log.
function search.new(server)
  local searches, order, sequence = {}, {}, 0

  -- A read that waits for a removed search gets an error, so the Client does not wait for ever.
  local function remove(state)
    if searches[state.id] ~= state then return end
    searches[state.id] = nil
    for i, id in ipairs(order) do
      if id == state.id then table.remove(order, i) break end
    end
    state.stream:cancel()
    local waiter = state.waiter
    state.waiter = nil
    if waiter and not state.client.dead then server.fail(state.client, waiter, "not_found", "The search has ended") end
  end

  local function answer(state)
    local waiter = state.waiter
    if not waiter or (#state.output == 0 and not state.finished) then return end
    state.waiter = nil
    local bytes = table.concat(state.output)
    state.output, state.bytes = {}, 0
    local result = {done = state.finished or nil}
    if state.finished then
      result.code, result.error = state.stream.exit_code, state.stream.error
      remove(state)
    end
    server.reply(state.client, waiter, {result = result}, bytes)
  end

  -- Keep result paths in the requested cwd, while ripgrep uses its checked disk path.
  local function pump(state)
    while searches[state.id] == state do
      if state.client.dead or system.get_time() - state.last_read > IDLE_SECONDS then
        server.log("Machine server search ends: id=%s client=%s", state.id, state.client.dead and "gone" or "idle")
        return remove(state)
      end
      local line = state.bytes < CHUNK and state.stream:read_line()
      if line then
        if state.disk_prefix then
          local prefix = line:sub(1, #state.disk_prefix):gsub("\\", "/")
          if PLATFORM == "Windows" then prefix = prefix:lower() end
          if prefix == state.disk_prefix then
            line = state.result_prefix .. line:sub(#state.disk_prefix + 1)
          end
        end
        state.output[#state.output + 1] = line .. "\n"
        state.bytes = state.bytes + #line + 1
      else
        if state.stream.done and state.bytes < CHUNK then state.finished = true end
        answer(state)
        if state.finished then return end
        coroutine.yield(0.004)
      end
    end
  end

  -- `search.start {args, cwd}` starts ripgrep and gives its `id`. `args[1]` names the program and is ignored.
  local function start(client, id, params)
    if type(params.args) ~= "table" then return server.fail(client, id, "invalid_request", "args must be a list") end
    local cwd, code, message, disk_cwd = server.check_path(params.cwd)
    if not cwd then return server.fail(client, id, code, message) end
    local indexes, err, filenames = path_indexes(params.args)
    if not indexes then return server.fail(client, id, "invalid_request", err) end
    filenames = filenames or #indexes ~= 1
    local command = {ripgrep_path()}
    for i = 2, #params.args do command[i] = params.args[i] end
    for _, i in ipairs(indexes) do
      local path = command[i]
      -- ripgrep reads `\x` from the drive's root and `C:x` from the drive's current folder, not from `cwd`.
      if not common.is_absolute_path(path) and (path:match("^[/\\]") or path:match("^%a:")) then
        return server.fail(client, id, "invalid_path", "A path must be absolute or relative to cwd")
      end
      local absolute = common.is_absolute_path(path) and path or (cwd .. PATHSEP .. path)
      local normalized_ok, normalized = pcall(common.normalize_path, absolute)
      if not normalized_ok then return server.fail(client, id, "invalid_path", "The path is not valid") end
      local checked, path_code, path_message, disk = server.check_path(normalized)
      if not checked then return server.fail(client, id, path_code, path_message) end
      -- The credential exclusions below hold only for paths in `cwd`.
      if not common.path_equals(disk, disk_cwd) and not common.path_belongs_to(disk, disk_cwd) then
        return server.fail(client, id, "invalid_path", "A search path must be in cwd")
      end
      -- Pass the checked spelling to ripgrep, so its exclusions see the same names.
      command[i] = common.is_absolute_path(path) and disk or common.relative_path(disk_cwd, disk)
      if command[i]:sub(1, 1) == "-" then command[i] = "." .. PATHSEP .. command[i] end
      if not filenames then
        local info = system.get_file_info(disk)
        filenames = info and info.type == "dir"
      end
    end
    -- ripgrep skips the credential folders in the folders that it searches. A glob that starts with `/` names a
    -- path from ripgrep's working folder.
    local excluded = {}
    for _, folder in ipairs(server.private) do
      if common.path_belongs_to(folder, disk_cwd) then
        excluded[#excluded + 1] = "--glob"
        excluded[#excluded + 1] = "!/" .. glob_literal((common.relative_path(disk_cwd, folder):gsub("\\", "/")))
      end
    end
    if #excluded > 0 then table.insert(excluded, 1, "--glob-case-insensitive") end
    -- A Client that gives no --max-columns gets MAX_COLUMNS.
    table.insert(excluded, 1, tostring(MAX_COLUMNS))
    table.insert(excluded, 1, "--max-columns")
    table.insert(excluded, 1, "--no-config")
    for j = #excluded, 1, -1 do table.insert(command, 2, excluded[j]) end
    local stream, start_error = process_stream.start(command, {cwd = disk_cwd})
    if not stream then return server.fail(client, id, "search_failed", tostring(start_error)) end
    if #order >= MAX_SEARCHES then remove(searches[order[1]]) end
    sequence = sequence + 1
    local state = {id = tostring(sequence), client = client, stream = stream, output = {}, bytes = 0,
      last_read = system.get_time()}
    if filenames and not common.path_equals(cwd, disk_cwd) then
      state.disk_prefix = disk_cwd:gsub("\\", "/"):gsub("/+$", "") .. "/"
      if PLATFORM == "Windows" then state.disk_prefix = state.disk_prefix:lower() end
      state.result_prefix = cwd:gsub("[/\\]+$", "") .. PATHSEP
    end
    searches[state.id], order[#order + 1] = state, state.id
    core.add_thread(function() pump(state) end)
    server.reply(client, id, {result = {id = state.id}})
  end

  local function find(client, id, params)
    local state = searches[params.id]
    if state and state.client == client then return state end
    server.fail(client, id, "not_found", "The search has ended")
  end

  -- `search.read {id}` waits for output. Its reply carries the records in the bytes. `done = true` ends the
  -- search and gives ripgrep's exit `code`.
  local function read(client, id, params)
    local state = find(client, id, params)
    if not state then return end
    state.waiter, state.last_read = id, system.get_time()
    answer(state)
  end

  local function cancel(client, id, params)
    local state = find(client, id, params)
    if not state then return end
    remove(state)
    server.reply(client, id, {result = {}})
  end

  return {["search.start"] = start, ["search.read"] = read, ["search.cancel"] = cancel}
end

return search
