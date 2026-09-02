local common = require "core.common"
local config = require "core.config"
local core = require "core"
local renderer = require "renderer"

local transition = {}

local DELAY_SECONDS = 0
local DURATION_SECONDS = 0.11 / 1.5 - 0.02
local ALPHA_DURATION_SECONDS = 0.11 / 1.5 / 1.2 - 0.02
local START_SCALE = 0.97

local function cubic_ease_out(progress)
  local remaining = 1 - progress
  return 1 - remaining * remaining * remaining
end

local function enabled()
  local fps = core.fps
  if not fps or fps <= 0 then fps = config.fps or 60 end
  return config.transitions
    and not config.disabled_transitions.fuzzy_searcher
    and not core.in_live_resize_frame
    and fps >= 30
end

local function ready(view)
  return not view.loading_feedback_pending
    and not view.everything_loading_pending
end

function transition.state(view, now)
  if view.open_transition_complete or not enabled() then
    view.open_transition_complete = true
    return 1, 1, true
  end

  now = now or system.get_time()
  if not view.open_transition_ready_at and ready(view) then
    view.open_transition_ready_at = now
  end
  if not view.open_transition_ready_at then
    core.redraw = true
    return 0, START_SCALE, false
  end

  local start_time = math.max(
    view.open_transition_requested_at + DELAY_SECONDS,
    view.open_transition_ready_at
  )
  if now <= start_time then
    core.redraw = true
    return 0, START_SCALE, false
  end

  if not view.open_transition_started_logged then
    view.open_transition_started_logged = true
    core.log_quiet(
      "Fuzzy Searcher: opening transition started after %.1f ms",
      (start_time - view.open_transition_requested_at) * 1000
    )
  end
  local elapsed = now - start_time
  local scale_progress = common.clamp(elapsed / DURATION_SECONDS, 0, 1)
  local alpha_progress = common.clamp(elapsed / ALPHA_DURATION_SECONDS, 0, 1)
  local scale_eased = cubic_ease_out(scale_progress)
  local alpha_eased = cubic_ease_out(alpha_progress)
  if scale_progress < 1 then
    core.redraw = true
  else
    view.open_transition_complete = true
    core.log_quiet("Fuzzy Searcher: opening transition complete")
  end
  return alpha_eased,
    1 + (START_SCALE - 1) * (1 - scale_eased),
    alpha_eased > 0
end

function transition.begin_close(view, now)
  now = now or system.get_time()
  local opacity, scale, visible = transition.state(view, now)
  if not enabled() or not visible or opacity <= 0 then return false end

  view.close_transition_started_at = now
  view.close_transition_start_opacity = opacity
  view.close_transition_start_scale = scale
  core.redraw = true
  core.log_quiet("Fuzzy Searcher: closing transition started")
  return true
end

function transition.close_state(view, now)
  if not enabled() then return 0, START_SCALE, false, true end
  now = now or system.get_time()
  local elapsed = now - view.close_transition_started_at
  local scale_progress = common.clamp(elapsed / DURATION_SECONDS, 0, 1)
  local alpha_progress = common.clamp(elapsed / ALPHA_DURATION_SECONDS, 0, 1)
  local scale_eased = cubic_ease_out(scale_progress)
  local alpha_eased = cubic_ease_out(alpha_progress)
  local opacity = view.close_transition_start_opacity * (1 - alpha_eased)
  local scale = view.close_transition_start_scale
    + (START_SCALE - view.close_transition_start_scale) * scale_eased
  if scale_progress < 1 then
    core.redraw = true
  else
    core.log_quiet("Fuzzy Searcher: closing transition complete")
  end
  return opacity, scale, opacity > 0, scale_progress >= 1
end

function transition.draw(view, opacity, scale, draw)
  if opacity >= 1 and scale == 1 then return draw() end

  local center_x = view.position.x + view.size.x / 2
  local center_y = view.position.y + view.size.y / 2
  renderer.push_transform(center_x, center_y, scale, opacity)
  local ok, result = pcall(draw)
  renderer.pop_transform()
  if not ok then error(result, 0) end
  return result
end

return transition
