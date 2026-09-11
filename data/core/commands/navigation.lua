local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local panes = require "core.panes"

command.add(function() return panes.is_back_available() end, {
  ["core:navigate_back"] = command.palette(function() panes.back() end),
})

command.add(function() return panes.is_forward_available() end, {
  ["core:navigate_forward"] = command.palette(function() panes.forward() end),
})

local function navigate_mouse(button, ...)
  local view = core.active_view
  local diff_view = view and view.diff_view_parent
  if diff_view then
    local command_name = button == "x"
      and "core:previous_point_of_interest"
      or "core:next_point_of_interest"
    return command.perform(command_name, ...)
  end

  local command_name = button == "x" and "core:navigate_back" or "core:navigate_forward"
  return command.perform(command_name, ...)
end


keymap.add {
  ["alt+left"] = "core:navigate_back",
  ["alt+right"] = "core:navigate_forward",
  ["xclick"] = function(...) return navigate_mouse("x", ...) end,
  ["yclick"] = function(...) return navigate_mouse("y", ...) end,
}
