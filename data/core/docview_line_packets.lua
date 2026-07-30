local core = require "core"
local linewrapping = require "core.linewrapping"
local style = require "core.style"
local tokenizer = require "core.tokenizer"

local line_packets = {}

local CONTENT = renderer.display_packet and renderer.display_packet.CONTENT or 0
local FOREGROUND_GUIDES = renderer.display_packet
  and renderer.display_packet.FOREGROUND_GUIDES or 1
local state = core.__docview_line_packet_state
if not state then
  state = {
    contributors = {},
    contributor_generation = 0,
    tracked_views = setmetatable({}, { __mode = "k" }),
    contributor_configs = {},
    logged_missing_api = false,
  }
  core.__docview_line_packet_state = state
end
local contributors = state.contributors
local tracked_views = state.tracked_views

function line_packets.persistent_contributor_config(name, defaults)
  local existing = state.contributor_configs[name]
  if existing then return existing end
  state.contributor_configs[name] = defaults
  return defaults
end
local DEFAULT_MAX_PACKETS = 1024
local DEFAULT_MAX_BYTES = 12 * 1024 * 1024

local function perf_add(name, value)
  local stats = core.perf_frame_stats
  if stats then stats[name] = (stats[name] or 0) + (value or 1) end
end

local function perf_max(name, value)
  local stats = core.perf_frame_stats
  if stats then stats[name] = math.max(stats[name] or 0, value or 0) end
end

local function stats_for(view)
  local cache = view.__line_packet_cache
  if not cache then
    cache = {
      entries = {},
      hits = 0,
      misses = 0,
      builds = 0,
      build_ms = 0,
      replay_ms = 0,
      fallbacks = {},
      resident_packets = 0,
      resident_bytes = 0,
      evictions = 0,
      clock = 0,
      view = view,
    }
    view.__line_packet_cache = cache
    tracked_views[view] = true
  end
  return cache
end

local function fallback(view, reason)
  local cache = stats_for(view)
  cache.fallbacks[reason] = (cache.fallbacks[reason] or 0) + 1
  perf_add("docview_line_packet_fallback_" .. tostring(reason), 1)
  return nil, reason
end

local function discard_entry(cache, line, reason)
  local entry = cache.entries[line]
  if not entry then return end
  cache.entries[line] = nil
  if entry.retained then
    cache.resident_packets = math.max(0, cache.resident_packets - 1)
    cache.resident_bytes = math.max(0, cache.resident_bytes - (entry.bytes or 0))
    entry.retained = false
  end
  if entry.packet then entry.packet:release() end
  entry.packet = nil
  if reason == "eviction" then cache.evictions = cache.evictions + 1 end
  if reason == "eviction" then perf_add("docview_line_packet_evictions", 1) end
end

