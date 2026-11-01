-- A Project on another Machine has one key in the Sidebar, Shell App State, recent Projects and Workspaces:
-- `anvil-machine://<Machine ID>/<path on the Machine>`. Inside its Project process, paths stay native paths.
local fs = require "core.fs"

local machine_project = {}

local PREFIX = "anvil-machine://"

-- The key of this process's Project when it is on another Machine, or nil.
machine_project.current = nil

function machine_project.key(machine, path)
  return PREFIX .. machine .. "/" .. path
end

-- Returns the Machine ID and the path of a key, or nil for another value.
function machine_project.parse(key)
  if type(key) ~= "string" then return end
  return key:match("^anvil%-machine://(%x+)/(.+)$")
end

function machine_project.is_key(value)
  return machine_project.parse(value) ~= nil
end

-- The Machine file for `fs.use_machine`: this PC's own server, or the record of a paired Machine.
function machine_project.machine_file(machine)
  local directory = USERDIR .. PATHSEP .. "machine"
  local file = io.open(directory .. PATHSEP .. "id", "rb")
  local own = file and file:read("*a")
  if file then file:close() end
  if own == machine then return directory .. PATHSEP .. "server.json" end
  return USERDIR .. PATHSEP .. "machines" .. PATHSEP .. machine .. ".json"
end

-- Connects this Project process to the Machine of `key`, and returns the Project's path on the Machine.
function machine_project.use(key)
  local machine, path = machine_project.parse(key)
  fs.use_machine(machine_project.machine_file(machine), { path })
  machine_project.current = key
  return path
end

-- The name of this process's Project in the Sidebar and other processes: its key on a Machine, or its path.
function machine_project.root_key(path)
  return machine_project.current or path
end

-- The name of a folder that opens as a Project: a folder on this process's Machine gets its key.
-- Other paths and keys stay unchanged.
function machine_project.folder_key(path)
  local machine = machine_project.parse(machine_project.current)
  if machine and not machine_project.is_key(path) and fs.on_machine(path) then
    return machine_project.key(machine, path)
  end
  return path
end

return machine_project
