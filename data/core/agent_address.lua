local json = require "core.json"

return function(project, pane, terminal)
  system.set_clipboard(json.encode({
    type = "anvil-agent-address", project = project, pane = pane, terminal = terminal,
  }))
end
