-- Project content for this Project process. A Project on another Machine reaches its files only
-- through this module. For now only the Buffer's open and save flow uses it (docs/machines.md).
local MachineClient = require "core.machine_client"

local fs = {}
local reconnect_listeners = {}

-- The Machine of this Project process, or nil when the Project is on this PC.
---@type core.machine_client?
fs.machine = nil

-- `discovery` names the Machine server's `server.json`. Only tests call this until
-- Projects on other Machines exist.
function fs.use_machine(discovery)
  fs.use_local()
  fs.machine = MachineClient.new(discovery, function(reconnect)
    if not reconnect then return end
    for _, listener in ipairs(reconnect_listeners) do listener() end
  end)
end

function fs.use_local()
  if fs.machine then fs.machine:close() end
  fs.machine = nil
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

-- `on_done(err, version)` with the version that the save wrote, or the error `unknown_save`.
function fs.save_result(save, on_done)
  fs.machine:request("files.save_result", {save = save}, nil, function(err, result)
    if err then return on_done(err) end
    on_done(nil, result.version)
  end)
end

return fs
