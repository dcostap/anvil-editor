local core = require "core"
local common = require "core.common"
local layout = require "core.pane_layout"

local M = {
  groups = {},
  panes_by_id = {},
  groups_by_id = {},
  focus_owners = setmetatable({}, { __mode = "k" }),
  suspended_services = setmetatable({}, { __mode = "k" }),
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

local function claim_view(pane, view)
  local existing = M.pane_for_view and M.pane_for_view(view)
  assert(not existing or existing == pane, "View is already owned by another Pane")
  view.__pane_owner = pane
  if view.update_suspended then M.suspended_services[view] = true end
end

local function release_view(pane, view)
  if view and view.__pane_owner == pane then view.__pane_owner = nil end
  if view then M.suspended_services[view] = nil end
  for child, owner in pairs(M.focus_owners) do
    if child == view or owner == view then M.focus_owners[child] = nil end
  end
end

local function capture_navigation_state(view)
  if view and view.get_navigation_state then return view:get_navigation_state() end
end

local function restore_navigation_state(view, state)
  if view and state and view.set_navigation_state then view:set_navigation_state(state) end
end

local function navigation_state_key(view, state)
  if state == nil then return tostring(view) .. ":nil" end
  return tostring(view) .. ":" .. common.serialize(state, { sort = true })
end

local function create_identity(view, opts)
  local pane = {
    id = next_id("pane"),
    group = nil,
    current_view = nil,
    position = { x = 0, y = 0 },
    size = { x = 0, y = 0 },
    history = {
      entries = {},
      index = 0,
      limit = math.max(1, tonumber(opts and opts.history_limit) or 100),
    },
    retained_views = {},
  }
  claim_view(pane, view)
  pane.history.entries[1] = { view = view, state = capture_navigation_state(view) }
  pane.history.index = 1
  pane.current_view = view
  M.panes_by_id[pane.id] = pane
  return pane
end

local function create_restored_identity(view, id)
  local pane = {
    id = id,
    group = nil,
    current_view = view,
    position = { x = 0, y = 0 },
    size = { x = 0, y = 0 },
    history = { entries = {}, index = 1, limit = 100 },
    retained_views = {},
  }
  claim_view(pane, view)
  pane.history.entries[1] = { view = view, state = capture_navigation_state(view) }
  M.panes_by_id[id] = pane
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

function M.current_editor()
  local pane = M.active_pane
  local view = pane and pane.current_view
  local Editor = require "core.editor"
  return view and view.extends and view:extends(Editor) and view or nil
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
  local pane = create_identity(view, opts)
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
  if direction ~= "left" and direction ~= "right"
      and direction ~= "up" and direction ~= "down" then
    return nil, "invalid split direction"
  end
  local view, err = make_view(opts)
  if not view then
    quiet("Pane split failed target=%s: %s", pane.id, tostring(err))
    return nil, err
  end
  local new_pane = create_identity(view, opts)
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
        local overlap
        if direction == "left" or direction == "right" then
          overlap = candidate.position.y < active.position.y + active.size.y
            and active.position.y < candidate.position.y + candidate.size.y
        else
          overlap = candidate.position.x < active.position.x + active.size.x
            and active.position.x < candidate.position.x + candidate.size.x
        end
        local score = (overlap and 0 or 1e12) + primary * primary + secondary * secondary
        if not best_score or score < best_score then best, best_score = candidate, score end
      end
    end
  end
  return best and M.focus(best) or nil
end

function M.rotate_group_clockwise(target)
  local pane = M.find(target or M.active_pane)
  local group = pane and pane.group
  if not group then return false end

  local ordered = layout.leaves(group.root)
  if #ordered < 2 then return false end

  local slots = {}
  local min_x, min_y, max_x, max_y
  local min_cx, min_cy, max_cx, max_cy
  for index, member in ipairs(ordered) do
    local x, y = member.position.x, member.position.y
    local w, h = member.size.x, member.size.y
    if type(x) ~= "number" or type(y) ~= "number"
    or type(w) ~= "number" or type(h) ~= "number" then
      return false
    end
    local cx, cy = x + w / 2, y + h / 2
    slots[#slots + 1] = { pane = member, cx = cx, cy = cy, index = index }
    min_x, min_y = math.min(min_x or x, x), math.min(min_y or y, y)
    max_x, max_y = math.max(max_x or x + w, x + w), math.max(max_y or y + h, y + h)
    min_cx, min_cy = math.min(min_cx or cx, cx), math.min(min_cy or cy, cy)
    max_cx, max_cy = math.max(max_cx or cx, cx), math.max(max_cy or cy, cy)
  end

  local center_x, center_y = (min_x + max_x) / 2, (min_y + max_y) / 2
  local epsilon = 0.001
  if max_cy - min_cy <= epsilon then
    table.sort(slots, function(a, b)
      return a.cx == b.cx and a.index < b.index or a.cx < b.cx
    end)
  elseif max_cx - min_cx <= epsilon then
    table.sort(slots, function(a, b)
      return a.cy == b.cy and a.index < b.index or a.cy < b.cy
    end)
  else
    local function vector(slot)
      return center_y - slot.cy, slot.cx - center_x
    end
    local function second_half(x, y)
      return y < 0 or (y == 0 and x < 0)
    end
    table.sort(slots, function(a, b)
      local ax, ay = vector(a)
      local bx, by = vector(b)
      local a_second, b_second = second_half(ax, ay), second_half(bx, by)
      if a_second ~= b_second then return not a_second end
      local cross = ax * by - ay * bx
      if math.abs(cross) > epsilon then return cross > 0 end
      local ad, bd = ax * ax + ay * ay, bx * bx + by * by
      if ad ~= bd then return ad < bd end
      return a.index < b.index
    end)
  end

  local source_for_slot = {}
  for index, slot in ipairs(slots) do
    local destination = slots[index % #slots + 1]
    source_for_slot[destination.pane] = slot.pane
  end
  local rotated = {}
  for index, slot_pane in ipairs(ordered) do
    rotated[index] = source_for_slot[slot_pane]
  end
  layout.reorder(group.root, rotated)
  if group.root.rect then layout.update_rects(group.root, group.root.rect) end
  M.visible_group_value = group
  after_mutation("rotated Pane Group clockwise " .. group.id)
  return true
end

local function remove_group(group)
  local index = group_index(group)
  if index then table.remove(M.groups, index) end
  M.groups_by_id[group.id] = nil
end

local function remove_from_group(pane)
  local group = pane.group
  group.root = layout.remove(group.root, pane)
  pane.group = nil
  if not group.root then remove_group(group) end
  return group
end

function M.move(source_target, destination_target, direction)
  local source = M.find(source_target)
  local destination = M.find(destination_target)
  if not source or not destination then return nil, "invalid source or target Pane" end
  if source == destination then return nil, "source and target Pane are the same" end
  if direction ~= "left" and direction ~= "right"
    and direction ~= "up" and direction ~= "down" then
    return nil, "invalid Pane move direction"
  end
  local destination_group = destination.group
  if source.group == destination_group then
    local ordered = layout.leaves(destination_group.root)
    local source_index, destination_index
    for i, pane in ipairs(ordered) do
      if pane == source then source_index = i end
      if pane == destination then destination_index = i end
    end
    table.remove(ordered, source_index)
    if source_index < destination_index then destination_index = destination_index - 1 end
    local insertion = (direction == "left" or direction == "up")
      and destination_index or destination_index + 1
    table.insert(ordered, insertion, source)
    layout.reorder(destination_group.root, ordered)
    layout.rebalance(destination_group.root,
      (direction == "left" or direction == "right") and "x" or "y")
    M.active_pane = source
    M.visible_group_value = destination_group
    focus_view(source)
    after_mutation(string.format("reordered %s %s of %s", source.id, direction, destination.id))
    return source
  end
  remove_from_group(source)
  source.group = destination_group
  destination_group.root = layout.split(destination_group.root, destination, direction, source)
  M.active_pane = source
  M.visible_group_value = destination_group
  focus_view(source)
  after_mutation(string.format("moved %s %s of %s", source.id, direction, destination.id))
  return source
end

function M.swap(source_target, destination_target)
  local source = M.find(source_target)
  local destination = M.find(destination_target)
  if not source or not destination then return nil, "invalid source or target Pane" end
  if source == destination then return source end

  local source_group = source.group
  local destination_group = destination.group
  local source_order = layout.leaves(source_group.root)
  local destination_order = source_group == destination_group
    and source_order or layout.leaves(destination_group.root)
  local source_index, destination_index
  for index, pane in ipairs(source_order) do
    if pane == source then source_index = index end
    if pane == destination then destination_index = index end
  end
  if source_group ~= destination_group then
    for index, pane in ipairs(destination_order) do
      if pane == destination then destination_index = index break end
    end
  end
  assert(source_index and destination_index, "Pane swap target is missing from its layout")

  source_order[source_index] = destination
  destination_order[destination_index] = source
  layout.reorder(source_group.root, source_order)
  if source_group ~= destination_group then
    layout.reorder(destination_group.root, destination_order)
    source.group = destination_group
    destination.group = source_group
  end
  if source_group.root.rect then layout.update_rects(source_group.root, source_group.root.rect) end
  if destination_group ~= source_group and destination_group.root.rect then
    layout.update_rects(destination_group.root, destination_group.root.rect)
  end

  M.active_pane = source
  M.visible_group_value = source.group
  focus_view(source)
  after_mutation(string.format("swapped %s with %s", source.id, destination.id))
  return source
end

function M.detach(target)
  local pane = M.find(target)
  if not pane then return nil, "invalid Pane" end
  if #layout.leaves(pane.group.root) == 1 then return pane end
  remove_from_group(pane)
  local group = create_group(pane)
  M.active_pane = pane
  M.visible_group_value = group
  focus_view(pane)
  after_mutation("detached " .. pane.id)
  return pane
end

function M.move_to_group_boundary(source_target, destination_target, placement)
  local source = M.find(source_target)
  local destination = M.find(destination_target)
  if not source or not destination then return nil, "invalid source or target Pane" end
  if placement ~= "before" and placement ~= "after" then
    return nil, "invalid Pane Group boundary"
  end
  local source_group = source.group
  local destination_group = destination.group
  if source_group == destination_group and #layout.leaves(source_group.root) == 1 then
    return source
  end

  local singleton = #layout.leaves(source_group.root) == 1
  if singleton then
    local index = assert(group_index(source_group), "source Pane Group is not registered")
    table.remove(M.groups, index)
  else
    remove_from_group(source)
  end

  local destination_index = assert(
    group_index(destination_group), "destination Pane Group is not registered"
  )
  local insertion = destination_index + (placement == "after" and 1 or 0)
  if singleton then
    table.insert(M.groups, insertion, source_group)
  else
    create_group(source, insertion)
  end
  M.active_pane = source
  M.visible_group_value = source.group
  focus_view(source)
  after_mutation(string.format(
    "moved %s %s group %s", source.id, placement, destination_group.id
  ))
  return source
end

function M.drop_target_at(x, y)
  local group = M.visible_group_value
  local pane = group and layout.pane_at(group.root, x, y)
  if not pane then return nil end
  local left = (x - pane.position.x) / math.max(1, pane.size.x)
  local top = (y - pane.position.y) / math.max(1, pane.size.y)
  local distances = {
    { "left", left }, { "right", 1 - left },
    { "up", top }, { "down", 1 - top },
  }
  table.sort(distances, function(a, b) return a[2] < b[2] end)
  if distances[1][2] > 0.25 then return pane, "center" end
  return pane, distances[1][1]
end

function M.drop(source, x, y)
  local destination, direction = M.drop_target_at(x, y)
  if not destination then return nil, "no Pane drop target" end
  if direction == "center" then
    return M.swap(source, destination)
  end
  return M.move(source, destination, direction)
end

local function call_lifecycle(view, method)
  if view and view[method] then view[method](view) end
end

local function log_navigation_history(pane, action)
  quiet(
    "Navigation History: pane=%s action=%s index=%d length=%d view=%s",
    pane.id, action, pane.history.index, #pane.history.entries,
    tostring(pane.current_view)
  )
end

local function set_history_index(pane, index, opts)
  local history = pane.history
  if index < 1 or index > #history.entries then return nil end
  if index == history.index then return pane.current_view end
  local old = pane.current_view
  history.entries[history.index].state = capture_navigation_state(old)
  local next_view = history.entries[index].view
  if old ~= next_view then call_lifecycle(old, "on_suspend") end
  history.index = index
  pane.current_view = next_view
  restore_navigation_state(next_view, history.entries[index].state)
  log_navigation_history(pane, "traverse")
  if old ~= next_view then call_lifecycle(next_view, "on_resume") end
  if not opts or opts.focus ~= false then M.focus(pane) end
  after_mutation("navigated " .. pane.id)
  return pane.current_view
end

local function history_has_view(pane, view)
  for _, entry in ipairs(pane.history.entries) do
    if entry.view == view then return true end
  end
  return false
end

local function history_view_index(pane, view)
  local current = pane.history.index
  for index = current, 1, -1 do
    if pane.history.entries[index].view == view then return index end
  end
  for index = current + 1, #pane.history.entries do
    if pane.history.entries[index].view == view then return index end
  end
end

local function retained_view_index(pane, view)
  for index, candidate in ipairs(pane.retained_views or {}) do
    if candidate == view then return index end
  end
end

local function retain_view(pane, view)
  if not retained_view_index(pane, view) then
    pane.retained_views[#pane.retained_views + 1] = view
  end
end

local function unretain_view(pane, view)
  local index = retained_view_index(pane, view)
  if index then table.remove(pane.retained_views, index) end
  return index ~= nil
end

local function discard_retained_view(pane, index)
  local view = table.remove(pane.retained_views, index)
  if not view or history_has_view(pane, view) then return view end
  release_view(pane, view)
  if view.on_history_discarded then
    view:on_history_discarded()
  else
    call_lifecycle(view, "on_close")
  end
  return view
end

local function discard_entry(pane, index, retain_if_unreferenced)
  local entry = table.remove(pane.history.entries, index)
  if not entry then return end
  if index <= pane.history.index then pane.history.index = pane.history.index - 1 end
  local referenced = history_has_view(pane, entry.view)
  if not referenced and retain_if_unreferenced then retain_view(pane, entry.view) end
  if not referenced and not retained_view_index(pane, entry.view) then
    release_view(pane, entry.view)
    if entry.view.on_history_discarded then
      entry.view:on_history_discarded()
    else
      call_lifecycle(entry.view, "on_close")
    end
  end
end

local function can_trim_history_view(view)
  if view.can_discard_from_history then return view:can_discard_from_history() end
  if view.buffer and view.buffer.is_dirty and view.buffer:is_dirty() then return false end
  return not view.history_protected
end

local function clear_forward_history(pane, preserve_view)
  local history = pane.history
  local removed = #history.entries - history.index
  for i = #history.entries, history.index + 1, -1 do
    local view = history.entries[i].view
    discard_entry(pane, i, view == preserve_view or not can_trim_history_view(view))
  end
  if removed > 0 then log_navigation_history(pane, "clear-forward") end
end

function M.prune_history(target)
  local pane = M.find(target)
  if not pane then return 0 end
  local removed = 0
  for index = #(pane.retained_views or {}), 1, -1 do
    local view = pane.retained_views[index]
    if (view.is_stale and view:is_stale()) or can_trim_history_view(view) then
      discard_retained_view(pane, index)
      removed = removed + 1
    end
  end
  for i = #pane.history.entries, 1, -1 do
    local view = pane.history.entries[i].view
    if i ~= pane.history.index and view.is_stale and view:is_stale() then
      discard_entry(pane, i)
      removed = removed + 1
    end
  end
  while #pane.history.entries > pane.history.limit do
    local discard_index
    for i, entry in ipairs(pane.history.entries) do
      if i ~= pane.history.index and can_trim_history_view(entry.view) then
        discard_index = i
        break
      end
    end
    local retain
    if not discard_index then
      for i in ipairs(pane.history.entries) do
        if i ~= pane.history.index then discard_index, retain = i, true; break end
      end
    end
    if not discard_index then break end
    discard_entry(pane, discard_index, retain)
    removed = removed + 1
  end
  pane.current_view = pane.history.entries[pane.history.index].view
  return removed
end

local function collect_owned_views(pane)
  local result = {}
  local seen = {}
  for _, entry in ipairs(pane.history.entries) do
    if not seen[entry.view] then
      seen[entry.view] = true
      result[#result + 1] = entry.view
    end
  end
  for _, view in ipairs(pane.retained_views or {}) do
    if not seen[view] then
      seen[view] = true
      result[#result + 1] = view
    end
  end
  return result
end

function M.is_disposable(target)
  local pane = M.find(target)
  if not pane or #pane.history.entries ~= 1 or #(pane.retained_views or {}) ~= 0 then
    return false
  end
  local view = pane.current_view
  local buffer = view and view.buffer
  local Editor = require "core.editor"
  return view.extends and view:extends(Editor)
    and buffer
    and buffer.intellij_untitled
    and buffer.new_file
    and not buffer.filename
    and not buffer.abs_filename
    and #buffer.lines == 1
    and buffer.lines[1] == "\n"
end

function M.move_and_merge(source_target, destination_target)
  local source = M.find(source_target)
  local destination = M.find(destination_target)
  if not source or not destination then return false, "invalid source or destination Pane" end
  if source == destination then return false, "source and destination Pane are the same" end

  source.history.entries[source.history.index].state = capture_navigation_state(source.current_view)
  destination.history.entries[destination.history.index].state =
    capture_navigation_state(destination.current_view)

  local destination_entries = destination.history.entries
  if M.is_disposable(destination) then
    local placeholder = destination.current_view
    call_lifecycle(placeholder, "on_suspend")
    release_view(destination, placeholder)
    call_lifecycle(placeholder, "on_close")
    destination_entries = {}
  else
    call_lifecycle(destination.current_view, "on_suspend")
  end

  local destination_count = #destination_entries
  for _, view in ipairs(collect_owned_views(source)) do
    release_view(source, view)
    claim_view(destination, view)
  end
  for _, entry in ipairs(source.history.entries) do
    destination_entries[#destination_entries + 1] = entry
  end
  for _, view in ipairs(source.retained_views or {}) do
    if not retained_view_index(destination, view) then
      destination.retained_views[#destination.retained_views + 1] = view
    end
  end

  destination.history.entries = destination_entries
  destination.history.index = destination_count + source.history.index
  destination.history.limit = math.max(
    destination.history.limit, source.history.limit, #destination_entries
  )
  destination.current_view = source.current_view

  remove_from_group(source)
  M.panes_by_id[source.id] = nil
  source.history = { entries = {}, index = 0, limit = source.history.limit }
  source.retained_views = {}
  source.current_view = nil

  M.active_pane = destination
  M.visible_group_value = destination.group
  focus_view(destination)
  log_navigation_history(destination, "move-and-merge")
  after_mutation(string.format("moved and merged %s into %s", source.id, destination.id))
  return destination
end

---Return each live View owned by a Pane once.
---This includes protected Views retained outside the current Navigation History branch.
function M.views(target)
  local pane = M.find(target)
  if not pane then return {} end
  M.prune_history(pane)
  return collect_owned_views(pane)
end

function M.history_length(target)
  local pane = M.find(target)
  return pane and #pane.history.entries or 0
end

function M.record_location(target)
  local pane = M.find(target or M.active_pane)
  if not pane then return false end
  local history = pane.history
  local state = capture_navigation_state(pane.current_view)
  local current = history.entries[history.index]
  if current and navigation_state_key(current.view, current.state)
      == navigation_state_key(pane.current_view, state) then
    return false
  end
  clear_forward_history(pane, pane.current_view)
  local index = history.index + 1
  table.insert(history.entries, index, { view = pane.current_view, state = state })
  history.index = index
  M.prune_history(pane)
  log_navigation_history(pane, "record-place")
  after_mutation("recorded location in " .. pane.id)
  return true
end

function M.present(view, opts)
  opts = opts or {}
  local pane = M.find(opts.pane or M.active_pane)
  if not pane then
    return M.create {
      factory = function() return view end,
      focus = opts.focus,
      history_limit = opts.history_limit,
    }
  end
  local existing = M.pane_for_view(view)
  if existing and existing ~= pane then
    return nil, "View is owned by another Pane"
  end
  if existing == pane and opts.reuse then
    local index = history_view_index(pane, view)
    if index then
      if index ~= pane.history.index then
        set_history_index(pane, index, opts)
        return pane
      end
      if opts.focus ~= false then M.focus(pane) end
      return pane
    end
  end
  local current = pane.current_view
  if current ~= view and current.can_suspend and current:can_suspend() == false then
    return nil, "Current View requires transactional replacement"
  end
  if existing == pane and current == view then
    M.record_location(pane)
    if opts.focus ~= false then M.focus(pane) end
    return pane
  end

  local history = pane.history
  history.entries[history.index].state = capture_navigation_state(pane.current_view)
  clear_forward_history(pane, view)
  call_lifecycle(pane.current_view, "on_suspend")
  unretain_view(pane, view)
  claim_view(pane, view)
  local index = history.index + 1
  table.insert(history.entries, index, {
    view = view,
    state = capture_navigation_state(view),
  })
  history.index = index
  pane.current_view = view
  call_lifecycle(view, "on_resume")
  M.prune_history(pane)
  log_navigation_history(pane, "present")
  if opts.focus ~= false then M.focus(pane) end
  after_mutation("presented View in " .. pane.id)
  return pane
end

local function construct_view(factory)
  local ok, view = pcall(factory)
  if not ok then return nil, view end
  if not view then return nil, "View factory returned nil" end
  return view
end

local function commit_non_suspendable_replacement(pane, old, view, opts)
  local history = pane.history
  local insertion = history.index
  local kept = {}
  for _, entry in ipairs(history.entries) do
    if entry.view ~= old then kept[#kept + 1] = entry end
  end
  insertion = math.max(1, math.min(insertion, #kept + 1))
  claim_view(pane, view)
  table.insert(kept, insertion, { view = view, state = capture_navigation_state(view) })
  history.entries, history.index = kept, insertion
  pane.current_view = view
  release_view(pane, old)
  call_lifecycle(old, "on_close")
  call_lifecycle(view, "on_resume")
  if not opts or opts.focus ~= false then M.focus(pane) end
  after_mutation("replaced non-suspendable View in " .. pane.id)
  return pane
end

local function detach_current_view_for_move(source)
  local view = source.current_view
  call_lifecycle(view, "on_suspend")

  unretain_view(source, view)
  local kept = {}
  local before = 0
  for index, entry in ipairs(source.history.entries) do
    if entry.view ~= view then
      kept[#kept + 1] = entry
      if index < source.history.index then before = before + 1 end
    end
  end
  source.history.entries = kept
  source.history.index = math.min(#kept, math.max(1, before))

  if #kept == 0 and #source.retained_views > 0 then
    local fallback = table.remove(source.retained_views)
    kept[1] = { view = fallback, state = capture_navigation_state(fallback) }
    source.history.index = 1
  end

  release_view(source, view)
  if #kept > 0 then
    source.current_view = kept[source.history.index].view
    restore_navigation_state(
      source.current_view, kept[source.history.index].state
    )
    call_lifecycle(source.current_view, "on_resume")
  else
    remove_from_group(source)
    M.panes_by_id[source.id] = nil
    source.current_view = nil
    source.history.index = 0
  end
  return view
end

---Move a Pane's Current View into an existing Pane.
---The source Pane closes when it owns no other View.
function M.move_current_view(source_target, destination_target, opts)
  opts = opts or {}
  local source = M.find(source_target or M.active_pane)
  local destination = M.find(destination_target)
  if not source or not destination then return nil, "invalid source or destination Pane" end
  if source == destination then return nil, "source and destination Pane are the same" end

  local old = destination.current_view
  local suspendable = not old.can_suspend or old:can_suspend() ~= false
  local result
  local function approved()
    if not M.contains(source) or not M.contains(destination) then return end
    local moved = detach_current_view_for_move(source)
    if suspendable then
      local pane, err = M.present(moved, { pane = destination, focus = opts.focus })
      if pane then result = moved else result = nil; quiet("View move failed: %s", tostring(err)) end
    else
      commit_non_suspendable_replacement(destination, old, moved, opts)
      result = moved
    end
  end
  if suspendable or opts.force or not old.can_close then
    approved()
  else
    old:can_close(approved)
  end
  return result, result and nil or "View move is pending or was canceled"
end

---Move a Pane's Current View into a new split next to that Pane.
---The source Pane reveals another owned View or receives a replacement View.
function M.move_current_view_to_split(source_target, direction, opts)
  opts = opts or {}
  local source = M.find(source_target or M.active_pane)
  if not source then return nil, "invalid source Pane" end
  if direction ~= "left" and direction ~= "right"
      and direction ~= "up" and direction ~= "down" then
    return nil, "invalid split direction"
  end

  if #collect_owned_views(source) == 1 then
    local replacement, err = make_view { factory = opts.replacement_factory }
    if not replacement then return nil, err end
    claim_view(source, replacement)
    source.retained_views[#source.retained_views + 1] = replacement
  end

  local moved = detach_current_view_for_move(source)
  local destination = create_identity(moved, opts)
  destination.group = source.group
  source.group.root = layout.split(source.group.root, source, direction, destination)
  M.active_pane = destination
  M.visible_group_value = source.group
  call_lifecycle(moved, "on_resume")
  if opts.focus ~= false then focus_view(destination) end
  after_mutation(string.format(
    "moved Current View from %s into split %s %s", source.id, direction, destination.id
  ))
  return destination
end

---Move a Pane's Current View into a new singleton Pane Group.
function M.move_current_view_to_new_group(source_target, opts)
  opts = opts or {}
  local source = M.find(source_target or M.active_pane)
  if not source then return nil, "invalid source Pane" end
  local moved = detach_current_view_for_move(source)
  local destination = create_identity(moved, opts)
  local group = create_group(destination)
  M.active_pane = destination
  M.visible_group_value = group
  call_lifecycle(moved, "on_resume")
  if opts.focus ~= false then focus_view(destination) end
  after_mutation(string.format("moved Current View from %s into %s", source.id, destination.id))
  return destination
end

function M.replace_view(target, factory, opts)
  opts = opts or {}
  local pane = M.find(target or opts.pane or M.active_pane)
  if not pane then return nil, "invalid target Pane" end
  assert(type(factory) == "function", "View replacement requires a factory")
  local old = pane.current_view
  local suspendable = not old.can_suspend or old:can_suspend() ~= false
  if suspendable then
    local view, err = construct_view(factory)
    if not view then return nil, err end
    local result, present_err = M.present(view, { pane = pane, focus = opts.focus })
    return result and view or nil, present_err
  end

  local result, failure
  local function approved()
    local view, err = construct_view(factory)
    if not view then
      old.discard_buffer_on_close = nil
      failure = err
      return
    end
    commit_non_suspendable_replacement(pane, old, view, opts)
    result = view
  end
  if opts.force or not old.can_close then approved() else old:can_close(approved) end
  if result then return result end
  return nil, failure or "View replacement is pending or was canceled"
end

function M.place(factory, opts)
  opts = opts or {}
  local placement = opts.placement or "current"
  local starting = M.active_pane
  local explicit = opts.pane ~= nil
  local target = M.find(opts.pane or M.active_pane)
  if explicit and not target then return nil, "invalid target Pane" end
  local view, pane, err
  if placement == "current" then
    if target then
      view, err = M.replace_view(target, factory, opts)
      pane = view and target or nil
    else
      pane, err = M.create { factory = factory, focus = opts.focus }
      view = pane and pane.current_view or nil
    end
  elseif placement == "new" then
    pane, err = M.create { factory = factory, focus = opts.focus }
    view = pane and pane.current_view or nil
  elseif placement == "split" then
    if not target then return nil, "split placement requires a target Pane" end
    pane, err = M.split(target, opts.direction or "right", { factory = factory, focus = opts.focus })
    view = pane and pane.current_view or nil
  else
    return nil, "invalid View placement"
  end
  if view and opts.preserve_focus and starting and M.contains(starting) then M.focus(starting) end
  return view, pane or err
end

function M.back(target)
  local pane = M.find(target or M.active_pane)
  if not pane then return nil end
  M.prune_history(pane)
  return set_history_index(pane, pane.history.index - 1)
end

function M.forward(target)
  local pane = M.find(target or M.active_pane)
  if not pane then return nil end
  M.prune_history(pane)
  return set_history_index(pane, pane.history.index + 1)
end

function M.is_back_available(target)
  local pane = M.find(target or M.active_pane)
  return pane ~= nil and pane.history.index > 1
end

function M.is_forward_available(target)
  local pane = M.find(target or M.active_pane)
  return pane ~= nil and pane.history.index < #pane.history.entries
end

function M.close_view(target, opts)
  opts = opts or {}
  local pane = M.find(target or M.active_pane)
  if not pane then return false end
  local view = opts.view or pane.current_view
  local found, other_view = false, false
  for _, candidate in ipairs(collect_owned_views(pane)) do
    if candidate == view then found = true else other_view = true end
  end
  if not found then return false end
  if not other_view then return M.close(pane, opts) end

  local committed = false
  local function approved()
    local was_current = pane.current_view == view
    if was_current then call_lifecycle(view, "on_suspend") end
    unretain_view(pane, view)
    for index = #pane.history.entries, 1, -1 do
      if pane.history.entries[index].view == view then discard_entry(pane, index) end
    end
    if view.__pane_owner == pane then
      release_view(pane, view)
      call_lifecycle(view, "on_close")
    end
    pane.history.index = common.clamp(pane.history.index, 1, #pane.history.entries)
    pane.current_view = pane.history.entries[pane.history.index].view
    if was_current then call_lifecycle(pane.current_view, "on_resume") end
    if opts.focus ~= false then M.focus(pane) end
    after_mutation("closed View in " .. pane.id)
    committed = true
  end
  if opts.force or not view.can_close then approved() else view:can_close(approved) end
  return committed
end

local function nearest_after_removal(old_order, old_index)
  return old_order[math.min(old_index, #old_order)] or old_order[old_index - 1]
end

local function commit_close(pane)
  local old_order = M.ordered()
  local old_index = M.number(pane)
  local closed_active_view = M.pane_for_view(core.active_view) == pane
  local group = pane.group
  local old_group_order = layout.leaves(group.root)
  local old_group_index
  for index, member in ipairs(old_group_order) do
    if member == pane then old_group_index = index break end
  end
  assert(old_group_index, "closed Pane is not in its Pane Group")
  group.root = layout.remove(group.root, pane)
  M.panes_by_id[pane.id] = nil
  for _, view in ipairs(collect_owned_views(pane)) do
    release_view(pane, view)
    call_lifecycle(view, "on_close")
  end
  pane.group = nil
  if not group.root then
    local index = group_index(group)
    if index then table.remove(M.groups, index) end
    M.groups_by_id[group.id] = nil
  end
  local survivors = M.ordered()
  local group_survivors = group.root and layout.leaves(group.root) or {}
  local next_pane = nearest_after_removal(group_survivors, old_group_index)
    or nearest_after_removal(survivors, old_index)
  if #survivors == 0 then
    M.active_pane = nil
    M.visible_group_value = nil
    if closed_active_view and core.clear_active_view then core.clear_active_view(core.active_view) end
  elseif M.active_pane == pane or not M.contains(M.active_pane) then
    M.active_pane = next_pane
    M.visible_group_value = next_pane.group
    focus_view(next_pane)
  elseif M.visible_group_value == group and not group.root then
    M.visible_group_value = M.active_pane.group
  end
  after_mutation("closed " .. pane.id)
end

local function close_candidates(pane)
  local result = { pane.current_view }
  for _, view in ipairs(collect_owned_views(pane)) do
    if view ~= pane.current_view then result[#result + 1] = view end
  end
  return result
end

local function authorize_close(pane, force, done)
  local views = close_candidates(pane)
  local index = 1
  local function next_view()
    local view = views[index]
    if not view then done(); return end
    index = index + 1
    if force or not view.can_close then next_view() else view:can_close(next_view) end
  end
  next_view()
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
  authorize_close(pane, opts.force, close)
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
      authorize_close(pane, opts and opts.force, function()
        commit_close(pane)
        close_next()
      end)
    else
      close_next()
    end
  end
  close_next()
  return M.count() == 0
end

local function serialize_pruned_layout(node, valid)
  if not node then return nil end
  if node.kind == "pane" then
    if valid[node.pane] then return { kind = "pane", pane_id = node.pane.id } end
    return nil
  end
  if node.kind ~= "split" then return nil end
  local a = serialize_pruned_layout(node.a, valid)
  local b = serialize_pruned_layout(node.b, valid)
  if not a then return b end
  if not b then return a end
  return { kind = "split", axis = node.axis, ratio = node.ratio, a = a, b = b }
end

function M.save_workspace_state(save_view)
  assert(type(save_view) == "function", "Workspace View saver is required")
  local state = { version = 1, groups = {}, panes = {} }
  local valid = {}
  for _, pane in ipairs(M.ordered()) do
    local ok, saved = pcall(save_view, pane.current_view)
    if ok and saved then
      valid[pane] = true
      state.panes[#state.panes + 1] = { id = pane.id, view = saved }
    elseif not ok then
      quiet("Workspace: skipped Pane %s after View save failed: %s", pane.id, tostring(saved))
    end
  end
  local saved_groups = {}
  for _, group in ipairs(M.groups) do
    local saved_layout = serialize_pruned_layout(group.root, valid)
    if saved_layout then
      state.groups[#state.groups + 1] = { id = group.id, layout = saved_layout }
      saved_groups[group] = true
    end
  end
  if M.visible_group_value and saved_groups[M.visible_group_value] then
    state.visible_group_id = M.visible_group_value.id
  end
  if M.active_pane and valid[M.active_pane] and saved_groups[M.active_pane.group] then
    state.focused_pane_id = M.active_pane.id
  end
  return state
end

local function prune_restored_layout(node, panes_by_id, attached)
  if type(node) ~= "table" then return nil end
  if node.kind == "pane" then
    local pane = panes_by_id[node.pane_id]
    if not pane or attached[pane] then return nil end
    attached[pane] = true
    return { kind = "pane", pane_id = pane.id }
  end
  if node.kind ~= "split" or (node.axis ~= "x" and node.axis ~= "y") then return nil end
  local a = prune_restored_layout(node.a, panes_by_id, attached)
  local b = prune_restored_layout(node.b, panes_by_id, attached)
  if not a then return b end
  if not b then return a end
  return {
    kind = "split", axis = node.axis,
    ratio = common.clamp(tonumber(node.ratio) or 0.5, 0.05, 0.95),
    a = a, b = b,
  }
end

local function numeric_id(id, prefix)
  return tonumber(type(id) == "string" and id:match("^" .. prefix .. "%-(%d+)$") or nil) or 0
end

function M.restore_workspace_state(state, load_view)
  M.close_all { force = true }
  M.reset_for_tests()
  if type(state) ~= "table" or state.version ~= 1
      or type(state.groups) ~= "table" or type(state.panes) ~= "table" then
    quiet("Workspace: ignored obsolete or invalid Pane layout state")
    return false
  end
  assert(type(load_view) == "function", "Workspace View loader is required")

  local restored = {}
  for _, record in ipairs(state.panes) do
    if type(record) == "table" and type(record.id) == "string" and not restored[record.id] then
      local ok, view = pcall(load_view, record.view)
      if ok and view then
        local pane = create_restored_identity(view, record.id)
        restored[pane.id] = pane
        M.next_pane_id = math.max(M.next_pane_id, numeric_id(pane.id, "pane"))
      else
        quiet("Workspace: pruned invalid View for Pane %s: %s", record.id, tostring(view))
      end
    end
  end

  local attached = {}
  local group_ids = {}
  for _, record in ipairs(state.groups) do
    if type(record) == "table" and type(record.id) == "string" and not group_ids[record.id] then
      local pruned = prune_restored_layout(record.layout, restored, attached)
      if pruned then
        local root = layout.deserialize(pruned, restored)
        local group = { id = record.id, root = root }
        group_ids[group.id] = true
        M.groups[#M.groups + 1] = group
        M.groups_by_id[group.id] = group
        M.next_group_id = math.max(M.next_group_id, numeric_id(group.id, "group"))
        for _, pane in ipairs(layout.leaves(root)) do pane.group = group end
      end
    end
  end

  for _, pane in pairs(restored) do
    if not attached[pane] then
      local views = M.views(pane)
      M.panes_by_id[pane.id] = nil
      for _, view in ipairs(views) do
        release_view(pane, view)
        call_lifecycle(view, "on_close")
      end
    end
  end

  local visible = M.groups_by_id[state.visible_group_id] or M.groups[1]
  local focused = M.panes_by_id[state.focused_pane_id]
  if not focused or not visible or focused.group ~= visible then
    focused = visible and layout.leaves(visible.root)[1] or nil
  end
  M.visible_group_value = visible
  M.active_pane = focused
  if focused then focus_view(focused) end
  after_mutation("restored Workspace")
  return true
end

function M.reset_for_tests()
  for _, pane in ipairs(M.ordered()) do
    for _, view in ipairs(collect_owned_views(pane)) do release_view(pane, view) end
  end
  M.groups = {}
  M.panes_by_id = {}
  M.groups_by_id = {}
  M.focus_owners = setmetatable({}, { __mode = "k" })
  M.suspended_services = setmetatable({}, { __mode = "k" })
  M.active_pane = nil
  M.visible_group_value = nil
  M.next_pane_id = 0
  M.next_group_id = 0
end

function M.validate()
  local seen_panes = {}
  local seen_current_views = {}
  local seen_owned_views = {}
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
      assert(pane.history and #pane.history.entries > 0, "Pane has no View history")
      assert(pane.history.index >= 1 and pane.history.index <= #pane.history.entries,
        "Pane View history index is invalid")
      assert(pane.history.entries[pane.history.index].view == pane.current_view,
        "Current View does not match Pane View history")
      assert(not seen_current_views[pane.current_view], "View is Current in more than one Pane")
      seen_current_views[pane.current_view] = true
      assert(pane.current_view.__pane_owner == pane, "Current View points to the wrong Pane")
      for _, entry in ipairs(pane.history.entries) do
        assert(entry.view, "Pane View history entry has no View")
        assert(not seen_owned_views[entry.view] or seen_owned_views[entry.view] == pane,
          "View is retained by more than one Pane")
        seen_owned_views[entry.view] = pane
        assert(entry.view.__pane_owner == pane, "retained View points to the wrong Pane")
      end
      for _, view in ipairs(pane.retained_views or {}) do
        assert(view and not history_has_view(pane, view),
          "retained View must not duplicate a Navigation Place")
        assert(not seen_owned_views[view] or seen_owned_views[view] == pane,
          "View is retained by more than one Pane")
        seen_owned_views[view] = pane
        assert(view.__pane_owner == pane, "retained View points to the wrong Pane")
      end
    end
  end
  for _, pane in pairs(M.panes_by_id) do assert(seen_panes[pane], "registered Pane is missing from layout") end
  for child, owner in pairs(M.focus_owners) do
    assert(child ~= owner, "focus target cannot own itself")
    assert(seen_owned_views[owner], "focus target owner is not retained by a Pane")
    assert(owner.__pane_owner == seen_owned_views[owner], "focus target owner points to the wrong Pane")
  end
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
