local command = require "core.command"
local keymap = require "core.keymap"
local panes = require "core.panes"

command.add(function() return panes.is_back_available() end, {
  ["core:navigate_back"] = command.palette(function() panes.back() end),
})

command.add(function() return panes.is_forward_available() end, {
  ["core:navigate_forward"] = command.palette(function() panes.forward() end),
})


keymap.add {
  ["alt+left"] = "core:navigate_back",
  ["alt+right"] = "core:navigate_forward",
  ["xclick"] = "core:navigate_back",
  ["yclick"] = "core:navigate_forward",
}
