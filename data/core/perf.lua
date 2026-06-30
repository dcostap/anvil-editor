local core = require "core"

local perf = {}

local recording = false
local record = nil
local renderer_originals = {}
local system_originals = {}
local sample_interval = 10000

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
    branch = row.branch or "",
  }
  table.sort(rows, function(a, b) return a.elapsed_ms > b.elapsed_ms end)
  while #rows > 30 do table.remove(rows) end
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
  "docview_update_ms",
  "docview_update_cache_ms",
  "docview_update_selection_ms",
  "docview_scroll_to_make_visible_ms",
  "docview_update_blink_ms",
  "docview_update_active_focus_ms",
  "docview_update_ime_ms",
  "docview_update_super_ms",
  "ime_set_location_calls",
  "ime_set_location_ms",
  "ime_set_location_changed",
  "ime_set_location_system_ms",
  "linewrapping_update_docview_breaks_calls",
  "linewrapping_update_docview_breaks_ms",
  "linewrapping_update_docview_breaks_width_changed",
  "linewrapping_reconstruct_breaks_calls",
  "linewrapping_reconstruct_breaks_ms",
  "linewrapping_reconstruct_breaks_lines",
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
    "text_width_calls", "text_width_bytes", "text_width_chars", "text_width_shaped_runs", "text_width_unshaped_runs", "text_width_shape_probe_bytes", "text_width_hb_shapes", "text_width_shaped_cache_hits", "text_width_shaped_cache_misses", "text_width_hb_shape_ms",
    "text_render_calls", "text_render_bytes", "text_render_chars", "text_render_shaped_runs", "text_render_unshaped_runs", "text_render_shape_probe_bytes", "text_render_hb_shapes", "text_render_glyphs", "text_render_whitespace_chars", "text_render_chars_after_clip", "text_render_top_clip_breaks", "text_render_hb_shape_ms",
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
    "filetree_line_hint_calls", "filetree_line_hint_ms", "filetree_line_hint_get_file_info_calls", "filetree_line_hint_get_file_info_ms", "filetree_line_hint_format_ms", "filetree_line_hint_git_ms", "filetree_line_hint_segments", "filetree_line_hint_cache_hits", "filetree_line_hint_cache_misses", "filetree_line_hint_folder_count_hits", "filetree_line_hint_folder_count_pending", "filetree_line_hint_entry_calls", "filetree_line_hint_entry_ms", "filetree_line_hint_entry_rebuilds", "filetree_line_hint_entry_build_ms", "filetree_folder_row_background_calls", "filetree_folder_row_background_rects", "filetree_folder_row_background_ms", "filetree_line_is_dir_calls", "filetree_line_is_dir_ms", "filetree_draw_line_body_calls", "filetree_draw_line_body_ms", "filetree_draw_line_text_calls", "filetree_draw_line_text_ms", "filetree_draw_line_text_git_ms", "filetree_draw_line_text_colored_calls", "filetree_draw_line_text_plain_calls",
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
  "filetree_line_hint_entry_rebuilds",
  "filetree_line_hint_entry_build_ms",
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
}

