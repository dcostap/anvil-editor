local config = require "core.config"
local core = require "core"
local style = require "core.style"
local wallpaper_contrast = require "core.wallpaper_contrast"

local wallpapers = {}

-- One native worker decodes wallpapers, so a decode never waits behind other background work, and no Lua
-- worker threads start for it. Each request maps its job to the state that waits for it.
local decoder
local requests = {}

local files = {
  image1 = "wallpaper.jpg",
  image2 = "wallpaper2.jpg",
  image3 = "wallpaper3.jpg",
  image4 = "wallpaper4.jpg",
  image5 = "wallpaper5.jpg",
  image6 = "wallpaper6.jpg",
  image7 = "wallpaper7.jpg",
  image8 = "wallpaper8.jpg",
  image9 = "wallpaper9.jpg",
  image10 = "wallpaper10.jpg",
  image11 = "wallpaper11.jpg",
  image12 = "wallpaper12.jpg",
  image13 = "wallpaper13.jpg",
  image14 = "wallpaper14.jpg",
  image15 = "wallpaper15.jpg",
  image16 = "wallpaper16.jpg",
  image17 = "wallpaper17.jpg",
  image18 = "wallpaper18.jpg",
}

function wallpapers.current()
  local name = config.wallpaper
  if name == "none" or files[name] then return name end
  return "image1"
end

function wallpapers.path(name)
  local file = files[name]
  return file and DATADIR .. "/core/assets/" .. file
end

function wallpapers.exists(name)
  return name == "none" or files[name] ~= nil
end

