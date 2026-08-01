local core = require "core"

local perf = {}

local recording = false
local record = nil
local renderer_originals = {}
local system_originals = {}
local sample_interval = 10000
local draw_scope_frame = nil
local pending_draw_scope_frame = nil

local function csv_escape(value)
  value = tostring(value or "")
  if value:find('[,"\n\r]') then
    value = '"' .. value:gsub('"', '""') .. '"'
  end
  return value
end

local function output_dir()
  local dir = os.getenv("ANVIL_PERF_OUTPUT_DIR")
  if dir and dir ~= "" then return dir end
  return os.getenv("TEMP") or os.getenv("TMP") or "."
end

local function timestamp_name()
  local t = os.date("*t")
  return string.format(
    "anvil_perf_%04d%02d%02d_%02d%02d%02d",
    t.year, t.month, t.day, t.hour, t.min, t.sec
  )
end

local function source_key(info)
  if not info then return "unknown" end
  local src = info.short_src or info.source or "unknown"
  local line = info.currentline or 0
  return string.format("%s:%d", src, line)
end

local function add_count(tbl, key, amount)
  tbl[key] = (tbl[key] or 0) + (amount or 1)
end

local function pack(...)
  return { n = select("#", ...), ... }
end

function perf.add_detail(key, amount)
  if not recording or not record or not key then return end
  add_count(record.detail_counts, key, amount or 1)
end

function perf.frame_add(key, amount)
  local stats = core.perf_frame_stats
  if not stats or not key then return end
  stats[key] = (stats[key] or 0) + (amount or 1)
  perf.add_detail(key, amount or 1)
end

local function finish_scope_token(token, now)
  local frame = draw_scope_frame
  if not frame or not token or token.finished then return end
  token.finished = true
  local elapsed_ms = math.max(0, (now - token.started) * 1000)
  local exclusive_ms = math.max(0, elapsed_ms - token.child_ms)
  local heap_delta_kb = token.lua_heap_start_kb
    and (collectgarbage("count") - token.lua_heap_start_kb) or 0
  local row = frame.paths[token.path]
  if not row then
    row = {
      path = token.path, calls = 0, inclusive_ms = 0, exclusive_ms = 0,
      lua_heap_delta_kb = 0, lua_heap_drop_calls = 0,
    }
    frame.paths[token.path] = row
  end
  row.calls = row.calls + 1
  row.inclusive_ms = row.inclusive_ms + elapsed_ms
  row.exclusive_ms = row.exclusive_ms + exclusive_ms
  row.lua_heap_delta_kb = row.lua_heap_delta_kb + heap_delta_kb
  if token.lua_heap_start_kb and heap_delta_kb < 0 then
    row.lua_heap_drop_calls = row.lua_heap_drop_calls + 1
  end
  if token.parent then token.parent.child_ms = token.parent.child_ms + elapsed_ms end
end

---Start hierarchical draw-scope collection for one redraw frame.
function perf.begin_draw_frame()
  if not recording then
    core.perf_draw_scope_active = false
    return
  end
  core.perf_draw_scope_active = true
  draw_scope_frame = {
    started = system.get_time(),
    stack = {},
    paths = {},
    imbalance = 0,
    lua_heap_start_kb = collectgarbage("count"),
  }
end

