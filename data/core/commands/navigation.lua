local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local panes = require "core.panes"

command.add(nil, {
  ["core:reopen_last_closed_pane"] = function()
    local pane, err = panes.reopen_last_closed()
    if not pane then core.warn("Could not reopen Pane: %s", err) end
  end,
})

command.add(function() return panes.is_back_available() end, {
  ["core:navigate_back"] = command.palette(function() panes.back() end),
  ["core:navigate_back_file"] = command.palette(function() panes.back_file() end),
})

command.add(function() return panes.is_forward_available() end, {
  ["core:navigate_forward"] = command.palette(function() panes.forward() end),
  ["core:navigate_forward_file"] = command.palette(function() panes.forward_file() end),
})

local function navigate_mouse(button, ...)
  local command_name = button == "x" and "core:navigate_back" or "core:navigate_forward"
  local view = core.active_view
  local diff_view = view and view.diff_view_parent
  if diff_view then
    require("core.poi").navigate(view, button == "x" and -1 or 1, {
      on_boundary = function()
        if view.continue_point_of_interest then
          core.log_quiet("Diff View mouse navigation reached the end of its extended POI source")
          return
        end
        core.log_quiet("Diff View mouse navigation reached a POI boundary: %s", command_name)
        return command.perform(command_name)
      end,
    })
    return true
  end

  return command.perform(command_name, ...)
end


keymap.add {
  ["alt+left"] = "core:navigate_back",
  ["alt+right"] = "core:navigate_forward",
  ["alt+shift+left"] = "core:navigate_back_file",
  ["alt+shift+right"] = "core:navigate_forward_file",
  ["xclick"] = function(...) return navigate_mouse("x", ...) end,
  ["yclick"] = function(...) return navigate_mouse("y", ...) end,
  ["shift+xclick"] = "core:navigate_back_file",
  ["shift+yclick"] = "core:navigate_forward_file",
}
