-- One action completes only after a redraw contains its verified result.
local Object = require "core.object"
local Actions = Object:extend()

function Actions:new(clock, timeout)
  self.clock = clock
  self.timeout = timeout
  self.origin = clock()
  self.sequence = 0
end

function Actions:start(name, dispatch, ready)
  assert(not self.pending, "benchmark action is still pending")
  self.sequence = self.sequence + 1
  local start = self.clock()
  self.pending = {
    id = self.sequence, name = name, started = start,
    start_ms = (start - self.origin) * 1000, redraws = 0, ready = ready,
  }
  dispatch()
  self.pending.dispatch_ms = (self.clock() - start) * 1000
end

function Actions:check_timeout()
  local pending = self.pending
  if pending and self.clock() - pending.started > self.timeout then
    error("benchmark action timed out: " .. pending.name)
  end
end

function Actions:before_draw()
  self:check_timeout()
  local pending = self.pending
  if pending then
    local ready, result = pending.ready()
    pending.draw_ready = ready
    if ready and not pending.ready_ms then
      pending.ready_ms = (self.clock() - pending.started) * 1000
      pending.result = result or "ok"
    end
  end
end

function Actions:after_frame(did_redraw)
  self:check_timeout()
  local pending = self.pending
  if not pending or not did_redraw then return end
  pending.redraws = pending.redraws + 1
  if not pending.draw_ready then return end
  self.pending = nil
  return {
    id = pending.id, name = pending.name, start_ms = pending.start_ms,
    dispatch_ms = pending.dispatch_ms, ready_ms = pending.ready_ms,
    latency_ms = (self.clock() - pending.started) * 1000,
    redraws = pending.redraws, result = pending.result,
  }
end

return Actions
