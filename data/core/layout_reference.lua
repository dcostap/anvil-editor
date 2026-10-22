-- Compare a Text View's layout with a fresh view of the same Buffer.
--
-- The fresh view builds every row again from the current text, providers,
-- folds, selection, focus, size and scroll. A difference is drift in the
-- layout that the view under test kept across its earlier changes.
--
-- This is a debug and test tool. Set ANVIL_LAYOUT_REFERENCE=1 to compare the
-- Editors that each Lua test opens, after the test passes.
local core = require "core"
local style = require "core.style"
local linewrapping = require "core.linewrapping"
local panes = require "core.panes"

local reference = {}

local MAX_REPORTED = 12

local function key_part(value)
  if type(value) == "number" and value % 1 == 0 then
    return string.format("%d", value)
  end
  return tostring(value)
end

local function row_key(entry)
  local fold = entry.type == "fold" and entry.fold
  return table.concat({
    tostring(entry.type), key_part(entry.line), key_part(entry.row_in_line),
    tostring(entry.placement or ""), tostring(entry.provider_id or ""),
    key_part(entry.provider_row_id or ""),
    fold and (key_part(fold.line1) .. "-" .. key_part(fold.line2)) or "",
  }, "|")
end

---Run `fn` while `view` has focus, when `focused` says the view under test has it.
local function with_focus(view, focused, fn, ...)
  if not focused then return fn(...) end
  local active = core.active_view
  core.active_view = view
  local ok, a, b = pcall(fn, ...)
  core.active_view = active
  if not ok then error(a, 0) end
  return a, b
end

---Run the layout work of the view's next frames.
local function settle(view)
  for _ = 1, 3 do
    view:update()
    linewrapping.complete_async_reconstruction(view)
    view:reconcile_visible_line_layout()
  end
end

---A name that tells apart the views of one Buffer.
local function view_name(view)
  return string.format("%s (%dx%d)", view.buffer:get_name(), view.size.x, view.size.y)
end

---Capture the observable layout of a view.
---@param view core.textview
---@return table snapshot
function reference.capture(view)
  local rows, lines = {}, {}
  local count = view:get_scrollable_line_count()
  for row = 1, count do
    local entry = view:get_metric_row_entry(row)
    local line, col = view:get_visual_row_line_col(row)
    rows[row] = {
      key = row_key(entry),
      line = line,
      col = col,
      height = view:get_visual_row_height(row),
      y = view:get_visual_row_y_offset(row),
    }
  end
  for line = 1, #view.buffer.lines do
    lines[line] = view:get_visual_row(line, 1)
  end
  return {
    rows = rows,
    lines = lines,
    scrollable_size = view:get_scrollable_size(),
    scroll_y = view.scroll.y,
    height = view.size.y,
  }
end

local function visible(snapshot, row)
  local top = snapshot.rows[row].y + style.padding.y - snapshot.scroll_y
  return top < snapshot.height and top + snapshot.rows[row].height > 0
end

