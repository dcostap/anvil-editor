local copy_feedback = {}

local DURATION = 0.20
local INITIAL_ALPHA = 33 -- white at 13% opacity / 87% transparency

function copy_feedback.start(payload, now)
  local state = {}
  for key, value in pairs(payload or {}) do state[key] = value end
  state.started_at = now or system.get_time()
  state.duration = DURATION
  return state
end

function copy_feedback.alpha(state, now)
  if not state then return nil end
  local duration = state.duration or DURATION
  local elapsed = (now or system.get_time()) - (state.started_at or 0)
  if elapsed < 0 then elapsed = 0 end
  if elapsed >= duration then return nil end
  local alpha = math.floor(INITIAL_ALPHA * (1 - elapsed / duration))
  if alpha <= 0 then return nil end
  return alpha
end

function copy_feedback.color(state, now)
  local alpha = copy_feedback.alpha(state, now)
  if not alpha then return nil end
  return { 255, 255, 255, alpha }
end

return copy_feedback
