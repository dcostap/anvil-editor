local core = require "core"
local layout = require "core.pane_layout"

local M = {
  groups = {},
  panes_by_id = {},
  groups_by_id = {},
  focus_owners = setmetatable({}, { __mode = "k" }),
  active_pane = nil,
  visible_group_value = nil,
  next_pane_id = 0,
  next_group_id = 0,
}

core.panes = M

local function quiet(message, ...)
  if core.log_quiet then core.log_quiet(message, ...) end
end

local function request_refresh()
  core.redraw = true
  local root = core.root_panel
  if root and root.request_layout then root:request_layout() end
end

local function next_id(kind)
  if kind == "pane" then
    M.next_pane_id = M.next_pane_id + 1
    return "pane-" .. M.next_pane_id
  end
  M.next_group_id = M.next_group_id + 1
  return "group-" .. M.next_group_id
end

local function make_view(opts)
  opts = opts or {}
  local factory = opts.factory or opts.view_factory
  if not factory then
    factory = function()
      local Editor = require "core.editor"
      return Editor(core.open_buffer())
    end
  end
  local ok, view = pcall(factory)
  if not ok then return nil, view end
  if not view then return nil, "Pane View factory returned nil" end
  return view
end

local function group_index(group)
  for i, candidate in ipairs(M.groups) do
    if candidate == group then return i end
  end
end

local function assign_view(pane, view)
  local existing = M.pane_for_view and M.pane_for_view(view)
  assert(not existing or existing == pane, "View is already Current in another Pane")
  pane.current_view = assert(view)
  view.__pane_owner = pane
end

local function clear_view_owner(pane, view)
  if view and view.__pane_owner == pane then view.__pane_owner = nil end
end

local function create_identity(view)
  local pane = {
    id = next_id("pane"),
    group = nil,
    current_view = nil,
    position = { x = 0, y = 0 },
    size = { x = 0, y = 0 },
    navigation_history = nil,
  }
  local PaneCommandBar = require "core.pane_command_bar"
  pane.command_bar = PaneCommandBar(pane)
  assign_view(pane, view)
  M.panes_by_id[pane.id] = pane
  return pane
end

