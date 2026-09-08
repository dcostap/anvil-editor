local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local navigation_feedback = require "core.navigation_feedback"
local panes = require "core.panes"

local M = core.poi or {}
core.poi = M
M.activation_providers = M.activation_providers or {}
M.remote_sources = M.remote_sources or setmetatable({}, { __mode = "k" })

function M.set_remote_source(view, opts)
  opts = opts or {}
  local project = opts.project or core.root_project()
  if not project or not view or view.remote_poi_source ~= true then return false end
  M.remote_sources[project] = { view = view, initial = opts.from_start ~= false }
  local preview = package.loaded["core.poi_preview"]
  if preview then preview.dismiss(view) end
  core.log_quiet("Remote POI source selected: %s", view:get_name())
  return true
end

function M.get_remote_source(project)
  local source = M.remote_sources[project or core.root_project()]
  return source and source.view
end

function M.is_selected_remote_source(view)
  for _, source in pairs(M.remote_sources) do
    if source.view == view then return true end
  end
  return false
end

function M.clear_remote_source(view, project)
  if project then
    local source = M.remote_sources[project]
    if source and source.view == view then M.remote_sources[project] = nil end
  else
    for owner, source in pairs(M.remote_sources) do
      if source.view == view then M.remote_sources[owner] = nil end
    end
  end
end

---Register a provider for context-sensitive Point of Interest Activation.
---Providers above priority 0 run before a view's own POIs; providers at or below 0
---are fallbacks used only when the Focused View has no activatable POI.
---A returned POI can set alternate_placement to "new" to open a new Pane Group instead of a split.
function M.add_activation_provider(id, provider, opts)
  assert(type(id) == "string" and id ~= "", "POI activation provider id must be a non-empty string")
  assert(type(provider) == "table" and type(provider.point_at_caret) == "function",
    "POI activation provider must define point_at_caret")
  opts = opts or {}
  M.activation_providers[id] = {
    id = id,
    provider = provider,
    priority = tonumber(opts.priority or provider.priority) or 0,
  }
end

function M.remove_activation_provider(id)
  if not M.activation_providers[id] then return false end
  M.activation_providers[id] = nil
  return true
end

