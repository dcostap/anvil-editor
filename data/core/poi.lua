local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local navigation_feedback = require "core.navigation_feedback"
local panes = require "core.panes"

local M = core.poi or {}
core.poi = M

local function normalize_direction(direction)
  if direction == "previous" or direction == "prev" or direction == "backward" then return -1 end
  if type(direction) == "number" and direction < 0 then return -1 end
  return 1
end

local function with_selection_state(view, fn, ...)
  if view and type(view.with_selection_state) == "function" then
    return view:with_selection_state(fn, ...)
  end
  return fn(...)
end

local function poi_line2(poi)
  return poi.line2 or poi.line
end

local function poi_col2(poi)
  return poi.col2 or poi.col
end

local function compare_pos(line_a, col_a, line_b, col_b)
  if line_a ~= line_b then return line_a < line_b and -1 or 1 end
  if col_a ~= col_b then return col_a < col_b and -1 or 1 end
  return 0
end

local function compare_navigation_pos(poi, line, col)
  if poi.line_only_navigation then
    if poi.line ~= line then return poi.line < line and -1 or 1 end
    return 0
  end
  return compare_pos(poi.line, poi.col, line, col)
end

local function sort_points(points)
  table.sort(points, function(a, b)
    local cmp = compare_pos(a.line or 1, a.col or 1, b.line or 1, b.col or 1)
    if cmp ~= 0 then return cmp < 0 end
    cmp = compare_pos(poi_line2(a) or 1, poi_col2(a) or 1, poi_line2(b) or 1, poi_col2(b) or 1)
    if cmp ~= 0 then return cmp < 0 end
    return tostring(a.kind or "") < tostring(b.kind or "")
  end)
  return points
end

local function valid_point(poi)
  return type(poi) == "table" and tonumber(poi.line) and tonumber(poi.col)
end

