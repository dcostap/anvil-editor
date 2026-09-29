local core = require "core"
local Buffer = require "core.buffer"
local common = require "core.common"
local style = require "core.style"
local text_poi_locations = require "core.text_poi_locations"
local TextView = require "core.textview"
local worker_pool = require "core.worker_pool"

local M = {}

local MAX_CANDIDATES = 32768
local ACTION_REVALIDATION_INTERVAL = 1
local INLINE_SCAN_LINES = 128
local INLINE_SCAN_BYTES = 32768
local SCAN_SLICE_SECONDS = 0.002

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

local function can_scan_inline(buffer, first)
  local lines = buffer.lines or {}
  if #lines - first + 1 > INLINE_SCAN_LINES then return false end
  local bytes = 0
  for i = first, #lines do
    bytes = bytes + #lines[i]
    if bytes > INLINE_SCAN_BYTES then return false end
  end
  return true
end

local function can_refresh_inline(buffer, ranges)
  local lines, count, bytes = buffer.lines or {}, 0, 0
  for _, range in ipairs(ranges) do
    local first = range.new_line1 or range.old_line1 or 1
    local last = range.new_line2 or first
    count = count + last - first + 1
    if count > INLINE_SCAN_LINES then return false end
    for line = first, last do
      bytes = bytes + #(lines[line] or "")
      if bytes > INLINE_SCAN_BYTES then return false end
    end
  end
  return true
end

local function is_append(old_lines, new_lines)
  if not old_lines or #new_lines <= #old_lines then return false end
  for i = 1, #old_lines do
    if old_lines[i] ~= new_lines[i] then return false end
  end
  return true
end

local function cancel_scan(cache)
  if not cache or not cache.worker_handle then return end
  local pool = worker_pool.current_system()
  if pool then pool:cancel(cache.worker_handle) end
  cache.worker_handle = nil
end

