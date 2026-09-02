local common = require "core.common"
local config = require "core.config"
local core = require "core"
local renderer = require "renderer"
local style = require "core.style"

local transition = {}

local DELAY_SECONDS = 0
local DURATION_SECONDS = 0.11 / 1.5
local START_SCALE = 1 - (1 - 0.965) * 1.25

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

local function color_at_opacity(color, opacity)
  if type(color) ~= "table" then return color end
  return {
    color[1] or 255,
    color[2] or 255,
    color[3] or 255,
    (color[4] or 255) * opacity,
  }
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
  local progress = common.clamp((now - start_time) / DURATION_SECONDS, 0, 1)
  local eased = cubic_ease_out(progress)
  if progress < 1 then
    core.redraw = true
  else
    view.open_transition_complete = true
    core.log_quiet("Fuzzy Searcher: opening transition complete")
  end
  return eased, 1 + (START_SCALE - 1) * (1 - eased), eased > 0
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
  local progress = common.clamp(
    (now - view.close_transition_started_at) / DURATION_SECONDS, 0, 1
  )
  local eased = cubic_ease_out(progress)
  local opacity = view.close_transition_start_opacity * (1 - eased)
  local scale = view.close_transition_start_scale
    + (START_SCALE - view.close_transition_start_scale) * eased
  if progress < 1 then
    core.redraw = true
  else
    core.log_quiet("Fuzzy Searcher: closing transition complete")
  end
  return opacity, scale, opacity > 0, progress >= 1
end

function transition.draw(view, opacity, scale, draw)
  if opacity >= 1 and scale == 1 then return draw() end

  local center_x = view.position.x + view.size.x / 2
  local center_y = view.position.y + view.size.y / 2
  local originals = {
    set_clip_rect = renderer.set_clip_rect,
    draw_rect = renderer.draw_rect,
    draw_rounded_rect = renderer.draw_rounded_rect,
    draw_text = renderer.draw_text,
    draw_text_known_bounds = renderer.draw_text_known_bounds,
    draw_poly = renderer.draw_poly,
    draw_canvas = renderer.draw_canvas,
    draw_canvas_scaled = renderer.draw_canvas_scaled,
  }

  local function tx(x) return center_x + (x - center_x) * scale end
  local function ty(y) return center_y + (y - center_y) * scale end
  local function transformed_rect(x, y, width, height)
    return tx(x), ty(y), width * scale, height * scale
  end
  local function scaled_font(font)
    if not font then return font end
    local ok, size = pcall(function() return font:get_size() end)
    if not ok or not size then return font end
    return style.get_scaled_font(font, size * scale)
  end
  local function logical_x(x)
    return type(x) == "number" and center_x + (x - center_x) / scale or x
  end

  renderer.set_clip_rect = function(x, y, width, height)
    return originals.set_clip_rect(transformed_rect(x, y, width, height))
  end
  renderer.draw_rect = function(x, y, width, height, color)
    local sx, sy, sw, sh = transformed_rect(x, y, width, height)
    return originals.draw_rect(sx, sy, sw, sh, color_at_opacity(color, opacity))
  end
  renderer.draw_rounded_rect = function(x, y, width, height, radius, color)
    local sx, sy, sw, sh = transformed_rect(x, y, width, height)
    return originals.draw_rounded_rect(
      sx, sy, sw, sh, radius * scale, color_at_opacity(color, opacity))
  end
  renderer.draw_text = function(font, text, x, y, color, tab)
    local result = originals.draw_text(
      scaled_font(font), text, tx(x), ty(y), color_at_opacity(color, opacity), tab)
    return logical_x(result)
  end
  renderer.draw_text_known_bounds = function(
      font, text, x, y, bounds_x, bounds_y, bounds_w, bounds_h, color, tab)
    local sx, sy, sw, sh = transformed_rect(bounds_x, bounds_y, bounds_w, bounds_h)
    local result = originals.draw_text_known_bounds(
      scaled_font(font), text, tx(x), ty(y), sx, sy, sw, sh,
      color_at_opacity(color, opacity), tab)
    return logical_x(result)
  end
  renderer.draw_poly = function(points, color)
    local transformed = {}
    for index, point in ipairs(points) do
      local copy = {}
      for coordinate = 1, #point, 2 do
        copy[coordinate] = tx(point[coordinate])
        copy[coordinate + 1] = ty(point[coordinate + 1])
      end
      transformed[index] = copy
    end
    local x, y, width, height = originals.draw_poly(
      transformed, color_at_opacity(color, opacity))
    if type(x) ~= "number" then return x, y, width, height end
    return logical_x(x), center_y + (y - center_y) / scale,
      width / scale, height / scale
  end
  renderer.draw_canvas = function(canvas, x, y)
    local width, height = canvas:get_size()
    local sx, sy, sw, sh = transformed_rect(x, y, width, height)
    return originals.draw_canvas_scaled(canvas, sx, sy, sw, sh, opacity)
  end
  renderer.draw_canvas_scaled = function(canvas, x, y, width, height)
    local sx, sy, sw, sh = transformed_rect(x, y, width, height)
    return originals.draw_canvas_scaled(canvas, sx, sy, sw, sh, opacity)
  end

  local ok, result = pcall(draw)
  for name, original in pairs(originals) do renderer[name] = original end
  local clip = core.clip_rect_stack and core.clip_rect_stack[#core.clip_rect_stack]
  if clip then originals.set_clip_rect(table.unpack(clip)) end
  if not ok then error(result, 0) end
  return result
end

return transition