function M.points_for_view(view, opts)
  if not view or type(view.get_points_of_interest) ~= "function" then
    return nil, "no-provider"
  end
  local points, unavailable = view:get_points_of_interest(opts or {})
  if points == nil then return nil, unavailable end
  local normalized = {}
  for _, poi in ipairs(points) do
    if valid_point(poi) then
      poi.line = math.max(1, math.floor(tonumber(poi.line) or 1))
      poi.col = math.max(1, math.floor(tonumber(poi.col) or 1))
      if poi.line2 then poi.line2 = math.max(1, math.floor(tonumber(poi.line2) or poi.line)) end
      if poi.col2 then poi.col2 = math.max(1, math.floor(tonumber(poi.col2) or poi.col)) end
      normalized[#normalized + 1] = poi
    end
  end
  return sort_points(normalized)
end

function M.is_activatable(view, poi)
  if not poi then return false end
  return type(poi.activate) == "function" or type(view and view.activate_point_of_interest) == "function"
end

local function point_contains(poi, line, col)
  if not poi or not poi.text_bounds then return false end
  local line1, col1 = poi.line, poi.col
  local line2, col2 = poi_line2(poi), poi_col2(poi)
  if compare_pos(line, col, line1, col1) < 0 then return false end
  return compare_pos(line, col, line2, col2) < 0
end

function M.point_at_caret(view, opts)
  opts = opts or {}
  if not view or not view.doc then return nil end
  return with_selection_state(view, function()
    local line, col = view.doc:get_selection()
    if type(view.get_point_of_interest_at) == "function" then
      local poi = view:get_point_of_interest_at(line, col, opts)
      if poi and (not opts.activatable or M.is_activatable(view, poi)) then return poi end
    end
    local points = M.points_for_view(view, opts)
    if not points then return nil end
    for _, poi in ipairs(points) do
      if point_contains(poi, line, col) and (not opts.activatable or M.is_activatable(view, poi)) then
        return poi
      end
    end
  end)
end

local function provider_view(view)
  if view and not view.doc and type(view.get_focus_view) == "function" then
    local focus = view:get_focus_view()
    if focus then return focus end
  end
  return view
end

function M.next(view, direction, opts)
  opts = opts or {}
  view = provider_view(view)
  direction = normalize_direction(direction)
  if not view or not view.doc then return nil, "no-provider" end
  return with_selection_state(view, function()
    local points, unavailable = M.points_for_view(view, opts)
    if not points then return nil, unavailable or "no-provider" end
    if #points == 0 then return nil, "empty" end

    local line, col = view.doc:get_selection()
    local selected
    if direction > 0 then
      for _, poi in ipairs(points) do
        if compare_navigation_pos(poi, line, col) > 0 then
          selected = poi
          break
        end
      end
    else
      for i = #points, 1, -1 do
        local poi = points[i]
        if compare_navigation_pos(poi, line, col) < 0 then
          selected = poi
          break
        end
      end
    end
    return selected, selected and nil or "boundary"
  end)
end

local function show_navigation_feedback(status, direction)
  if status == "empty" or status == "no-provider" or status == nil then
    return navigation_feedback.none("Points of Interest")
  end
  if status == "boundary" then
    return navigation_feedback.no_more(direction, "Point of Interest")
  end
  return navigation_feedback.warning(status)
end

function M.navigate(view, direction, opts)
  view = provider_view(view)
  direction = normalize_direction(direction)
  local poi, status = M.next(view, direction, opts)
  if not poi then return show_navigation_feedback(status, direction) end
  return with_selection_state(view, function()
    local _, current_col = view.doc:get_selection()
    local col = poi.preserve_col and current_col or poi.col
    view.doc:set_selection(poi.line, col, poi.line, col)
    if poi.scroll_to_line and type(view.scroll_to_line) == "function" then
      view:scroll_to_line(poi.line, false, true)
    elseif type(view.scroll_to_make_visible) == "function" then
      view:scroll_to_make_visible(poi.line, col)
    elseif type(view.scroll_to_line) == "function" then
      view:scroll_to_line(poi.line, false, true)
    end
    return poi
  end)
end

function M.activate(view, poi, opts)
  opts = opts or {}
  if not view then return false end
  poi = poi or M.point_at_caret(view, { activatable = true, silent = true })
  if not poi then return false end
  if type(poi.activate) == "function" then
    local result = poi.activate(view, poi, opts)
    if result then return result end
  end
  if type(view.activate_point_of_interest) == "function" then
    return view:activate_point_of_interest(poi, opts)
  end
  return false
end

local function focus_view_for_pane_owner(owner)
  if owner and type(owner.get_focus_view) == "function" then
    return owner:get_focus_view() or owner
  end
  return owner
end

function M.right_target_view()
  if not panes.right_visible() then return nil end
  local owner = panes.selected_view("right")
  if owner and not panes.is_placeholder(owner) then return focus_view_for_pane_owner(owner) end
end

local function active_view_has_activatable_poi(...)
  local view = core.active_view
  local poi = M.point_at_caret(view, { activatable = true, silent = true })
  return poi ~= nil, view, poi, ...
end

local function perform_right_navigate_activate(direction)
  local starting_focus = core.active_view
  local starting_right = panes.pane_for_view(starting_focus) == "right"
  local target = M.right_target_view()
  local selected = M.navigate(target, direction, { source = "right-pane" })
  if type(selected) ~= "table" then return end
  M.activate(target, selected, { pane = "left", preserve_focus = starting_right, source = "right-pane" })
  if starting_right and starting_focus then core.set_active_view(starting_focus) end
end

command.add(nil, {
  ["poi:previous"] = function()
    M.navigate(core.active_view, -1)
  end,
  ["poi:next"] = function()
    M.navigate(core.active_view, 1)
  end,
  ["poi:right-previous-activate"] = function()
    perform_right_navigate_activate(-1)
  end,
  ["poi:right-next-activate"] = function()
    perform_right_navigate_activate(1)
  end,
})

command.add(active_view_has_activatable_poi, {
  ["poi:activate"] = function(view, poi)
    M.activate(view, poi, { preserve_focus = false })
  end,
  ["poi:activate-right"] = function(view, poi)
    M.activate(view, poi, { pane = "right", preserve_focus = false })
  end,
})

keymap.add({
  ["ctrl+alt+,"] = "poi:previous",
  ["ctrl+alt+."] = "poi:next",
  ["alt+r"] = "poi:activate",
  ["alt+shift+r"] = "poi:activate-right",
  ["ctrl+shift+r"] = "poi:activate-right",
  ["alt+8"] = "poi:right-previous-activate",
  ["alt+9"] = "poi:right-next-activate",
})

return M
