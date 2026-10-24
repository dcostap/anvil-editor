-- A deliberately incomplete UI producer checks whether the harness hides missing redraws.
local core = require "core"
local config = require "core.config"
local panes = require "core.panes"
local View = require "core.view"
local scene = {}

function scene.setup(context)
  config.transitions = false
  config.fps = 20
  local ProbeView = View:extend()
  function ProbeView:update() end
  function ProbeView:draw()
    context.drawn = context.value
    if context.deadline and system.get_time() + 0.001 < context.deadline then
      context.early_draws = context.early_draws + 1
    end
    context.deadline = nil
    if context.late_result then
      context.late_result = false
      core.add_thread(function()
        coroutine.yield(0.02)
        context.ready = true -- Deliberately omit the redraw after publication.
      end)
    end
  end
  context.value, context.drawn = 0, 0
  context.early_draws = 0
  return panes.place(function() return ProbeView() end, { placement = "new", focus = true })
end

function scene.ready(context)
  return require("scenes.support").background_settled(context)
end

function scene.dispatch(context, index)
  context.value = index
  context.ready = not context.settings.late_result
  context.late_result = context.settings.late_result
  local snapshot = core.performance_snapshot
  context.deadline = snapshot.time + snapshot.next_frame_due_ms / 1000
  if context.settings.request_redraw then core.redraw = true end
end

function scene.action_ready(context) return context.ready, "changed" end
function scene.action_visible(context) return context.drawn == context.value end
function scene.state(context) return { early_draws = context.early_draws } end

return scene
