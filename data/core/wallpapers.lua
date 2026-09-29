local config = require "core.config"
local core = require "core"
local style = require "core.style"

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

function wallpapers.select(name)
  if not wallpapers.exists(name) then return false end
  config.wallpaper = name
  style.update_wallpaper_line_highlight()
  core.redraw = true
  core.log_quiet("Window wallpaper selected: %s", name)
  return true
end

return wallpapers