local function create_group(pane, index)
  local group = {
    id = next_id("group"),
    root = { kind = "pane", pane = pane },
  }
  pane.group = group
  M.groups_by_id[group.id] = group
  table.insert(M.groups, index or (#M.groups + 1), group)
  return group
end

local function focus_view(pane)
  local view = pane and pane.current_view
  if not view then return end
  local target = view.get_focus_view and view:get_focus_view() or view
  if target and target ~= view then M.register_focus_target(view, target) end
  local root = core.root_panel
  if target and core.set_active_view and root and root.contains_view and root:contains_view(target) then
    core.set_active_view(target)
  end
end

local function after_mutation(reason)
  M.validate()
  request_refresh()
  quiet("Pane manager: %s count=%d active=%s", reason, M.count(), M.active_pane and M.active_pane.id or "none")
end

function M.count()
  local count = 0
  for _, group in ipairs(M.groups) do count = count + #layout.leaves(group.root) end
  return count
end

function M.ordered()
  local result = {}
  for _, group in ipairs(M.groups) do
    for _, pane in ipairs(layout.leaves(group.root)) do result[#result + 1] = pane end
  end
  return result
end

function M.number(pane)
  for i, candidate in ipairs(M.ordered()) do
    if candidate == pane then return i end
  end
end

function M.find(id)
  if type(id) == "table" then return M.contains(id) and id or nil end
  return M.panes_by_id[id]
end

function M.active()
  return M.active_pane
end

function M.visible_group()
  return M.visible_group_value
end

function M.contains(pane)
  return type(pane) == "table" and pane.id and M.panes_by_id[pane.id] == pane
end

function M.is_visible(pane)
  return M.contains(pane) and pane.group == M.visible_group_value
end

function M.owner_for_view(view)
  if not view then return nil end
  return M.focus_owners[view] or view.__pane_owner and view or nil
end

function M.pane_for_view(view)
  local owner = M.owner_for_view(view)
  return owner and owner.__pane_owner or nil
end

function M.register_focus_target(owner_view, child_view)
  assert(owner_view and child_view, "focus owner and target are required")
  M.focus_owners[child_view] = owner_view
  return child_view
end

function M.unregister_focus_target(child_view)
  local owner = M.focus_owners[child_view]
  M.focus_owners[child_view] = nil
  return owner
end

function M.create(opts)
  opts = opts or {}
  local view, err = make_view(opts)
  if not view then
    quiet("Pane create failed: %s", tostring(err))
    return nil, err
  end
  local pane = create_identity(view)
  local group = create_group(pane)
  M.active_pane = pane
  M.visible_group_value = group
  if opts.focus ~= false then focus_view(pane) end
  after_mutation("created " .. pane.id)
  return pane
end

function M.split(target, direction, opts)
  opts = opts or {}
  local pane = M.find(target)
  if not pane then return nil, "invalid target Pane" end
  local view, err = make_view(opts)
  if not view then
    quiet("Pane split failed target=%s: %s", pane.id, tostring(err))
    return nil, err
  end
  local new_pane = create_identity(view)
  new_pane.group = pane.group
  pane.group.root = layout.split(pane.group.root, pane, direction, new_pane)
  M.visible_group_value = pane.group
  if opts.focus ~= false then
    M.active_pane = new_pane
    focus_view(new_pane)
  end
  after_mutation(string.format("split %s %s -> %s", pane.id, direction, new_pane.id))
  return new_pane
end

function M.focus(target)
  local pane = M.find(target)
  if not pane then return nil, "invalid Pane" end
  M.active_pane = pane
  M.visible_group_value = pane.group
  focus_view(pane)
  request_refresh()
  quiet("Pane focus: id=%s number=%s", pane.id, tostring(M.number(pane)))
  return pane
end

function M.focus_index(index)
  local pane = M.ordered()[tonumber(index)]
  if not pane then return nil end
  return M.focus(pane)
end

function M.focus_direction(direction)
  local active = M.active_pane
  if not active then return nil end
  local ax = active.position.x + active.size.x / 2
  local ay = active.position.y + active.size.y / 2
  local best, best_score
  for _, candidate in ipairs(layout.leaves(active.group.root)) do
    if candidate ~= active then
      local cx = candidate.position.x + candidate.size.x / 2
      local cy = candidate.position.y + candidate.size.y / 2
      local primary, secondary
      if direction == "left" then primary, secondary = ax - cx, math.abs(ay - cy)
      elseif direction == "right" then primary, secondary = cx - ax, math.abs(ay - cy)
      elseif direction == "up" then primary, secondary = ay - cy, math.abs(ax - cx)
      elseif direction == "down" then primary, secondary = cy - ay, math.abs(ax - cx)
      else return nil end
      if primary > 0 then
        local score = primary * 100000 + secondary
        if not best_score or score < best_score then best, best_score = candidate, score end
      end
    end
  end
  return best and M.focus(best) or nil
end

function M.present(view, opts)
  opts = opts or {}
  local pane = M.find(opts.pane or M.active_pane)
  if not pane then
    return M.create { factory = function() return view end, focus = opts.focus }
  end
  local existing = M.pane_for_view(view)
  if existing then
    if opts.focus ~= false then M.focus(existing) end
    return existing
  end
  clear_view_owner(pane, pane.current_view)
  assign_view(pane, view)
  if opts.focus ~= false then M.focus(pane) end
  after_mutation("presented View in " .. pane.id)
  return pane
end

local function nearest_after_removal(old_order, old_index)
  return old_order[math.min(old_index, #old_order)] or old_order[old_index - 1]
end

local function commit_close(pane)
  local old_order = M.ordered()
  local old_index = M.number(pane)
  local group = pane.group
  group.root = layout.remove(group.root, pane)
  clear_view_owner(pane, pane.current_view)
  M.panes_by_id[pane.id] = nil
  pane.group = nil
  if not group.root then
    local index = group_index(group)
    if index then table.remove(M.groups, index) end
    M.groups_by_id[group.id] = nil
  end
  local survivors = M.ordered()
  local next_pane = nearest_after_removal(survivors, old_index)
  if #survivors == 0 then
    M.active_pane = nil
    M.visible_group_value = nil
  elseif M.active_pane == pane or not M.contains(M.active_pane) then
    M.active_pane = next_pane
    M.visible_group_value = next_pane.group
    focus_view(next_pane)
  elseif M.visible_group_value == group and not group.root then
    M.visible_group_value = M.active_pane.group
  end
  after_mutation("closed " .. pane.id)
end

function M.close(target, opts)
  opts = opts or {}
  local pane = M.find(target)
  if not pane then return false end
  local committed = false
  local function close()
    if committed or not M.contains(pane) then return end
    committed = true
    commit_close(pane)
  end
  local view = pane.current_view
  if opts.force or not view.try_close then close() else view:try_close(close) end
  return committed
end

function M.close_all(opts)
  local ordered = M.ordered()
  local index = 1
  local function close_next()
    local pane = ordered[index]
    if not pane then return end
    index = index + 1
    if M.contains(pane) then
      local view = pane.current_view
      if not (opts and opts.force) and view.try_close then
        view:try_close(function() commit_close(pane); close_next() end)
      else
        commit_close(pane)
        close_next()
      end
    else
      close_next()
    end
  end
  close_next()
  return M.count() == 0
end

function M.reset_for_tests()
  for _, pane in ipairs(M.ordered()) do clear_view_owner(pane, pane.current_view) end
  M.groups = {}
  M.panes_by_id = {}
  M.groups_by_id = {}
  M.focus_owners = setmetatable({}, { __mode = "k" })
  M.active_pane = nil
  M.visible_group_value = nil
  M.next_pane_id = 0
  M.next_group_id = 0
end

function M.validate()
  local seen_panes = {}
  local seen_views = {}
  for _, group in ipairs(M.groups) do
    assert(group and group.id and M.groups_by_id[group.id] == group, "invalid Pane Group registry")
    assert(group.root, "Pane Group has no layout")
    layout.validate(group.root)
    local members = layout.leaves(group.root)
    assert(#members > 0, "Pane Group is empty")
    for _, pane in ipairs(members) do
      assert(not seen_panes[pane], "Pane appears in more than one Pane Group")
      seen_panes[pane] = true
      assert(pane.group == group, "Pane points to the wrong Pane Group")
      assert(pane.id and M.panes_by_id[pane.id] == pane, "invalid Pane registry")
      assert(pane.current_view, "Pane has no Current View")
      assert(not seen_views[pane.current_view], "View is Current in more than one Pane")
      seen_views[pane.current_view] = true
      assert(pane.current_view.__pane_owner == pane, "Current View points to the wrong Pane")
    end
  end
  for _, pane in pairs(M.panes_by_id) do assert(seen_panes[pane], "registered Pane is missing from layout") end
  if not next(seen_panes) then
    assert(M.active_pane == nil and M.visible_group_value == nil, "zero Panes require no active Pane or visible group")
  else
    assert(M.active_pane and seen_panes[M.active_pane], "active Pane is invalid")
    assert(M.visible_group_value and M.groups_by_id[M.visible_group_value.id] == M.visible_group_value, "visible Pane Group is invalid")
    assert(M.active_pane.group == M.visible_group_value, "active Pane must belong to visible Pane Group")
  end
  for i, pane in ipairs(M.ordered()) do assert(M.number(pane) == i, "Pane numbering is invalid") end
  return true
end

return M