function wallpapers.options()
  local choices = { { name = "none", text = "None" } }
  for index = 1, math.huge do
    local name = "image" .. index
    if not files[name] then break end
    choices[#choices + 1] = { name = name, text = name }
  end
  return choices
end

-- Cancels the decode that `state` waits for, so a newer request does not wait behind it.
local function cancel(state)
  local pending = requests[state.wallpaper_request]
  if pending then
    decoder:cancel(pending.job)
    requests[state.wallpaper_request] = nil
  end
  state.wallpaper_request = nil
end

-- Decodes wallpaper `name` on the worker, at the size that covers a `width` x `height` backdrop. Until the
-- result arrives, `state` keeps its current image.
local function request(state, name, width, height)
  cancel(state)
  local path, ok, job, err = wallpapers.path(name), true, nil, nil
  if not decoder then
    ok, err = pcall(function() decoder = require("worker_pool_native").new({name = "wallpaper", worker_count = 1}) end)
  end
  if ok then
    ok, job, err = pcall(decoder.submit, decoder, {kind = "image_decode", priority = "interactive", path = path,
      width = math.ceil(width), height = math.ceil(height)})
    if not ok then job, err = nil, job end
  end
  if not job then
    state.wallpaper = false
    core.log_quiet("Window wallpaper unavailable: %s (%s)", path, tostring(err))
    return
  end
  local id = decoder:status(job).id
  state.wallpaper_request = id
  requests[id] = {state = state, job = job, path = path, size = width .. "x" .. height,
    started = system.get_time()}
end

-- Applies finished decodes. The `imagedecoded` event calls it. Returns true when a wallpaper changed.
function wallpapers.receive()
  if not decoder then return false end
  local changed = false
  for _, message in ipairs(decoder:drain({max_messages = 16})) do
    local entry = requests[message.job_id]
    if entry and (message.type == "result" or message.type == "error") then
      requests[message.job_id] = nil
      local state = entry.state
      if state.wallpaper_request == message.job_id then
        state.wallpaper_request = nil
        if message.image then
          state.wallpaper = message.image
          state.wallpaper_covers = {message.covers_width, message.covers_height}
          local w, h = message.image:get_size()
          core.log_quiet("Window wallpaper loaded: %s at %dx%d for %s in %.1f ms", entry.path, w, h, entry.size,
            (system.get_time() - entry.started) * 1000)
        else
          state.wallpaper = state.wallpaper or false
          core.log_quiet("Window wallpaper unavailable: %s (%s)", entry.path, tostring(message.error))
        end
        changed = true
      end
    end
  end
  return changed
end

-- Replaces the content of one region with the wallpaper, aligned to the backdrop rect (bx, by, bw, bh).
-- `state` keeps the loaded image and its theme visibility between frames.
function wallpapers.draw_region(state, bx, by, bw, bh, x, y, width, height)
  if width <= 0 or height <= 0 then return end
  if not state.wallpaper then
    renderer.draw_rect(x, y, width, height, style.background)
    return
  end
  local clipped = x ~= bx or y ~= by or width ~= bw or height ~= bh
  if clipped then core.push_clip_rect(x, y, width, height) end
  local iw, ih = state.wallpaper:get_size()
  local scale = math.max(bw / iw, bh / ih)
  local w, h = iw * scale, ih * scale
  renderer.draw_canvas_scaled(state.wallpaper, bx + (bw - w) / 2, by + (bh - h) / 2, w, h)
  if clipped then core.pop_clip_rect() end
  renderer.draw_rect(x, y, width, height,
    style.wallpaper_surface(style.background, state.wallpaper_backdrop_opacity))
end

-- Draws the selected wallpaper over the whole backdrop rect. With a Pane View, the View's fill also attenuates
-- the image.
function wallpapers.draw(state, bx, by, bw, bh, has_pane_view)
  local selected = wallpapers.current()
  if selected == "none" then
    state.wallpaper = nil
    state.wallpaper_name = nil
    cancel(state)
    state.wallpaper_contrast_image = nil
    state.wallpaper_visibility = nil
    state.wallpaper_backdrop_opacity = nil
    renderer.draw_rect(bx, by, bw, bh, style.background)
    return
  end
  if state.wallpaper_name ~= selected then
    state.wallpaper_name = selected
    state.wallpaper = nil
    request(state, selected, bw, bh)
  elseif state.wallpaper and not state.wallpaper_request then
    -- A larger backdrop needs a larger decode. The smaller image shows until it arrives.
    local covers = state.wallpaper_covers
    if covers and covers[1] > 0 and (bw > covers[1] or bh > covers[2]) then request(state, selected, bw, bh) end
  end
  if not state.wallpaper then
    wallpapers.draw_region(state, bx, by, bw, bh, bx, by, bw, bh)
    return
  end
  if state.wallpaper_contrast_image ~= state.wallpaper then
    state.wallpaper_contrast_image = state.wallpaper
    state.wallpaper_sample_low, state.wallpaper_sample_high, state.wallpaper_sample_mid =
      wallpaper_contrast.sample(state.wallpaper)
    state.wallpaper_contrast_generation = nil
  end
  if not state.wallpaper_visibility or state.wallpaper_contrast_generation ~= core.color_theme_generation then
    state.wallpaper_visibility = wallpaper_contrast.visibility(
      state.wallpaper_sample_low, state.wallpaper_sample_high, state.wallpaper_sample_mid,
      style.background,
      style.wallpaper_reference_background, style.wallpaper_reference_visibility)
    state.wallpaper_contrast_generation = core.color_theme_generation
    core.log_quiet("Window wallpaper theme visibility: %.1f%% generation=%s",
      state.wallpaper_visibility * 100, tostring(core.color_theme_generation))
  end
  state.wallpaper_backdrop_opacity = 1 - state.wallpaper_visibility
    / (has_pane_view and (1 - style.wallpaper_surface_opacity) or 1)
  wallpapers.draw_region(state, bx, by, bw, bh, bx, by, bw, bh)
end

function wallpapers.select(name)
  if not wallpapers.exists(name) then return false end
  config.wallpaper = name
  style.update_wallpaper_line_highlight()
  core.redraw = true
  core.log_quiet("Window wallpaper selected: %s", name)
  return true
end

return wallpapers
