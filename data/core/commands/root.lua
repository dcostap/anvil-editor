local core = require "core"
local command = require "core.command"
local config = require "core.config"
local panes = require "core.panes"

local function active_pane()
  local pane = panes.active()
  return pane ~= nil, pane
end

local function new_untitled_editor()
  local Editor = require "core.editor"
  local buffer = core.open_buffer()
  local untitled = require "plugins.untitled_tabs"
  return Editor(untitled.tag_buffer(buffer))
end

local commands = {
  ["core:close_pane"] = command.palette(function(pane) return panes.close(pane) end),
  ["core:close_view"] = function(pane) return panes.close_view(pane) end,
  ["core:close_all_panes"] = command.palette(function() return panes.close_all() end),
  ["core:close_other_panes"] = command.palette(function(pane)
    local result = true
    for index = #panes.ordered(), 1, -1 do
      local candidate = panes.ordered()[index]
      if candidate ~= pane and not panes.close(candidate) then result = false end
    end
    return result
  end),
  ["core:move_pane_previous"] = command.palette(function(pane)
    local ordered, index = panes.ordered(), panes.number(pane)
    if index and index > 1 then return panes.move(pane, ordered[index - 1], "left") end
  end),
  ["core:move_pane_next"] = command.palette(function(pane)
    local ordered, index = panes.ordered(), panes.number(pane)
    if index and index < #ordered then return panes.move(pane, ordered[index + 1], "right") end
  end),
  ["core:focus_previous_pane"] = function(pane)
    local ordered, index = panes.ordered(), panes.number(pane)
    if #ordered > 0 then return panes.focus_index((index - 2) % #ordered + 1) end
  end,
  ["core:focus_next_pane"] = function(pane)
    local ordered, index = panes.ordered(), panes.number(pane)
    if #ordered > 0 then return panes.focus_index(index % #ordered + 1) end
  end,
}

for _, direction in ipairs { "left", "right", "up", "down" } do
  commands["core:split_pane_" .. direction] = command.palette(function(pane)
    return panes.split(pane, direction, { factory = new_untitled_editor })
  end)
end

for _, direction in ipairs { "left", "right", "up", "down" } do
  commands["core:focus_pane_" .. direction] = function()
    return panes.focus_direction(direction)
  end
end

for index = 1, 9 do
  commands["core:focus_pane_" .. index] = function()
    return panes.focus_index(index)
  end
end

command.add(active_pane, commands)

command.add(nil, {
  ["editor:open"] = command.palette(function()
    local context = command.get_invocation_context() or {}
    return panes.place(new_untitled_editor, {
      pane = context.source_pane,
      placement = context.placement or "current",
      direction = context.direction,
      focus = true,
      reason = "editor-open",
    })
  end, {
    keywords = { "new", "untitled", "file" },
    supports_placement = true,
    opens_view = true,
  }),
  ["core:new_pane"] = command.palette(function()
    return panes.create { factory = new_untitled_editor }
  end),
  ["core:close_pane_or_quit"] = function()
    local pane = panes.active()
    if pane then return panes.close(pane) end
    return core.quit()
  end,
  ["core:scroll"] = function(delta)
    local view = core.root_panel.overlapping_view or core.active_view
    if view and view.scrollable then
      view.scroll.to.y = view.scroll.to.y + delta * -config.mouse_wheel_scroll
      return true
    end
    return false
  end,
  ["core:horizontal_scroll"] = function(delta)
    local view = core.root_panel.overlapping_view or core.active_view
    if view and view.scrollable then
      view.scroll.to.x = view.scroll.to.x + delta * -config.mouse_wheel_scroll
      return true
    end
    return false
  end,
})
