local core = require "core"
local command = require "core.command"

command.add(nil, {
  ["machine:manage"] = command.palette(function()
    require("core.machine_dialog").open()
  end),
  ["machine:pair"] = command.palette(function()
    require("core.machine_dialog").open({ pair = true })
  end),
  ["machine:open_project"] = command.palette(function(machine)
    if not system.is_hosted_surface() then return core.error("A Project on a Machine opens only in the Anvil shell") end
    require("core.machine_dialog").open({ browse = true, machine = machine })
  end),
})