local function sorted_activation_providers()
  local providers = {}
  for _, entry in pairs(M.activation_providers) do providers[#providers + 1] = entry end
  table.sort(providers, function(a, b)
    if a.priority ~= b.priority then return a.priority > b.priority end
    return a.id < b.id
  end)
  return providers
end

local function provider_point_at_caret(view, opts, before_view)
  for _, entry in ipairs(sorted_activation_providers()) do
    if (entry.priority > 0) == before_view then
      local ok, point = pcall(entry.provider.point_at_caret, entry.provider, view, opts or {})
      if not ok then
        core.log_quiet("POI activation provider %s failed: %s", entry.id, tostring(point))
      elseif point and M.is_activatable(view, point) then
        return point
      end
    end
  end
end

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
  if not view then return nil end
  local point = provider_point_at_caret(view, opts, true)
  if point then return point end
  if not view.buffer then return provider_point_at_caret(view, opts, false) end
  return with_selection_state(view, function()
    local line, col = view.buffer:get_selection()
    if type(view.get_point_of_interest_at) == "function" then
      local poi = view:get_point_of_interest_at(line, col, opts)
      if poi and (not opts.activatable or M.is_activatable(view, poi)) then return poi end
    end
    local points = M.points_for_view(view, opts)
    if points then
      for _, poi in ipairs(points) do
        if point_contains(poi, line, col) and (not opts.activatable or M.is_activatable(view, poi)) then
          return poi
        end
      end
    end
    return provider_point_at_caret(view, opts, false)
  end)
end

local function provider_view(view)
  if view and not view.buffer and type(view.get_focus_view) == "function" then
    local focus = view:get_focus_view()
    if focus then return focus end
  end
  return view
end

function M.next(view, direction, opts)
  opts = opts or {}
  view = provider_view(view)
  direction = normalize_direction(direction)
  if not view or not view.buffer then return nil, "no-provider" end
  return with_selection_state(view, function()
    local points, unavailable = M.points_for_view(view, opts)
    if not points then return nil, unavailable or "no-provider" end
    if #points == 0 then return nil, "empty" end

    local line, col = view.buffer:get_selection()
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

function M.select(view, poi, opts)
  opts = opts or {}
  require("core.poi_preview").dismiss(view)
  return with_selection_state(view, function()
    local _, current_col = view.buffer:get_selection()
    local col = poi.preserve_col and current_col or poi.col
    view.buffer:set_selection(poi.line, col, poi.line, col)
    if poi.scroll_to_line and type(view.scroll_to_line) == "function" then
      view:scroll_to_line(poi.line, false, true)
    elseif type(view.scroll_to_make_visible) == "function" then
      view:scroll_to_make_visible(poi.line, col)
    elseif type(view.scroll_to_line) == "function" then
      view:scroll_to_line(poi.line, false, true)
    end
    if opts.preview ~= false then
      if type(poi.preview) == "function" then
        poi.preview(view, poi)
      elseif type(view.preview_point_of_interest) == "function" then
        view:preview_point_of_interest(poi)
      end
    end
    return poi
  end)
end

function M.navigate(view, direction, opts)
  view = provider_view(view)
  direction = normalize_direction(direction)
  local point, status = M.next(view, direction, opts)
  if not point then return show_navigation_feedback(status, direction) end
  for _, source in pairs(M.remote_sources) do
    if source.view == view then source.initial = false end
  end
  return M.select(view, point, opts)
end

function M.navigate_remote(direction, opts)
  opts = opts or {}
  direction = normalize_direction(direction)
  local source = M.remote_sources[opts.project or core.root_project()]
  if not source then return navigation_feedback.none("Remote POIs") end
  local view = source.view
  local point, status
  if source.initial then
    local points
    points, status = M.points_for_view(view, { remote = true })
    point = points and (direction > 0 and points[1] or points[#points])
    status = status or "empty"
  else
    point, status = M.next(view, direction, { remote = true })
  end
  if not point then return show_navigation_feedback(status, direction) end
  source.initial = false
  M.select(view, point, { preview = false })
  local result = M.activate(view, point, {
    pane = opts.pane or panes.active(), placement = "current", preserve_focus = false,
    remote = true,
  })
  if not result then navigation_feedback.warning("Could not activate remote POI") end
  return result
end

function M.activate(view, poi, opts)
  opts = opts or {}
  if not view then return false end
  poi = poi or M.point_at_caret(view, { activatable = true, silent = true })
  if not poi then return false end
  for _, source in pairs(M.remote_sources) do
    if source.view == view then source.initial = false end
  end
  if type(poi.activate) == "function" then
    local result = poi.activate(view, poi, opts)
    if result then return result end
  end
  if type(view.activate_point_of_interest) == "function" then
    return view:activate_point_of_interest(poi, opts)
  end
  return false
end

local function active_view_has_activatable_poi(...)
  local view = provider_view(core.active_view)
  local poi = M.point_at_caret(view, { activatable = true, silent = true })
  return poi ~= nil, view, poi, ...
end

command.add(nil, {
  ["core:show_remote_point_of_interest_source"] = function()
    local view = M.get_remote_source()
    local owner = panes.owner_for_view(view)
    if not owner then return navigation_feedback.none("Remote POI Source") end
    panes.present(owner, { pane = panes.pane_for_view(owner) })
    if owner.focus_surface_target then owner:focus_surface_target(view) end
  end,
  ["core:previous_remote_point_of_interest"] = function()
    M.navigate_remote(-1)
  end,
  ["core:next_remote_point_of_interest"] = function()
    M.navigate_remote(1)
  end,
  ["core:previous_point_of_interest"] = function()
    M.navigate(core.active_view, -1)
  end,
  ["core:next_point_of_interest"] = function()
    M.navigate(core.active_view, 1)
  end,
})

command.add(function()
  local view = provider_view(core.active_view)
  return view and view.remote_poi_source == true, view
end, {
  ["core:use_remote_point_of_interest_source"] = function(view)
    M.set_remote_source(view, { from_start = false })
  end,
})

command.add(active_view_has_activatable_poi, {
  ["core:activate_point_of_interest"] = function(view, poi)
    M.activate(view, poi, { preserve_focus = false })
  end,
  ["core:activate_point_of_interest_alternate"] = function(view, poi)
    local placement = poi.alternate_placement or "split"
    core.log_quiet("Point of Interest alternate activation: kind=%s placement=%s", tostring(poi.kind), placement)
    M.activate(view, poi, {
      placement = placement,
      preserve_focus = false,
    })
  end,
})

keymap.add({
  ["ctrl+alt+,"] = "core:previous_point_of_interest",
  ["ctrl+alt+."] = "core:next_point_of_interest",
  ["alt+r"] = "core:activate_point_of_interest",
  ["alt+shift+r"] = "core:activate_point_of_interest_alternate",
})

return M
