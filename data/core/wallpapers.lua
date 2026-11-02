local config = require "core.config"
local core = require "core"
local style = require "core.style"
local wallpaper_contrast = require "core.wallpaper_contrast"

local wallpapers = {}

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
  image10 = "wallpaper10.png",
  image11 = "wallpaper11.png",
  image12 = "wallpaper12.png",
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
    state.wallpaper_contrast_image = nil
    state.wallpaper_visibility = nil
    state.wallpaper_backdrop_opacity = nil
    renderer.draw_rect(bx, by, bw, bh, style.background)
    return
  end
  if state.wallpaper_name ~= selected then
    local path = wallpapers.path(selected)
    local image, err = canvas.load_image(path)
    state.wallpaper = image or false
    state.wallpaper_name = selected
    if image then
      core.log_quiet("Window wallpaper loaded: %s", path)
    else
      core.log_quiet("Window wallpaper unavailable: %s (%s)", path, tostring(err))
    end
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
