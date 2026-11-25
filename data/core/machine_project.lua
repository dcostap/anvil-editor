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

-- Names are presentation only. Keep the full key for routing and storage.
local tags = {}
function machine_project.tag(id)
  if type(id) ~= "string" or not id:match("^%x+$") then return "Machine" end
  if not tags[id] then
    tags[id] = "Machine " .. id:sub(1, 8)
    require("core.worker_pool").named("file_io", {worker_count = 1}):submit {
      kind = "file_read", payload = {path = USERDIR .. PATHSEP .. "machines" .. PATHSEP .. id .. ".json"},
      on_result = function(message)
        local bytes = message.payload.bytes
        if not bytes then return end
        local ok, record = pcall(require("core.json").decode, bytes)
        if ok and type(record) == "table" and record.machine == id and type(record.host) == "string"
            and record.host ~= "" and not record.host:find("%c") then
          tags[id] = record.host .. (record.port and record.port ~= 7690 and ":" .. tostring(record.port) or "")
          local core = require "core"
          core.redraw = true
          local picker = core.fuzzy_searcher_active_view
          if picker and picker.input then picker:refresh(picker.input:get_text()) end
        end
      end,
    }
  end
  return tags[id]
end

function machine_project.label(key, full_path)
  local id, path = machine_project.parse(key)
  if not id then return end
  local name = full_path and path or path:match("([^/\\]+)[/\\]*$") or path
  return name .. " @ " .. machine_project.tag(id)
end

function machine_project.own_id()
  local directory = USERDIR .. PATHSEP .. "machine"
  local file = io.open(directory .. PATHSEP .. "id", "rb")
  local own = file and file:read("*a")
  if file then file:close() end
  return own and own:match("^%x+$")
end

-- The Machine file for `fs.use_machine`: this PC's own server, or the record of a paired Machine.
function machine_project.machine_file(machine)
  if machine_project.own_id() == machine then return USERDIR .. PATHSEP .. "machine" .. PATHSEP .. "server.json" end
  return USERDIR .. PATHSEP .. "machines" .. PATHSEP .. machine .. ".json"
end

-- Connects this Project process to the Machine of `key`, and returns the Project's path on the Machine.
function machine_project.use(key)
  local machine, path = machine_project.parse(key)
  local common = require "core.common"
  local guarded, seen = {path}, {[common.path_compare_key(path)] = true}
  machine_project.paths = nil
  fs.use_machine(machine_project.machine_file(machine), { path }, function(client)
    local supported = false
    for _, method in ipairs(client.features or {}) do supported = supported or method == "projects.paths" end
    if not supported then return end
    client:request("projects.paths", {project = path}, nil, function(err, state)
      if fs.machine ~= client then return end
      if err then return require("core").log_quiet("Machine Project Paths: %s", err.message) end
      local roots = {path}
      for _, entry in ipairs(state.entries) do
        roots[#roots + 1] = entry.path
        local id = common.path_compare_key(entry.path)
        if not seen[id] then guarded[#guarded + 1], seen[id] = entry.path, true end
      end
      -- An open View of a removed root must not start reading the Client's disk.
      require("core.machine_guard").set_roots(guarded)
      fs.roots, machine_project.paths = roots, state
      local core = require "core"
      if core.workspace_restored then
        local _, changed = require("core.project_paths").load_workspace_state(state)
        if changed then core.refresh_project_path_consumers("Machine Project Paths") end
      end
    end)
  end)
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
