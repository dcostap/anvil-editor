local core = require "core"
local Buffer = require "core.buffer"
local common = require "core.common"
local style = require "core.style"
local text_poi_locations = require "core.text_poi_locations"
local TextView = require "core.textview"

local M = {}

local MAX_CANDIDATES = 32768
local ACTION_REVALIDATION_INTERVAL = 1

local function perf_add(name, value)
  if not core.perf_frame_stats then return end
  local perf = package.loaded["core.perf"]
  if perf then perf.frame_add(name, value) end
end

local function normalize_root(path)
  if type(path) ~= "string" or path == "" then return nil end
  local ok, normalized = pcall(common.normalize_path, path)
  return ok and normalized or nil
end

local function project_path()
  local project = core.root_project and core.root_project()
  return project and project.path or nil
end

local function source_path(view)
  local buffer = view and view.buffer
  return buffer and buffer.abs_filename
    or (view and type(view.path) == "string" and view.path or nil)
end

local function roots_for_paths(source, project)
  local roots, seen = {}, {}
  local function add(path)
    path = normalize_root(path)
    if path and not seen[path] then
      seen[path] = true
      roots[#roots + 1] = path
    end
  end

  -- A relative location in a source file is often relative to that file,
  -- while a copied compiler diagnostic is often relative to the Project.
  add(source and common.dirname(source))
  add(project)
  if #roots == 0 then add(system.getcwd()) end
  return roots
end

local function buffer_revision(buffer)
  return buffer and (buffer.text_revision or buffer:get_change_id()) or 0
end

local function existing_file(path)
  local info = path and system.get_file_info(path)
  return info and info.type ~= "dir"
end

local function resolve_candidates(candidates, roots)
  local points = {}
  for _, candidate in ipairs(candidates or {}) do
    for _, root in ipairs(roots) do
      local point = text_poi_locations.resolve_candidate(
        candidate, root, "editor-file-location"
      )
      if point then
        point.text_poi = true
        point.activate = M.activate
        points[#points + 1] = point
        break
      end
    end
  end
  return points
end

local function build_line_index(points)
  local by_line = {}
  for _, point in ipairs(points or {}) do
    local line_points = by_line[point.line]
    if not line_points then
      line_points = {}
      by_line[point.line] = line_points
    end
    line_points[#line_points + 1] = point
  end
  return by_line
end

local function resolve_cache(cache)
  cache.points = resolve_candidates(cache.candidates, cache.roots)
  cache.by_line = build_line_index(cache.points)
  cache.validated_at = system.get_time()
end

local function sort_entries(values)
  table.sort(values, function(left, right)
    return left.line ~= right.line and left.line < right.line
      or left.line == right.line and left.col < right.col
  end)
  return values
end

local function scan_buffer(buffer)
  local candidates = {}
  for line, text in ipairs(buffer.lines or {}) do
    if #candidates >= MAX_CANDIDATES then break end
    local found = text_poi_locations.extract_line_candidates(
      text, line, MAX_CANDIDATES - #candidates
    )
    for _, candidate in ipairs(found) do candidates[#candidates + 1] = candidate end
  end
  return candidates
end

local function new_cache(view, revision, source, project)
  local cache = {
    revision = revision,
    source_path = source,
    project_path = project,
    roots = roots_for_paths(source, project),
    candidates = scan_buffer(view.buffer),
    points = nil,
    by_line = nil,
    validated_at = 0,
  }
  resolve_cache(cache)
  return cache
end

local function cache_for(view)
  local buffer = view and view.buffer
  local revision = buffer_revision(buffer)
  local source = source_path(view)
  local project = project_path()
  local cache = view.editor_file_poi_cache
  if cache
      and cache.revision == revision
      and cache.source_path == source
      and cache.project_path == project then
    return cache
  end
  cache = new_cache(view, revision, source, project)
  view.editor_file_poi_cache = cache
  return cache
end

local function ordered_ranges(transaction)
  local ranges = {}
  for _, range in ipairs(transaction and transaction.changed_ranges or {}) do
    ranges[#ranges + 1] = range
  end
  table.sort(ranges, function(left, right)
    return (left.old_line1 or left.new_line1 or 1)
      < (right.old_line1 or right.new_line1 or 1)
  end)
  return ranges
end

local function map_unchanged_line(ranges, old_line)
  local delta = 0
  for _, range in ipairs(ranges) do
    local old_line1 = range.old_line1 or range.new_line1 or 1
    local old_line2 = range.old_line2 or old_line1
    if old_line < old_line1 then return old_line + delta end
    if old_line <= old_line2 then return nil end
    delta = delta + (range.line_delta or 0)
  end
  return old_line + delta
end

local function rebase_entries(entries, ranges)
  local rebased = {}
  for _, entry in ipairs(entries or {}) do
    local old_line = entry.line
    local new_line = map_unchanged_line(ranges, old_line)
    if new_line then
      local delta = new_line - old_line
      if delta == 0 then
        rebased[#rebased + 1] = entry
      else
        local copy = {}
        for key, value in pairs(entry) do copy[key] = value end
        copy.line = new_line
        if copy.line2 then copy.line2 = copy.line2 + delta end
        rebased[#rebased + 1] = copy
      end
    end
  end
  return sort_entries(rebased)
end

local function refresh_changed_lines(view, cache, transaction)
  local started = core.perf_frame_stats and system.get_time()
  local ranges = ordered_ranges(transaction)
  if #ranges == 0 then return false end
  local candidates = rebase_entries(cache.candidates, ranges)
  local points = rebase_entries(cache.points, ranges)
  local scanned = 0
  for _, range in ipairs(ranges) do
    local line1 = range.new_line1 or range.old_line1 or 1
    local line2 = range.new_line2 or line1
    for line = line1, line2 do
      local found = text_poi_locations.extract_line_candidates(
        view.buffer.lines[line], line, MAX_CANDIDATES - #candidates
      )
      for _, candidate in ipairs(found) do candidates[#candidates + 1] = candidate end
      for _, point in ipairs(resolve_candidates(found, cache.roots)) do
        points[#points + 1] = point
      end
      scanned = scanned + 1
    end
  end
  cache.candidates = sort_entries(candidates)
  cache.points = sort_entries(points)
  cache.by_line = build_line_index(cache.points)
  cache.revision = buffer_revision(view.buffer)
  cache.validated_at = system.get_time()
  perf_add("editor_file_poi_incremental_lines", scanned)
  if started then
    perf_add("editor_file_poi_incremental_ms", (system.get_time() - started) * 1000)
  end
  return true
end

function M.on_text_transaction(view, transaction)
  local cache = view and view.editor_file_poi_cache
  if not cache or not transaction or not transaction.changed then return false end
  local source = source_path(view)
  local project = project_path()
  if cache.source_path ~= source or cache.project_path ~= project
      or not refresh_changed_lines(view, cache, transaction) then
    view.editor_file_poi_cache = nil
    return false
  end
  return true
end

local function points_for_view(view, opts)
  local buffer = view and view.buffer
  if not buffer or buffer.binary then return {} end

  local cache = cache_for(view)
  opts = opts or {}
  local now = system.get_time()
  if opts.force_revalidate == true
      or not cache.points
      or now - cache.validated_at >= ACTION_REVALIDATION_INTERVAL then
    resolve_cache(cache)
  end
  return cache.points
end

function M.update(view)
  local started = core.perf_frame_stats and system.get_time()
  local buffer = view and view.buffer
  if not buffer or buffer.binary then return end
  local cache = cache_for(view)
  if not cache.points then resolve_cache(cache) end
  if started then
    perf_add("editor_file_poi_update_ms", (system.get_time() - started) * 1000)
  end
end

function M.points_of_interest(_, view, opts)
  return points_for_view(view, opts)
end

function M.activate(view, point, opts)
  if not point or not point.path or not existing_file(point.path) then return false end
  opts = opts or {}
  local panes = require "core.panes"
  local preserve_focus = opts.preserve_focus == true
  local pane = type(opts.pane) == "table" and opts.pane or panes.pane_for_view(view)
  local placement = opts.placement or "current"
  local target = core.open_file(point.path, {
    pane = pane,
    placement = placement,
    direction = placement == "split" and "right" or nil,
    line = point.target_line or point.line,
    col = point.target_col or 1,
    focus = not preserve_focus,
    preserve_focus = preserve_focus,
  })
  return target
end

local function draw_line_underlines(view, line, x, y, points)
  if not points or #points == 0 then return end
  local thickness = math.max(1, math.floor(SCALE))
  local min_x = view.position.x
  local max_x = view.position.x + view.size.x
  for _, point in ipairs(points) do
    if point.kind == "editor-file-location"
        and point.text_bounds
        and (point.line2 or point.line) == line then
      for x1, row_y, x2, row_height in view:iter_text_range_screen_segments(
        line, point.col, point.col2 or point.col, x, y
      ) do
        if x2 > min_x and x1 < max_x and x2 > x1 then
          x1 = math.max(x1, min_x)
          x2 = math.min(x2, max_x)
          renderer.draw_rect(
            x1, row_y + row_height - thickness * 2,
            x2 - x1, thickness, style.accent or style.text
          )
        end
      end
    end
  end
end

function M.draw_line(view, line, x, y)
  local cache = view and view.editor_file_poi_cache
  if not cache or cache.revision ~= buffer_revision(view.buffer) then return end
  draw_line_underlines(view, line, x, y, cache.by_line and cache.by_line[line])
end

Buffer.register_text_transaction_handler("editor-file-pois", function(buffer, transaction)
  for view in pairs(TextView.registry[buffer] or {}) do
    if view.editor_file_poi_cache then M.on_text_transaction(view, transaction) end
  end
end)

return M