local function scan_async(view, cache, first)
  local buffer = view.buffer
  core.add_thread(function()
    local candidates, points, by_line = {}, {}, {}
    local slice_start = system.get_time()
    local function yield_if_needed()
      if system.get_time() - slice_start >= SCAN_SLICE_SECONDS then
        coroutine.yield(0)
        slice_start = system.get_time()
      end
    end
    local function current()
      return not view.textview_closed and view.editor_file_poi_cache == cache
        and buffer_revision(buffer) == cache.revision
    end
    if not current() then return end
    if first > 1 then
      for _, candidate in ipairs(cache.candidates) do
        candidates[#candidates + 1] = candidate
        yield_if_needed()
      end
      for _, point in ipairs(cache.points) do
        points[#points + 1] = point
        yield_if_needed()
      end
      for line, entries in pairs(cache.by_line) do
        by_line[line] = entries
        yield_if_needed()
      end
    end
    local scanned, line = 0, first
    local pool = worker_pool.system()
    while line <= #buffer.lines do
      if not current() then return end
      if #candidates >= MAX_CANDIDATES then break end
      local lines, bytes, chunk_first = {}, 0, line
      repeat
        local text = buffer.lines[line]
        lines[#lines + 1] = text
        bytes = bytes + #text
        line = line + 1
        yield_if_needed()
      until line > #buffer.lines or #lines >= INLINE_SCAN_LINES or bytes >= INLINE_SCAN_BYTES
      if not current() then return end
      local chunks, chunk_index, done, failure = {}, 1, false, nil
      local handle, err = pool:submit {
        kind = "core.workers.file_locations",
        priority = "background",
        payload = { lines = lines, first = chunk_first, limit = MAX_CANDIDATES - #candidates },
        is_stale = function() return not current() end,
        on_result = function(message) chunks[#chunks + 1] = message.payload end,
        on_complete = function() done = true end,
        on_error = function(message) failure, done = message.error, true end,
        on_cancelled = function() done = true end,
      }
      if not handle then failure, done = err, true end
      cache.worker_handle = handle
      while not done or chunk_index <= #chunks do
        if not current() then cancel_scan(cache) return end
        local found = chunks[chunk_index]
        if found then
          chunks[chunk_index] = false
          chunk_index = chunk_index + 1
          for _, candidate in ipairs(found) do
            candidates[#candidates + 1] = candidate
            for _, point in ipairs(resolve_candidates({ candidate }, cache.roots)) do
              points[#points + 1] = point
              local entries = by_line[point.line]
              if not entries or entries == cache.by_line[point.line] then
                local copy = {}
                for _, entry in ipairs(entries or {}) do copy[#copy + 1] = entry end
                entries = copy
                by_line[point.line] = entries
              end
              entries[#entries + 1] = point
            end
            yield_if_needed()
          end
        else
          coroutine.yield(0.01)
          slice_start = system.get_time()
        end
      end
      cache.worker_handle = nil
      if failure then
        cache.pending = nil
        core.log_quiet("Editor file-location worker failed: path=%s error=%s",
          buffer:get_name(), tostring(failure))
        return
      end
      scanned = scanned + #lines
    end
    if not current() then return end
    cache.candidates, cache.points, cache.by_line = candidates, points, by_line
    cache.validated_at = system.get_time()
    cache.pending = nil
    core.redraw = true
    core.log_quiet("Editor file locations scanned: path=%s lines=%d points=%d",
      buffer:get_name(), scanned, #points)
  end)
end

local function revalidate_async(view, cache)
  if cache.revalidating then return end
  cache.revalidating = true
  local buffer = view.buffer
  core.add_thread(function()
    local points, by_line = {}, {}
    local slice_start = system.get_time()
    for _, candidate in ipairs(cache.candidates) do
      if view.textview_closed or view.editor_file_poi_cache ~= cache
          or buffer_revision(buffer) ~= cache.revision then return end
      for _, point in ipairs(resolve_candidates({ candidate }, cache.roots)) do
        points[#points + 1] = point
        local entries = by_line[point.line] or {}
        by_line[point.line] = entries
        entries[#entries + 1] = point
      end
      if system.get_time() - slice_start >= SCAN_SLICE_SECONDS then
        coroutine.yield(0)
        slice_start = system.get_time()
      end
    end
    if view.textview_closed or view.editor_file_poi_cache ~= cache
        or buffer_revision(buffer) ~= cache.revision then return end
    cache.points, cache.by_line = points, by_line
    cache.validated_at = system.get_time()
    cache.revalidating = nil
    core.redraw = true
  end)
end

local function new_cache(view, revision, source, project, previous, append)
  local buffer = view.buffer
  cancel_scan(view.editor_file_poi_cache)
  local first = append and #previous.lines + 1 or 1
  local cache = {
    revision = revision,
    source_path = source,
    project_path = project,
    roots = roots_for_paths(source, project),
    candidates = append and previous.candidates or {},
    points = append and previous.points or {},
    by_line = append and previous.by_line or {},
    lines = buffer.lines,
    validated_at = 0,
  }
  view.editor_file_poi_cache = cache
  if can_scan_inline(buffer, first) then
    if append then
      for line = first, #buffer.lines do
        if #cache.candidates >= MAX_CANDIDATES then break end
        local found = text_poi_locations.extract_line_candidates(
          buffer.lines[line], line, MAX_CANDIDATES - #cache.candidates
        )
        for _, candidate in ipairs(found) do cache.candidates[#cache.candidates + 1] = candidate end
        for _, point in ipairs(resolve_candidates(found, cache.roots)) do
          cache.points[#cache.points + 1] = point
          cache.by_line[line] = cache.by_line[line] or {}
          cache.by_line[line][#cache.by_line[line] + 1] = point
        end
      end
      cache.validated_at = system.get_time()
    else
      cache.candidates = scan_buffer(buffer)
      resolve_cache(cache)
    end
  else
    cache.pending = true
    scan_async(view, cache, first)
  end
  return cache
end

function M.close(view)
  cancel_scan(view.editor_file_poi_cache)
  view.editor_file_poi_cache = nil
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

local function entry_before(left, right)
  return left.line ~= right.line and left.line < right.line
    or left.line == right.line and left.col < right.col
end

-- Rebased entries keep their order, so merging in the rescanned lines keeps
-- a large list sorted without sorting it again.
local function merge_entries(sorted, fresh)
  if #fresh == 0 then return sorted end
  sort_entries(fresh)
  local merged, i, j = {}, 1, 1
  while i <= #sorted or j <= #fresh do
    local current, incoming = sorted[i], fresh[j]
    if incoming and (not current or entry_before(incoming, current)) then
      merged[#merged + 1] = incoming
      j = j + 1
    else
      merged[#merged + 1] = current
      i = i + 1
    end
  end
  return merged
end

-- Unchanged lines keep their relative order, so the result stays sorted.
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
  return rebased
end

local function refresh_changed_lines(view, cache, transaction)
  local started = core.perf_frame_stats and system.get_time()
  local ranges = ordered_ranges(transaction)
  if #ranges == 0 then return false end
  local candidates = rebase_entries(cache.candidates, ranges)
  local points = rebase_entries(cache.points, ranges)
  local fresh_candidates, fresh_points = {}, {}
  local scanned = 0
  for _, range in ipairs(ranges) do
    local line1 = range.new_line1 or range.old_line1 or 1
    local line2 = range.new_line2 or line1
    for line = line1, line2 do
      local found = text_poi_locations.extract_line_candidates(
        view.buffer.lines[line], line,
        MAX_CANDIDATES - #candidates - #fresh_candidates
      )
      for _, candidate in ipairs(found) do fresh_candidates[#fresh_candidates + 1] = candidate end
      for _, point in ipairs(resolve_candidates(found, cache.roots)) do
        fresh_points[#fresh_points + 1] = point
      end
      scanned = scanned + 1
    end
  end
  cache.candidates = merge_entries(candidates, fresh_candidates)
  cache.points = merge_entries(points, fresh_points)
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
  if cache.source_path ~= source or cache.project_path ~= project then
    view.editor_file_poi_cache = nil
    return false
  end
  if transaction.full_snapshot and transaction.content_changed == false then
    cache.revision = buffer_revision(view.buffer)
    cache.lines = view.buffer.lines
    return true
  end
  if transaction.full_snapshot or cache.pending then
    local append = is_append(cache.lines, view.buffer.lines)
    if append and cache.pending then
      cache.revision = buffer_revision(view.buffer)
      cache.lines = view.buffer.lines
      return true
    end
    new_cache(view, buffer_revision(view.buffer), source, project, cache, append)
    return true
  end
  local ranges = transaction.changed_ranges or {}
  if not can_refresh_inline(view.buffer, ranges) then
    new_cache(view, buffer_revision(view.buffer), source, project)
    return true
  end
  if not refresh_changed_lines(view, cache, transaction) then
    view.editor_file_poi_cache = nil
    return false
  end
  cache.lines = view.buffer.lines
  return true
end

local function points_for_view(view, opts)
  local buffer = view and view.buffer
  if not buffer or buffer.binary then return {} end

  local cache = cache_for(view)
  opts = opts or {}
  local now = system.get_time()
  if not cache.pending and (opts.force_revalidate == true
      or not cache.points
      or now - cache.validated_at >= ACTION_REVALIDATION_INTERVAL) then
    if #cache.candidates > INLINE_SCAN_LINES then
      revalidate_async(view, cache)
    else
      resolve_cache(cache)
    end
  end
  return cache.points
end

function M.update(view)
  local started = core.perf_frame_stats and system.get_time()
  local buffer = view and view.buffer
  if not buffer or buffer.binary then return end
  local cache = cache_for(view)
  if not cache.points and not cache.pending then resolve_cache(cache) end
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
