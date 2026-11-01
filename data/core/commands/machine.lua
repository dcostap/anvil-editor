local core = require "core"
local common = require "core.common"
local command = require "core.command"
local json = require "core.json"
local MachineClient = require "core.machine_client"
local machine_project = require "core.machine_project"

-- Asks for one of `choices` (a label to value map) and calls `on_choice(value)`.
local function choose(label, choices, on_choice)
  local labels = {}
  for text in pairs(choices) do labels[#labels + 1] = text end
  table.sort(labels)
  core.global_prompt_bar:enter(label, {
    suggest = function(text) return common.fuzzy_match(labels, text) end,
    validate = function(text, suggestion)
      return choices[type(suggestion) == "table" and suggestion.text or suggestion or text] ~= nil
    end,
    submit = function(text, suggestion)
      on_choice(choices[type(suggestion) == "table" and suggestion.text or suggestion or text])
    end,
  })
end

-- The paired Machines, as a label to record path map.
local function paired_machines()
  local directory = USERDIR .. PATHSEP .. "machines"
  local machines = {}
  for _, name in ipairs(system.list_dir(directory) or {}) do
    local path = directory .. PATHSEP .. name
    local file = name:match("^%x+%.json$") and io.open(path, "rb")
    local ok, record = pcall(json.decode, file and file:read("*a") or "")
    if file then file:close() end
    if ok and type(record) == "table" and record.machine and record.host then
      machines[string.format("%s:%s", record.host, tostring(record.port))] = record.machine
    end
  end
  return machines
end

-- Asks the Machine for its Projects, then lets the user choose one.
local function choose_project(machine)
  local client = MachineClient.new(machine_project.machine_file(machine))
  client:request("projects.list", {}, nil, function(err, result)
    client:close()
    if err then return core.error("Cannot list the Machine's Projects: %s", err.message or err.code) end
    local projects = {}
    for _, project in ipairs(result.projects or {}) do
      if type(project.path) == "string" then projects[project.path] = project.path end
    end
    choose("Project on the Machine", projects, function(path)
      local key = machine_project.key(machine, path)
      core.log_quiet("Open a Project on a Machine: %s", key)
      if not core.open_project_in_same_window(key) then core.error("Cannot open %s", path) end
    end)
  end)
end

local function parse_address(text)
  local host, port = text:match("^%s*([^%s:]+):(%d+)%s*$")
  return host, tonumber(port)
end

command.add(nil, {
  -- On the Machine, `anvil machine code full` prints the pairing code and the port.
  ["machine:pair"] = command.palette(function()
    core.global_prompt_bar:enter("Machine address (host:port)", {
      validate = function(text) return parse_address(text) ~= nil end,
      submit = function(address)
        local host, port = parse_address(address)
        core.global_prompt_bar:enter("Pairing code", {
          submit = function(code)
            local name = os.getenv("COMPUTERNAME") or os.getenv("HOSTNAME") or "Anvil"
            MachineClient.pair(host, port, code:match("^%s*(.-)%s*$"), name, function(err)
              if err then return core.error("Pairing with %s failed: %s", address, err.message or err.code) end
              core.log("Paired with the Machine at %s", address)
            end)
          end,
        })
      end,
    })
  end),

  -- The Project opens as a separate Sidebar Project with a Machine key (`core.machine_project`).
  ["machine:open_project"] = command.palette(function()
    if not system.is_hosted_surface() then return core.error("A Project on a Machine opens only in the Anvil shell") end
    local machines = paired_machines()
    if next(machines) == nil then return core.error("Pair with a Machine first") end
    choose("Machine", machines, choose_project)
  end),
})
