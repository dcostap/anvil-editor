-- Project content for this Project process. A Project on another Machine reaches its files only
-- through this module. The Buffer's open and save flow and `core.project_files` use it (docs/machines.md).
local json = require "core.json"
local MachineClient = require "core.machine_client"
local machine_guard = require "core.machine_guard"

local fs = {}
local reconnect_listeners = {}

-- The Machine of this Project process, or nil when the Project is on this PC.
---@type core.machine_client?
fs.machine = nil

-- `path` names a Machine file: the local server's `server.json` or a paired Machine's record.
-- `roots` lists the Project's paths. The raw file functions then refuse them (`core.machine_guard`).
-- Only tests call this until Projects on other Machines exist.
function fs.use_machine(path, roots)
  fs.use_local()
  machine_guard.enable(roots)
  fs.machine = MachineClient.new(path, function(reconnect)
    if not reconnect then return end
    for _, listener in ipairs(reconnect_listeners) do listener() end
  end)
end

function fs.use_local()
  if fs.machine then fs.machine:close() end
  fs.machine = nil
  machine_guard.disable()
end

-- True when `path` names a file of the Machine. Such paths cannot use the raw file functions.
function fs.on_machine(path)
  return machine_guard.owns(path)
end

-- `listener()` runs after each reconnect, because the Client missed the Machine's changes.
function fs.on_reconnect(listener)
  reconnect_listeners[#reconnect_listeners + 1] = listener
end

-- `on_done(err, bytes, version)`. A missing file gives the error code `not_found`.
function fs.read(path, on_done)
  fs.machine:request("files.read", {path = path}, nil, function(err, result, bytes)
    if err then return on_done(err) end
    on_done(nil, bytes, result.version)
  end)
end

-- Replaces the whole file, only while it has the version `base`. A nil `base` only creates a file.
-- `save` is an ID for `fs.save_result`. `on_done(err, version)`. A `conflict` error has the current
-- `version`. A `disconnected` error means that the write can have happened.
function fs.write(path, bytes, base, save, on_done)
  fs.machine:request("files.write", {path = path, base = base, save = save}, bytes, function(err, result)
    if err then return on_done(err) end
    on_done(nil, result.version)
  end)
end

-- Calls `fn(..., on_done)` and waits for `on_done` in this coroutine. Returns its arguments.
function fs.wait(fn, ...)
  local result
  local args = table.pack(...)
  args[args.n + 1] = function(...) result = table.pack(...) end
  fn(table.unpack(args, 1, args.n + 1))
  while not result do coroutine.yield(0.005) end
  return table.unpack(result, 1, result.n)
end

-- Splits NUL-separated names: the first `count` go to the first list, the rest to the second.
local function split(bytes, count)
  local first, second = {}, {}
  if bytes == "" then return first, second end
  for name in (bytes .. "\0"):gmatch("(.-)%z") do
    if #first < count then first[#first + 1] = name else second[#second + 1] = name end
  end
  return first, second
end

-- `on_done(err, files, folders, changes)`. Paths are relative to `root`. `changes` is the sequence for
-- `fs.changes`. `include_ignored` also lists the files that the ignore rules hide.
function fs.list(root, include_ignored, on_done)
  fs.machine:request("files.list", {root = root, ignored = include_ignored or nil}, nil, function(err, result, bytes)
    if err then return on_done(err) end
    local files, folders = split(bytes, result.files)
    on_done(nil, files, folders, result.changes)
  end)
end

-- Waits for a change after the sequence `since`. `on_done(err, result)`: `result.paths` lists relative paths,
-- `result.sequence` is the next `since`, and `result.reset` means that the list must be read again.
function fs.changes(root, since, on_done)
  fs.machine:request("files.changes", {root = root, since = since}, nil, function(err, result)
    on_done(err, result)
  end)
end

-- `on_done(err, results)`: `{type, size, modified}` or false for each path.
function fs.stat(paths, on_done)
  fs.machine:request("files.stat", {paths = paths}, nil, function(err, _, bytes)
    if err then return on_done(err) end
    on_done(nil, json.decode(bytes))
  end)
end

-- `on_done(err, entries)`: `{name, type, size, modified}` for each entry of the folder.
function fs.list_dir(path, on_done)
  fs.machine:request("files.list_dir", {path = path}, nil, function(err, _, bytes)
    if err then return on_done(err) end
    on_done(nil, json.decode(bytes))
  end)
end

-- `on_done(err, version)` with the version that the save wrote, or the error `unknown_save`.
function fs.save_result(save, on_done)
  fs.machine:request("files.save_result", {save = save}, nil, function(err, result)
    if err then return on_done(err) end
    on_done(nil, result.version)
  end)
end

return fs
