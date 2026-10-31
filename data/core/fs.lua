-- Project content for this Project process. A Project on another Machine reaches its files only
-- through this module. For now only the Buffer's open and save flow uses it (docs/machines.md).
local MachineClient = require "core.machine_client"

local fs = {}

-- The Machine of this Project process, or nil when the Project is on this PC.
---@type core.machine_client?
fs.machine = nil

-- `discovery` names the Machine server's `server.json`. Only tests call this until
-- Projects on other Machines exist.
function fs.use_machine(discovery)
  fs.use_local()
  fs.machine = MachineClient.new(discovery)
end

function fs.use_local()
  if fs.machine then fs.machine:close() end
  fs.machine = nil
end

-- `on_done(err, bytes, version)`. A missing file gives the error code `not_found`.
function fs.read(path, on_done)
  fs.machine:request("files.read", {path = path}, nil, function(err, result, bytes)
    if err then return on_done(err) end
    on_done(nil, bytes, result.version)
  end)
end

-- Replaces the whole file, only while it has the version `base`. A nil `base` only creates a file.
-- `on_done(err, version, current)`. A `conflict` error carries the Machine's current bytes.
function fs.write(path, bytes, base, on_done)
  fs.machine:request("files.write", {path = path, base = base}, bytes, function(err, result, current)
    if err then return on_done(err, nil, current) end
    on_done(nil, result.version)
  end)
end

return fs