---The screen point in the middle of each visible row.
local function hit_points(view, snapshot)
  local x, y = view:get_content_offset()
  x = x + view:get_gutter_width() + 1
  local points = {}
  for row = 1, #snapshot.rows do
    if visible(snapshot, row) then
      local r = snapshot.rows[row]
      points[#points + 1] = { row = row, x = x, y = y + style.padding.y + r.y + r.height / 2 }
    end
  end
  return points
end

local function resolve_points(view, points)
  local hits = {}
  for i, point in ipairs(points) do
    local line, col = view:resolve_screen_position(point.x, point.y)
    hits[i] = { line = line, col = col }
  end
  return hits
end

---Compare two snapshots and the hit tests of the views they came from.
local function diff(actual, expected, points, actual_hits, expected_hits)
  local report = { count = 0, mismatches = {}, kinds = {}, visible = 0 }
  local function add(kind, is_visible, fmt, ...)
    report.count = report.count + 1
    report.kinds[kind] = (report.kinds[kind] or 0) + 1
    if is_visible then report.visible = report.visible + 1 end
    if #report.mismatches < MAX_REPORTED then
      report.mismatches[#report.mismatches + 1] = string.format(
        "%s %s: " .. fmt, kind, is_visible and "visible" or "offscreen", ...)
    end
  end

  if #actual.rows ~= #expected.rows then
    add("row-count", true, "%d rows, reference %d", #actual.rows, #expected.rows)
  end
  local y_drift
  for row = 1, math.min(#actual.rows, #expected.rows) do
    local a, e = actual.rows[row], expected.rows[row]
    local is_visible = visible(expected, row)
    if a.key ~= e.key or a.line ~= e.line or a.col ~= e.col then
      add("row", is_visible, "row %d: %s at %d:%d, reference %s at %d:%d",
        row, a.key, a.line, a.col, e.key, e.line, e.col)
    end
    if a.height ~= e.height then
      add("height", is_visible, "row %d (line %d): %s, reference %s", row, e.line, a.height, e.height)
    end
    -- One wrong height moves every later row, so report only where y drifts first.
    if not y_drift and a.y ~= e.y then
      y_drift = row
      add("y", is_visible, "row %d (line %d): %s, reference %s", row, e.line, a.y, e.y)
    end
  end
  for line = 1, math.min(#actual.lines, #expected.lines) do
    if actual.lines[line] ~= expected.lines[line] then
      local row = expected.lines[line]
      add("line-row", expected.rows[row] ~= nil and visible(expected, row),
        "line %d: row %d, reference %d", line, actual.lines[line], row)
    end
  end
  if actual.scrollable_size ~= expected.scrollable_size then
    add("size", false, "scrollable size %s, reference %s", actual.scrollable_size, expected.scrollable_size)
  end
  for i, point in ipairs(points) do
    local a, e = actual_hits[i], expected_hits[i]
    if a.line ~= e.line or a.col ~= e.col then
      add("hit", true, "row %d: %d:%d, reference %d:%d", point.row, a.line, a.col, e.line, e.col)
    end
  end

  local kinds = {}
  for kind, n in pairs(report.kinds) do kinds[#kinds + 1] = kind .. "=" .. n end
  table.sort(kinds)
  report.ok = report.count == 0
  report.summary = report.ok and "layout matches a fresh view"
    or string.format("%d layout mismatch(es), %d visible: %s",
      report.count, report.visible, table.concat(kinds, " "))
  return report
end

local function sync_folds(view, ref)
  for _, fold in ipairs(view.fold_regions or {}) do
    if view:refresh_fold_region(fold) then
      local match
      for _, candidate in ipairs(ref.fold_regions or {}) do
        if candidate.kind == fold.kind and candidate.line1 == fold.line1
          and candidate.line2 == fold.line2
        then
          match = candidate
          break
        end
      end
      if not match then
        ref:add_fold_region {
          line1 = fold.line1, col1 = fold.col1, line2 = fold.line2, col2 = fold.col2,
          collapsed = fold.collapsed, placeholder = fold.placeholder,
          show_widget = fold.show_widget, allow_nested = fold.allow_nested,
          kind = fold.kind, metadata = fold.metadata,
        }
      elseif match.collapsed ~= fold.collapsed then
        if fold.collapsed then
          ref:collapse_fold_region(match, "layout-reference")
        else
          ref:expand_fold_region(match, "layout-reference")
        end
      end
    end
  end
end

-- Providers that the view's class and Live Preview do not install, such as
-- a diff view's rows, are presentation inputs too.
local PROVIDER_KINDS = {
  { field = "visual_row_providers", add = "add_visual_row_provider" },
  { field = "visual_metric_providers", add = "add_visual_metric_provider" },
  { field = "line_render_providers", add = "add_line_render_provider" },
}

local function copy_providers(view, ref)
  for _, kind in ipairs(PROVIDER_KINDS) do
    for id, entry in pairs(view[kind.field] or {}) do
      if not (ref[kind.field] and ref[kind.field][id]) then
        ref[kind.add](ref, id, entry.provider, { priority = entry.priority })
      end
    end
  end
end

local function sync_scroll(view, ref)
  ref.scroll.x, ref.scroll.to.x = view.scroll.x, view.scroll.x
  ref.scroll.y, ref.scroll.to.y = view.scroll.y, view.scroll.y
  ref.scroll.move_data_x, ref.scroll.move_data_y = nil, nil
  -- A wide Markdown table scrolls inside its own frame.
  for line1, state in pairs(view.__markdown_table_scroll or {}) do
    local copy = require("core.markdown.table_presentation").scroll_state(ref, line1)
    copy.x, copy.to = state.x, state.x
  end
end

local function settle_reference(view, ref)
  for _ = 1, 3 do
    sync_scroll(view, ref)
    settle(ref)
    copy_providers(view, ref)
    sync_folds(view, ref)
  end
  sync_scroll(view, ref)
  ref:reconcile_visible_line_layout()
  linewrapping.complete_async_reconstruction(ref)
end

---Give a fresh view the same presentation inputs as `view`.
local function prepare(view, ref, focused)
  ref.position.x, ref.position.y = view.position.x, view.position.y
  ref.size.x, ref.size.y = view.size.x, view.size.y
  ref:set_selection_state(view:get_selection_state())
  ref:restore_owned_feature_state(view:get_owned_feature_state())
  ref.__wrapping_user_override = view.__wrapping_user_override
  if view.__markdown_live_attached then
    require("core.markdown.live_render").refresh_view(ref)
  end
  ref:set_wrapping_enabled(view:is_wrapping_enabled())
  with_focus(ref, focused, settle_reference, view, ref)
end

local function same_snapshot(a, b)
  if #a.rows ~= #b.rows or a.scrollable_size ~= b.scrollable_size then return false end
  for row = 1, #a.rows do
    local ra, rb = a.rows[row], b.rows[row]
    if ra.key ~= rb.key or ra.height ~= rb.height or ra.y ~= rb.y then return false end
  end
  return true
end

local function same_selections(a, b)
  if #a.selections ~= #b.selections then return false end
  for i = 1, #a.selections do
    if a.selections[i] ~= b.selections[i] then return false end
  end
  return true
end

---Return why `view` cannot be compared now, or nil when it can.
function reference.pending_reason(view)
  if view.textview_closed then return "closed" end
  if view.size.x <= 0 or view.size.y <= 0 then return "no size" end
  if view.__presentation_reload_frozen then return "presentation reload" end
  if view.__markdown_live_attached then
    local instance = require("core.markdown.model").peek(view.buffer)
    -- Without a model, the reference would open one and measure before it publishes.
    if not instance then return "no Markdown model" end
    if instance.status ~= "ready"
      or instance.published_revision ~= view.buffer.text_revision
    then
      return "Markdown model publication"
    end
    -- An open note editor sizes its card from text that is not in the Buffer yet.
    if require("core.markdown.footnotes").editing_input(view) then
      return "footnote editor open"
    end
  end
end

-- Frames that UI-thread work gets before the views are measured.
local UI_FRAMES = 3
-- The longest wait for async work, such as a Markdown parse.
local ASYNC_DEADLINE = 5

---Let the UI run frames until the async work of `view` finishes:
---UI-thread work such as Markdown reference definitions, Markdown publication,
---and the background scan for an unwrapped view's widest line. That width
---decides the horizontal scrollbar, which adds to the scrollable size.
local function wait_for_async(view)
  local deadline = system.get_time() + ASYNC_DEADLINE
  for _ = 1, UI_FRAMES do coroutine.yield(0) end
  view:get_h_content_size()
  while (reference.pending_reason(view) == "Markdown model publication"
      or view:is_horizontal_extent_scan_pending())
    and system.get_time() < deadline
  do
    local pool = require("core.worker_pool").current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    coroutine.yield(0.01)
    view:get_h_content_size()
  end
end

---Compare `view` with a fresh view of the same Buffer.
---Both views first run the layout work of their next frames. Without
---`opts.ui_frames`, the caller must let async work finish first; see pending_reason.
---@param view core.textview
---@param opts? { ui_frames: boolean? } Let the UI run frames for async work. Call from a coroutine.
---@return table report { ok, count, visible, kinds, mismatches, summary }
function reference.compare(view, opts)
  local ui_frames = opts and opts.ui_frames
  -- Earlier work, such as a style change, settles before the first measurement.
  if ui_frames then wait_for_async(view) end
  local pending = reference.pending_reason(view)
  if pending then return { ok = true, skipped = pending, summary = "skipped: " .. pending } end
  local focused = core.active_view == view
  view:get_h_content_size()
  settle(view)
  local before = reference.capture(view)
  local selection = view:get_selection_state()
  local scroll_y = view.scroll.y
  local ref
  local in_pane = panes.pane_for_view(view) ~= nil
  local ok, report = pcall(function()
    ref = getmetatable(view)(view.buffer)
    -- Pane membership is a presentation input. A centered Editor uses it for its wrap width.
    if in_pane then panes.register_focus_target(view, ref) end
    prepare(view, ref, focused)
    ref:get_h_content_size()
    if ui_frames then
      wait_for_async(ref)
      with_focus(ref, focused, settle_reference, view, ref)
    end
    settle(view)
    local actual = reference.capture(view)
    local expected = with_focus(ref, focused, reference.capture, ref)
    local points = hit_points(ref, expected)
    local expected_hits = with_focus(ref, focused, resolve_points, ref, points)
    local actual_hits = resolve_points(view, points)
    return diff(actual, expected, points, actual_hits, expected_hits)
  end)
  if ref then
    if in_pane then panes.unregister_focus_target(ref) end
    ref.discard_buffer_on_close = false
    ref:on_close()
  end
  if not ok then error(report, 0) end
  -- The view under test must not change while the reference is built.
  -- A change would hide the drift that this comparison looks for.
  local after = reference.capture(view)
  if view.scroll.y ~= scroll_y
    or not same_selections(view:get_selection_state(), selection)
    or not same_snapshot(after, before)
  then
    local change = diff(after, before, {}, {}, {})
    report.ok = false
    report.summary = string.format("the view under test changed during the comparison (%s, scroll %s to %s); %s",
      change.summary, scroll_y, view.scroll.y, report.summary)
    for _, line in ipairs(change.mismatches) do
      table.insert(report.mismatches, "changed " .. line)
    end
  end
  core.log_quiet("Layout reference for %s: %s", view_name(view), report.summary)
  for _, line in ipairs(report.mismatches) do
    core.log_quiet("Layout reference mismatch: %s", line)
  end
  return report
end

---Return the set of open Editors.
---@return table<core.editor, true>
function reference.open_editors()
  local Editor = require "core.editor"
  local views = {}
  for _, registered in pairs(require("core.textview").registry) do
    for view in pairs(registered) do
      if getmetatable(view) == Editor and not view.textview_closed then
        views[view] = true
      end
    end
  end
  return views
end

---Compare every open Editor that is not in `earlier`.
---@param earlier? table<core.editor, true> Editors to leave out, from open_editors
---@param opts? { ui_frames: boolean? } See compare
---@return string? failure A description of each mismatch, or nil
function reference.check_open_views(earlier, opts)
  local views = {}
  for view in pairs(reference.open_editors()) do
    if not (earlier and earlier[view]) then views[#views + 1] = view end
  end
  local failures = {}
  for _, view in ipairs(views) do
    local report = reference.compare(view, opts)
    if report.skipped then
      core.log_quiet("Layout reference skipped %s: %s", view_name(view), report.skipped)
    elseif not report.ok then
      failures[#failures + 1] = string.format("%s: %s\n  %s", view_name(view),
        report.summary, table.concat(report.mismatches, "\n  "))
    end
  end
  if #failures > 0 then return "Layout reference: " .. table.concat(failures, "\n") end
end

return reference
