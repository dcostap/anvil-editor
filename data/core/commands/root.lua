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

local function duplicate_view(view)
  if not (view and view.duplicate) then return nil, "Current View does not support copying" end
  local ok, duplicate = pcall(view.duplicate, view)
  if ok and duplicate and duplicate ~= view then return duplicate end
  return nil, ok and "Current View does not support copying" or tostring(duplicate)
end

local function existing_pane_target(text, item, source)
  if item and item.pane and item.pane ~= source and panes.contains(item.pane) then
    return item.pane
  end
  local number = tonumber(tostring(text or ""):match("^%s*(%d+)%s*$"))
  local target = number and panes.ordered()[number] or nil
  return target ~= source and target or nil
end

local function view_copy_factory(view)
  return function()
    local duplicate, err = duplicate_view(view)
    if not duplicate then error(err, 0) end
    return duplicate
  end
end

local function copy_view_to_split(source, direction)
  local view = source and source.current_view
  if not view then return nil, "There is no Current View" end
  return panes.split(source, direction, { factory = view_copy_factory(view) })
end

local function report_failure(action, result, err)
  if result or err == "View replacement is pending or was canceled" then return end
  core.error("Cannot %s: %s", action, tostring(err or "operation failed"))
end

local function destination_items(source, include_splits)
  local items = {}
  if include_splits then
    for _, direction in ipairs { "right", "left", "down", "up" } do
      items[#items + 1] = {
        text = "New Split — " .. direction:gsub("^%l", string.upper),
        kind = "split",
        direction = direction,
      }
    end
  end
  items[#items + 1] = { text = "New Pane Group", kind = "new_group" }
  for number, pane in ipairs(panes.ordered()) do
    if pane ~= source then
      local view = pane.current_view
      local name = view and view.get_name and view:get_name() or "Pane"
      items[#items + 1] = {
        text = string.format("Pane %d — %s", number, name),
        kind = "pane",
        pane = pane,
      }
    end
  end
  return items
end

local function destination_prompt(label, source, include_splits, submit)
  local items = destination_items(source, include_splits)
  local by_text = {}
  for _, item in ipairs(items) do by_text[item.text] = item end
  core.global_prompt_bar:enter(label, {
    suggest = function(text)
      local result = {}
      local labels = {}
      for _, item in ipairs(items) do labels[#labels + 1] = item.text end
      for _, item_label in ipairs(common.fuzzy_match(labels, text)) do
        result[#result + 1] = by_text[item_label]
      end
      return result
    end,
    validate = function(text, item)
      return item ~= nil or existing_pane_target(text, nil, source) ~= nil
    end,
    submit = function(text, item)
      item = item or { kind = "pane", pane = existing_pane_target(text, nil, source) }
      if item.pane and not panes.contains(item.pane) then return end
      if panes.contains(source) then submit(item) end
    end,
  })
  return true
end

local function copy_view_to(source)
  local view = source.current_view
  return destination_prompt("Copy Current View To", source, true, function(item)
    local result, err
    if item.kind == "split" then
      result, err = copy_view_to_split(source, item.direction)
    elseif item.kind == "new_group" then
      result, err = panes.create { factory = view_copy_factory(view) }
    elseif item.kind == "pane" then
      result, err = panes.place(view_copy_factory(view), {
        pane = item.pane, placement = "current", focus = true,
      })
    end
    report_failure("copy Current View", result, err)
  end)
end

local function move_view_to(source)
  return destination_prompt("Move Current View To", source, false, function(item)
    local result, err
    if item.kind == "new_group" then
      result, err = panes.move_current_view_to_new_group(source)
    elseif item.kind == "pane" then
      result, err = panes.move_current_view(source, item.pane)
    end
    report_failure("move Current View", result, err)
  end)
end

local function move_pane_to(source)
  return destination_prompt("Move Current Pane To", source, false, function(item)
    local result, err
    if item.kind == "new_group" then
      result, err = panes.detach(source)
    elseif item.kind == "pane" then
      result, err = panes.move_and_merge(source, item.pane)
    end
    report_failure("move Current Pane", result, err)
  end)
end

local function focus_local(pane, step)
  local targets = {}
  for _, member in ipairs(panes.ordered()) do
    if member.group == pane.group then
      local owner = member.current_view
      local surfaces = owner and owner:get_surface_focus_targets()
      if type(surfaces) == "table" and #surfaces > 0 then
        for _, target in ipairs(surfaces) do
          targets[#targets + 1] = { pane = member, owner = owner, target = target }
        end
      elseif owner then
        targets[#targets + 1] = { pane = member, owner = owner, target = owner }
      end
    end
  end
  if #targets == 0 then return false end

  local current
  for index, entry in ipairs(targets) do
    if entry.target == core.active_view then current = index break end
  end
  local destination_index
  if current then
    destination_index = (current - 1 + step) % #targets + 1
  else
    destination_index = step > 0 and 1 or #targets
  end
  local destination = targets[destination_index]
  panes.focus(destination.pane)
  if destination.target ~= destination.owner then
    panes.register_focus_target(destination.owner, destination.target)
    return destination.owner:focus_surface_target(destination.target)
  end
  return true
end

local commands = {
  ["pane:close"] = command.palette(function(pane) return panes.close(pane) end),
  ["pane:close_view"] = function(pane) return panes.close_view(pane) end,
  ["pane:close_all"] = command.palette(function() return panes.close_all() end),
  ["pane:close_others"] = command.palette(function(pane)
    local result = true
    for index = #panes.ordered(), 1, -1 do
      local candidate = panes.ordered()[index]
      if candidate ~= pane and not panes.close(candidate) then result = false end
    end
    return result
  end),
  ["pane:move_previous"] = command.palette(function(pane)
    local ordered, index = panes.ordered(), panes.number(pane)
    if index and index > 1 then return panes.move(pane, ordered[index - 1], "left") end
  end),
  ["pane:move_next"] = command.palette(function(pane)
    local ordered, index = panes.ordered(), panes.number(pane)
    if index and index < #ordered then return panes.move(pane, ordered[index + 1], "right") end
  end),
  ["pane:rotate_group_clockwise"] = command.palette(function(pane)
    return panes.rotate_group_clockwise(pane)
  end, { keywords = { "split", "group" } }),
  ["pane:copy_view_to"] = command.palette(function(pane)
    return copy_view_to(pane)
  end, { keywords = { "duplicate", "split", "pane", "group" } }),
  ["pane:move_view_to"] = command.palette(function(pane)
    return move_view_to(pane)
  end, { keywords = { "pane", "group" } }),
  ["pane:move_to"] = command.palette(function(pane)
    return move_pane_to(pane)
  end, { keywords = { "history", "navigation" } }),
  ["pane:focus_previous"] = function(pane)
    local ordered, index = panes.ordered(), panes.number(pane)
    if #ordered > 0 then return panes.focus_index((index - 2) % #ordered + 1) end
  end,
  ["pane:focus_next"] = function(pane)
    local ordered, index = panes.ordered(), panes.number(pane)
    if #ordered > 0 then return panes.focus_index(index % #ordered + 1) end
  end,
  ["pane:focus_local_next"] = command.palette(function(pane)
    return focus_local(pane, 1)
  end),
  ["pane:focus_local_previous"] = command.palette(function(pane)
    return focus_local(pane, -1)
  end),
}

for _, direction in ipairs { "left", "right", "up", "down" } do
  commands["pane:split_" .. direction] = command.palette(function(pane)
    return panes.split(pane, direction, { factory = new_untitled_editor })
  end)
  commands["pane:copy_view_to_split_" .. direction] = command.palette(function(pane)
    local result, err = copy_view_to_split(pane, direction)
    report_failure("copy Current View", result, err)
    return result
  end, { keywords = { "duplicate", "current" } })
end

for _, direction in ipairs { "left", "right", "up", "down" } do
  commands["pane:focus_" .. direction] = function()
    return panes.focus_direction(direction)
  end
end

for index = 1, 9 do
  commands["pane:focus_" .. index] = function()
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
  ["pane:new_group"] = command.palette(function()
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
