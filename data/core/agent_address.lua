local json = require "core.json"

return function(project, pane, terminal)
  local machines = require "core.machine_project"
  local own = not machines.is_key(project) and machines.own_id()
  if own then project = machines.key(own, project) end
  system.set_clipboard(json.encode({
    type = "anvil-agent-address", project = project, pane = pane, terminal = terminal,
    name = require("core.agent_name").for_terminal(terminal),
  }))
end
