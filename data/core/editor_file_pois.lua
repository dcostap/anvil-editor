local core = require "core"
local common = require "core.common"
local file_context = require "core.file_context"
local style = require "core.style"
local text_poi_locations = require "core.text_poi_locations"

local M = {}

local MAX_CANDIDATES = 32768
local VALIDATION_INTERVAL = 1

local function normalize_root(path)
  if type(path) ~= "string" or path == "" then return nil end
  local ok, normalized = pcall(common.normalize_path, path)
  return ok and normalized or nil
end

local function project_root()
  local project = core.root_project and core.root_project()
  return normalize_root(project and project.path)
end

local function roots_for_view(view)
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
  add(file_context.source_directory(view))
  add(project_root())
  if #roots == 0 then add(system.getcwd()) end
  return roots
end

local function roots_key(roots)
  return table.concat(roots, "\0")
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

local function cache_for(view, roots)
  local buffer = view and view.buffer
  local revision = buffer_revision(buffer)
  local key = tostring(revision) .. "\0" .. roots_key(roots)
  local cache = view.editor_file_poi_cache
  if cache and cache.key == key then return cache end

  local text = table.concat(buffer.lines or {})
  cache = {
    key = key,
    revision = revision,
    roots = roots,
    candidates = text_poi_locations.extract_candidates(text, MAX_CANDIDATES),
    points = nil,
    validated_at = 0,
  }
  view.editor_file_poi_cache = cache
  return cache
end

local function points_for_view(view, opts)
  local buffer = view and view.buffer
  if not buffer or buffer.binary then return {} end

  local roots = roots_for_view(view)
  local cache = cache_for(view, roots)
  opts = opts or {}
  local now = system.get_time()
  if opts.force_revalidate == true
      or not cache.points
      or now - cache.validated_at >= VALIDATION_INTERVAL then
    cache.points = resolve_candidates(cache.candidates, cache.roots)
    cache.validated_at = now
  end
  return cache.points
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
  local thickness = math.max(1, math.floor(SCALE))
  local min_x = view.position.x
  local max_x = view.position.x + view.size.x
  for _, point in ipairs(points or {}) do
    if point.kind == "editor-file-location"
        and point.text_bounds
        and point.line == line
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
  draw_line_underlines(view, line, x, y, points_for_view(view, { silent = true }))
end

return M
