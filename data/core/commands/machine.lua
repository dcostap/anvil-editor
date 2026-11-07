local core = require "core"
local common = require "core.common"
local command = require "core.command"
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

-- The paired Machines, as a label to Machine ID map.
local function paired_machines()
  local machines = {}
  for _, record in ipairs(MachineClient.records()) do
    machines[string.format("%s:%s", record.host, tostring(record.port))] = record.machine
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

command.add(nil, {
  -- The Machines Dialog: this PC's access, pairing codes and devices, and the paired Machines.
  ["machine:manage"] = command.palette(function()
    require("core.machine_dialog").open()
  end),

  -- Opens the Machines Dialog at its pairing fields.
  ["machine:pair"] = command.palette(function()
    require("core.machine_dialog").open({ pair = true })
  end),

  -- The Project opens as a separate Sidebar Project with a Machine key (`core.machine_project`).
  -- `machine` is a Machine ID. Without it, the command asks for the Machine.
  ["machine:open_project"] = command.palette(function(machine)
    if not system.is_hosted_surface() then return core.error("A Project on a Machine opens only in the Anvil shell") end
    if type(machine) == "string" then return choose_project(machine) end
    local machines = paired_machines()
    if next(machines) == nil then return core.error("Pair with a Machine first") end
    choose("Machine", machines, choose_project)
  end),
})
