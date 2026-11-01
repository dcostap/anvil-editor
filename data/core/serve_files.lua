-- The Files service of the Machine server (`core.serve`): file lists, stats, folder listings and change notices.
-- The file list is the editor's own scan (`core.project_files`), so a Client gets the same files as a local Project.
-- Paths in lists and change notices are relative to the Project root, with `/` or `\` as on the Machine.
local core = require "core"
local common = require "core.common"
local json = require "core.json"
local project_files = require "core.project_files"

local files = {}
local MAX_STAT_PATHS, MAX_CHANGE_BATCHES, MAX_CHANGE_PATHS = 4096, 64, 4096

-- `server` gives: reply, fail, check_path (path -> path or nil, code, message), disk_path, project_root, log.
function files.new(server)
  local roots = {}

  local function relative(state, path)
    path = common.normalize_path(path)
    if common.path_equals(path, state.disk_root) then return "" end
    return path:sub(#state.disk_root + 2)
  end

  -- Replies to each waiting `files.changes` with the batches after its `since`.
  local function answer_waiters(state)
    local first = state.batches[1]
    for i = #state.waiters, 1, -1 do
      local waiter = state.waiters[i]
      if waiter.client.dead then
        table.remove(state.waiters, i)
      elseif waiter.since < state.sequence then
        table.remove(state.waiters, i)
        local result = {sequence = state.sequence}
        if not first or waiter.since < first.sequence - 1 then
          result.reset = true
        else
          local paths, seen = {}, {}
          for _, batch in ipairs(state.batches) do
            if batch.sequence > waiter.since then
              result.refreshed = result.refreshed or batch.refreshed
              for _, path in ipairs(batch.paths) do
                if not seen[path] then seen[path], paths[#paths + 1] = true, path end
              end
            end
          end
          if #paths > MAX_CHANGE_PATHS then result.reset = true else result.paths = paths end
        end
        server.reply(waiter.client, waiter.id, {result = result})
      end
    end
  end

  -- The first list of a Project starts its folder watcher. The watcher stays while the server runs.
  local function root_state(root)
    local key = common.path_compare_key(root)
    if roots[key] then return roots[key] end
    local state = {root = root, disk_root = common.normalize_path(server.disk_path(root)), sequence = 0,
      batches = {}, waiters = {}}
    roots[key] = state
    project_files.subscribe(state.disk_root, "machine", function(paths, event)
      local batch = {paths = {}, refreshed = event.refreshed or nil}
      for key_path, value in pairs(paths) do
        local path = type(key_path) == "number" and value or key_path
        if type(path) == "string" then batch.paths[#batch.paths + 1] = relative(state, path) end
      end
      state.sequence = state.sequence + 1
      batch.sequence = state.sequence
      state.batches[#state.batches + 1] = batch
      if #state.batches > MAX_CHANGE_BATCHES then table.remove(state.batches, 1) end
      server.log("Machine server change notice: root=%s sequence=%d paths=%d", root, state.sequence, #batch.paths)
      answer_waiters(state)
    end)
    return state
  end

  -- `files.list {root, ignored}` gives the Project's files, then its folders, separated by NUL bytes.
  -- `files` counts the files. `changes` is the sequence to pass to `files.changes`. `ignored = true` also
  -- lists the files that the ignore rules hide.
  local function list(client, id, params)
    local root = server.project_root(params.root)
    if not root then return server.fail(client, id, "not_a_project", "The root is not a Project of this Machine") end
    local state = root_state(root)
    core.add_thread(function()
      local found, err, directories = project_files.list(state.disk_root,
        {include_ignored = params.ignored == true, refresh = params.ignored == true})
      if client.dead then return end
      if not found then return server.fail(client, id, "list_failed", tostring(err)) end
      local names = {}
      for i, file in ipairs(found) do names[i] = file.relative end
      for _, directory in ipairs(directories or {}) do
        local name = relative(state, directory)
        if name ~= "" then names[#names + 1] = name end
      end
      local status = project_files.watch_status(state.disk_root)
      server.reply(client, id, {result = {files = #found, generation = status.generation, changes = state.sequence}},
        table.concat(names, "\0"))
    end)
  end

  -- `files.changes {root, since}` waits until a change after `since`. Its reply gives the changed paths and the
  -- new sequence. `reset = true` means that the Client must list the Project again.
  local function changes(client, id, params)
    local root = server.project_root(params.root)
    if not root then return server.fail(client, id, "not_a_project", "The root is not a Project of this Machine") end
    if type(params.since) ~= "number" then return server.fail(client, id, "invalid_request", "since must be a number") end
    local state = root_state(root)
    state.waiters[#state.waiters + 1] = {client = client, id = id, since = params.since}
    answer_waiters(state)
  end

  local function stat(path)
    local info = system.get_file_info(server.disk_path(path))
    return info and {type = info.type, size = info.size, modified = info.modified} or false
  end

  -- `files.stat {paths}` gives `{type, size, modified}` or false for each path, as JSON in the bytes.
  local function stat_paths(client, id, params)
    if type(params.paths) ~= "table" or #params.paths > MAX_STAT_PATHS then
      return server.fail(client, id, "invalid_request", "paths must be a list of at most " .. MAX_STAT_PATHS)
    end
    local results = {}
    for i, path in ipairs(params.paths) do
      local checked, code, message = server.check_path(path)
      if not checked then return server.fail(client, id, code, message) end
      results[i] = stat(checked)
    end
    server.reply(client, id, {result = {count = #results}}, json.encode(results))
  end

  -- `files.list_dir {path}` gives `{name, type, size, modified}` for each entry, as JSON in the bytes.
  local function list_dir(client, id, params)
    local path, code, message = server.check_path(params.path)
    if not path then return server.fail(client, id, code, message) end
    local names = system.list_dir(server.disk_path(path))
    if not names then return server.fail(client, id, "not_found", "The folder does not exist") end
    local entries = {}
    for _, name in ipairs(names) do
      local info = stat(path .. PATHSEP .. name)
      if info then
        info.name = name
        entries[#entries + 1] = info
      end
    end
    server.reply(client, id, {result = {count = #entries}}, json.encode(entries))
  end

  return {["files.list"] = list, ["files.changes"] = changes, ["files.stat"] = stat_paths,
    ["files.list_dir"] = list_dir}
end

return files
