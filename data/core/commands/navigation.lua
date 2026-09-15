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
})

command.add(function() return panes.is_forward_available() end, {
  ["core:navigate_forward"] = command.palette(function() panes.forward() end),
})

local function navigate_mouse(button, ...)
  local command_name = button == "x" and "core:navigate_back" or "core:navigate_forward"
  local view = core.active_view
  local diff_view = view and view.diff_view_parent
  if diff_view then
    require("core.poi").navigate(view, button == "x" and -1 or 1, {
      on_boundary = function()
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
  ["xclick"] = function(...) return navigate_mouse("x", ...) end,
  ["yclick"] = function(...) return navigate_mouse("y", ...) end,
}