local renderer_detail_keys = {
  "rencache_text_commands",
  "rencache_text_bytes",
  "rencache_max_text_bytes",
  "rencache_draw_text_ms",
  "rencache_draw_text_width_ms",
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

function perf.on_frame(snapshot)
  if not recording or not record or not snapshot then return end
  local now = snapshot.time or system.get_time()
  local renderer_stats = snapshot.did_redraw and renderer.get_last_frame_stats and renderer.get_last_frame_stats() or {}
  record.iteration_count = record.iteration_count + 1
  local ui_update_ms = math.max(
    snapshot.core_root_panel_update_ms or 0,
    snapshot.rootpanel_update_ms or 0,
    snapshot.update_ms or 0
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
    tostring(snapshot_value(snapshot, "filetree_line_hint_entry_rebuilds")),
    string.format("%.3f", snapshot.filetree_line_hint_entry_build_ms or 0),
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

local function write_summary(path)
  local file = io.open(path, "wb")
  if not file then return end
  local elapsed = record.stop_time - record.start_time
  file:write("Anvil performance recording\n")
  file:write(string.format("Elapsed: %.3fs\n", elapsed))
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
  file:write("time,total,run_threads,run_threads_runs,run_threads_slowest,run_threads_loc,core,gc,event_count,event,event_types,slowest_event,slowest_event_ms,command_calls,command_total,slowest_command,slowest_command_name,update,pre_draw,frame,draw_emit,renderer_end,present,draw_calls,docview_draw,docview_prepare,docview_prepare_caret,docview_prepare_selection,docview_gutter,docview_body,docview_text,docview_overlay,docview_text_calls,lsp_tokens_ms,lsp_offsets_ms,lsp_scan_ms,lsp_calls,lsp_hits,lsp_misses,doc_get_selections_calls,doc_get_selections_iters,doc_set_selections_calls,doc_set_selections_ms,statusbar_selection,pending_events,queue_depth\n")
  for _, row in ipairs(record.slow_frames or {}) do
    file:write(string.format(
      "%.6f,%.3f,%.3f,%d,%.3f,%s,%.3f,%.3f,%d,%.3f,%s,%s,%.3f,%d,%.3f,%.3f,%s,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%.3f,%.3f,%d,%d,%d,%d,%d,%d,%.3f,%.3f,%d,%d\n",
      row.time, row.total_ms, row.run_threads_ms, row.run_threads_runs,
      row.run_threads_slowest_ms, csv_escape(row.run_threads_slowest_loc),
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
  drill_metric("linewrap reconstruct calls", "linewrapping_reconstruct_breaks_calls", update_denom, "update")
  drill_metric("linewrap reconstruct ms", "linewrapping_reconstruct_breaks_ms", update_denom, "update")
  drill_metric("linewrap reconstruct lines", "linewrapping_reconstruct_breaks_lines", update_denom, "update")
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

  file:write("Slow linewrap compute calls (top by elapsed_ms):\n")
  file:write("elapsed_ms,line,bytes,visible_bytes,splits,width,mode,tokenized,ascii,has_space,branch\n")
  for _, row in ipairs(record.linewrap_compute_rows or {}) do
    file:write(string.format(
      "%.3f,%d,%d,%d,%d,%.3f,%s,%d,%d,%d,%s\n",
      row.elapsed_ms, row.line, row.bytes, row.visible_bytes, row.splits, row.width,
      csv_escape(row.mode), row.tokenized and 1 or 0, row.ascii and 1 or 0,
      row.has_space and 1 or 0, csv_escape(row.branch)
    ))
  end
  file:write("\n")

  file:write("Top Lua samples:\n")
  for i, row in ipairs(sorted_counts(record.lua_samples)) do
    if i > 30 then break end
    local pct = record.sample_count > 0 and (row.count * 100 / record.sample_count) or 0
    file:write(string.format("%6.2f%% %7d %s\n", pct, row.count, row.key))
  end

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
  write_frame_header(file)
  record = {
    base = base,
    frames_path = frames_path,
    summary_path = base .. "_summary.txt",
    samples_path = base .. "_lua_samples.csv",
    api_path = base .. "_api_calls.csv",
    detail_path = base .. "_details.csv",
    file = file,
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
    redraw_intervals = {},
    lua_samples = {},
    sample_count = 0,
    api_calls = {},
    detail_counts = {},
  }
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
  write_counts_csv(record.samples_path, "samples,source", sorted_counts(record.lua_samples))
  write_counts_csv(record.api_path, "calls,api_source", sorted_counts(record.api_calls))
  write_counts_csv(record.detail_path, "value,metric", sorted_counts(record.detail_counts))
  write_summary(record.summary_path)
  local summary_path = record.summary_path
  recording = false
  record = nil
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