---Begin one named draw scope. Scopes must be ended in stack order.
---@param name string
---@param capture_heap? boolean
---@return table? token
function perf.scope_begin(name, capture_heap)
  local frame = draw_scope_frame
  if not frame then return nil end
  local stack = frame.stack
  local parent = stack[#stack]
  local clean_name = tostring(name or "unnamed"):gsub("[/\r\n]", "_")
  local lua_heap_start_kb = capture_heap and collectgarbage("count") or nil
  local token = {
    path = parent and (parent.path .. "/" .. clean_name) or clean_name,
    parent = parent,
    started = system.get_time(),
    child_ms = 0,
    lua_heap_start_kb = lua_heap_start_kb,
  }
  stack[#stack + 1] = token
  return token
end

---End a draw scope returned by scope_begin().
---@param token table?
function perf.scope_end(token)
  local frame = draw_scope_frame
  if not frame or not token or token.finished then return end
  local stack = frame.stack
  local now = system.get_time()
  if stack[#stack] ~= token then
    frame.imbalance = frame.imbalance + 1
    local found
    for i = #stack, 1, -1 do
      if stack[i] == token then found = i break end
    end
    if not found then return end
    for i = #stack, found, -1 do
      local open = table.remove(stack)
      finish_scope_token(open, now)
    end
    return
  end
  table.remove(stack)
  finish_scope_token(token, now)
end

---Add an already-timed leaf child to an open scope without allocating one
---scope token per hot-loop operation.
---@param parent table?
---@param name string
---@param elapsed_ms number
---@param calls? integer
function perf.scope_add_child(parent, name, elapsed_ms, calls)
  local frame = draw_scope_frame
  calls = calls or 1
  elapsed_ms = math.max(0, tonumber(elapsed_ms) or 0)
  if not frame or not parent or parent.finished or calls <= 0 then return end
  local clean_name = tostring(name or "unnamed"):gsub("[/\r\n]", "_")
  local path = parent.path .. "/" .. clean_name
  local row = frame.paths[path]
  if not row then
    row = {
      path = path, calls = 0, inclusive_ms = 0, exclusive_ms = 0,
      lua_heap_delta_kb = 0, lua_heap_drop_calls = 0,
    }
    frame.paths[path] = row
  end
  row.calls = row.calls + calls
  row.inclusive_ms = row.inclusive_ms + elapsed_ms
  row.exclusive_ms = row.exclusive_ms + elapsed_ms
  parent.child_ms = parent.child_ms + elapsed_ms
end

---Finish collection for the current redraw. perf.on_frame() publishes it.
function perf.finish_draw_frame()
  local frame = draw_scope_frame
  if not frame then
    core.perf_draw_scope_active = false
    return
  end
  local now = system.get_time()
  while #frame.stack > 0 do
    frame.imbalance = frame.imbalance + 1
    finish_scope_token(table.remove(frame.stack), now)
  end
  if frame.imbalance > 0 then
    core.log_quiet(
      "Performance draw scopes: auto-closed an imbalanced scope stack (%d)",
      frame.imbalance
    )
  end
  frame.elapsed_ms = math.max(0, (now - frame.started) * 1000)
  frame.lua_heap_end_kb = collectgarbage("count")
  frame.lua_heap_delta_kb = frame.lua_heap_end_kb - frame.lua_heap_start_kb
  pending_draw_scope_frame = frame
  draw_scope_frame = nil
  core.perf_draw_scope_active = false
end

function perf.record_linewrap_compute(row)
  if not recording or not record or not row then return end
  local rows = record.linewrap_compute_rows
  rows[#rows + 1] = {
    elapsed_ms = row.elapsed_ms or 0,
    line = row.line or 0,
    bytes = row.bytes or 0,
    visible_bytes = row.visible_bytes or 0,
    splits = row.splits or 0,
    width = row.width or 0,
    mode = row.mode or "",
    tokenized = row.tokenized and true or false,
    ascii = row.ascii and true or false,
    has_space = row.has_space and true or false,
    has_tab = row.has_tab and true or false,
    has_non_ascii = row.has_non_ascii and true or false,
    branch = row.branch or "",
  }
  table.sort(rows, function(a, b) return a.elapsed_ms > b.elapsed_ms end)
  while #rows > 30 do table.remove(rows) end
end

local function record_slowest_row(rows, row, limit)
  rows[#rows + 1] = row
  table.sort(rows, function(a, b) return (a.elapsed_ms or 0) > (b.elapsed_ms or 0) end)
  while #rows > (limit or 30) do table.remove(rows) end
end

function perf.record_markdown_model_publication(row)
  if not recording or not record or not row then return end
  record_slowest_row(record.markdown_model_publication_rows, row)
end

function perf.record_markdown_view_publication(row)
  if not recording or not record or not row then return end
  record_slowest_row(record.markdown_view_publication_rows, row)
end

local function hook()
  if not record then return end
  local level = 2
  while level < 16 do
    local info = debug.getinfo(level, "Sl")
    if not info then return end
    local src = info.short_src or info.source or ""
    if not src:find("core[/\\]perf%.lua") then
      add_count(record.lua_samples, source_key(info), 1)
      record.sample_count = record.sample_count + 1
      return
    end
    level = level + 1
  end
end

local function wrap_renderer_api(name)
  if renderer_originals[name] or type(renderer[name]) ~= "function" then return end
  local original = renderer[name]
  renderer_originals[name] = original
  renderer[name] = function(...)
    if record then
      local info = debug.getinfo(2, "Sl")
      local key = "renderer." .. name .. "," .. source_key(info)
      add_count(record.api_calls, key, 1)
    end
    return original(...)
  end
end

local function unwrap_renderer_api()
  for name, fn in pairs(renderer_originals) do
    renderer[name] = fn
  end
  renderer_originals = {}
end

local function wrap_system_api(name)
  if system_originals[name] or type(system[name]) ~= "function" then return end
  local original = system[name]
  system_originals[name] = original
  system[name] = function(...)
    if not record then return original(...) end
    local info = debug.getinfo(2, "Sl")
    local source = source_key(info)
    local key = "system." .. name .. "," .. source
    add_count(record.api_calls, key, 1)
    local start = system_originals.get_time and system_originals.get_time() or system.get_time()
    local result = pack(original(...))
    local elapsed = ((system_originals.get_time and system_originals.get_time() or system.get_time()) - start) * 1000
    add_count(record.detail_counts, "system." .. name .. "_ms," .. source, elapsed)
    return table.unpack(result, 1, result.n)
  end
end

local function unwrap_system_api()
  for name, fn in pairs(system_originals) do
    system[name] = fn
  end
  system_originals = {}
end

local diagnostic_frame_keys = {
  "worker_pool_drain_wall_ms",
  "worker_pool_drain_ms",
  "worker_pool_drain_messages",
  "worker_pool_dispatch_ms",
  "worker_pool_callback_ms",
  "worker_pool_callbacks",
  "worker_pool_slowest_dispatch_ms",
  "worker_pool_slowest_message_type",
  "worker_pool_slowest_callback_ms",
  "worker_pool_slowest_callback_name",
  "treesitter_project_metadata_cache_hits",
  "treesitter_project_metadata_cache_misses",
  "docview_update_ms",
  "docview_update_cache_ms",
  "docview_update_selection_ms",
  "docview_scroll_to_make_visible_ms",
  "docview_update_blink_ms",
  "docview_update_active_focus_ms",
  "docview_update_ime_ms",
  "docview_update_super_ms",
  "docview_visual_metric_cache_calls",
  "docview_visual_metric_cache_hits",
  "docview_visual_metric_cache_lookup_ms",
  "docview_visual_metric_signature_ms",
  "docview_visual_metric_signature_cache_hits",
  "docview_visual_metric_signature_computations",
  "docview_visual_metric_signature_changes",
  "docview_visual_metric_full_rebuilds",
  "docview_visual_metric_full_rebuild_rows",
  "docview_visual_metric_full_rebuild_ms",
  "docview_visual_metric_dirty_passes",
  "docview_visual_metric_dirty_rows",
  "docview_visual_metric_row_splices",
  "docview_visual_metric_row_splice_rows",
  "docview_line_render_cache_calls",
  "docview_line_render_cache_hits",
  "docview_line_render_cache_misses",
  "docview_line_render_cold_misses",
  "docview_line_render_signature_misses",
  "docview_line_render_cache_lookup_ms",
  "docview_line_render_build_ms",
  "docview_fragment_normalization_calls",
  "docview_fragment_normalization_cache_hits",
  "docview_fragment_normalization_builds",
  "markdown_live_provider_generation_requests",
  "markdown_live_provider_generation_cache_hits",
  "markdown_live_provider_generation_calls",
  "markdown_live_provider_generation_host_calls",
  "markdown_live_provider_generation_centered_calls",
  "markdown_live_semantic_publications",
  "markdown_live_semantic_publication_ranges",
  "markdown_live_semantic_publication_lines",
  "markdown_live_semantic_global_invalidations",
  "markdown_model_publication_ms",
  "markdown_model_publication_summary_ms",
  "markdown_model_publication_previous_close_ms",
  "markdown_model_publication_state_ms",
  "markdown_model_publication_notify_ms",
  "markdown_model_publication_listener_calls",
  "markdown_live_publication_listener_ms",
  "markdown_live_publication_reset_ms",
  "markdown_live_publication_fence_reconcile_ms",
  "markdown_live_publication_range_expand_ms",
  "markdown_live_publication_prune_images_ms",
  "markdown_live_publication_line_invalidate_ms",
  "markdown_live_publication_metric_invalidate_ms",
  "markdown_live_link_index_invalidations",
  "markdown_live_image_fragment_calls",
  "markdown_image_get_asset_calls",
  "markdown_image_asset_key_calls",
  "markdown_image_asset_request_key_cache_hits",
  "markdown_image_asset_cache_hits",
  "markdown_image_asset_cache_misses",
  "markdown_image_asset_retry_checks",
  "markdown_image_asset_refreshes",
  "markdown_image_resolve_local_path_calls",
  "markdown_image_resolve_local_path_skips",
  "markdown_image_resolve_local_path_misses",
  "markdown_image_resolve_absolute_hits",
  "markdown_image_resolve_source_hits",
  "markdown_image_resolve_project_hits",
  "markdown_image_resolve_attachment_hits",
  "markdown_image_file_exists_calls",
  "centered_editor_should_center_calls",
  "centered_editor_should_center_true",
  "centered_editor_should_center_disabled",
  "centered_editor_should_center_non_editor",
  "centered_editor_should_center_not_pane",
  "centered_editor_should_center_no_width",
  "centered_editor_should_center_too_narrow",
  "centered_editor_node_lookup_calls",
  "centered_editor_node_lookup_cache_hits",
  "centered_editor_node_lookup_ms",
  "centered_editor_with_geometry_calls",
  "centered_editor_with_geometry_entries",
  "centered_editor_with_geometry_nested_bypasses",
  "centered_editor_with_geometry_inactive_bypasses",
  "ime_set_location_calls",
  "ime_set_location_ms",
  "ime_set_location_changed",
  "ime_set_location_system_ms",
  "linewrapping_update_docview_breaks_calls",
  "linewrapping_update_docview_breaks_ms",
  "linewrapping_update_docview_breaks_width_changed",
  "linewrapping_update_docview_breaks_text_changed",
  "linewrapping_update_docview_breaks_line_count_changed",
  "linewrapping_reconstruct_line_render_invalidation_calls",
  "linewrapping_reconstruct_breaks_calls",
  "linewrapping_reconstruct_breaks_ms",
  "linewrapping_reconstruct_breaks_lines",
  "linewrapping_async_reconstruct_calls",
  "linewrapping_async_reconstruct_lines",
  "linewrapping_async_reconstruct_ms",
  "linewrapping_async_reconstruct_yields",
  "linewrapping_async_reconstruct_commits",
  "linewrapping_async_reconstruct_cancelled",
  "linewrapping_async_reconstruct_restarts",
  "linewrapping_update_breaks_calls",
  "linewrapping_update_breaks_ms",
  "linewrapping_update_breaks_lines",
  "linewrapping_compute_line_breaks_calls",
  "linewrapping_compute_line_breaks_ms",
  "linewrapping_compute_line_breaks_bytes",
  "linewrapping_compute_line_breaks_splits",
  "linewrapping_draw_line_text_calls",
  "linewrapping_draw_line_text_ms",
  "linewrapping_draw_line_text_rows",
  "linewrapping_draw_line_text_segments",
  "linewrapping_draw_line_text_bytes",
  "linewrapping_draw_line_text_known_bounds_segments",
  "docview_line_packet_hits",
  "docview_line_packet_misses",
  "docview_line_packet_builds",
  "docview_line_packet_build_ms",
  "docview_line_packet_replay_ms",
  "docview_line_packet_evictions",
  "docview_line_packet_resident_packets",
  "docview_line_packet_resident_bytes",
  "docview_line_packet_frame_failures",
  "core_root_panel_update_ms",
  "core_tool_window_update_ms",
  "rootpanel_update_ms",
  "rootpanel_copy_position_ms",
  "rootpanel_initial_layout_ms",
  "rootpanel_node_update_ms",
  "rootpanel_final_layout_ms",
  "rootpanel_drag_overlay_ms",
  "rootpanel_defer_open_docs_ms",
  "node_update_layout_calls",
  "node_update_layout_leaf_calls",
  "node_update_layout_split_calls",
  "node_update_layout_ms",
  "node_update_calls",
  "node_update_leaf_calls",
  "node_update_split_calls",
  "node_update_ms",
  "node_scroll_tabs_to_visible_ms",
  "node_active_view_update_ms",
  "node_tab_hover_update_ms",
  "node_tab_animation_ms",
}

local function write_frame_header(file)
  file:write(table.concat({
    "time", "did_redraw", "fps", "target_fps", "active_present_paced",
    "pending_events", "queue_depth", "run_mode", "window_has_focus", "active_view_is_docview", "active_view_name",
    "selection_count", "search_selection_count", "docview_caret_draw_calls", "docview_selection_rect_calls",
    "event_count", "event_ms", "event_types", "slowest_event_type", "slowest_event_ms", "update_ms", "pre_draw_ms",
    "frame_ms", "draw_emit_ms", "renderer_end_ms",
    "present_ms", "run_threads_ms", "run_threads_runs", "run_threads_slowest_ms", "run_threads_slowest_loc", "core_step_ms", "gc_ms", "sleep_requested_ms", "sleep_actual_ms", "total_ms",
    "draw_calls", "quad_instances", "texture_uploads", "texture_upload_bytes", "d3d11_glyph_push_ms", "d3d11_flush_quads_ms", "d3d11_dwm_flush_ms", "d3d11_clear_state_ms",
    "rencache_text_commands", "rencache_text_bytes", "rencache_max_text_bytes", "rencache_draw_text_ms", "rencache_draw_text_width_ms",
    "display_packet_replays", "display_packet_commands_replayed", "display_packet_text_commands_replayed", "display_packet_rect_commands_replayed", "display_packet_source_bytes", "display_packet_frame_bytes_copied", "display_packet_replay_ms", "display_packet_frame_allocation_failures", "rencache_frame_failed",
    "text_width_calls", "text_width_bytes", "text_width_chars", "text_width_shaped_runs", "text_width_unshaped_runs", "text_width_shape_probe_bytes", "text_width_hb_shapes", "text_width_shaped_cache_hits", "text_width_shaped_cache_misses", "text_width_hb_shape_ms",
    "text_render_calls", "text_render_bytes", "text_render_chars", "text_render_shaped_runs", "text_render_unshaped_runs", "text_render_shape_probe_bytes", "text_render_hb_shapes", "text_render_shaped_cache_hits", "text_render_shaped_cache_misses", "text_render_glyphs", "text_render_whitespace_chars", "text_render_chars_after_clip", "text_render_top_clip_breaks", "text_render_hb_shape_ms",
    "docview_draw_ms", "docview_prepare_ms", "docview_prepare_highlight_ms", "docview_prepare_caret_ms", "docview_prepare_selection_ms", "docview_prepare_merge_ms", "docview_gutter_ms", "docview_body_ms", "docview_text_ms", "docview_overlay_ms",
    "docview_highlighter_get_line_ms", "docview_token_loop_ms", "docview_renderer_draw_text_ms",
    "lsp_render_tokens_calls", "lsp_render_tokens_ms", "lsp_render_tokens_matching_ms", "lsp_render_tokens_capability_ms", "lsp_render_tokens_latest_ms",
    "lsp_render_tokens_cache_hits", "lsp_render_tokens_cache_misses", "lsp_render_tokens_line_offsets_ms", "lsp_render_tokens_line_offsets_lines",
    "lsp_render_tokens_scan_ms", "lsp_render_tokens_scan_tokens", "lsp_render_tokens_spans", "lsp_render_tokens_base_ms", "lsp_render_tokens_overlay_ms", "lsp_render_tokens_schedule_calls",
    "docview_visible_lines", "docview_text_lines", "docview_tokens", "docview_draw_text_calls",
    "docview_prepare_highlight_iters", "docview_prepare_caret_scan_count", "docview_visible_carets", "docview_prepare_selection_iters", "docview_visible_selection_ranges", "docview_selection_cache_lines", "docview_selection_cache_ranges", "docview_selection_cache_merged_ranges",
    "doc_get_selections_calls", "doc_get_selections_iters", "doc_set_selections_calls", "doc_set_selections_ms", "doc_add_selection_calls", "doc_add_selection_ms", "doc_merge_cursors_calls", "doc_merge_cursors_ms", "doc_sanitize_selection_calls", "doc_sanitize_selection_ms", "doc_apply_edits_calls", "doc_apply_edits_ms",
    "command_calls", "command_total_ms", "command_predicate_ms", "command_body_ms", "slowest_command_ms", "slowest_command_name",
    "statusbar_selection_ms", "statusbar_selection_cache_hits", "statusbar_selection_cache_misses",
    "docview_line_hint_calls", "docview_line_hint_drawn", "docview_line_hint_ms", "docview_line_hint_get_ms", "docview_line_hint_normalize_ms", "docview_line_hint_layout_ms", "docview_line_hint_measure_ms", "docview_line_hint_truncate_ms", "docview_line_hint_draw_ms", "docview_line_hint_draw_text_calls", "docview_line_hint_draw_text_ms", "docview_line_hint_skip_no_hint", "docview_line_hint_skip_no_space", "docview_line_hint_skip_truncated",
    "filetree_line_hint_calls", "filetree_line_hint_ms", "filetree_line_hint_get_file_info_calls", "filetree_line_hint_get_file_info_ms", "filetree_line_hint_format_ms", "filetree_line_hint_git_ms", "filetree_line_hint_segments", "filetree_line_hint_cache_hits", "filetree_line_hint_cache_misses", "filetree_line_hint_folder_count_hits", "filetree_line_hint_folder_count_pending", "filetree_line_hint_entry_calls", "filetree_line_hint_entry_ms", "filetree_entry_snapshot_hits", "filetree_entry_snapshot_builds", "filetree_entry_snapshot_rows", "filetree_entry_snapshot_build_ms", "filetree_folder_row_background_calls", "filetree_folder_row_background_rects", "filetree_folder_row_background_ms", "filetree_line_is_dir_calls", "filetree_line_is_dir_ms", "filetree_draw_line_body_calls", "filetree_draw_line_body_ms", "filetree_draw_line_text_calls", "filetree_draw_line_text_ms", "filetree_draw_line_text_git_ms", "filetree_draw_line_text_colored_calls", "filetree_draw_line_text_plain_calls",
    "over_budget" .. (#diagnostic_frame_keys > 0 and "," .. table.concat(diagnostic_frame_keys, ",") or "")
  }, ",") .. "\n")
end

local function snapshot_value(s, key)
  local value = s and s[key]
  if type(value) == "boolean" then return value and 1 or 0 end
  return value or 0
end

local function diagnostic_frame_csv(snapshot)
  local values = {}
  for i, key in ipairs(diagnostic_frame_keys) do
    local value = snapshot_value(snapshot, key)
    if key:find("_ms$") then
      values[i] = string.format("%.3f", tonumber(value) or 0)
    else
      values[i] = tostring(value or 0)
    end
  end
  return table.concat(values, ",")
end

local aggregate_detail_keys = {
  "worker_pool_drain_wall_ms",
  "worker_pool_drain_ms",
  "worker_pool_drain_messages",
  "worker_pool_dispatch_ms",
  "worker_pool_callback_ms",
  "worker_pool_callbacks",
  "worker_pool_slowest_dispatch_ms",
  "worker_pool_slowest_callback_ms",
  "treesitter_project_metadata_cache_hits",
  "treesitter_project_metadata_cache_misses",
  "docview_line_hint_calls",
  "docview_line_hint_drawn",
  "docview_line_hint_ms",
  "docview_line_hint_get_ms",
  "docview_line_hint_normalize_ms",
  "docview_line_hint_layout_ms",
  "docview_line_hint_measure_ms",
  "docview_line_hint_truncate_ms",
  "docview_line_hint_draw_ms",
  "docview_line_hint_draw_text_calls",
  "docview_line_hint_draw_text_ms",
  "docview_line_hint_skip_no_hint",
  "docview_line_hint_skip_no_space",
  "docview_line_hint_skip_truncated",
  "filetree_line_hint_calls",
  "filetree_line_hint_ms",
  "filetree_line_hint_get_file_info_calls",
  "filetree_line_hint_get_file_info_ms",
  "filetree_line_hint_format_ms",
  "filetree_line_hint_git_ms",
  "filetree_line_hint_segments",
  "filetree_line_hint_cache_hits",
  "filetree_line_hint_cache_misses",
  "filetree_line_hint_folder_count_hits",
  "filetree_line_hint_folder_count_pending",
  "filetree_line_hint_entry_calls",
  "filetree_line_hint_entry_ms",
  "filetree_entry_snapshot_hits",
  "filetree_entry_snapshot_builds",
  "filetree_entry_snapshot_rows",
  "filetree_entry_snapshot_build_ms",
  "filetree_folder_row_background_calls",
  "filetree_folder_row_background_rects",
  "filetree_folder_row_background_ms",
  "filetree_line_is_dir_calls",
  "filetree_line_is_dir_ms",
  "filetree_draw_line_body_calls",
  "filetree_draw_line_body_ms",
  "filetree_draw_line_text_calls",
  "filetree_draw_line_text_ms",
  "filetree_draw_line_text_git_ms",
  "filetree_draw_line_text_colored_calls",
  "filetree_draw_line_text_plain_calls",
  "docview_line_packet_hits",
  "docview_line_packet_misses",
  "docview_line_packet_builds",
  "docview_line_packet_build_ms",
  "docview_line_packet_replay_ms",
  "docview_line_packet_evictions",
  "docview_line_packet_resident_packets",
  "docview_line_packet_resident_bytes",
  "docview_line_packet_frame_failures",
}

local renderer_detail_keys = {
  "rencache_text_commands",
  "rencache_text_bytes",
  "rencache_max_text_bytes",
  "rencache_draw_text_ms",
  "rencache_draw_text_width_ms",
  "display_packet_replays",
  "display_packet_commands_replayed",
  "display_packet_text_commands_replayed",
  "display_packet_rect_commands_replayed",
  "display_packet_source_bytes",
  "display_packet_frame_bytes_copied",
  "display_packet_replay_ms",
  "display_packet_frame_allocation_failures",
  "rencache_frame_failed",
  "text_width_calls",
  "text_width_bytes",
  "text_width_chars",
  "text_width_shaped_runs",
  "text_width_unshaped_runs",
  "text_width_shape_probe_bytes",
  "text_width_hb_shapes",
  "text_width_shaped_cache_hits",
  "text_width_shaped_cache_misses",
  "text_width_hb_shape_ms",
  "text_render_calls",
  "text_render_bytes",
  "text_render_chars",
  "text_render_shaped_runs",
  "text_render_unshaped_runs",
  "text_render_shape_probe_bytes",
  "text_render_hb_shapes",
  "text_render_shaped_cache_hits",
  "text_render_shaped_cache_misses",
  "text_render_glyphs",
  "text_render_whitespace_chars",
  "text_render_chars_after_clip",
  "text_render_top_clip_breaks",
  "text_render_hb_shape_ms",
}

local function aggregate_snapshot_details(snapshot)
  for _, key in ipairs(aggregate_detail_keys) do
    local value = snapshot[key]
    if type(value) == "number" and value ~= 0 then
      add_count(record.detail_counts, key, value)
    end
  end
end

local function aggregate_renderer_details(renderer_stats)
  for _, key in ipairs(renderer_detail_keys) do
    local value = renderer_stats[key]
    if type(value) == "number" and value ~= 0 then
      add_count(record.detail_counts, key, value)
    end
  end
end

local function sorted_scope_rows(paths)
  local rows = {}
  for _, row in pairs(paths or {}) do rows[#rows + 1] = row end
  table.sort(rows, function(a, b) return a.path < b.path end)
  return rows
end

local function publish_draw_scope_frame(snapshot)
  local frame = pending_draw_scope_frame
  pending_draw_scope_frame = nil
  if not frame or not record or not snapshot.did_redraw then return end
  record.scope_frame_count = record.scope_frame_count + 1
  frame.index = record.scope_frame_count
  frame.time = snapshot.time or system.get_time()
  frame.draw_emit_ms = snapshot.draw_emit_ms or frame.elapsed_ms or 0
  local rows = sorted_scope_rows(frame.paths)
  for _, row in ipairs(rows) do
    record.scope_file:write(table.concat({
      tostring(frame.index),
      string.format("%.6f", frame.time),
      string.format("%.3f", frame.draw_emit_ms),
      csv_escape(row.path),
      tostring(row.calls),
      string.format("%.3f", row.inclusive_ms),
      string.format("%.3f", row.exclusive_ms),
      string.format("%.3f", row.lua_heap_delta_kb or 0),
      tostring(row.lua_heap_drop_calls or 0),
      string.format("%.3f", frame.lua_heap_delta_kb or 0),
      tostring(frame.imbalance or 0),
    }, ",") .. "\n")

    local aggregate = record.scope_aggregates[row.path]
    if not aggregate then
      aggregate = {
        path = row.path, frames = 0, calls = 0,
        inclusive_ms = 0, exclusive_ms = 0,
        max_inclusive_ms = 0, max_exclusive_ms = 0,
        lua_heap_delta_kb = 0, lua_heap_drop_calls = 0,
      }
      record.scope_aggregates[row.path] = aggregate
    end
    aggregate.frames = aggregate.frames + 1
    aggregate.calls = aggregate.calls + row.calls
    aggregate.inclusive_ms = aggregate.inclusive_ms + row.inclusive_ms
    aggregate.exclusive_ms = aggregate.exclusive_ms + row.exclusive_ms
    aggregate.max_inclusive_ms = math.max(aggregate.max_inclusive_ms, row.inclusive_ms)
    aggregate.max_exclusive_ms = math.max(aggregate.max_exclusive_ms, row.exclusive_ms)
    aggregate.lua_heap_delta_kb = aggregate.lua_heap_delta_kb + (row.lua_heap_delta_kb or 0)
    aggregate.lua_heap_drop_calls = aggregate.lua_heap_drop_calls + (row.lua_heap_drop_calls or 0)
  end

  if frame.draw_emit_ms > 10 then
    local slow = record.slow_scope_frames
    slow[#slow + 1] = frame
    table.sort(slow, function(a, b) return a.draw_emit_ms > b.draw_emit_ms end)
    while #slow > 30 do table.remove(slow) end
  end
end

function perf.on_frame(snapshot)
  if not recording or not record or not snapshot then return end
  publish_draw_scope_frame(snapshot)
  local now = snapshot.time or system.get_time()
  local renderer_stats = snapshot.did_redraw and renderer.get_last_frame_stats and renderer.get_last_frame_stats() or {}
  record.iteration_count = record.iteration_count + 1
  local ui_update_ms = math.max(
    snapshot.core_root_panel_update_ms or 0,
    snapshot.rootpanel_update_ms or 0
  )
  if ui_update_ms > 0 then
    record.update_iteration_count = record.update_iteration_count + 1
    if snapshot.did_redraw then
      record.redraw_update_iteration_count = record.redraw_update_iteration_count + 1
    else
      record.idle_update_iteration_count = record.idle_update_iteration_count + 1
    end
    if ui_update_ms > 10 or (snapshot.update_ms or 0) > 10 then
      local slow = record.slow_updates
      slow[#slow + 1] = {
        time = now,
        did_redraw = snapshot.did_redraw,
        total_ms = snapshot.total_ms or 0,
        update_ms = snapshot.update_ms or 0,
        core_root_panel_update_ms = snapshot.core_root_panel_update_ms or 0,
        rootpanel_update_ms = snapshot.rootpanel_update_ms or 0,
        rootpanel_initial_layout_ms = snapshot.rootpanel_initial_layout_ms or 0,
        rootpanel_node_update_ms = snapshot.rootpanel_node_update_ms or 0,
        rootpanel_final_layout_ms = snapshot.rootpanel_final_layout_ms or 0,
        node_update_ms = snapshot.node_update_ms or 0,
        node_update_calls = snapshot.node_update_calls or 0,
        node_update_layout_ms = snapshot.node_update_layout_ms or 0,
        node_update_layout_calls = snapshot.node_update_layout_calls or 0,
        node_scroll_tabs_to_visible_ms = snapshot.node_scroll_tabs_to_visible_ms or 0,
        node_active_view_update_ms = snapshot.node_active_view_update_ms or 0,
        node_tab_hover_update_ms = snapshot.node_tab_hover_update_ms or 0,
        docview_update_ms = snapshot.docview_update_ms or 0,
        linewrapping_update_docview_breaks_ms = snapshot.linewrapping_update_docview_breaks_ms or 0,
        linewrapping_update_docview_breaks_calls = snapshot.linewrapping_update_docview_breaks_calls or 0,
        event_count = snapshot.event_count or 0,
        event_types = snapshot.event_types or "",
        pending_events = snapshot.pending_events,
        queue_depth = snapshot.queue_depth or 0,
      }
      table.sort(slow, function(a, b)
        local a_ms = math.max(a.core_root_panel_update_ms, a.rootpanel_update_ms, a.update_ms)
        local b_ms = math.max(b.core_root_panel_update_ms, b.rootpanel_update_ms, b.update_ms)
        return a_ms > b_ms
      end)
      while #slow > 30 do table.remove(slow) end
    end
  end
  if snapshot.did_redraw then
    record.frame_count = record.frame_count + 1
    if record.last_redraw_time then
      record.redraw_intervals[#record.redraw_intervals + 1] = (now - record.last_redraw_time) * 1000
    end
    record.last_redraw_time = now
    if snapshot.over_budget then record.over_budget_count = record.over_budget_count + 1 end
    local total_ms = snapshot.total_ms or 0
    local frame_ms = snapshot.frame_ms or 0
    local present_ms = snapshot.present_ms or 0
    if total_ms > 25 or frame_ms > 20 or present_ms > 18 then
      local slow = record.slow_frames
      slow[#slow + 1] = {
        time = now,
        total_ms = total_ms,
        run_threads_ms = snapshot.run_threads_ms or 0,
        run_threads_runs = snapshot.run_threads_runs or 0,
        run_threads_slowest_ms = snapshot.run_threads_slowest_ms or 0,
        run_threads_slowest_loc = snapshot.run_threads_slowest_loc or "",
        worker_pool_drain_wall_ms = snapshot.worker_pool_drain_wall_ms or 0,
        worker_pool_drain_ms = snapshot.worker_pool_drain_ms or 0,
        worker_pool_drain_messages = snapshot.worker_pool_drain_messages or 0,
        worker_pool_dispatch_ms = snapshot.worker_pool_dispatch_ms or 0,
        worker_pool_callback_ms = snapshot.worker_pool_callback_ms or 0,
        worker_pool_slowest_callback_ms = snapshot.worker_pool_slowest_callback_ms or 0,
        worker_pool_slowest_callback_name = snapshot.worker_pool_slowest_callback_name or "",
        core_step_ms = snapshot.core_step_ms or 0,
        gc_ms = snapshot.gc_ms or 0,
        event_count = snapshot.event_count or 0,
        event_ms = snapshot.event_ms or 0,
        event_types = snapshot.event_types or "",
        slowest_event_type = snapshot.slowest_event_type or "",
        slowest_event_ms = snapshot.slowest_event_ms or 0,
        update_ms = snapshot.update_ms or 0,
        pre_draw_ms = snapshot.pre_draw_ms or 0,
        frame_ms = frame_ms,
        draw_emit_ms = snapshot.draw_emit_ms or 0,
        renderer_end_ms = snapshot.renderer_end_ms or 0,
        present_ms = present_ms,
        draw_calls = renderer_stats.draw_calls or 0,
        d3d11_glyph_push_ms = snapshot.d3d11_glyph_push_ms or 0,
        d3d11_flush_quads_ms = snapshot.d3d11_flush_quads_ms or 0,
        d3d11_dwm_flush_ms = snapshot.d3d11_dwm_flush_ms or 0,
        d3d11_clear_state_ms = snapshot.d3d11_clear_state_ms or 0,
        docview_draw_ms = snapshot.docview_draw_ms or 0,
        docview_prepare_ms = snapshot.docview_prepare_ms or 0,
        docview_prepare_caret_ms = snapshot.docview_prepare_caret_ms or 0,
        docview_prepare_selection_ms = snapshot.docview_prepare_selection_ms or 0,
        docview_gutter_ms = snapshot.docview_gutter_ms or 0,
        docview_body_ms = snapshot.docview_body_ms or 0,
        docview_text_ms = snapshot.docview_text_ms or 0,
        docview_overlay_ms = snapshot.docview_overlay_ms or 0,
        docview_draw_text_calls = snapshot.docview_draw_text_calls or 0,
        lsp_render_tokens_calls = snapshot.lsp_render_tokens_calls or 0,
        lsp_render_tokens_ms = snapshot.lsp_render_tokens_ms or 0,
        lsp_render_tokens_line_offsets_ms = snapshot.lsp_render_tokens_line_offsets_ms or 0,
        lsp_render_tokens_scan_ms = snapshot.lsp_render_tokens_scan_ms or 0,
        lsp_render_tokens_cache_hits = snapshot.lsp_render_tokens_cache_hits or 0,
        lsp_render_tokens_cache_misses = snapshot.lsp_render_tokens_cache_misses or 0,
        doc_get_selections_calls = snapshot.doc_get_selections_calls or 0,
        doc_get_selections_iters = snapshot.doc_get_selections_iters or 0,
        doc_set_selections_calls = snapshot.doc_set_selections_calls or 0,
        doc_set_selections_ms = snapshot.doc_set_selections_ms or 0,
        command_calls = snapshot.command_calls or 0,
        command_total_ms = snapshot.command_total_ms or 0,
        command_predicate_ms = snapshot.command_predicate_ms or 0,
        command_body_ms = snapshot.command_body_ms or 0,
        slowest_command_ms = snapshot.slowest_command_ms or 0,
        slowest_command_name = snapshot.slowest_command_name or "",
        statusbar_selection_ms = snapshot.statusbar_selection_ms or 0,
        pending_events = snapshot.pending_events,
        queue_depth = snapshot.queue_depth or 0,
      }
      table.sort(slow, function(a, b) return a.total_ms > b.total_ms end)
      while #slow > 30 do table.remove(slow) end
    end
  else
    record.idle_iteration_count = record.idle_iteration_count + 1
  end
  aggregate_snapshot_details(snapshot)
  if snapshot.did_redraw then aggregate_renderer_details(renderer_stats) end
  record.max_selection_count = math.max(record.max_selection_count, snapshot.selection_count or 0)
  record.max_search_selection_count = math.max(record.max_search_selection_count, snapshot.search_selection_count or 0)
  if (snapshot.sleep_actual_ms or 0) > 0 then
    record.sleep_count = record.sleep_count + 1
    record.sleep_actual_total_ms = record.sleep_actual_total_ms + snapshot.sleep_actual_ms
  end
  local frame_row = table.concat({
    string.format("%.6f", now),
    snapshot.did_redraw and "1" or "0",
    string.format("%.3f", snapshot.fps or 0),
    string.format("%.3f", snapshot.target_fps or 0),
    snapshot.active_present_paced and "1" or "0",
    snapshot.pending_events and "1" or "0",
    tostring(snapshot.queue_depth or 0),
    csv_escape(snapshot.run_mode or ""),
    snapshot.window_has_focus and "1" or "0",
    snapshot.active_view_is_docview and "1" or "0",
    csv_escape(snapshot.active_view_name or ""),
    tostring(snapshot.selection_count or 0),
    tostring(snapshot.search_selection_count or 0),
    tostring(snapshot.docview_caret_draw_calls or 0),
    tostring(snapshot.docview_selection_rect_calls or 0),
    tostring(snapshot.event_count or 0),
    string.format("%.3f", snapshot.event_ms or 0),
    csv_escape(snapshot.event_types or ""),
    csv_escape(snapshot.slowest_event_type or ""),
    string.format("%.3f", snapshot.slowest_event_ms or 0),
    string.format("%.3f", snapshot.update_ms or 0),
    string.format("%.3f", snapshot.pre_draw_ms or 0),
    string.format("%.3f", snapshot.frame_ms or 0),
    string.format("%.3f", snapshot.draw_emit_ms or 0),
    string.format("%.3f", snapshot.renderer_end_ms or 0),
    string.format("%.3f", snapshot.present_ms or 0),
    string.format("%.3f", snapshot.run_threads_ms or 0),
    tostring(snapshot.run_threads_runs or 0),
    string.format("%.3f", snapshot.run_threads_slowest_ms or 0),
    csv_escape(snapshot.run_threads_slowest_loc or ""),
    string.format("%.3f", snapshot.core_step_ms or 0),
    string.format("%.3f", snapshot.gc_ms or 0),
    string.format("%.3f", snapshot.sleep_requested_ms or 0),
    string.format("%.3f", snapshot.sleep_actual_ms or 0),
    string.format("%.3f", snapshot.total_ms or 0),
    tostring(renderer_stats.draw_calls or 0),
    tostring(renderer_stats.quad_instances or 0),
    tostring(renderer_stats.texture_uploads or 0),
    tostring(renderer_stats.texture_upload_bytes or 0),
    string.format("%.3f", renderer_stats.d3d11_glyph_push_ms or 0),
    string.format("%.3f", renderer_stats.d3d11_flush_quads_ms or 0),
    string.format("%.3f", renderer_stats.d3d11_dwm_flush_ms or 0),
    string.format("%.3f", renderer_stats.d3d11_clear_state_ms or 0),
    tostring(renderer_stats.rencache_text_commands or 0),
    tostring(renderer_stats.rencache_text_bytes or 0),
    tostring(renderer_stats.rencache_max_text_bytes or 0),
    string.format("%.3f", renderer_stats.rencache_draw_text_ms or 0),
    string.format("%.3f", renderer_stats.rencache_draw_text_width_ms or 0),
    tostring(renderer_stats.display_packet_replays or 0),
    tostring(renderer_stats.display_packet_commands_replayed or 0),
    tostring(renderer_stats.display_packet_text_commands_replayed or 0),
    tostring(renderer_stats.display_packet_rect_commands_replayed or 0),
    tostring(renderer_stats.display_packet_source_bytes or 0),
    tostring(renderer_stats.display_packet_frame_bytes_copied or 0),
    string.format("%.3f", renderer_stats.display_packet_replay_ms or 0),
    tostring(renderer_stats.display_packet_frame_allocation_failures or 0),
    tostring(renderer_stats.rencache_frame_failed and 1 or 0),
    tostring(renderer_stats.text_width_calls or 0),
    tostring(renderer_stats.text_width_bytes or 0),
    tostring(renderer_stats.text_width_chars or 0),
    tostring(renderer_stats.text_width_shaped_runs or 0),
    tostring(renderer_stats.text_width_unshaped_runs or 0),
    tostring(renderer_stats.text_width_shape_probe_bytes or 0),
    tostring(renderer_stats.text_width_hb_shapes or 0),
    tostring(renderer_stats.text_width_shaped_cache_hits or 0),
    tostring(renderer_stats.text_width_shaped_cache_misses or 0),
    string.format("%.3f", renderer_stats.text_width_hb_shape_ms or 0),
    tostring(renderer_stats.text_render_calls or 0),
    tostring(renderer_stats.text_render_bytes or 0),
    tostring(renderer_stats.text_render_chars or 0),
    tostring(renderer_stats.text_render_shaped_runs or 0),
    tostring(renderer_stats.text_render_unshaped_runs or 0),
    tostring(renderer_stats.text_render_shape_probe_bytes or 0),
    tostring(renderer_stats.text_render_hb_shapes or 0),
    tostring(renderer_stats.text_render_shaped_cache_hits or 0),
    tostring(renderer_stats.text_render_shaped_cache_misses or 0),
    tostring(renderer_stats.text_render_glyphs or 0),
    tostring(renderer_stats.text_render_whitespace_chars or 0),
    tostring(renderer_stats.text_render_chars_after_clip or 0),
    tostring(renderer_stats.text_render_top_clip_breaks or 0),
    string.format("%.3f", renderer_stats.text_render_hb_shape_ms or 0),
    string.format("%.3f", snapshot.docview_draw_ms or 0),
    string.format("%.3f", snapshot.docview_prepare_ms or 0),
    string.format("%.3f", snapshot.docview_prepare_highlight_ms or 0),
    string.format("%.3f", snapshot.docview_prepare_caret_ms or 0),
    string.format("%.3f", snapshot.docview_prepare_selection_ms or 0),
    string.format("%.3f", snapshot.docview_prepare_merge_ms or 0),
    string.format("%.3f", snapshot.docview_gutter_ms or 0),
    string.format("%.3f", snapshot.docview_body_ms or 0),
    string.format("%.3f", snapshot.docview_text_ms or 0),
    string.format("%.3f", snapshot.docview_overlay_ms or 0),
    string.format("%.3f", snapshot.docview_highlighter_get_line_ms or 0),
    string.format("%.3f", snapshot.docview_token_loop_ms or 0),
    string.format("%.3f", snapshot.docview_renderer_draw_text_ms or 0),
    tostring(snapshot_value(snapshot, "lsp_render_tokens_calls")),
    string.format("%.3f", snapshot.lsp_render_tokens_ms or 0),
    string.format("%.3f", snapshot.lsp_render_tokens_matching_ms or 0),
    string.format("%.3f", snapshot.lsp_render_tokens_capability_ms or 0),
    string.format("%.3f", snapshot.lsp_render_tokens_latest_ms or 0),
    tostring(snapshot_value(snapshot, "lsp_render_tokens_cache_hits")),
    tostring(snapshot_value(snapshot, "lsp_render_tokens_cache_misses")),
    string.format("%.3f", snapshot.lsp_render_tokens_line_offsets_ms or 0),
    tostring(snapshot_value(snapshot, "lsp_render_tokens_line_offsets_lines")),
    string.format("%.3f", snapshot.lsp_render_tokens_scan_ms or 0),
    tostring(snapshot_value(snapshot, "lsp_render_tokens_scan_tokens")),
    tostring(snapshot_value(snapshot, "lsp_render_tokens_spans")),
    string.format("%.3f", snapshot.lsp_render_tokens_base_ms or 0),
    string.format("%.3f", snapshot.lsp_render_tokens_overlay_ms or 0),
    tostring(snapshot_value(snapshot, "lsp_render_tokens_schedule_calls")),
    tostring(snapshot_value(snapshot, "docview_visible_lines")),
    tostring(snapshot_value(snapshot, "docview_text_lines")),
    tostring(snapshot_value(snapshot, "docview_tokens")),
    tostring(snapshot_value(snapshot, "docview_draw_text_calls")),
    tostring(snapshot_value(snapshot, "docview_prepare_highlight_iters")),
    tostring(snapshot_value(snapshot, "docview_prepare_caret_scan_count")),
    tostring(snapshot_value(snapshot, "docview_visible_carets")),
    tostring(snapshot_value(snapshot, "docview_prepare_selection_iters")),
    tostring(snapshot_value(snapshot, "docview_visible_selection_ranges")),
    tostring(snapshot_value(snapshot, "docview_selection_cache_lines")),
    tostring(snapshot_value(snapshot, "docview_selection_cache_ranges")),
    tostring(snapshot_value(snapshot, "docview_selection_cache_merged_ranges")),
    tostring(snapshot_value(snapshot, "doc_get_selections_calls")),
    tostring(snapshot_value(snapshot, "doc_get_selections_iters")),
    tostring(snapshot_value(snapshot, "doc_set_selections_calls")),
    string.format("%.3f", snapshot.doc_set_selections_ms or 0),
    tostring(snapshot_value(snapshot, "doc_add_selection_calls")),
    string.format("%.3f", snapshot.doc_add_selection_ms or 0),
    tostring(snapshot_value(snapshot, "doc_merge_cursors_calls")),
    string.format("%.3f", snapshot.doc_merge_cursors_ms or 0),
    tostring(snapshot_value(snapshot, "doc_sanitize_selection_calls")),
    string.format("%.3f", snapshot.doc_sanitize_selection_ms or 0),
    tostring(snapshot_value(snapshot, "doc_apply_edits_calls")),
    string.format("%.3f", snapshot.doc_apply_edits_ms or 0),
    tostring(snapshot_value(snapshot, "command_calls")),
    string.format("%.3f", snapshot.command_total_ms or 0),
    string.format("%.3f", snapshot.command_predicate_ms or 0),
    string.format("%.3f", snapshot.command_body_ms or 0),
    string.format("%.3f", snapshot.slowest_command_ms or 0),
    csv_escape(snapshot.slowest_command_name or ""),
    string.format("%.3f", snapshot.statusbar_selection_ms or 0),
    tostring(snapshot_value(snapshot, "statusbar_selection_cache_hits")),
    tostring(snapshot_value(snapshot, "statusbar_selection_cache_misses")),
    tostring(snapshot_value(snapshot, "docview_line_hint_calls")),
    tostring(snapshot_value(snapshot, "docview_line_hint_drawn")),
    string.format("%.3f", snapshot.docview_line_hint_ms or 0),
    string.format("%.3f", snapshot.docview_line_hint_get_ms or 0),
    string.format("%.3f", snapshot.docview_line_hint_normalize_ms or 0),
    string.format("%.3f", snapshot.docview_line_hint_layout_ms or 0),
    string.format("%.3f", snapshot.docview_line_hint_measure_ms or 0),
    string.format("%.3f", snapshot.docview_line_hint_truncate_ms or 0),
    string.format("%.3f", snapshot.docview_line_hint_draw_ms or 0),
    tostring(snapshot_value(snapshot, "docview_line_hint_draw_text_calls")),
    string.format("%.3f", snapshot.docview_line_hint_draw_text_ms or 0),
    tostring(snapshot_value(snapshot, "docview_line_hint_skip_no_hint")),
    tostring(snapshot_value(snapshot, "docview_line_hint_skip_no_space")),
    tostring(snapshot_value(snapshot, "docview_line_hint_skip_truncated")),
    tostring(snapshot_value(snapshot, "filetree_line_hint_calls")),
    string.format("%.3f", snapshot.filetree_line_hint_ms or 0),
    tostring(snapshot_value(snapshot, "filetree_line_hint_get_file_info_calls")),
    string.format("%.3f", snapshot.filetree_line_hint_get_file_info_ms or 0),
    string.format("%.3f", snapshot.filetree_line_hint_format_ms or 0),
    string.format("%.3f", snapshot.filetree_line_hint_git_ms or 0),
    tostring(snapshot_value(snapshot, "filetree_line_hint_segments")),
    tostring(snapshot_value(snapshot, "filetree_line_hint_cache_hits")),
    tostring(snapshot_value(snapshot, "filetree_line_hint_cache_misses")),
    tostring(snapshot_value(snapshot, "filetree_line_hint_folder_count_hits")),
    tostring(snapshot_value(snapshot, "filetree_line_hint_folder_count_pending")),
    tostring(snapshot_value(snapshot, "filetree_line_hint_entry_calls")),
    string.format("%.3f", snapshot.filetree_line_hint_entry_ms or 0),
    tostring(snapshot_value(snapshot, "filetree_entry_snapshot_hits")),
    tostring(snapshot_value(snapshot, "filetree_entry_snapshot_builds")),
    tostring(snapshot_value(snapshot, "filetree_entry_snapshot_rows")),
    string.format("%.3f", snapshot.filetree_entry_snapshot_build_ms or 0),
    tostring(snapshot_value(snapshot, "filetree_folder_row_background_calls")),
    tostring(snapshot_value(snapshot, "filetree_folder_row_background_rects")),
    string.format("%.3f", snapshot.filetree_folder_row_background_ms or 0),
    tostring(snapshot_value(snapshot, "filetree_line_is_dir_calls")),
    string.format("%.3f", snapshot.filetree_line_is_dir_ms or 0),
    tostring(snapshot_value(snapshot, "filetree_draw_line_body_calls")),
    string.format("%.3f", snapshot.filetree_draw_line_body_ms or 0),
    tostring(snapshot_value(snapshot, "filetree_draw_line_text_calls")),
    string.format("%.3f", snapshot.filetree_draw_line_text_ms or 0),
    string.format("%.3f", snapshot.filetree_draw_line_text_git_ms or 0),
    tostring(snapshot_value(snapshot, "filetree_draw_line_text_colored_calls")),
    tostring(snapshot_value(snapshot, "filetree_draw_line_text_plain_calls")),
    snapshot.over_budget and "1" or "0",
  }, ",")
  local diagnostic = diagnostic_frame_csv(snapshot)
  if diagnostic ~= "" then frame_row = frame_row .. "," .. diagnostic end
  record.file:write(frame_row .. "\n")
end

local function sorted_counts(tbl)
  local rows = {}
  for key, count in pairs(tbl) do
    rows[#rows + 1] = { key = key, count = count }
  end
  table.sort(rows, function(a, b) return a.count > b.count end)
  return rows
end

local function percentile(values, q)
  if #values == 0 then return 0 end
  table.sort(values)
  return values[math.min(#values, math.max(1, math.floor((#values - 1) * q) + 1))]
end

local function write_counts_csv(path, header, rows)
  local file = io.open(path, "wb")
  if not file then return end
  file:write(header .. "\n")
  for _, row in ipairs(rows) do
    file:write(tostring(row.count), ",", csv_escape(row.key), "\n")
  end
  file:close()
end

local function context_text(value)
  return tostring(value or ""):gsub("[\r\n]+", " ")
end

local function capture_recording_context()
  local view = core.active_view
  local doc = view and view.doc
  local bytes = 0
  for _, line in ipairs(doc and doc.lines or {}) do bytes = bytes + #line end
  local function count_entries(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do count = count + 1 end
    return count
  end
  return {
    view_name = context_text(view),
    document_name = context_text(doc and doc:get_name()),
    document_path = context_text(doc and (doc.abs_filename or doc.filename)),
    document_lines = doc and #doc.lines or 0,
    document_bytes = bytes,
    view_x = view and view.position and view.position.x or 0,
    view_y = view and view.position and view.position.y or 0,
    view_width = view and view.size and view.size.x or 0,
    view_height = view and view.size and view.size.y or 0,
    wrapping_enabled = view and view.wrapping_enabled == true or false,
    has_wrapped_layout = view and view.wrapped_settings ~= nil or false,
    markdown_live_preview = view and view.__markdown_live_attached == true or false,
    visual_metric_providers = count_entries(view and view.visual_metric_providers),
    line_render_providers = count_entries(view and view.line_render_providers),
  }
end

local function write_summary(path)
  local file = io.open(path, "wb")
  if not file then return end
  local elapsed = record.stop_time - record.start_time
  file:write("Anvil performance recording\n")
  file:write(string.format("Elapsed: %.3fs\n", elapsed))
  file:write(string.format(
    "Draw scope capture: frames=%d csv=%s\n",
    record.scope_frame_count or 0, record.scope_path or ""
  ))
  local context = record.context or {}
  file:write(string.format(
    "Context: view=%s document=%s path=%s lines=%d bytes=%d\n",
    context.view_name or "", context.document_name or "", context.document_path or "",
    context.document_lines or 0, context.document_bytes or 0
  ))
  file:write(string.format(
    "Context geometry: x=%.1f y=%.1f width=%.1f height=%.1f wrapping=%s wrapped_layout=%s markdown_live_preview=%s metric_providers=%d line_render_providers=%d\n",
    context.view_x or 0, context.view_y or 0, context.view_width or 0, context.view_height or 0,
    tostring(context.wrapping_enabled == true), tostring(context.has_wrapped_layout == true),
    tostring(context.markdown_live_preview == true), context.visual_metric_providers or 0,
    context.line_render_providers or 0
  ))
  file:write(string.format("Run-loop iterations: %d\n", record.iteration_count))
  file:write(string.format("Idle/non-redraw iterations: %d\n", record.idle_iteration_count))
  file:write(string.format("UI update iterations: %d (%d with redraw, %d without redraw)\n",
    record.update_iteration_count, record.redraw_update_iteration_count, record.idle_update_iteration_count))
  file:write(string.format("Redraw frames: %d\n", record.frame_count))
  if elapsed > 0 then
    file:write(string.format("Whole-record redraw FPS: %.1f\n", record.frame_count / elapsed))
  end
  if #record.redraw_intervals > 0 then
    local intervals = { table.unpack(record.redraw_intervals) }
    local active_like = 0
    local over_20 = 0
    local over_50 = 0
    for _, ms in ipairs(intervals) do
      if ms <= 20 then active_like = active_like + 1 end
      if ms > 20 then over_20 = over_20 + 1 end
      if ms > 50 then over_50 = over_50 + 1 end
    end
    file:write(string.format(
      "Redraw interval ms (includes idle gaps): p50 %.3f p90 %.3f p95 %.3f p99 %.3f max %.3f\n",
      percentile(intervals, 0.50), percentile(intervals, 0.90),
      percentile(intervals, 0.95), percentile(intervals, 0.99), intervals[#intervals]
    ))
    local active_elapsed = 0
    for _, ms in ipairs(record.redraw_intervals) do
      if ms <= 20 then active_elapsed = active_elapsed + ms / 1000 end
    end
    if active_elapsed > 0 then
      file:write(string.format("Active-cadence redraw FPS (intervals <=20ms): %.1f\n", active_like / active_elapsed))
    end
    file:write(string.format("Redraw intervals >20ms: %d, >50ms: %d (often idle gaps if no slow frames are listed)\n", over_20, over_50))
  end
  file:write(string.format("Sleep calls: %d, sleep actual total: %.1fms\n", record.sleep_count, record.sleep_actual_total_ms))
  file:write(string.format("Max selections: %d, max search selections: %d\n", record.max_selection_count, record.max_search_selection_count))
  file:write(string.format("Over-budget redraw frames: %d (%.1f%%)\n\n",
    record.over_budget_count,
    record.frame_count > 0 and (record.over_budget_count * 100 / record.frame_count) or 0
  ))

  file:write("Slow redraw frames (top by total_ms; thresholds total>25ms/frame>20ms/present>18ms):\n")
  file:write("time,total,run_threads,run_threads_runs,run_threads_slowest,run_threads_loc,worker_pool_drain,worker_pool_messages,worker_pool_dispatch,worker_pool_callback,worker_pool_slowest_callback,worker_pool_slowest_callback_name,core,gc,event_count,event,event_types,slowest_event,slowest_event_ms,command_calls,command_total,slowest_command,slowest_command_name,update,pre_draw,frame,draw_emit,renderer_end,present,draw_calls,docview_draw,docview_prepare,docview_prepare_caret,docview_prepare_selection,docview_gutter,docview_body,docview_text,docview_overlay,docview_text_calls,lsp_tokens_ms,lsp_offsets_ms,lsp_scan_ms,lsp_calls,lsp_hits,lsp_misses,doc_get_selections_calls,doc_get_selections_iters,doc_set_selections_calls,doc_set_selections_ms,statusbar_selection,pending_events,queue_depth\n")
  for _, row in ipairs(record.slow_frames or {}) do
    file:write(string.format(
      "%.6f,%.3f,%.3f,%d,%.3f,%s,%.3f,%d,%.3f,%.3f,%.3f,%s,%.3f,%.3f,%d,%.3f,%s,%s,%.3f,%d,%.3f,%.3f,%s,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%.3f,%.3f,%d,%d,%d,%d,%d,%d,%.3f,%.3f,%d,%d\n",
      row.time, row.total_ms, row.run_threads_ms, row.run_threads_runs,
      row.run_threads_slowest_ms, csv_escape(row.run_threads_slowest_loc),
      row.worker_pool_drain_ms, row.worker_pool_drain_messages,
      row.worker_pool_dispatch_ms, row.worker_pool_callback_ms,
      row.worker_pool_slowest_callback_ms, csv_escape(row.worker_pool_slowest_callback_name),
      row.core_step_ms, row.gc_ms, row.event_count, row.event_ms,
      csv_escape(row.event_types), csv_escape(row.slowest_event_type), row.slowest_event_ms,
      row.command_calls, row.command_total_ms, row.slowest_command_ms, csv_escape(row.slowest_command_name),
      row.update_ms, row.pre_draw_ms, row.frame_ms, row.draw_emit_ms,
      row.renderer_end_ms, row.present_ms, row.draw_calls, row.docview_draw_ms,
      row.docview_prepare_ms, row.docview_prepare_caret_ms, row.docview_prepare_selection_ms,
      row.docview_gutter_ms, row.docview_body_ms, row.docview_text_ms, row.docview_overlay_ms,
      row.docview_draw_text_calls, row.lsp_render_tokens_ms, row.lsp_render_tokens_line_offsets_ms,
      row.lsp_render_tokens_scan_ms, row.lsp_render_tokens_calls, row.lsp_render_tokens_cache_hits,
      row.lsp_render_tokens_cache_misses, row.doc_get_selections_calls, row.doc_get_selections_iters,
      row.doc_set_selections_calls, row.doc_set_selections_ms,
      row.statusbar_selection_ms, row.pending_events and 1 or 0, row.queue_depth
    ))
  end
  file:write("\n")

  file:write("Slow UI update iterations (top by update/rootpanel time; thresholds ui_update>10ms/update>10ms):\n")
  file:write("time,did_redraw,total,update,core_root_panel,rootpanel,initial_layout,node_update,final_layout,node_update_inclusive,node_update_calls,node_layout_inclusive,node_layout_calls,scroll_tabs,active_view_update,tab_hover,docview_update,linewrap_update,linewrap_update_calls,event_count,event_types,pending_events,queue_depth\n")
  for _, row in ipairs(record.slow_updates or {}) do
    file:write(string.format(
      "%.6f,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%d,%s,%d,%d\n",
      row.time, row.did_redraw and 1 or 0, row.total_ms, row.update_ms,
      row.core_root_panel_update_ms, row.rootpanel_update_ms,
      row.rootpanel_initial_layout_ms, row.rootpanel_node_update_ms, row.rootpanel_final_layout_ms,
      row.node_update_ms, row.node_update_calls, row.node_update_layout_ms, row.node_update_layout_calls,
      row.node_scroll_tabs_to_visible_ms, row.node_active_view_update_ms, row.node_tab_hover_update_ms,
      row.docview_update_ms, row.linewrapping_update_docview_breaks_ms,
      row.linewrapping_update_docview_breaks_calls, row.event_count, csv_escape(row.event_types),
      row.pending_events and 1 or 0, row.queue_depth
    ))
  end
  file:write("\n")

  local function drill_metric(label, key, denom, denom_label)
    local total = record.detail_counts[key] or 0
    local avg = denom > 0 and total / denom or 0
    file:write(string.format("  %-42s total %10.3f  avg/%-7s %8.3f\n", label, total, denom_label, avg))
  end
  local redraw_denom = math.max(0, record.frame_count or 0)
  local update_denom = math.max(0, record.update_iteration_count or 0)
  local run_denom = math.max(0, record.iteration_count or 0)
  file:write("DocView/FileTree drilldown totals:\n")
  file:write(string.format("  Denominators: redraw=%d, ui_update=%d, run_loop=%d\n", redraw_denom, update_denom, run_denom))
  file:write("  Cache/Markdown/centered-layout diagnostics:\n")
  drill_metric("visual metric cache calls", "docview_visual_metric_cache_calls", run_denom, "run_loop")
  drill_metric("visual metric cache hits", "docview_visual_metric_cache_hits", run_denom, "run_loop")
  drill_metric("visual metric cache lookup ms", "docview_visual_metric_cache_lookup_ms", run_denom, "run_loop")
  drill_metric("visual metric signature ms", "docview_visual_metric_signature_ms", run_denom, "run_loop")
  drill_metric("visual metric signature cache hits", "docview_visual_metric_signature_cache_hits", run_denom, "run_loop")
  drill_metric("visual metric signature computations", "docview_visual_metric_signature_computations", run_denom, "run_loop")
  drill_metric("visual metric signature changes", "docview_visual_metric_signature_changes", run_denom, "run_loop")
  drill_metric("visual metric full rebuilds", "docview_visual_metric_full_rebuilds", run_denom, "run_loop")
  drill_metric("visual metric full rebuild rows", "docview_visual_metric_full_rebuild_rows", run_denom, "run_loop")
  drill_metric("visual metric full rebuild ms", "docview_visual_metric_full_rebuild_ms", run_denom, "run_loop")
  drill_metric("visual metric dirty passes", "docview_visual_metric_dirty_passes", run_denom, "run_loop")
  drill_metric("visual metric dirty rows", "docview_visual_metric_dirty_rows", run_denom, "run_loop")
  drill_metric("visual metric row splices", "docview_visual_metric_row_splices", run_denom, "run_loop")
  drill_metric("visual metric row splice rows", "docview_visual_metric_row_splice_rows", run_denom, "run_loop")
  drill_metric("line render cache calls", "docview_line_render_cache_calls", run_denom, "run_loop")
  drill_metric("line render cache hits", "docview_line_render_cache_hits", run_denom, "run_loop")
  drill_metric("line render cache misses", "docview_line_render_cache_misses", run_denom, "run_loop")
  drill_metric("line render cold misses", "docview_line_render_cold_misses", run_denom, "run_loop")
  drill_metric("line render signature misses", "docview_line_render_signature_misses", run_denom, "run_loop")
  drill_metric("line render cache lookup ms", "docview_line_render_cache_lookup_ms", run_denom, "run_loop")
  drill_metric("line render build ms", "docview_line_render_build_ms", run_denom, "run_loop")
  drill_metric("fragment normalization calls", "docview_fragment_normalization_calls", run_denom, "run_loop")
  drill_metric("fragment normalization cache hits", "docview_fragment_normalization_cache_hits", run_denom, "run_loop")
  drill_metric("fragment normalization builds", "docview_fragment_normalization_builds", run_denom, "run_loop")
  drill_metric("Markdown provider generation requests", "markdown_live_provider_generation_requests", run_denom, "run_loop")
  drill_metric("Markdown provider generation cache hits", "markdown_live_provider_generation_cache_hits", run_denom, "run_loop")
  drill_metric("Markdown provider generations", "markdown_live_provider_generation_calls", run_denom, "run_loop")
  drill_metric("Markdown generations at host geometry", "markdown_live_provider_generation_host_calls", run_denom, "run_loop")
  drill_metric("Markdown generations in centered geometry", "markdown_live_provider_generation_centered_calls", run_denom, "run_loop")
  drill_metric("Markdown semantic publications", "markdown_live_semantic_publications", run_denom, "run_loop")
  drill_metric("Markdown semantic publication ranges", "markdown_live_semantic_publication_ranges", run_denom, "run_loop")
  drill_metric("Markdown semantic publication lines", "markdown_live_semantic_publication_lines", run_denom, "run_loop")
  drill_metric("Markdown semantic global invalidations", "markdown_live_semantic_global_invalidations", run_denom, "run_loop")
  drill_metric("Markdown model publication ms", "markdown_model_publication_ms", run_denom, "run_loop")
  drill_metric("Markdown publication summary ms", "markdown_model_publication_summary_ms", run_denom, "run_loop")
  drill_metric("Markdown previous-result close ms", "markdown_model_publication_previous_close_ms", run_denom, "run_loop")
  drill_metric("Markdown publication state ms", "markdown_model_publication_state_ms", run_denom, "run_loop")
  drill_metric("Markdown publication notify ms", "markdown_model_publication_notify_ms", run_denom, "run_loop")
  drill_metric("Markdown publication listeners", "markdown_model_publication_listener_calls", run_denom, "run_loop")
  drill_metric("Markdown view publication ms", "markdown_live_publication_listener_ms", run_denom, "run_loop")
  drill_metric("Markdown view reset ms", "markdown_live_publication_reset_ms", run_denom, "run_loop")
  drill_metric("Markdown fence reconcile ms", "markdown_live_publication_fence_reconcile_ms", run_denom, "run_loop")
  drill_metric("Markdown publication expand ms", "markdown_live_publication_range_expand_ms", run_denom, "run_loop")
  drill_metric("Markdown publication image prune ms", "markdown_live_publication_prune_images_ms", run_denom, "run_loop")
  drill_metric("Markdown line invalidation ms", "markdown_live_publication_line_invalidate_ms", run_denom, "run_loop")
  drill_metric("Markdown metric invalidation ms", "markdown_live_publication_metric_invalidate_ms", run_denom, "run_loop")
  drill_metric("Markdown link-index invalidations", "markdown_live_link_index_invalidations", run_denom, "run_loop")
  drill_metric("Markdown image fragment builds", "markdown_live_image_fragment_calls", run_denom, "run_loop")
  drill_metric("Markdown image get_asset calls", "markdown_image_get_asset_calls", run_denom, "run_loop")
  drill_metric("Markdown image asset-key calls", "markdown_image_asset_key_calls", run_denom, "run_loop")
  drill_metric("Markdown image request-key cache hits", "markdown_image_asset_request_key_cache_hits", run_denom, "run_loop")
  drill_metric("Markdown image asset cache hits", "markdown_image_asset_cache_hits", run_denom, "run_loop")
  drill_metric("Markdown image asset cache misses", "markdown_image_asset_cache_misses", run_denom, "run_loop")
  drill_metric("Markdown image retry checks", "markdown_image_asset_retry_checks", run_denom, "run_loop")
  drill_metric("Markdown image refreshes", "markdown_image_asset_refreshes", run_denom, "run_loop")
  drill_metric("Markdown local-path resolutions", "markdown_image_resolve_local_path_calls", run_denom, "run_loop")
  drill_metric("Markdown local-path misses", "markdown_image_resolve_local_path_misses", run_denom, "run_loop")
  drill_metric("Markdown image file-exists calls", "markdown_image_file_exists_calls", run_denom, "run_loop")
  drill_metric("centered should_center calls", "centered_editor_should_center_calls", run_denom, "run_loop")
  drill_metric("centered should_center true", "centered_editor_should_center_true", run_denom, "run_loop")
  drill_metric("centered node lookup calls", "centered_editor_node_lookup_calls", run_denom, "run_loop")
  drill_metric("centered node lookup cache hits", "centered_editor_node_lookup_cache_hits", run_denom, "run_loop")
  drill_metric("centered node lookup ms", "centered_editor_node_lookup_ms", run_denom, "run_loop")
  drill_metric("centered geometry wrapper calls", "centered_editor_with_geometry_calls", run_denom, "run_loop")
  drill_metric("centered geometry entries", "centered_editor_with_geometry_entries", run_denom, "run_loop")
  drill_metric("centered nested bypasses", "centered_editor_with_geometry_nested_bypasses", run_denom, "run_loop")
  file:write("  Draw/redraw metrics:\n")
  drill_metric("docview line hint calls", "docview_line_hint_calls", redraw_denom, "redraw")
  drill_metric("docview line hint drawn", "docview_line_hint_drawn", redraw_denom, "redraw")
  drill_metric("docview line hint total ms", "docview_line_hint_ms", redraw_denom, "redraw")
  drill_metric("docview line hint get ms", "docview_line_hint_get_ms", redraw_denom, "redraw")
  drill_metric("docview line hint layout ms", "docview_line_hint_layout_ms", redraw_denom, "redraw")
  drill_metric("docview line hint measure ms", "docview_line_hint_measure_ms", redraw_denom, "redraw")
  drill_metric("docview line hint truncate ms", "docview_line_hint_truncate_ms", redraw_denom, "redraw")
  drill_metric("docview line hint draw ms", "docview_line_hint_draw_ms", redraw_denom, "redraw")
  drill_metric("linewrap draw_text calls", "linewrapping_draw_line_text_calls", redraw_denom, "redraw")
  drill_metric("linewrap draw_text ms", "linewrapping_draw_line_text_ms", redraw_denom, "redraw")
  drill_metric("linewrap draw_text rows", "linewrapping_draw_line_text_rows", redraw_denom, "redraw")
  drill_metric("linewrap draw_text segments", "linewrapping_draw_line_text_segments", redraw_denom, "redraw")
  drill_metric("linewrap draw_text bytes", "linewrapping_draw_line_text_bytes", redraw_denom, "redraw")
  drill_metric("linewrap known-bound segments", "linewrapping_draw_line_text_known_bounds_segments", redraw_denom, "redraw")
  drill_metric("filetree line hint calls", "filetree_line_hint_calls", redraw_denom, "redraw")
  drill_metric("filetree line hint total ms", "filetree_line_hint_ms", redraw_denom, "redraw")
  drill_metric("filetree get_file_info calls", "filetree_line_hint_get_file_info_calls", redraw_denom, "redraw")
  drill_metric("filetree get_file_info ms", "filetree_line_hint_get_file_info_ms", redraw_denom, "redraw")
  drill_metric("filetree line hint format ms", "filetree_line_hint_format_ms", redraw_denom, "redraw")
  drill_metric("filetree line hint git ms", "filetree_line_hint_git_ms", redraw_denom, "redraw")
  drill_metric("filetree line hint entry ms", "filetree_line_hint_entry_ms", redraw_denom, "redraw")
  drill_metric("filetree entry snapshot hits", "filetree_entry_snapshot_hits", run_denom, "run_loop")
  drill_metric("filetree entry snapshot builds", "filetree_entry_snapshot_builds", run_denom, "run_loop")
  drill_metric("filetree entry snapshot rows", "filetree_entry_snapshot_rows", run_denom, "run_loop")
  drill_metric("filetree entry snapshot build ms", "filetree_entry_snapshot_build_ms", run_denom, "run_loop")
  drill_metric("filetree folder row bg rects", "filetree_folder_row_background_rects", redraw_denom, "redraw")
  drill_metric("filetree folder row bg ms", "filetree_folder_row_background_ms", redraw_denom, "redraw")
  drill_metric("filetree line_is_dir calls", "filetree_line_is_dir_calls", redraw_denom, "redraw")
  drill_metric("filetree line_is_dir ms", "filetree_line_is_dir_ms", redraw_denom, "redraw")
  drill_metric("filetree draw_line_body ms", "filetree_draw_line_body_ms", redraw_denom, "redraw")
  drill_metric("filetree draw_line_text ms", "filetree_draw_line_text_ms", redraw_denom, "redraw")

  file:write("  UI update metrics:\n")
  drill_metric("docview update total ms", "docview_update_ms", update_denom, "update")
  drill_metric("docview update cache ms", "docview_update_cache_ms", update_denom, "update")
  drill_metric("docview update selection ms", "docview_update_selection_ms", update_denom, "update")
  drill_metric("docview scroll-to-visible ms", "docview_scroll_to_make_visible_ms", update_denom, "update")
  drill_metric("docview update blink ms", "docview_update_blink_ms", update_denom, "update")
  drill_metric("docview active focus ms", "docview_update_active_focus_ms", update_denom, "update")
  drill_metric("docview update IME ms", "docview_update_ime_ms", update_denom, "update")
  drill_metric("docview super update ms", "docview_update_super_ms", update_denom, "update")
  drill_metric("IME set_location calls", "ime_set_location_calls", update_denom, "update")
  drill_metric("IME set_location ms", "ime_set_location_ms", update_denom, "update")
  drill_metric("IME changed calls", "ime_set_location_changed", update_denom, "update")
  drill_metric("IME system rect ms", "ime_set_location_system_ms", update_denom, "update")
  drill_metric("linewrap update_docview calls", "linewrapping_update_docview_breaks_calls", update_denom, "update")
  drill_metric("linewrap update_docview ms", "linewrapping_update_docview_breaks_ms", update_denom, "update")
  drill_metric("linewrap width-changed calls", "linewrapping_update_docview_breaks_width_changed", update_denom, "update")
  drill_metric("linewrap text-changed calls", "linewrapping_update_docview_breaks_text_changed", update_denom, "update")
  drill_metric("linewrap line-count-changed calls", "linewrapping_update_docview_breaks_line_count_changed", update_denom, "update")
  drill_metric("linewrap line-render invalidation reconstructs", "linewrapping_reconstruct_line_render_invalidation_calls", update_denom, "update")
  drill_metric("linewrap reconstruct calls", "linewrapping_reconstruct_breaks_calls", update_denom, "update")
  drill_metric("linewrap reconstruct ms", "linewrapping_reconstruct_breaks_ms", update_denom, "update")
  drill_metric("linewrap reconstruct lines", "linewrapping_reconstruct_breaks_lines", update_denom, "update")
  drill_metric("linewrap async reconstruct calls", "linewrapping_async_reconstruct_calls", update_denom, "update")
  drill_metric("linewrap async reconstruct lines", "linewrapping_async_reconstruct_lines", update_denom, "update")
  drill_metric("linewrap async reconstruct ms", "linewrapping_async_reconstruct_ms", update_denom, "update")
  drill_metric("linewrap async reconstruct yields", "linewrapping_async_reconstruct_yields", update_denom, "update")
  drill_metric("linewrap async reconstruct commits", "linewrapping_async_reconstruct_commits", update_denom, "update")
  drill_metric("linewrap async reconstruct cancelled", "linewrapping_async_reconstruct_cancelled", update_denom, "update")
  drill_metric("linewrap async reconstruct restarts", "linewrapping_async_reconstruct_restarts", update_denom, "update")
  drill_metric("linewrap update_breaks calls", "linewrapping_update_breaks_calls", update_denom, "update")
  drill_metric("linewrap update_breaks ms", "linewrapping_update_breaks_ms", update_denom, "update")
  drill_metric("linewrap update_breaks lines", "linewrapping_update_breaks_lines", update_denom, "update")
  drill_metric("linewrap compute calls", "linewrapping_compute_line_breaks_calls", update_denom, "update")
  drill_metric("linewrap compute ms", "linewrapping_compute_line_breaks_ms", update_denom, "update")
  drill_metric("linewrap compute bytes", "linewrapping_compute_line_breaks_bytes", update_denom, "update")
  drill_metric("linewrap compute splits", "linewrapping_compute_line_breaks_splits", update_denom, "update")
  drill_metric("core root_panel update ms", "core_root_panel_update_ms", update_denom, "update")
  drill_metric("core tool_window update ms", "core_tool_window_update_ms", update_denom, "update")
  drill_metric("rootpanel update ms", "rootpanel_update_ms", update_denom, "update")
  drill_metric("rootpanel copy position ms", "rootpanel_copy_position_ms", update_denom, "update")
  drill_metric("rootpanel initial layout ms", "rootpanel_initial_layout_ms", update_denom, "update")
  drill_metric("rootpanel node update ms", "rootpanel_node_update_ms", update_denom, "update")
  drill_metric("rootpanel final layout ms", "rootpanel_final_layout_ms", update_denom, "update")
  drill_metric("rootpanel drag overlay ms", "rootpanel_drag_overlay_ms", update_denom, "update")
  drill_metric("rootpanel defer open docs ms", "rootpanel_defer_open_docs_ms", update_denom, "update")
  drill_metric("node layout calls", "node_update_layout_calls", update_denom, "update")
  drill_metric("node layout leaf calls", "node_update_layout_leaf_calls", update_denom, "update")
  drill_metric("node layout split calls", "node_update_layout_split_calls", update_denom, "update")
  drill_metric("node layout ms", "node_update_layout_ms", update_denom, "update")
  drill_metric("node update calls", "node_update_calls", update_denom, "update")
  drill_metric("node update leaf calls", "node_update_leaf_calls", update_denom, "update")
  drill_metric("node update split calls", "node_update_split_calls", update_denom, "update")
  drill_metric("node update ms", "node_update_ms", update_denom, "update")
  drill_metric("node scroll tabs ms", "node_scroll_tabs_to_visible_ms", update_denom, "update")
  drill_metric("node active view update ms", "node_active_view_update_ms", update_denom, "update")
  drill_metric("node tab hover ms", "node_tab_hover_update_ms", update_denom, "update")
  drill_metric("node tab animation ms", "node_tab_animation_ms", update_denom, "update")
  file:write("\n")

  file:write("Draw scope aggregates (exclusive time identifies work owned by the scope itself):\n")
  file:write("Heap deltas are inclusive; heap_drop_calls counts captured scopes ending below their starting heap and is collection evidence, not a complete GC-cycle count.\n")
  file:write("calls,frames,total_inclusive_ms,total_exclusive_ms,avg_inclusive_ms,avg_exclusive_ms,max_inclusive_ms,max_exclusive_ms,lua_heap_delta_kb,lua_heap_drop_calls,path\n")
  local scope_aggregates = {}
  for _, row in pairs(record.scope_aggregates or {}) do scope_aggregates[#scope_aggregates + 1] = row end
  table.sort(scope_aggregates, function(a, b)
    if a.exclusive_ms == b.exclusive_ms then return a.path < b.path end
    return a.exclusive_ms > b.exclusive_ms
  end)
  for _, row in ipairs(scope_aggregates) do
    file:write(string.format(
      "%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%s\n",
      row.calls, row.frames, row.inclusive_ms, row.exclusive_ms,
      row.frames > 0 and row.inclusive_ms / row.frames or 0,
      row.frames > 0 and row.exclusive_ms / row.frames or 0,
      row.max_inclusive_ms, row.max_exclusive_ms,
      row.lua_heap_delta_kb or 0, row.lua_heap_drop_calls or 0,
      csv_escape(row.path)
    ))
  end
  if #scope_aggregates == 0 then file:write("  (none recorded)\n") end
  file:write("\n")

  file:write("Slow draw scope frames (draw_emit_ms > 10; lexical paths preserve the scope tree):\n")
  for _, frame in ipairs(record.slow_scope_frames or {}) do
    file:write(string.format(
      "Frame %d time=%.6f draw_emit_ms=%.3f lua_heap_delta_kb=%.3f scope_imbalance=%d\n",
      frame.index or 0, frame.time or 0, frame.draw_emit_ms or 0,
      frame.lua_heap_delta_kb or 0, frame.imbalance or 0
    ))
    for _, row in ipairs(sorted_scope_rows(frame.paths)) do
      local _, depth = row.path:gsub("/", "")
      file:write(string.format(
        "%s%s calls=%d inclusive_ms=%.3f exclusive_ms=%.3f heap_delta_kb=%.3f heap_drop_calls=%d\n",
        string.rep("  ", depth + 1), row.path, row.calls,
        row.inclusive_ms, row.exclusive_ms,
        row.lua_heap_delta_kb or 0, row.lua_heap_drop_calls or 0
      ))
    end
  end
  if #(record.slow_scope_frames or {}) == 0 then file:write("  (none recorded)\n") end
  file:write("\n")

  file:write("Slow Markdown model publication callbacks (top by elapsed_ms):\n")
  file:write("time,elapsed_ms,path,bytes,lines,generation,revision,incremental,changed_line1,changed_line2,native_parse_ms,native_total_ms,summary_ms,previous_close_ms,state_ms,notify_ms,listener_count,slowest_listener_ms,slowest_listener_id\n")
  for _, row in ipairs(record.markdown_model_publication_rows or {}) do
    file:write(string.format(
      "%.6f,%.3f,%s,%d,%d,%d,%d,%d,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%s\n",
      row.time or 0, row.elapsed_ms or 0, csv_escape(row.path), row.bytes or 0, row.lines or 0,
      row.generation or 0, row.revision or 0, row.incremental and 1 or 0,
      row.changed_line1 or 0, row.changed_line2 or 0,
      row.native_parse_ms or 0, row.native_total_ms or 0,
      row.summary_ms or 0, row.previous_close_ms or 0, row.state_ms or 0,
      row.notify_ms or 0, row.listener_count or 0, row.slowest_listener_ms or 0,
      csv_escape(row.slowest_listener_id)
    ))
  end
  file:write("\n")

  file:write("Slow Markdown Live Preview publication listeners (top by elapsed_ms):\n")
  file:write("time,elapsed_ms,path,bytes,lines,reason,generation,wrapped,active,visible,view_width,range_count,publication_lines,global_invalidation,reset_ms,fence_reconcile_ms,range_expand_ms,prune_images_ms,line_invalidate_ms,metric_invalidate_ms\n")
  for _, row in ipairs(record.markdown_view_publication_rows or {}) do
    file:write(string.format(
      "%.6f,%.3f,%s,%d,%d,%s,%d,%d,%d,%d,%.3f,%d,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f\n",
      row.time or 0, row.elapsed_ms or 0, csv_escape(row.path), row.bytes or 0, row.lines or 0,
      csv_escape(row.reason), row.generation or 0, row.wrapped and 1 or 0,
      row.active and 1 or 0, row.visible and 1 or 0, row.view_width or 0,
      row.range_count or 0, row.publication_lines or 0,
      row.global_invalidation and 1 or 0, row.reset_ms or 0,
      row.fence_reconcile_ms or 0, row.range_expand_ms or 0,
      row.prune_images_ms or 0, row.line_invalidate_ms or 0,
      row.metric_invalidate_ms or 0
    ))
  end
  file:write("\n")

  file:write("Slow linewrap compute calls (top by elapsed_ms):\n")
  file:write("elapsed_ms,line,bytes,visible_bytes,splits,width,mode,tokenized,ascii,has_space,has_tab,has_non_ascii,branch\n")
  for _, row in ipairs(record.linewrap_compute_rows or {}) do
    file:write(string.format(
      "%.3f,%d,%d,%d,%d,%.3f,%s,%d,%d,%d,%d,%d,%s\n",
      row.elapsed_ms, row.line, row.bytes, row.visible_bytes, row.splits, row.width,
      csv_escape(row.mode), row.tokenized and 1 or 0, row.ascii and 1 or 0,
      row.has_space and 1 or 0, row.has_tab and 1 or 0, row.has_non_ascii and 1 or 0,
      csv_escape(row.branch)
    ))
  end
  file:write("\n")

  file:write("Top Lua samples:\n")
  for i, row in ipairs(sorted_counts(record.lua_samples)) do
    if i > 30 then break end
    local pct = record.sample_count > 0 and (row.count * 100 / record.sample_count) or 0
    file:write(string.format("%6.2f%% %7d %s\n", pct, row.count, row.key))
  end

  file:write("\nObserved cache/geometry modes:\n")
  local mode_count = 0
  for _, row in ipairs(sorted_counts(record.detail_counts)) do
    if row.key:find("^markdown_live_provider_geometry:")
      or row.key:find("^centered_editor_geometry:")
      or row.key:find("^docview_visual_metric_signature_transition:")
    then
      mode_count = mode_count + 1
      file:write(string.format("%12.3f %s\n", row.count, row.key))
      if mode_count >= 40 then break end
    end
  end
  if mode_count == 0 then file:write("  (none recorded)\n") end

  file:write("\nTop perf detail counters/timers:\n")
  for i, row in ipairs(sorted_counts(record.detail_counts)) do
    if i > 60 then break end
    file:write(string.format("%12.3f %s\n", row.count, row.key))
  end

  file:write("\nTop API callers:\n")
  local total_api = 0
  for _, count in pairs(record.api_calls) do total_api = total_api + count end
  for i, row in ipairs(sorted_counts(record.api_calls)) do
    if i > 40 then break end
    local pct = total_api > 0 and (row.count * 100 / total_api) or 0
    file:write(string.format("%6.2f%% %7d %s\n", pct, row.count, row.key))
  end
  file:close()
end

function perf.is_recording()
  return recording
end

function perf.start_recording()
  if recording then return record and record.dir end
  local base = output_dir() .. PATHSEP .. timestamp_name()
  local frames_path = base .. "_frames.csv"
  local file = assert(io.open(frames_path, "wb"))
  local scope_path = base .. "_draw_scopes.csv"
  local scope_file = assert(io.open(scope_path, "wb"))
  write_frame_header(file)
  scope_file:write("frame,time,draw_emit_ms,path,calls,inclusive_ms,exclusive_ms,scope_heap_delta_kb,scope_heap_drop_calls,frame_heap_delta_kb,scope_imbalance\n")
  record = {
    base = base,
    frames_path = frames_path,
    summary_path = base .. "_summary.txt",
    samples_path = base .. "_lua_samples.csv",
    api_path = base .. "_api_calls.csv",
    detail_path = base .. "_details.csv",
    scope_path = scope_path,
    file = file,
    scope_file = scope_file,
    start_time = system.get_time(),
    stop_time = nil,
    iteration_count = 0,
    idle_iteration_count = 0,
    update_iteration_count = 0,
    redraw_update_iteration_count = 0,
    idle_update_iteration_count = 0,
    frame_count = 0,
    over_budget_count = 0,
    sleep_count = 0,
    sleep_actual_total_ms = 0,
    max_selection_count = 0,
    max_search_selection_count = 0,
    last_redraw_time = nil,
    slow_frames = {},
    slow_updates = {},
    linewrap_compute_rows = {},
    markdown_model_publication_rows = {},
    markdown_view_publication_rows = {},
    context = capture_recording_context(),
    redraw_intervals = {},
    lua_samples = {},
    sample_count = 0,
    api_calls = {},
    detail_counts = {},
    scope_frame_count = 0,
    scope_aggregates = {},
    slow_scope_frames = {},
  }
  draw_scope_frame = nil
  pending_draw_scope_frame = nil
  core.perf_draw_scope_active = false
  recording = true
  wrap_renderer_api("draw_text")
  wrap_renderer_api("draw_text_known_bounds")
  wrap_renderer_api("draw_rect")
  wrap_renderer_api("draw_rect_grid")
  wrap_system_api("get_file_info")
  wrap_system_api("list_dir")
  wrap_system_api("absolute_path")
  wrap_system_api("set_text_input_rect")
  wrap_system_api("window_has_focus")
  debug.sethook(hook, "", sample_interval)
  return frames_path
end

function perf.stop_recording()
  if not recording or not record then return nil end
  debug.sethook()
  unwrap_renderer_api()
  unwrap_system_api()
  record.stop_time = system.get_time()
  record.file:close()
  record.scope_file:close()
  write_counts_csv(record.samples_path, "samples,source", sorted_counts(record.lua_samples))
  write_counts_csv(record.api_path, "calls,api_source", sorted_counts(record.api_calls))
  write_counts_csv(record.detail_path, "value,metric", sorted_counts(record.detail_counts))
  write_summary(record.summary_path)
  local summary_path = record.summary_path
  recording = false
  record = nil
  draw_scope_frame = nil
  pending_draw_scope_frame = nil
  core.perf_draw_scope_active = false
  system.set_clipboard(summary_path)
  core.log("Performance recording saved: %s", summary_path)
  return summary_path
end

function perf.toggle_recording()
  if recording then
    return false, perf.stop_recording()
  else
    return true, perf.start_recording()
  end
end

return perf
