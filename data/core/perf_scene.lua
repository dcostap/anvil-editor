-- Runs a shared scene module (`scenes.<name>`) as a benchmark workload.
-- Only the isolated benchmark plugin loads this module.
local core = require "core"
local Scene = {}
Scene.__index = Scene

function Scene.new(settings, root)
  local module = require("scenes." .. settings.scene)
  local context = require("scenes.support").context(settings, root)
  return setmetatable({ settings = settings, root = root, completed = 0,
                        module = module, context = context }, Scene)
end

function Scene:setup()
  local view = self.module.setup(self.context)
  self.context.view = view or self.context.view
  self.view = self.context.view
  core.log_quiet("Scene setup: %s root=%s", self.settings.scene, tostring(self.root))
  core.redraw = true
  return self.view
end

function Scene:setup_ready()
  local ready = not self.module.ready or self.module.ready(self.context)
  self.view = self.context.view
  return ready
end

function Scene:action_name(index)
  return self.module.action_name and self.module.action_name(self.context, index) or self.settings.scene
end

function Scene:dispatch(index)
  self.index = index
  self.module.dispatch(self.context, index)
  self.view = self.context.view
  core.redraw = true
end

function Scene:action_ready()
  local ready, result = self.module.action_ready(self.context, self.index)
  self.view = self.context.view
  if ready then self.result = result or "ok" end
  return ready, self.result
end

---Report whether the scene drives its own actions from a coroutine.
---Scenes that span processes use this, because another process presents their result.
function Scene:runs_itself()
  return self.module.run ~= nil
end

---Run a self-driven scene. `record(row)` adds one action with its measured latency.
function Scene:run(record)
  self.context.record = function(row)
    self.completed = self.completed + 1
    self.result = row.result or "ok"
    record(row)
  end
  self.module.run(self.context)
end

function Scene:capture_ready()
  return not self.module.capture_ready or self.module.capture_ready(self.context)
end

function Scene:state()
  local state = { workload_kind = "scene", workload_result = self.result or "",
                  workload_actions = self.completed }
  for key, value in pairs(self.module.state and self.module.state(self.context) or {}) do
    state["scene_" .. key] = value
  end
  return state
end

return Scene
