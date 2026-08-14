local command = require "core.command"
local keymap = require "core.keymap"
local panes = require "core.panes"

command.add(function() return panes.is_back_available() end, {
  ["navigation:back"] = function() panes.back() end,
})

command.add(function() return panes.is_forward_available() end, {
  ["navigation:forward"] = function() panes.forward() end,
})

keymap.add {
  ["alt+left"] = "navigation:back",
  ["alt+right"] = "navigation:forward",
  ["xclick"] = "navigation:back",
  ["yclick"] = "navigation:forward",
}
