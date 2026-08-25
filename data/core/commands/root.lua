local core = require "core"
local command = require "core.command"
local common = require "core.common"
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

local function duplicate_or_untitled(view)
  if not (view and view.duplicate) then
    core.log_quiet("Copy View Split used normal split: Current View does not support duplication")
    return new_untitled_editor()
  end
  local ok, duplicate = pcall(view.duplicate, view)
  if ok and duplicate and duplicate ~= view then return duplicate end
  core.log_quiet("Copy View Split used normal split for %s: %s",
    tostring(view), ok and "duplication returned no new View" or tostring(duplicate))
  return new_untitled_editor()
end

local function move_and_merge_target(text, item, source)
  if item and item.pane and item.pane ~= source and panes.contains(item.pane) then
    return item.pane
  end
  local number = tonumber(tostring(text or ""):match("^%s*(%d+)%s*$"))
  local target = number and panes.ordered()[number] or nil
  return target ~= source and target or nil
end

local function move_and_merge_pane(source)
  if #panes.ordered() < 2 then
    core.log("There is no other Pane to move and merge into")
    return false
  end
  core.global_prompt_bar:enter("Move and Merge Pane Into", {
    suggest = function(text)
      local items, by_text = {}, {}
      for number, pane in ipairs(panes.ordered()) do
        if pane ~= source then
          local view = pane.current_view
          local name = view and view.get_name and view:get_name() or "Pane"
          local label = string.format("%d — %s", number, name)
          by_text[label] = { text = label, pane = pane }
          items[#items + 1] = label
        end
      end
      local result = {}
      for _, label in ipairs(common.fuzzy_match(items, text)) do
        result[#result + 1] = by_text[label]
      end
      return result
    end,
    validate = function(text, item)
      return move_and_merge_target(text, item, source) ~= nil
    end,
    submit = function(text, item)
      local destination = move_and_merge_target(text, item, source)
      if destination and panes.contains(source) then
        panes.move_and_merge(source, destination)
      end
    end,
  })
  return true
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
  ["core:rotate_panes_clockwise"] = command.palette(function(pane)
    return panes.rotate_group_clockwise(pane)
  end, { keywords = { "split", "group" } }),
  ["core:move_and_merge_pane"] = command.palette(function(pane)
    return move_and_merge_pane(pane)
  end, { keywords = { "history", "navigation" } }),
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
  commands["core:split_pane_" .. direction .. "_copy_view"] = command.palette(function(pane)
    local source_view = pane.current_view
    return panes.split(pane, direction, {
      factory = function() return duplicate_or_untitled(source_view) end,
    })
  end, { keywords = { "duplicate", "current" } })
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