function line_packets.clear(view)
  local cache = view and view.__line_packet_cache
  if not cache then return end
  local lines = {}
  for line in pairs(cache.entries) do lines[#lines + 1] = line end
  for _, line in ipairs(lines) do discard_entry(cache, line, "clear") end
  local prepared = view.__line_packet_prepared
  if prepared and prepared.entry and not prepared.entry.retained
  and prepared.entry.packet then
    prepared.entry.packet:release()
    prepared.entry.packet = nil
  end
  local last = view.__line_packet_last_content
  if last and last.entry and not last.entry.retained and last.entry.packet then
    last.entry.packet:release()
    last.entry.packet = nil
  end
  if prepared then
    prepared.line, prepared.x, prepared.y, prepared.entry = nil, nil, nil, nil
  end
  view.__line_packet_last_content = nil
  view.__line_packet_finalization_suspended = nil
end

function line_packets.invalidate_range(view, line1, line2)
  local cache = view and view.__line_packet_cache
  if not cache then return end
  line1 = math.max(1, math.floor(line1 or 1))
  line2 = math.max(line1, math.floor(line2 or line1))
  local lines = {}
  for line in pairs(cache.entries) do
    if line >= line1 and line <= line2 then lines[#lines + 1] = line end
  end
  for _, line in ipairs(lines) do discard_entry(cache, line, "invalidation") end
  local prepared = view.__line_packet_prepared
  if prepared and prepared.line
  and prepared.line >= line1 and prepared.line <= line2 then
    prepared.line, prepared.x, prepared.y, prepared.entry = nil, nil, nil, nil
  end
end

function line_packets.invalidate_document(doc, line1, line2)
  for view in pairs(tracked_views) do
    if view.doc == doc then line_packets.invalidate_range(view, line1, line2) end
  end
end

function line_packets.apply_transaction(view, transaction)
  if not (view and transaction and transaction.changed) then return end
  local first_line, last_line, structure_changed
  for _, range in ipairs(transaction.changed_ranges or {}) do
    local old_line1 = range.old_line1 or range.new_line1 or 1
    local old_line2 = range.old_line2 or old_line1
    local new_line1 = range.new_line1 or old_line1
    local new_line2 = range.new_line2 or new_line1
    first_line = math.min(first_line or old_line1, old_line1, new_line1)
    last_line = math.max(last_line or old_line2, old_line2, new_line2)
    local line_delta = range.line_delta
    if line_delta == nil then
      line_delta = new_line2 - new_line1 - old_line2 + old_line1
    end
    structure_changed = structure_changed or line_delta ~= 0
  end
  if not first_line then return end
  if structure_changed then
    line_packets.invalidate_range(view, first_line, math.huge)
  else
    line_packets.invalidate_range(view, first_line, last_line)
    for _, contributor in pairs(contributors) do
      if contributor.invalidate_transaction then
        contributor.invalidate_transaction(
          view, first_line, last_line, transaction
        )
      end
    end
  end
end

local function clear_all_views()
  for view in pairs(tracked_views) do line_packets.clear(view) end
end

function line_packets.register_contributor(name, contributor)
  assert(type(name) == "string" and type(contributor) == "table")
  contributors[name] = contributor
  state.contributor_generation = state.contributor_generation + 1
  clear_all_views()
end

function line_packets.unregister_contributor(name, contributor)
  if contributor and contributors[name] ~= contributor then return end
  if contributors[name] then
    contributors[name] = nil
    state.contributor_generation = state.contributor_generation + 1
    clear_all_views()
  end
end

function line_packets.invalidate_contributor(name)
  if contributors[name] then
    state.contributor_generation = state.contributor_generation + 1
    clear_all_views()
  end
end

local function markdown_live_mode(view)
  local live_render = package.loaded["core.markdown.live_render"]
  return live_render and live_render.is_live_mode
    and live_render.is_live_mode(view)
end

local function standard_docview(view)
  local DocView = package.loaded["core.docview"]
  return type(DocView) ~= "table" or getmetatable(view) == DocView
end

local function eligible(view, line)
  if view.__test_disable_line_packets then return false, "test_disabled" end
  if package.loaded["core.test"] and not view.__test_force_line_packets then
    return false, "test_default_legacy"
  end
  if not (renderer.display_packet and renderer.display_packet.new) then
    if not state.logged_missing_api then
      state.logged_missing_api = true
      core.log_quiet("Document View line packets unavailable: native renderer API missing")
    end
    return false, "native_api_missing"
  end
  if not standard_docview(view) then return false, "nonstandard_docview" end
  if view.has_visual_metric_providers and view:has_visual_metric_providers() then
    return false, "variable_visual_metrics"
  end
  if not (view.doc and view.doc.lines[line]) then return false, "missing_line" end
  if markdown_live_mode(view) then return false, "markdown_live" end
  if view:get_line_render(line) then return false, "custom_render_line" end
  if view:decoration_text_color(line) then return false, "decoration_text_color" end
  return true
end

local function contributor_signature(view, line)
  local frame_id = core.render_frame_active and core.render_frame_id
  local cache
  local view_scoped = frame_id ~= nil
  if view_scoped then
    for _, contributor in pairs(contributors) do
      if contributor.signature_scope ~= "view"
      or contributor.packet_enabled_scope ~= "view" then
        view_scoped = false
        break
      end
    end
    if view_scoped then
      cache = stats_for(view)
      if cache.all_contributor_signature_frame == frame_id then
        return cache.all_contributor_signature, true
      end
    end
  end
  local parts = { tostring(state.contributor_generation) }
  local names = {}
  for name in pairs(contributors) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local contributor = contributors[name]
    local enabled = not contributor.packet_enabled
      or contributor.packet_enabled(view, line)
    parts[#parts + 1] = name
    parts[#parts + 1] = enabled and "1" or "0"
    if enabled and contributor.signature then
      local value
      if contributor.signature_scope == "view" and frame_id then
        local contributor_cache = cache or stats_for(view)
        local signatures = contributor_cache.contributor_frame_signatures
        if not signatures
        or contributor_cache.contributor_signature_frame ~= frame_id then
          signatures = {}
          contributor_cache.contributor_frame_signatures = signatures
          contributor_cache.contributor_signature_frame = frame_id
        end
        value = signatures[name]
        if value == nil then
          value = contributor.signature(view, line)
          signatures[name] = value
        end
      else
        value = contributor.signature(view, line)
      end
      parts[#parts + 1] = tostring(value)
    end
  end
  local signature = table.concat(parts, "\0")
  if view_scoped then
    cache.all_contributor_signature_frame = frame_id
    cache.all_contributor_signature = signature
  end
  return signature, view_scoped
end

local function row_slice(view, line)
  local first_idx, _, count = linewrapping.get_line_idx_col_count(view, line)
  local last_idx = first_idx + count - 1
  local visible_first = math.max(first_idx, view.__wrapped_draw_first_idx or first_idx)
  local visible_last = math.min(last_idx, view.__wrapped_draw_last_idx or last_idx)
  if count <= 128 then return first_idx, last_idx, first_idx, last_idx, count end
  return first_idx, last_idx,
    math.max(first_idx, visible_first - 2), math.min(last_idx, visible_last + 2), count
end

local function append_font_signature(parts, font)
  if type(font) == "table" then
    parts[#parts + 1] = "group:" .. tostring(#font)
    for _, child in ipairs(font) do append_font_signature(parts, child) end
    return
  end
  parts[#parts + 1] = tostring(font)
  parts[#parts + 1] = tostring(font and font:get_size())
  parts[#parts + 1] = tostring(
    font and font.get_generation and font:get_generation() or 0
  )
  parts[#parts + 1] = tostring(
    font and font.get_surface_scale and font:get_surface_scale() or 1
  )
end

local function font_signature(view)
  local frame_id = core.render_frame_active and core.render_frame_id
  local cache = stats_for(view)
  if frame_id and cache.font_signature_frame == frame_id then
    return cache.font_signature
  end
  local parts = {}
  append_font_signature(parts, view:get_font())
  local names = {}
  for name in pairs(style.syntax_fonts) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    parts[#parts + 1] = name
    append_font_signature(parts, style.syntax_fonts[name])
  end
  parts[#parts + 1] = tostring(view:get_line_height())
  parts[#parts + 1] = tostring(view:get_line_text_y_offset())
  local signature = table.concat(parts, "\0")
  if frame_id then
    cache.font_signature_frame = frame_id
    cache.font_signature = signature
  end
  return signature
end

local function wrapped_row_signature(
  view, first_idx, built_first, built_last, count
)
  if count == 1 then return "" end
  local parts = {}
  for row_idx = built_first, built_last do
    local row_line, row_col = linewrapping.get_idx_line_col(view, row_idx)
    parts[#parts + 1] = tostring(row_line)
    parts[#parts + 1] = tostring(row_col)
  end
  parts[#parts + 1] = tostring(built_first - first_idx + 1)
  parts[#parts + 1] = tostring(built_last - first_idx + 1)
  return table.concat(parts, ":")
end

local function packet_base_signature(view, line, screen_x)
  local highlighter = view.doc.highlighter
  local clip = core.clip_rect_stack and core.clip_rect_stack[#core.clip_rect_stack]
  local clip_x = clip and clip[1] or nil
  local clip_width = clip and clip[3] or nil
  local contributor_value, contributors_view_scoped =
    contributor_signature(view, line)
  local frame_id = core.render_frame_active and core.render_frame_id
  local cache = stats_for(view)
  if frame_id and contributors_view_scoped
  and cache.base_signature_frame == frame_id
  and cache.base_signature_screen_x == screen_x
  and cache.base_signature_clip_x == clip_x
  and cache.base_signature_clip_width == clip_width then
    return cache.base_signature
  end
  local signature = table.concat({
    tostring(view.wrapped_settings),
    font_signature(view),
    tostring(core.color_theme_generation or 0),
    tostring(core.render_style_generation or 0),
    tostring(highlighter.packet_reset_generation or 0),
    contributor_value,
    tostring(screen_x),
    tostring(clip_x),
    tostring(clip_width),
  }, "\0")
  if frame_id and contributors_view_scoped then
    cache.base_signature_frame = frame_id
    cache.base_signature_screen_x = screen_x
    cache.base_signature_clip_x = clip_x
    cache.base_signature_clip_width = clip_width
    cache.base_signature = signature
  end
  return signature
end

local function make_key(
  view, line, first_idx, built_first, built_last, count,
  row_signature, base_signature
)
  return {
    text = view.doc.lines[line],
    first_idx = first_idx,
    built_first = built_first,
    built_last = built_last,
    wrapped_row_count = count,
    row_signature = row_signature,
    continuation_offset = view.wrapped_line_offsets
      and view.wrapped_line_offsets[line] or 0,
    base_signature = base_signature,
  }
end

local function key_matches(
  key, view, line, first_idx, built_first, built_last, count,
  row_signature, base_signature
)
  return key
    and key.text == view.doc.lines[line]
    and key.first_idx == first_idx
    and key.built_first == built_first
    and key.built_last == built_last
    and key.wrapped_row_count == count
    and key.row_signature == row_signature
    and key.continuation_offset == (
      view.wrapped_line_offsets and view.wrapped_line_offsets[line] or 0
    )
    and key.base_signature == base_signature
end

local function compile_syntax(
  builder, view, line, tokens, first_idx, built_first, built_last
)
  local default_font = view:get_font()
  local text_y_offset = view:get_line_text_y_offset()
  local begin_width = view.wrapped_line_offsets
    and view.wrapped_line_offsets[line] or 0
  local line_height = view:get_line_height()
  local _, indent_size = view.doc:get_indent_info()
  indent_size = indent_size or 2
  local row_idx = built_first
  local _, row_start_col = linewrapping.get_idx_line_col(view, row_idx)
  local row_next_line, row_end_col = linewrapping.get_idx_line_col(view, row_idx + 1)
  if row_next_line ~= line then row_end_col = #view.doc.lines[line] end
  local tx = row_start_col ~= 1 and begin_width or 0
  local token_start_col = 1

  local function advance_row()
    row_idx = row_idx + 1
    if row_idx > built_last then return false end
    _, row_start_col = linewrapping.get_idx_line_col(view, row_idx)
    row_next_line, row_end_col = linewrapping.get_idx_line_col(view, row_idx + 1)
    if row_next_line ~= line then row_end_col = #view.doc.lines[line] end
    tx = row_start_col ~= 1 and begin_width or 0
    return true
  end

  for _, token_type, text in tokenizer.each_token(tokens) do
    if row_idx > built_last then break end
    local token_end_col = token_start_col + #text
    local color = style.syntax[token_type] or style.syntax.normal
    local font = style.syntax_fonts[token_type] or default_font
    while row_idx <= built_last and token_end_col > row_start_col do
      if token_start_col >= row_end_col then
        if not advance_row() then break end
      else
        local draw_start_col = math.max(token_start_col, row_start_col)
        local draw_end_col = math.min(token_end_col, row_end_col)
        local rendered = text:sub(
          draw_start_col - token_start_col + 1,
          draw_end_col - token_start_col
        )
        if rendered ~= "" then
          tx = builder:add_text(
            CONTENT,
            row_idx - first_idx + 1,
            font,
            rendered,
            tx,
            text_y_offset + (row_idx - first_idx) * line_height,
            color,
            nil,
            indent_size
          )
        end
        if token_end_col >= row_end_col then
          if not advance_row() then break end
        else
          break
        end
      end
    end
    token_start_col = token_end_col
  end
end

local function touch_entry(cache, entry)
  cache.clock = cache.clock + 1
  entry.last_used = cache.clock
  entry.last_used_frame = core.render_frame_id or 0
end

local function enforce_budget(cache, protected)
  local view = cache.view
  local max_packets = math.max(
    1, tonumber(view.__test_line_packet_max_count) or DEFAULT_MAX_PACKETS
  )
  local max_bytes = math.max(
    1, tonumber(view.__test_line_packet_max_bytes) or DEFAULT_MAX_BYTES
  )
  while cache.resident_packets > max_packets
  or cache.resident_bytes > max_bytes do
    local candidate_line, candidate
    for line, entry in pairs(cache.entries) do
      if entry ~= protected
      and (not candidate or (entry.last_used or 0) < (candidate.last_used or 0)) then
        candidate_line, candidate = line, entry
      end
    end
    if not candidate then break end
    discard_entry(cache, candidate_line, "eviction")
  end
end

local function build_entry(view, line, screen_x, screen_y)
  local first_idx, last_idx, built_first, built_last, count = row_slice(view, line)
  if built_last < built_first then return fallback(view, "no_visible_rows") end
  local row_signature = wrapped_row_signature(
    view, first_idx, built_first, built_last, count
  )
  local base_signature = packet_base_signature(view, line, screen_x)
  local cache = stats_for(view)
  local existing = cache.entries[line]
  if existing and key_matches(
    existing.key, view, line, first_idx, built_first, built_last, count,
    row_signature, base_signature
  ) then
    cache.hits = cache.hits + 1
    perf_add("docview_line_packet_hits", 1)
    touch_entry(cache, existing)
    return existing
  end
  local key = make_key(
    view, line, first_idx, built_first, built_last, count,
    row_signature, base_signature
  )
  if existing then
    for key_name, value in pairs(existing.key) do
      if key[key_name] ~= value then
        cache.last_miss_key = key_name
        break
      end
    end
  end
  cache.misses = cache.misses + 1
  perf_add("docview_line_packet_misses", 1)
  if existing then discard_entry(cache, line) end

  local highlighter_line = view.doc.highlighter:get_line(line)
  local tokens = highlighter_line.tokens

  local started = system.get_time()
  local builder = renderer.display_packet.new()
  local context = {
    first_idx = first_idx,
    last_idx = last_idx,
    built_first = built_first,
    built_last = built_last,
    count = count,
    screen_x = screen_x,
    screen_y = screen_y,
    content_layer = CONTENT,
    guides_layer = FOREGROUND_GUIDES,
  }
  local names = {}
  for name in pairs(contributors) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local contributor = contributors[name]
    if (not contributor.packet_enabled or contributor.packet_enabled(view, line))
    and contributor.append_packet then
      contributor.append_packet(builder, view, line, context)
    end
  end
  compile_syntax(builder, view, line, tokens, first_idx, built_first, built_last)
  local packet = builder:seal()
  local entry = {
    key = key,
    packet = packet,
    first_idx = first_idx,
    last_idx = last_idx,
    built_first = built_first,
    built_last = built_last,
    count = count,
    bytes = packet:bytes(),
  }
  touch_entry(cache, entry)
  local max_bytes = math.max(
    1, tonumber(view.__test_line_packet_max_bytes) or DEFAULT_MAX_BYTES
  )
  if entry.bytes <= max_bytes then
    entry.retained = true
    cache.entries[line] = entry
    cache.resident_packets = cache.resident_packets + 1
    cache.resident_bytes = cache.resident_bytes + entry.bytes
    enforce_budget(cache, entry)
  else
    entry.oversized = true
    core.log_quiet(
      "Document View line packet bypasses retention for %s:%d (%d bytes)",
      view.doc:get_name(), line, entry.bytes
    )
  end
  cache.builds = cache.builds + 1
  local build_ms = (system.get_time() - started) * 1000
  cache.build_ms = cache.build_ms + build_ms
  perf_add("docview_line_packet_builds", 1)
  perf_add("docview_line_packet_build_ms", build_ms)
  return entry
end

local function prepare(view, line, x, y)
  local ok, reason = eligible(view, line)
  if not ok then return fallback(view, reason) end
  local prepared = view.__line_packet_prepared
  if prepared and prepared.line == line and prepared.x == x and prepared.y == y
  and prepared.entry and prepared.entry.packet then
    return prepared.entry
  end
  local success, entry_or_error, fallback_reason = pcall(build_entry, view, line, x, y)
  if not success then
    stats_for(view).last_build_error = tostring(entry_or_error)
    core.log_quiet(
      "Document View line packet build failed for %s:%d: %s",
      view.doc:get_name(), line, tostring(entry_or_error)
    )
    return fallback(view, "build_error")
  end
  local entry = entry_or_error
  if not entry then return nil, fallback_reason end
  prepared = prepared or {}
  prepared.line, prepared.x, prepared.y, prepared.entry = line, x, y, entry
  view.__line_packet_prepared = prepared
  return entry
end

function line_packets.draw_legacy_before_text(view, line, x, y)
  local contributor = contributors.whitespace
  if not contributor then return end
  if contributor.packet_enabled and contributor.packet_enabled(view, line)
  and prepare(view, line, x, y) then return end
  if contributor.draw_legacy then contributor.draw_legacy(view, line, x, y) end
end

function line_packets.update_contributors(view)
  for _, contributor in pairs(contributors) do
    if contributor.update then contributor.update(view) end
  end
end

function line_packets.with_suspended_finalization(view, fn)
  view.__line_packet_finalization_suspended =
    (view.__line_packet_finalization_suspended or 0) + 1
  local ok, result = pcall(fn)
  view.__line_packet_finalization_suspended = math.max(
    0, (view.__line_packet_finalization_suspended or 1) - 1
  )
  if not ok then error(result, 0) end
  return result
end

local function store_last_content(view, line, x, y, entry, frame_failed)
  local last = view.__line_packet_last_content
  if not last then
    last = {}
    view.__line_packet_last_content = last
  end
  last.line, last.x, last.y = line, x, y
  last.entry, last.frame_failed = entry, frame_failed or nil
end

function line_packets.draw_content(view, line, x, y)
  local entry = prepare(view, line, x, y)
  if not entry then return nil end
  if view.__line_packet_prepared then
    view.__line_packet_prepared.line = nil
    view.__line_packet_prepared.entry = nil
  end
  local visible_first = math.max(entry.first_idx, view.__wrapped_draw_first_idx or entry.first_idx)
  local visible_last = math.min(entry.last_idx, view.__wrapped_draw_last_idx or entry.last_idx)
  local local_first = visible_first - entry.first_idx + 1
  local local_last = visible_last - entry.first_idx + 1
  local started = system.get_time()
  local ok, reason = entry.packet:draw(x, y, CONTENT, local_first, local_last)
  if not ok and reason == "stale_font" then
    local cache = stats_for(view)
    if entry.retained then
      discard_entry(cache, line, "stale_font")
    elseif entry.packet then
      entry.packet:release()
      entry.packet = nil
    end
    local rebuilt_ok, rebuilt = pcall(build_entry, view, line, x, y)
    if rebuilt_ok and rebuilt then
      entry = rebuilt
      visible_first = math.max(entry.first_idx, view.__wrapped_draw_first_idx or entry.first_idx)
      visible_last = math.min(entry.last_idx, view.__wrapped_draw_last_idx or entry.last_idx)
      local_first = visible_first - entry.first_idx + 1
      local_last = visible_last - entry.first_idx + 1
      ok, reason = entry.packet:draw(x, y, CONTENT, local_first, local_last)
    end
  end
  local replay_ms = (system.get_time() - started) * 1000
  stats_for(view).replay_ms = stats_for(view).replay_ms + replay_ms
  perf_add("docview_line_packet_replay_ms", replay_ms)
  perf_max("docview_line_packet_resident_packets", stats_for(view).resident_packets)
  perf_max("docview_line_packet_resident_bytes", stats_for(view).resident_bytes)
  if not ok then
    if reason == "frame_failed" then
      stats_for(view).frame_failures = (stats_for(view).frame_failures or 0) + 1
      perf_add("docview_line_packet_frame_failures", 1)
      core.redraw = true
      store_last_content(view, line, x, y, entry, true)
      return view:get_line_height() * entry.count
    end
    if not entry.retained and entry.packet then
      entry.packet:release()
      entry.packet = nil
    end
    return fallback(view, "replay_" .. tostring(reason))
  end
  store_last_content(view, line, x, y, entry)
  return view:get_line_height() * entry.count
end

function line_packets.draw_foreground_guides(view, line, x, y, last)
  local reusable = false
  if not last then
    last = view.__line_packet_last_content
    reusable = last ~= nil
  end
  if not last then return false end
  local matches = last.line == line and last.x == x and last.y == y
  local entry, frame_failed = last.entry, last.frame_failed
  if reusable then
    last.line, last.x, last.y = nil, nil, nil
    last.entry, last.frame_failed = nil, nil
  end
  if not matches then return false end
  local function release_ephemeral()
    if entry and not entry.retained and entry.packet then
      entry.packet:release()
      entry.packet = nil
    end
  end
  if frame_failed then
    release_ephemeral()
    return true
  end
  local contributor = contributors.indent_guides
  if not contributor or not contributor.packet_enabled
  or not contributor.packet_enabled(view, line) then
    release_ephemeral()
    return false
  end
  local visible_first = math.max(entry.first_idx, view.__wrapped_draw_first_idx or entry.first_idx)
  local visible_last = math.min(entry.last_idx, view.__wrapped_draw_last_idx or entry.last_idx)
  local ok, reason = entry.packet:draw(
    x, y, FOREGROUND_GUIDES,
    visible_first - entry.first_idx + 1,
    visible_last - entry.first_idx + 1
  )
  release_ephemeral()
  if not ok and reason == "frame_failed" then
    local cache = stats_for(view)
    cache.frame_failures = (cache.frame_failures or 0) + 1
    perf_add("docview_line_packet_frame_failures", 1)
    core.redraw = true
    return true
  end
  return ok == true
end

function line_packets.finish_line_body(view, line, x, y, height)
  if (view.__line_packet_finalization_suspended or 0) > 0 then
    local contributor = contributors.indent_guides
    if contributor and contributor.draw_legacy then
      contributor.draw_legacy(view, line, x, y)
    end
    return height
  end
  if not line_packets.draw_foreground_guides(view, line, x, y) then
    local contributor = contributors.indent_guides
    if contributor and contributor.draw_legacy then
      contributor.draw_legacy(view, line, x, y)
    end
  end
  return height
end

function line_packets.diagnostics(view)
  local cache = stats_for(view)
  return {
    hits = cache.hits,
    misses = cache.misses,
    builds = cache.builds,
    build_ms = cache.build_ms,
    replay_ms = cache.replay_ms,
    resident_packets = cache.resident_packets,
    resident_bytes = cache.resident_bytes,
    evictions = cache.evictions,
    frame_failures = cache.frame_failures or 0,
    fallbacks = cache.fallbacks,
    last_build_error = cache.last_build_error,
    last_miss_key = cache.last_miss_key,
  }
end

function line_packets.inspect_line(view, line)
  local cache = view.__line_packet_cache
  local entry = cache and cache.entries[line]
  return entry and entry.packet and entry.packet:inspect() or nil
end

return line_packets
