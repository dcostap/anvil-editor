-- Pixel coverage of ordered Local Find matches. Build outside the draw path.
local core = require "core"
local style = require "core.style"
local overview = {}
local ffi_ok, ffi = pcall(require, "ffi")
local float = ffi_ok and ffi.new("float[1]")

local function native_float(value)
  if not float or not renderer.draw_rect_lua then return value end
  float[0] = value
  return tonumber(float[0])
end

local function grid(value)
  value = value + .5
  return value < 0 and math.ceil(value) or math.floor(value)
end

local function pixel_range(y, h)
  y, h = native_float(y), native_float(h)
  return grid(y), grid(native_float(y + h))
end

local function geometry(view, state)
  local x, y, w, h = view.v_scrollbar:get_track_rect()
  local metrics = view:get_visual_row_metric_cache()
  return { state.match_set_revision, view.buffer.text_revision,
    math.max(1, view:get_scrollable_size()), x, y, w, h,
    view:get_line_height(), view.__wrap_layout_generation, view.fold_generation,
    view.__visual_metric_generation, metrics,
    style.scrollbar_overview_min_height, metrics and metrics.invalidated_rows }
end

local function same(a, b)
  if not a or not b then return false end
  for i = 1, 14 do if a[i] ~= b[i] then return false end end
  return true
end

local function marker(view, match, key, simple)
  local first, last
  if simple then
    first, last = (match.line - 1) * key[8], match.line * key[8]
  else
    first = view:get_visual_row_y_offset(view:get_visual_row(match.line, match.col1, false))
    last = view:get_visual_row_y_offset(
      view:get_visual_row(match.line, math.max(match.col1, match.col2 - 1), false) + 1)
  end
  local x, y, w, h = view.v_scrollbar:get_overview_marker_rect(first / key[3], last / key[3])
  if not x then return 0, 0 end
  return pixel_range(y, h)
end

-- Start and end pixels both increase through the ordered match set. Two lower
-- bounds give the exact coverage count without visiting each match.
local function covered(matches, view, key, simple, row, endpoint)
  local lo, hi = 1, #matches + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    local first, last = marker(view, matches[mid], key, simple)
    if (endpoint == 1 and first or last) <= row then lo = mid + 1
    else hi = mid end
  end
  return lo - 1
end

function overview.update(view, state)
  if #state.matches == 0 then
    if not state.pending then state.overview, state.overview_pending = nil, nil end
    return
  end
  -- Keep complete coverage while the wrapped row map is still changing.
  if view.__async_wrap_reconstruction then core.redraw = true; return end
  local key = geometry(view, state)
  local cache = state.overview
  -- Track expansion changes only the horizontal paint area, not row coverage.
  if cache then
    cache.key[4], cache.key[6] = key[4], key[6]
  end
  if cache and same(cache.key, key) then return end
  if state.overview_pending and not same(state.overview_pending.key, key) then
    state.overview_pending = nil
  end
  if state.match_index and not key[12] and not view:has_composed_visual_rows() then
    cache = state.overview_pending
    if not cache then cache = { key = key }; state.overview_pending = cache end
    local first, last = pixel_range(key[5], key[7])
    local wrapped = view:has_wrapping()
    local rows = state.match_index:coverage(
      wrapped and view.wrapped_line_to_idx or nil, wrapped and view.wrapped_lines or nil,
      key[3], key[8], key[5], key[7], style.scrollbar_overview_min_height,
      .006, not cache.native_started)
    cache.native_started = true
    if not rows then core.redraw = true; return end
    state.overview = { key = key, rows = rows, first_row = first,
      last_row = last - 1, complete = true, simple = not wrapped }
    state.overview_pending = nil
    return
  end
  cache = state.overview_pending
  if not cache then
    local first, last = pixel_range(key[5], key[7])
    cache = { key = key, rows = {}, first_row = first, next_row = first,
      last_row = last - 1, next_match = 1, edges = {}, coverage = 0,
      wrapped = view:has_wrapping(),
      simple = not view:has_wrapping() and not view:has_composed_visual_rows() and not key[12] }
    cache.matches, cache.by_line = state.matches, state.match_indexes_by_line
    state.overview_pending = cache
  end
  if cache.complete then return end
  local deadline = system.get_time() + .002
  -- Wrapped matches can cover unequal row counts. Their clamped marker starts
  -- need not be ordered near the track end. Accumulate exact range edges.
  if not cache.simple then
    local work = 0
    while cache.next_match <= #cache.matches do
      local match = cache.matches[cache.next_match]
      local count = cache.wrapped and 1 or #cache.by_line[match.line]
      local first, last = marker(view, match, cache.key, false)
      cache.edges[first] = (cache.edges[first] or 0) + count
      cache.edges[last] = (cache.edges[last] or 0) - count
      cache.next_match = cache.next_match + count
      work = work + 1
      if work % 32 == 0 and system.get_time() >= deadline then
        core.redraw = true
        return
      end
    end
  end
  repeat
    local row = cache.next_row
    if row > cache.last_row then
      cache.complete = true
      state.overview, state.overview_pending = cache, nil
      break
    end
    if cache.simple then
      cache.rows[row] = covered(cache.matches, view, cache.key, true, row, 1)
        - covered(cache.matches, view, cache.key, true, row, 2)
    else
      cache.coverage = cache.coverage + (cache.edges[row] or 0)
      cache.rows[row] = cache.coverage
    end
    cache.next_row = row + 1
  until system.get_time() >= deadline
  core.redraw = true
end

function overview.draw(view, state)
  local cache = state.overview
  if not cache or not cache.complete then return end
  local key = cache.key
  local x, _, w, h = view.v_scrollbar:get_track_rect()
  if w <= 0 or h <= 0 then return end
  local selected = state.matches[state.current]
  local first, last = 0, 0
  if selected then first, last = marker(view, selected, key, cache.simple) end
  local color = style.search_overview_secondary
  local alpha = color[4] or 255
  local row = cache.first_row
  while row <= cache.last_row do
    local count = cache.rows[row] - (row >= first and row < last and 1 or 0)
    -- Repeated equal-color blends converge in at most 255 steps on an 8-bit
    -- surface. Preserve translucent themes as well as opaque marker coverage.
    count = math.min(count, alpha == 0 and 0 or alpha == 255 and 1 or 255)
    local ending = row + 1
    while ending <= cache.last_row do
      local next_count = cache.rows[ending] - (ending >= first and ending < last and 1 or 0)
      next_count = math.min(next_count, alpha == 0 and 0 or alpha == 255 and 1 or 255)
      if next_count ~= count then break end
      ending = ending + 1
    end
    for _ = 1, count do renderer.draw_rect(x, row, w, ending - row, color) end
    row = ending
  end
  if selected then renderer.draw_rect(x, first, w, last - first, style.search_overview) end
  view.v_scrollbar:draw_thumb()
end

return overview
