local config = require "core.config"
local command = require "core.command"
local ImageView = require "core.imageview"

command.add(ImageView, {
  ["image:auto_fit"] = function(av)
    ---@cast av core.imageview
    av.zoom_mode = "fit"
  end,
  ["image:zoom_out"] = function(av)
    ---@cast av core.imageview
    av:zoom_out()
  end,
  ["image:zoom_in"] = function(av)
    ---@cast av core.imageview
    av:zoom_in()
  end,
  ["image:zoom_reset"] = function(av)
    ---@cast av core.imageview
    av:zoom_reset()
  end,
  ["image:background_mode_solid"] = function()
    config.images_background_mode = "solid"
  end,
  ["image:background_mode_grid"] = function()
    config.images_background_mode = "grid"
  end,
  ["image:background_mode_none"] = function()
    config.images_background_mode = "none"
  end,
})
