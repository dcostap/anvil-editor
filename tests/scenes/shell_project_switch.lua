-- Switch the selected Project in one shell Window.
-- A cold switch starts the Project's process. A warm switch shows a loaded Project again.
-- Each latency is the shell's time from the selection to the Project's first composited frame.
local shell = require "scenes.shell"

local scene = {}

function scene.setup()
  return nil
end

function scene.run(context)
  local settings = context.settings
  local projects = settings.projects
  local loaded = math.min(settings.loaded or 4, #projects)
  local log = shell.log()
  -- projects[1] runs this scene and is already selected.
  for index = 2, loaded do
    local ms, started = shell.select_project(log, projects[index], settings.cold_timeout or 30)
    context.record { name = "cold-switch", latency_ms = ms, started = started, result = tostring(index) }
  end
  local current = loaded
  for _ = 1, settings.warm or 12 do
    local target = current % loaded + 1
    local ms, started = shell.select_project(log, projects[target])
    context.record { name = "warm-switch", latency_ms = ms, started = started, result = tostring(target) }
    current = target
  end
end

function scene.state(context)
  return { loaded = math.min(context.settings.loaded or 4, #context.settings.projects) }
end

return scene
