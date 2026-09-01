local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local keymap = require "core.keymap"
local translate = require "core.buffer.translate"
local tokenizer = require "core.tokenizer"
local ime = require "core.ime"
local linewrapping = require "core.linewrapping"
local line_packets = require "core.textview_line_packets"
local language_intelligence = require "core.language_intelligence"
local range_marker = require "core.range_marker"
local copy_feedback = require "core.copy_feedback"
local Buffer = require "core.buffer"
local View = require "core.view"

local CACHE_LINE_LEN = 500
local LINE_HINT_ELLIPSIS = "…"

local IME_VIEW = nil
local IME_STATE = {line1 = 0, col1 = 0, line2 = 0, col2 = 0, w = 0, h = 0}

---@class core.textview.position
---@field line integer
---@field col integer
---@field offset number

---@class core.textview.ime_selection
---@field from integer
---@field size integer

---View for presenting Buffers with syntax highlighting and text behavior.
---Extends View to provide text editing capabilities including selection,
---scrolling, IME support, and rendering with syntax highlighting.
---@class core.textview : core.view
---@overload fun(buffer: core.buffer):core.textview
---@field super core.view
---@field buffer core.buffer
---@field font string
---@field last_x_offset core.textview.position
---@field ime_selection core.textview.ime_selection
---@field ime_status boolean
---@field hovering_gutter boolean
---@field cache_font renderer.font
---@field cache_font_size number
---@field cache_indent_size integer
---@field mouse_selecting table?
---@field last_line1 integer
---@field last_col1 integer
---@field last_line2 integer
---@field last_col2 integer
---@field hovered_render_fragment table?
local TextView = View:extend()

function TextView:__tostring() return "TextView" end

TextView.context = "workspace"

function TextView:is_wrapping_enabled()
  return not not self.wrapping_enabled
end

function TextView:has_wrapping()
  return self.wrapped_settings ~= nil
end

TextView.is_wrapped = TextView.has_wrapping

function TextView:clear_wrap_cache()
  linewrapping.clear_wrap_cache(self)
end

function TextView:compute_wrap_width()
  return linewrapping.compute_wrap_width(self)
end

local function capture_wrap_viewport_anchor(view, new_width)
  local settings = view.wrapped_settings
  if not settings or settings.width == new_width or not view.scroll then return end
  if view.wrapped_buffer_line_count ~= #view.buffer.lines
    or view.wrapped_text_revision ~= (view.buffer.text_revision or 0)
  then
    return
  end

  local scroll_y = math.max(0, view.scroll.y or 0)
  local row = view:get_visual_row_at_y(math.max(0, scroll_y - style.padding.y))
  local line, col = view:get_visual_row_line_col(row)
  if not line then return end
  return {
    line = line,
    col = col or 1,
    row_offset = scroll_y - style.padding.y - view:get_visual_row_y_offset(row),
    scroll_y = scroll_y,
  }
end

local function restore_wrap_viewport_anchor(view, anchor, expected_width)
  if not anchor or not view.wrapped_settings
    or view.wrapped_settings.width ~= expected_width
  then
    return
  end

  local row = view:get_visual_row(anchor.line, anchor.col)
  local anchored_y = style.padding.y + view:get_visual_row_y_offset(row) + anchor.row_offset
  local max_scroll = math.max(0, view:get_scrollable_size() - view.size.y)
  anchored_y = common.clamp(anchored_y, 0, max_scroll)
  local delta = anchored_y - anchor.scroll_y
  if delta ~= 0 then
    view.scroll.y = (view.scroll.y or 0) + delta
    view.scroll.to.y = (view.scroll.to.y or 0) + delta
  end
end

function TextView:update_wrap_cache()
  local width = self:compute_wrap_width()
  local anchor = capture_wrap_viewport_anchor(self, width)
  local result = linewrapping.update_textview_breaks(self, width)
  restore_wrap_viewport_anchor(self, anchor, width)
  return result
end

function TextView:set_wrapping_enabled(enabled)
  self.wrapping_enabled = not not enabled
  if self.wrapping_enabled then
    self:cancel_horizontal_extent_scan()
    if self.size and self.size.x > 0 then self:update_wrap_cache() end
  else
    self:clear_wrap_cache()
    line_packets.clear(self)
  end
end

function TextView:get_total_visual_lines()
  if self:has_composed_visual_rows() then return self:get_composed_visual_row_count() end
  return linewrapping.get_total_wrapped_lines(self)
end

function TextView:get_visual_row(line, col, line_end)
  if self:has_composed_visual_rows() then return self:get_composed_visual_row_for_position(line, col, line_end) end
  return linewrapping.get_line_idx_col_count(self, line, col, line_end)
end

function TextView:get_visual_row_line_col(idx)
  if self:has_composed_visual_rows() then
    local entry = self:get_visual_row_entry(idx)
    if entry and entry.type == "fold" then return entry.fold.line1, 1 end
    if entry and entry.wrapped_idx then return linewrapping.get_idx_line_col(self, entry.wrapped_idx) end
    return entry and entry.line or 1, 1
  end
  return linewrapping.get_idx_line_col(self, idx)
end

function TextView:get_visual_row_count_for_line(line)
  if self:has_collapsed_folds() then
    local hidden, fold = self:is_line_hidden_by_fold(line)
    if hidden then return 0 end
    if fold and fold.line1 == line then return 1 end
  end
  return linewrapping.get_wrapped_line_count(self, line)
end

function TextView:get_visual_row_bounds_for_line(line, row_idx)
  if self:has_collapsed_folds() then
    local hidden, fold = self:is_line_hidden_by_fold(line)
    if hidden then return nil, nil end
    if fold and fold.line1 == line then return 1, 1 end
  end
  if not self.wrapped_settings then return 1, #(self.buffer.lines[line] or "") + 1 end
  local first_idx = self.wrapped_line_to_idx[line]
  if not first_idx then return nil, nil end
  local idx = first_idx + math.max(0, (row_idx or 1) - 1)
  local row_line, row_start_col = linewrapping.get_idx_line_col(self, idx)
  if row_line ~= line then return nil, nil end
  local next_line, next_col = linewrapping.get_idx_line_col(self, idx + 1)
  local row_end_col = next_line == line and next_col or (#self.buffer.lines[line] + 1)
  return row_start_col, row_end_col
end

function TextView:iter_visible_wrap_rows_for_line(line, y)
  if self:has_collapsed_folds() then
    local hidden, fold = self:is_line_hidden_by_fold(line)
    if hidden then return function() return nil end end
    if fold and fold.line1 == line then
      local yielded = false
      return function()
        if yielded then return nil end
        yielded = true
        return 1, y
      end
    end
  end
  local first_idx = self.wrapped_line_to_idx and self.wrapped_line_to_idx[line]
  local total = first_idx and linewrapping.get_wrapped_line_count(self, line) or 1
  local lh = self:get_line_height()
  local _, content_y1, _, content_y2 = self:get_content_bounds()
  local first = math.max(1, math.floor((content_y1 - y) / lh) + 1)
  local last = math.min(total, math.floor((content_y2 - y) / lh) + 1)
  local row = first - 1
  return function()
    row = row + 1
    if row > last then return nil end
    return row, y + (row - 1) * lh
  end
end

local next_selection_owner_id = 0

TextView.registry = TextView.registry or setmetatable({}, { __mode = "k" })
TextView.fold_views_by_buffer = TextView.fold_views_by_buffer or setmetatable({}, { __mode = "k" })
TextView.mirror_owner = TextView.mirror_owner or setmetatable({}, { __mode = "k" })
TextView.owner_views = TextView.owner_views or TextView.session_views or setmetatable({}, { __mode = "v" })
TextView.session_views = TextView.owner_views -- deprecated compatibility alias

local register_fold_view
local unregister_fold_view

local function copy_array(t)
  local res = {}
  if t then
    for i = 1, #t do res[i] = t[i] end
  end
  return res
end

local function selection_states_equal(a, b)
  if not a or not b then return a == b end
  if (a.last_selection or 1) ~= (b.last_selection or 1) then return false end
  local as, bs = a.selections or {}, b.selections or {}
  if #as ~= #bs then return false end
  for i = 1, #as do
    if as[i] ~= bs[i] then return false end
  end
  return true
end

local function pack(...)
  return { n = select("#", ...), ... }
end

local function perf_frame_add(key, amount)
  if not core.perf_frame_stats then return end
  local perf = package.loaded["core.perf"]
  if perf and perf.frame_add then perf.frame_add(key, amount or 1) end
end

local function perf_detail(key, amount)
  local perf = package.loaded["core.perf"]
  if perf and perf.add_detail then perf.add_detail(key, amount or 1) end
end

local function perf_elapsed(key, start_time)
  if start_time then perf_frame_add(key, (system.get_time() - start_time) * 1000) end
end

local function perf_scope_begin(name, capture_heap)
  if not core.perf_draw_scope_active then return nil end
  local perf = package.loaded["core.perf"]
  return perf and perf.scope_begin and perf.scope_begin(name, capture_heap) or nil
end

local function perf_scope_end(token)
  if not token then return end
  local perf = package.loaded["core.perf"]
  if perf and perf.scope_end then perf.scope_end(token) end
end

local function file_open_view_update_begin(view)
  if not core.perf_file_open_tracking_active then return nil end
  local perf = package.loaded["core.perf"]
  return perf and perf.file_open_view_update_begin
    and perf.file_open_view_update_begin(view)
end

local function file_open_view_update_end(token)
  if not token then return end
  local perf = package.loaded["core.perf"]
  if perf and perf.file_open_view_update_end then perf.file_open_view_update_end(token) end
end

local function file_open_view_draw_begin(view)
  if not core.perf_file_open_tracking_active then return nil end
  local perf = package.loaded["core.perf"]
  return perf and perf.file_open_view_draw_begin
    and perf.file_open_view_draw_begin(view)
end

local function file_open_view_draw_end(token)
  if not token then return end
  local perf = package.loaded["core.perf"]
  if perf and perf.file_open_view_draw_end then perf.file_open_view_draw_end(token) end
end

local monospace_font_cache = setmetatable({}, { __mode = "k" })

local function font_looks_monospace(font)
  local size = font:get_size()
  local cached = monospace_font_cache[font]
  if cached and cached.size == size then return cached.value end
  local w = font:get_width(" ")
  local value = font:get_width("i") == w
    and font:get_width("W") == w
    and font:get_width("m") == w
    and font:get_width(".") == w
    and font:get_width("-") == w
  monospace_font_cache[font] = { size = size, value = value }
  return value
end

local function has_relevant_syntax_fonts(buffer)
  local syntax_name = tostring(buffer.syntax and buffer.syntax.name or ""):lower()
  local is_markdown = syntax_name:find("markdown", 1, true) ~= nil
  for name in pairs(style.syntax_fonts) do
    if is_markdown or not tostring(name):match("^markdown_") then
      return true
    end
  end
  return false
end

local ASCII_LIGATURE_SENSITIVE_PATTERN = "[=><!/*:.|&f%-]"

local function ascii_ligature_sensitive_byte(byte)
  return byte ~= nil
    and string.char(byte):find(ASCII_LIGATURE_SENSITIVE_PATTERN) ~= nil
end

local function has_ligature_sensitive_ascii(text)
  -- Keep this in sync with the renderer's text_needs_shaping() probes.
  -- Known monospace cell bounds are not exact for these shaped runs.
  return text:find(ASCII_LIGATURE_SENSITIVE_PATTERN) ~= nil
end

local function draw_text_known_advance(font, text, x, y, width, height, color, opts)
  local bounds_x = math.floor(x)
  local bounds_y = math.floor(y)
  renderer.draw_text_known_bounds(
    font, text, x, y,
    bounds_x,
    bounds_y,
    math.max(1, math.ceil(x + width - bounds_x)),
    math.max(1, math.ceil(y + height - bounds_y)),
    color,
    opts
  )
  -- The integer bounds conservatively describe the cached draw command; they
  -- are not the text advance. Returning their rounded width accumulates drift
  -- at every syntax-color boundary on fractional-width monospace fonts.
  return x + width
end

local function get_fast_ascii_monospace_x_offset(self, line, col, line_text, font)
  if col <= 1 then return 0 end
  if has_relevant_syntax_fonts(self.buffer) or not font_looks_monospace(font) then return nil end

  local change_id = self.buffer:get_change_id()
  local cache = self.__fast_ascii_col_x_cache
  if not cache or cache.change_id ~= change_id or cache.font ~= font or cache.font_size ~= font:get_size() then
    cache = { change_id = change_id, font = font, font_size = font:get_size(), lines = {} }
    self.__fast_ascii_col_x_cache = cache
  end

  local entry = cache.lines[line]
  if not entry or entry.text ~= line_text then
    entry = { text = line_text, fast = line_text:find("[\t\128-\255]") == nil }
    cache.lines[line] = entry
  end
  if not entry.fast then return nil end

  perf_frame_add("textview_get_col_x_offset_fast_ascii_calls", 1)
  return (col - 1) * font:get_width(" ")
end

local function with_wrapped_caret_affinity(textview, fn, ...)
  local old = textview.__use_wrapped_caret_affinity
  textview.__use_wrapped_caret_affinity = true
  local results = { pcall(fn, textview, ...) }
  textview.__use_wrapped_caret_affinity = old
  if not results[1] then error(results[2], 0) end
  return table.unpack(results, 2)
end

local function apply_resolved_line_end_affinity(textview)
  linewrapping.apply_resolved_line_end_affinity(textview)
  if textview.apply_resolved_line_render_position_row_affinity then
    textview:apply_resolved_line_render_position_row_affinity()
  end
end

local function draw_wrapped_search_match_segment(view, x1, y, x2, h, primary, outline)
  if x2 <= x1 then return end
  local bg, border = view:search_match_style(primary)
  if not outline then
    renderer.draw_rect(x1, y, x2 - x1, h, bg)
    return
  end
  local t = math.max(1, common.round(SCALE))
  renderer.draw_rect(x1, y, x2 - x1, t, border)
  renderer.draw_rect(x1, y + h - t, x2 - x1, t, border)
  renderer.draw_rect(x1, y, t, h, border)
  renderer.draw_rect(x2 - t, y, t, h, border)
end

local function get_wrapped_segment_bounds(view, line, col1, col2, idx1, idx2, idx)
  local row_line, row_start_col = linewrapping.get_idx_line_col(view, idx)
  if row_line ~= line then return nil, nil end
  local next_line, next_start_col = linewrapping.get_idx_line_col(view, idx + 1)
  local row_end_col = next_line == line and next_start_col or (#view.buffer.lines[line] + 1)
  local x1 = idx == idx1 and view:get_col_x_offset(line, col1, false) or view:get_col_x_offset(line, row_start_col, false)
  local x2 = idx == idx2 and view:get_col_x_offset(line, col2, false) or view:get_col_x_offset(line, row_end_col, true)
  return x1, x2
end

local function wrapped_row_geometry(view, y, first_idx, idx)
  local first_y_offset = view:get_visual_row_y_offset(first_idx)
  local row_y = y + view:get_visual_row_y_offset(idx) - first_y_offset
  return row_y, view:get_visual_row_height(idx)
end

local function draw_wrapped_search_match(view, line, col1, col2, x, y, idx0, primary, outline, visible_idx1, visible_idx2)
  if view:get_line_render(line) then
    for x1, row_y, x2, row_height in view:iter_text_range_screen_segments(
      line, col1, col2, x, y
    ) do
      draw_wrapped_search_match_segment(
        view, x1, row_y, x2, row_height, primary, outline
      )
    end
    return
  end
  local idx1 = linewrapping.get_line_idx_col_count(view, line, col1)
  local idx2 = linewrapping.get_line_idx_col_count(view, line, col2)
  local from_idx = math.max(idx1, visible_idx1 or idx1)
  local to_idx = math.min(idx2, visible_idx2 or idx2)
  for i = from_idx, to_idx do
    local x1, x2 = get_wrapped_segment_bounds(view, line, col1, col2, idx1, idx2, i)
    if x1 and x2 then
      local row_y, row_height = wrapped_row_geometry(view, y, idx0, i)
      draw_wrapped_search_match_segment(
        view, x + x1, row_y, x + x2, row_height, primary, outline
      )
    end
  end
end

local function new_selection_owner_id()
  next_selection_owner_id = next_selection_owner_id + 1
  return next_selection_owner_id
end

local function selection_count(selections)
  return math.max(1, math.floor(#(selections or {}) / 4))
end

local function normalize_selection_state(buffer, state, force)
  state = state or {}
  if not force and state.normalized and type(state.selections) == "table" and #state.selections >= 4 then
    state.last_selection = common.clamp(math.floor(tonumber(state.last_selection) or 1), 1, selection_count(state.selections))
    return state
  end

  local selections = state.selections or state
  local normalized = {}
  if type(selections) == "table" then
    for i = 1, #selections, 4 do
      local line1, col1 = selections[i], selections[i + 1]
      if not line1 or not col1 then break end
      local line2 = selections[i + 2] or line1
      local col2 = selections[i + 3] or col1
      line1, col1 = buffer:sanitize_position(line1, col1)
      line2, col2 = buffer:sanitize_position(line2, col2)
      normalized[#normalized + 1] = line1
      normalized[#normalized + 1] = col1
      normalized[#normalized + 1] = line2
      normalized[#normalized + 1] = col2
    end
  end
  if #normalized == 0 then
    local line, col = buffer:sanitize_position(1, 1)
    normalized = { line, col, line, col }
  end
  state.selections = normalized
  state.normalized = true
  state.last_selection = common.clamp(math.floor(tonumber(state.last_selection) or 1), 1, selection_count(normalized))
  return state
end

local function ensure_selection_state(state, buffer)
  if not state or type(state.selections) ~= "table" or #state.selections < 4 then
    return normalize_selection_state(buffer, state, true)
  end
  state.last_selection = common.clamp(math.floor(tonumber(state.last_selection) or 1), 1, selection_count(state.selections))
  return state
end

local function get_mirror_owner_view(buffer)
  local owner_id = TextView.mirror_owner[buffer]
  local view = owner_id and TextView.owner_views[owner_id]
  if view and view.buffer == buffer and view.selection_state then
    local view_owner_id = view.selection_state.owner_id or view.selection_state.session_id
    if view_owner_id == owner_id then return view end
  end
end

local function register_view(view)
  local buffer = view.buffer
  local views = TextView.registry[buffer]
  if not views then
    views = setmetatable({}, { __mode = "k" })
    TextView.registry[buffer] = views
  end
  views[view] = true
  local owner_id = view.selection_state.owner_id or view.selection_state.session_id
  view.selection_state.owner_id = owner_id
  view.selection_state.session_id = owner_id -- deprecated compatibility alias
  TextView.owner_views[owner_id] = view
  if not get_mirror_owner_view(buffer) then
    TextView.mirror_owner[buffer] = owner_id
  end
end

function TextView.get_buffer_mirror_owner_view(buffer)
  return get_mirror_owner_view(buffer)
end

function TextView.get_buffer_mirror_owner_id(buffer)
  local view = get_mirror_owner_view(buffer)
  return view and (view.selection_state.owner_id or view.selection_state.session_id)
end

---@deprecated Use `TextView.get_buffer_mirror_owner_id` instead.
function TextView.get_buffer_mirror_owner_session_id(buffer)
  core.deprecation_log("TextView.get_buffer_mirror_owner_session_id")
  return TextView.get_buffer_mirror_owner_id(buffer)
end

function TextView.count_registered_textviews(buffer)
  local count = 0
  local views = TextView.registry[buffer]
  if views then
    for view in pairs(views) do
      if view.buffer == buffer then count = count + 1 end
    end
  end
  return count
end

function TextView:owns_buffer_selection_mirror()
  return get_mirror_owner_view(self.buffer) == self
end

function TextView:get_selection_state()
  local selections = self.selection_state and self.selection_state.selections
  local last_selection = self.selection_state and self.selection_state.last_selection or 1
  if self.buffer.bound_selection_view == self then
    selections = self.buffer.selections
    last_selection = self.buffer.last_selection
  end
  local state = normalize_selection_state(self.buffer, {
    selections = copy_array(selections),
    last_selection = last_selection,
    normalized = true,
  })
  return {
    selections = copy_array(state.selections),
    last_selection = state.last_selection,
  }
end

function TextView:set_selection_state(state)
  local old_state = self:get_selection_state()
  local owner_id = self.selection_state and (self.selection_state.owner_id or self.selection_state.session_id) or new_selection_owner_id()
  self.selection_state = normalize_selection_state(self.buffer, {
    selections = copy_array(state and state.selections or state),
    last_selection = state and state.last_selection or 1,
    owner_id = owner_id,
  })
  self.selection_state.owner_id = owner_id
  self.selection_state.session_id = owner_id -- deprecated compatibility alias
  TextView.owner_views[owner_id] = self
  if self.buffer.bound_selection_view == self then
    self.buffer.selections = self.selection_state.selections
    self.buffer.last_selection = self.selection_state.last_selection
  elseif not self.buffer.bound_selection_view and self:owns_buffer_selection_mirror() then
    self:apply_selection_state()
  end
  local new_state = self:get_selection_state()
  if self.notify_selection_listeners and not selection_states_equal(old_state, new_state) then
    self:notify_selection_listeners("set", old_state, new_state)
  end
end

function TextView:capture_selection_state(old_state)
  old_state = old_state or self:get_selection_state()
  local owner_id = self.selection_state and (self.selection_state.owner_id or self.selection_state.session_id) or new_selection_owner_id()
  if self.selection_state and self.buffer.selections == self.selection_state.selections then
    self.selection_state.last_selection = self.buffer.last_selection
    self.selection_state.owner_id = owner_id
    self.selection_state.session_id = owner_id -- deprecated compatibility alias
  else
    self.selection_state = normalize_selection_state(self.buffer, {
      selections = copy_array(self.buffer.selections),
      last_selection = self.buffer.last_selection,
      owner_id = owner_id,
      normalized = true,
    })
    self.selection_state.owner_id = owner_id
    self.selection_state.session_id = owner_id -- deprecated compatibility alias
  end
  TextView.owner_views[owner_id] = self
  local new_state = self:get_selection_state()
  if self.notify_selection_listeners and not selection_states_equal(old_state, new_state) then
    self:notify_selection_listeners("capture", old_state, new_state)
  end
end

function TextView:apply_selection_state()
  normalize_selection_state(self.buffer, self.selection_state)
  self.buffer.selections = copy_array(self.selection_state.selections)
  self.buffer.last_selection = self.selection_state.last_selection
end

function TextView:become_selection_mirror_owner()
  local owner_id = self.selection_state.owner_id or self.selection_state.session_id
  self.selection_state.owner_id = owner_id
  self.selection_state.session_id = owner_id -- deprecated compatibility alias
  TextView.mirror_owner[self.buffer] = owner_id
  TextView.owner_views[owner_id] = self
  if not self.buffer.bound_selection_view then
    self:apply_selection_state()
  end
end

function TextView.refresh_buffer_selection_mirror(buffer)
  if buffer.bound_selection_view then return false end
  local view = get_mirror_owner_view(buffer)
  if view then
    view:apply_selection_state()
    return true
  end
  return false
end

function TextView.sync_buffer_mirror_owner_state(buffer)
  if buffer.bound_selection_view or buffer.__selection_text_adjusting then return end
  local view = get_mirror_owner_view(buffer)
  if view then view:capture_selection_state() end
end

function TextView.reset_registered_selection_states(buffer)
  local views = TextView.registry[buffer]
  if views then
    for view in pairs(views) do
      if view.buffer == buffer then
        view:set_selection_state({ selections = buffer.selections, last_selection = buffer.last_selection })
      end
    end
  end
  TextView.refresh_buffer_selection_mirror(buffer)
end

function TextView.sanitize_registered_selection_states(buffer)
  local views = TextView.registry[buffer]
  if views then
    for view in pairs(views) do
      if view.buffer == buffer and view.selection_state then
        normalize_selection_state(buffer, view.selection_state, true)
      end
    end
  end
  TextView.refresh_buffer_selection_mirror(buffer)
end

function TextView.snapshot_registered_selection_states(buffer)
  local snapshots = {}
  local views = TextView.registry[buffer]
  if views then
    for view in pairs(views) do
      if view.buffer == buffer then
        snapshots[view] = view:get_selection_state()
      end
    end
  end
  return snapshots
end

function TextView.restore_registered_selection_states(buffer, snapshots)
  for view, state in pairs(snapshots or {}) do
    if view.buffer == buffer then view:set_selection_state(state) end
  end
  TextView.sanitize_registered_selection_states(buffer)
end

function TextView.adjust_registered_selection_states(buffer, kind, active_view, ...)
  local views = TextView.registry[buffer]
  if views then
    for view in pairs(views) do
      if view.buffer == buffer and view.selection_state
      and view ~= active_view
      and view.selection_state.selections ~= buffer.selections then
        if kind == "insert" then
          buffer:adjust_selection_state_for_insert(view.selection_state, ...)
        elseif kind == "remove" then
          buffer:adjust_selection_state_for_remove(view.selection_state, ...)
        end
      end
    end
  end
  if not buffer.bound_selection_view then
    TextView.refresh_buffer_selection_mirror(buffer)
  end
end

function TextView.adjust_registered_selection_states_for_batch(buffer, active_view, mapper, transaction)
  local views = TextView.registry[buffer]
  if views then
    for view in pairs(views) do
      if view.buffer == buffer and view.selection_state
      and view ~= active_view
      and view.selection_state.selections ~= buffer.selections then
        local selections = view.selection_state.selections
        local mapped = {}
        for i = 1, #selections, 4 do
          local l1, c1 = mapper(selections[i], selections[i + 1])
          local l2, c2 = mapper(selections[i + 2], selections[i + 3])
          mapped[#mapped + 1] = l1
          mapped[#mapped + 1] = c1
          mapped[#mapped + 1] = l2
          mapped[#mapped + 1] = c2
        end
        view.selection_state.selections = mapped
        view.selection_state.normalized = false
        normalize_selection_state(buffer, view.selection_state, true)
      end
    end
  end
  if not buffer.bound_selection_view then
    TextView.refresh_buffer_selection_mirror(buffer)
  end
end

function TextView:with_selection_state(fn, ...)
  local buffer = self.buffer
  if buffer.bound_selection_view == self then
    return fn(...)
  end

  local old_self_selection_state = self:get_selection_state()
  local old_selections = buffer.selections
  local old_last_selection = buffer.last_selection
  local old_bound_view = buffer.bound_selection_view
  local old_bound_owner_id = buffer.bound_selection_owner_id or buffer.bound_selection_session_id

  -- If a nested binding suspends another view, make that view's owned state
  -- point at its current live compatibility table before it is hidden.  This
  -- lets inactive-edit adjustment update the suspended outer state instead of
  -- an older table that was superseded by a bound set_selection() call.
  if old_bound_view and old_bound_view.selection_state then
    old_bound_view.selection_state.selections = old_selections
    old_bound_view.selection_state.last_selection = old_last_selection
    old_bound_view.selection_state.owner_id = old_bound_owner_id
      or old_bound_view.selection_state.owner_id
    old_bound_view.selection_state.session_id = old_bound_view.selection_state.owner_id
  end

  local stack = buffer.__selection_binding_stack or {}
  buffer.__selection_binding_stack = stack
  stack[#stack + 1] = {
    view = self,
    old_bound_view = old_bound_view,
    old_selections = old_selections,
    old_last_selection = old_last_selection,
  }

  self.selection_state = ensure_selection_state(self.selection_state, buffer)
  if not self.selection_state.owner_id then
    self.selection_state.owner_id = self.selection_state.session_id or new_selection_owner_id()
  end
  self.selection_state.session_id = self.selection_state.owner_id -- deprecated compatibility alias
  TextView.owner_views[self.selection_state.owner_id] = self
  buffer.bound_selection_view = self
  buffer.bound_selection_owner_id = self.selection_state.owner_id
  buffer.bound_selection_session_id = self.selection_state.owner_id -- deprecated compatibility alias
  buffer.selections = self.selection_state.selections
  buffer.last_selection = self.selection_state.last_selection

  local args = pack(...)
  local ok, res = xpcall(function()
    return pack(fn(table.unpack(args, 1, args.n)))
  end, debug.traceback)

  local capture_ok, capture_err = xpcall(function()
    self:capture_selection_state(old_self_selection_state)
  end, debug.traceback)

  stack[#stack] = nil
  if #stack == 0 then buffer.__selection_binding_stack = nil end
  local restore_selections = old_selections
  local restore_last_selection = old_last_selection
  if old_bound_view and old_bound_view.selection_state then
    restore_selections = old_bound_view.selection_state.selections
    restore_last_selection = old_bound_view.selection_state.last_selection
  end
  buffer.selections = restore_selections
  buffer.last_selection = restore_last_selection
  buffer.bound_selection_view = old_bound_view
  buffer.bound_selection_owner_id = old_bound_owner_id
  buffer.bound_selection_session_id = old_bound_owner_id

  local mirror_ok, mirror_err = true, nil
  if not old_bound_view then
    mirror_ok, mirror_err = xpcall(function()
      TextView.refresh_buffer_selection_mirror(buffer)
    end, debug.traceback)
  end

  if not ok then error(res, 0) end
  if not capture_ok then error(capture_err, 0) end
  if not mirror_ok then error(mirror_err, 0) end
  return table.unpack(res, 1, res.n)
end

---Helper to move cursor vertically while preserving horizontal offset.
---@param dv core.textview
---@param line integer Current line
---@param col integer Current column
---@param offset integer Line offset (-1 for up, 1 for down)
---@return integer line New line number
---@return integer col New column number
local function move_to_line_offset(dv, line, col, offset)
  local xo = dv.last_x_offset
  if xo.line ~= line or xo.col ~= col then
    xo.offset = dv:get_col_x_offset(line, col)
  end
  xo.line = line + offset
  xo.col = dv:get_x_offset_col(line + offset, xo.offset)
  return xo.line, xo.col
end


TextView.translate = {
  ["previous_page"] = function(buffer, line, col, dv)
    local min, max = dv:get_visible_line_range()
    return line - (max - min), 1
  end,

  ["next_page"] = function(buffer, line, col, dv)
    if line == #buffer.lines then
      return #buffer.lines, #buffer.lines[line]
    end
    local min, max = dv:get_visible_line_range()
    return line + (max - min), 1
  end,

  ["previous_line"] = function(buffer, line, col, dv)
    if dv and dv.wrapped_settings then
      return linewrapping.wrapped_visual_line_position(dv, line, col, -1)
    end
    if line == 1 then
      return 1, 1
    end
    return move_to_line_offset(dv, line, col, -1)
  end,

  ["next_line"] = function(buffer, line, col, dv)
    if dv and dv.wrapped_settings then
      return linewrapping.wrapped_visual_line_position(dv, line, col, 1)
    end
    if line == #buffer.lines then
      return #buffer.lines, math.huge
    end
    return move_to_line_offset(dv, line, col, 1)
  end,
}


---Constructor - initializes a Text View.
---@param buffer core.buffer Buffer to display
function TextView:new(buffer)
  TextView.super.new(self)
  self.cursor = "ibeam"
  self.scrollable = true
  self.buffer = assert(buffer)
  local owner_id = new_selection_owner_id()
  self.selection_state = normalize_selection_state(self.buffer, {
    selections = copy_array(self.buffer.selections),
    last_selection = self.buffer.last_selection,
    owner_id = owner_id,
    session_id = owner_id, -- deprecated compatibility alias
    normalized = true,
  })
  register_view(self)
  self.buffer.cache.col_x = {}
  self.buffer.cache.line_width = {}
  self.__line_width_cache = {}
  self.buffer.cache.ulen = {}
  self.font = "code_font"
  self.last_x_offset = {}
  self.ime_selection = { from = 0, size = 0 }
  self.ime_status = false
  self.hovering_gutter = false
  self.show_current_line_highlight = true
  self.v_scrollbar:set_forced_status(config.force_scrollbar_status)
  self.h_scrollbar:set_forced_status(config.force_scrollbar_status)
  self.cache_font = self:get_font()
  self.cache_font_size = self.cache_font:get_size()
  self.__measurement_layout_scale = SCALE
  local _, indent_size = self.buffer:get_indent_info()
  self.cache_indent_size = indent_size
  self.fold_regions = {}
  self.fold_generation = 0
  self.__fold_next_id = 0
  self.visual_row_extensions = {}
  self.visual_row_providers = {}
  self.visual_metric_providers = {}
  self.__visual_metric_generation = 0
  self.line_render_providers = {}
  self.__line_render_generation = 0
  self.render_cache_diagnostics = {
    line_hits = 0,
    line_misses = 0,
    line_cold_misses = 0,
    line_signature_misses = 0,
    line_invalidations = 0,
    fragment_normalization_calls = 0,
    fragment_normalization_cache_hits = 0,
    fragment_normalization_builds = 0,
    metric_recomputations = 0,
    metric_invalidations = 0,
    metric_cache_hits = 0,
    metric_signature_cache_hits = 0,
    metric_signature_computations = 0,
    metric_signature_changes = 0,
    metric_full_rebuilds = 0,
    metric_full_rebuild_rows = 0,
    metric_dirty_passes = 0,
    metric_dirty_rows = 0,
    metric_row_splices = 0,
    metric_provider_queries = 0,
    metric_sparse_skips = 0,
  }
  self.decoration_providers = {}
  self.poi_providers = {}
  self.selection_listeners = {}
  self.scroll_listeners = {}
  self.fold_listeners = {}
  self.edit_guards = {}
  self.owned_features = {}
  self:add_owned_feature("core.textview-line-packets", {
    on_release = function(_, view)
      line_packets.clear(view)
    end,
  })
  register_fold_view(self)
  linewrapping.register_textview(self)
  self:set_wrapping_enabled(
    config.plugins.linewrapping.enable_by_default and not self.buffer.binary
  )
end


---Create a plain read-only Text View from generated text.
---@param text string Text to present
---@param opts? { name?: string, read_only_reason?: string }
---@return core.textview view
function TextView.from_text(text, opts)
  opts = opts or {}
  local buffer = Buffer()
  buffer.display_name = opts.name or "Text"
  buffer:insert(1, 1, tostring(text or ""))
  buffer:clear_undo_redo()
  buffer:clean()
  buffer.read_only = true
  buffer.read_only_reason = opts.read_only_reason or "This Buffer is read-only"
  return TextView(buffer)
end


function TextView:get_owned_feature_state()
  local state = {}
  for id, value in pairs(self.__pending_owned_feature_state or {}) do state[id] = value end
  for id, feature in pairs(self.owned_features or {}) do
    if feature.get_state then
      local ok, value = pcall(feature.get_state, feature, self)
      if ok and value ~= nil and state[id] == nil then state[id] = value
      elseif not ok then
        core.log_quiet("TextView owned feature %s state save failed for %s: %s", id, self.buffer:get_name(), tostring(value))
      end
    end
  end
  return next(state) and state or nil
end

function TextView:restore_owned_feature_state(state)
  for id, value in pairs(state or {}) do
    local feature = self.owned_features and self.owned_features[id]
    if feature and feature.set_state then
      local ok, err = pcall(feature.set_state, feature, self, value)
      if not ok then
        core.log_quiet("TextView owned feature %s state restore failed for %s: %s", id, self.buffer:get_name(), tostring(err))
        self.__pending_owned_feature_state = self.__pending_owned_feature_state or {}
        self.__pending_owned_feature_state[id] = value
      end
    else
      self.__pending_owned_feature_state = self.__pending_owned_feature_state or {}
      self.__pending_owned_feature_state[id] = value
    end
  end
end

function TextView:get_state()
  local selection_state = self:get_selection_state()
  return {
    filename = self.buffer.filename,
    selection = copy_array(selection_state.selections),
    selection_state = selection_state,
    scroll = { x = self.scroll.to.x, y = self.scroll.to.y },
    crlf = self.buffer.crlf,
    text = self.buffer.new_file and self.buffer:get_text(1, 1, math.huge, math.huge),
    language_mode = self.buffer.language_mode_override,
    inferred_language_mode = self.buffer.language_mode_inferred,
    owned_features = self:get_owned_feature_state(),
  }
end


---Register lifecycle state owned by this Text View.
---The feature's on_release(feature, view, reason) callback runs exactly once.
function TextView:add_owned_feature(id, feature)
  assert(type(id) == "string" and id ~= "", "owned feature id must be a non-empty string")
  assert(type(feature) == "table", "owned feature must be a table")
  self.owned_features = self.owned_features or {}
  local previous = self.owned_features[id]
  if previous == feature then return false end
  if previous then self:remove_owned_feature(id, "replaced") end
  self.owned_features[id] = feature
  local pending = self.__pending_owned_feature_state
  if pending and pending[id] ~= nil and feature.set_state then
    local ok, err = pcall(feature.set_state, feature, self, pending[id])
    if ok then
      pending[id] = nil
      if not next(pending) then self.__pending_owned_feature_state = nil end
    else
      core.log_quiet(
        "TextView owned feature %s deferred state restore failed for %s: %s",
        id, self.buffer:get_name(), tostring(err)
      )
    end
  end
  return true
end

function TextView:remove_owned_feature(id, reason)
  local features = self.owned_features
  local feature = features and features[id]
  if not feature then return false end
  features[id] = nil
  if feature.on_release then
    local ok, err = pcall(feature.on_release, feature, self, reason or "removed")
    if not ok then
      core.log_quiet(
        "TextView owned feature %s release failed for %s: %s",
        tostring(id), self.buffer:get_name(), tostring(err)
      )
    end
  end
  return true
end

function TextView:release_owned_features(reason)
  local ids = {}
  for id in pairs(self.owned_features or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do self:remove_owned_feature(id, reason or "released") end
  return #ids
end

---Request close approval without releasing Text View resources.
---@param approve function Callback to execute when close is approved.
function TextView:can_close(approve)
  -- A close policy can save or defer this View before the normal dirty prompt.
  -- Returning true means that the policy owns the approval decision.
  local close_handler = TextView.close_approval_handler
  if close_handler and close_handler(self, approve) then return end
  local references = core.buffer_registry
    and core.buffer_registry:reference_count(self.buffer)
    or #core.get_views_referencing_buffer(self.buffer)
  if self.buffer:is_dirty() and references <= 1 then
    core.global_prompt_bar:enter("Unsaved Changes; Confirm Close", {
      submit = function(_, item)
        if item.text:match("^[cC]") then
          self.discard_buffer_on_close = true
          approve()
        elseif item.text:match("^[sS]") then
          local ok, err = pcall(self.buffer.save, self.buffer)
          if ok then
            approve()
          elseif not tostring(err):find("file changed on disk", 1, true) then
            core.error("Couldn't save file \"%s\": %s", self.buffer.filename, err)
          end
        end
      end,
      suggest = function(text)
        local items = {}
        if not text:find("^[^cC]") then table.insert(items, "Close Without Saving") end
        if not text:find("^[^sS]") then table.insert(items, "Save And Close") end
        return items
      end
    })
  else
    approve()
  end
end

function TextView:on_close()
  if self.textview_closed then return end
  self.textview_closed = true
  self:cancel_horizontal_extent_scan()
  self:clear_fold_regions("view-close")
  unregister_fold_view(self)
  linewrapping.unregister_textview(self)
  self:release_owned_features("view-close")
end


---Get the display name for the tab, including a visible unsaved marker.
---@return string name Buffer display name
function TextView:get_name()
  local post = self.buffer:should_show_dirty_marker() and "*" or ""
  local name = self.buffer:get_name()
  return name:match("[^/%\\]*$") .. post
end


---Get the full filename path for display, with the home directory encoded.
---@return string filename Full display path or name
function TextView:get_filename()
  if self.buffer.abs_filename then
    local post = self.buffer:should_show_dirty_marker() and "*" or ""
    return common.home_encode(self.buffer.abs_filename) .. post
  end
  return self:get_name()
end


---Get the height reserved for the horizontal scrollbar, if it is visible.
---@return number height Reserved height in pixels
function TextView:get_horizontal_scrollbar_height()
  local _, _, _, h_scroll = self.h_scrollbar:get_track_rect()
  return math.max(0, h_scroll or 0)
end


---Get the vertical viewport height available for buffer rows.
---@return number height Viewport height in pixels
function TextView:get_vertical_viewport_height()
  return math.max(0, self.size.y - self:get_horizontal_scrollbar_height())
end


---Get the number of visual rows in the buffer scroll model.
---@return integer count Visual row count
function TextView:get_scrollable_line_count()
  if self:has_composed_visual_rows() then return self:get_composed_visual_row_count() end
  if self.wrapped_settings then return linewrapping.get_total_wrapped_lines(self) end
  return #self.buffer.lines
end


local function normalize_scroll_context_lines()
  return math.max(0, math.floor(tonumber(config.scroll_context_lines) or 0))
end


---Get the normal caret scroll context that can fit above and below the caret.
---@return integer count Context line count
function TextView:get_visible_scroll_context_lines()
  local lh = self:get_line_height()
  if lh <= 0 then return 0 end
  local visible_span = math.max(0, math.floor((self:get_vertical_viewport_height() - style.padding.y) / lh))
  return math.min(normalize_scroll_context_lines(), math.floor(visible_span / 2))
end


---Get the bottom overscroll context used when scroll-past-end is enabled.
---Keep this aligned with normal caret context so end-of-file scrolling moves
---smoothly into the same visible band instead of pinning the caret near the top.
---@return integer count Context line count
function TextView:get_scroll_past_end_context_lines()
  return self:get_visible_scroll_context_lines()
end


---Get scrollable height for a buffer with the given visual row count.
---@param line_count integer Visual row count
---@return number height Total scrollable height in pixels
function TextView:get_scrollable_size_for_line_count(line_count)
  line_count = math.max(1, math.floor(tonumber(line_count) or 1))
  local h_scroll = self:get_horizontal_scrollbar_height()
  local lh = self:get_line_height()
  local text_height = lh * line_count + style.padding.y * 2
  local content_height = text_height + h_scroll
  if config.scroll_past_end then
    local pad = self:get_scroll_past_end_context_lines()
    local last_line_y = style.padding.y + lh * math.max(0, line_count - 1)
    local max_scroll = math.max(0, last_line_y - self:get_vertical_viewport_height() + lh * (pad + 1))
    return math.max(self.size.y, max_scroll + self.size.y)
  end
  if content_height <= self.size.y then
    return self.size.y
  end
  return content_height
end


---Get the total scrollable height of the buffer.
---@return number height Total height in pixels
function TextView:get_scrollable_size()
  local cache = self:get_visual_row_metric_cache()
  if cache then
    local h_scroll = self:get_horizontal_scrollbar_height()
    local text_height = cache.total_height + style.padding.y * 2
    local content_height = text_height + h_scroll
    if config.scroll_past_end then
      local pad = self:get_scroll_past_end_context_lines()
      local last_line_y = style.padding.y + self:get_visual_row_y_offset(cache.row_count)
      local last_row_height = self:get_visual_row_height(cache.row_count)
      -- Only the final row contributes its specialized height here; the
      -- configurable context is still made of ordinary visual rows.
      local context_height = last_row_height + self:get_line_height() * pad
      local max_scroll = math.max(0, last_line_y - self:get_vertical_viewport_height() + context_height)
      return math.max(self.size.y, max_scroll + self.size.y)
    end
    return content_height <= self.size.y and self.size.y or content_height
  end
  return self:get_scrollable_size_for_line_count(self:get_scrollable_line_count())
end


-- Measuring the widest unwrapped line can be substantially more expensive than
-- the rest of a view update for large documents.  Keep this work out of the
-- synchronous scrollbar path.  The scheduler is cooperative, so the scan
-- still uses the normal renderer thread, but it is sliced between UI frames.
local UNWRAPPED_WIDTH_SCAN_BUDGET_MS = 2
local UNWRAPPED_WIDTH_SCAN_YIELD = 0.005
local UNWRAPPED_WIDTH_CHUNK_BYTES = 512
local UNWRAPPED_WIDTH_CHUNKS_PER_SLICE = 50

local function font_measurement_value(font, method, fallback)
  if type(font) == "table" then
    local parts = { "group", tostring(#font) }
    for _, child in ipairs(font) do
      parts[#parts + 1] = font_measurement_value(child, method, fallback)
    end
    return table.concat(parts, ":")
  end
  if not (font and font[method]) then return tostring(fallback) end
  local value = font[method](font)
  if type(value) ~= "table" then return tostring(value) end
  local parts = {}
  for i, item in ipairs(value) do parts[i] = tostring(item) end
  return table.concat(parts, ":")
end

local function append_measurement_font(parts, font)
  parts[#parts + 1] = tostring(font)
  parts[#parts + 1] = tostring(font and font:get_size())
  parts[#parts + 1] = font_measurement_value(font, "get_generation", 0)
  parts[#parts + 1] = font_measurement_value(font, "get_surface_scale", 1)
end

local function get_unwrapped_width_settings(self)
  local default_font = self:get_font()
  local _, indent_size = self.buffer:get_indent_info()
  local parts = {}
  append_measurement_font(parts, default_font)
  local names = {}
  if has_relevant_syntax_fonts(self.buffer) then
    for name in pairs(style.syntax_fonts) do names[#names + 1] = name end
    table.sort(names)
  end
  for _, name in ipairs(names) do
    parts[#parts + 1] = name
    append_measurement_font(parts, style.syntax_fonts[name])
  end
  local highlighter = self.buffer.highlighter
  parts[#parts + 1] = tostring(indent_size)
  parts[#parts + 1] = tostring(SCALE or 1)
  parts[#parts + 1] = tostring(highlighter.packet_reset_generation or 0)
  parts[#parts + 1] = tostring(core.render_style_generation or 0)
  parts[#parts + 1] = tostring(self.__line_render_generation or 0)
  parts[#parts + 1] = tostring(
    self.__line_render_invalidation_generation or 0
  )
  if self.has_line_render_providers and self:has_line_render_providers() then
    parts[#parts + 1] = tostring(self:get_presentation_layout_generation())
    for _, entry in ipairs(self:line_render_provider_entries()) do
      local provider = entry.provider
      local generation = provider and provider.generation
      if type(generation) == "function" then
        local ok, value = pcall(generation, provider, self)
        generation = ok and value or "generation-error"
      end
      parts[#parts + 1] = tostring(entry.id)
      parts[#parts + 1] = tostring(generation or 0)
    end
  end
  return {
    key = table.concat(parts, "\0"),
    font = default_font,
    font_size = default_font:get_size(),
    indent_size = indent_size,
    line_render_generation = self.__line_render_generation or 0,
    line_render_invalidation_generation =
      self.__line_render_invalidation_generation or 0,
  }
end

local function cancel_horizontal_extent_token(self, token)
  if not token then return false end
  token.cancelled = true
  local state = self.__horizontal_extent_state
  if state and state.scan == token then state.scan = nil end
  if token.thread_key then core.wake_thread(token.thread_key) end
  perf_frame_add("textview_async_horizontal_extent_cancellations", 1)
  core.log_quiet("Cancelled horizontal extent scan for %s", self.buffer:get_name())
  return true
end

local function horizontal_extent_state(self)
  local settings = get_unwrapped_width_settings(self)
  local revision = self.buffer.text_revision or 0
  local state = self.__horizontal_extent_state
  if not state or state.buffer ~= self.buffer or state.measurement_key ~= settings.key then
    local required_width = 0
    if state and self.scroll and self.size then
      local _, _, scroll_w = self.v_scrollbar:get_track_rect()
      local right_padding = math.max(style.padding.x, scroll_w or 0)
      local scroll_target = math.max(
        0, self.scroll.to.x or self.scroll.x or 0
      )
      required_width = math.max(
        0,
        scroll_target + self.size.x - self:get_gutter_width() - right_padding
      )
    end
    if state and state.scan then cancel_horizontal_extent_token(self, state.scan) end
    state = {
      buffer = self.buffer,
      measurement_key = settings.key,
      revision = revision,
      measured_width = 0,
      required_width = required_width,
    }
    self.__horizontal_extent_state = state
  elseif state.revision ~= revision then
    if state.scan then cancel_horizontal_extent_token(self, state.scan) end
    if state.exact_revision == state.revision then
      state.previous_exact_width = state.exact_width
    end
    state.revision = revision
    state.exact_width = nil
    state.exact_revision = nil
    state.measured_width = 0
    state.required_width = 0
    state.next_line = nil
    state.measurement = nil
  end
  state.settings = settings
  return state
end

local function unwrapped_width_scan_is_current(self, token)
  if not token or token.cancelled or self.buffer ~= token.buffer then return false end
  local state = self.__horizontal_extent_state
  if not state or state.scan ~= token or state.revision ~= token.text_revision
  or state.measurement_key ~= token.measurement_key then
    return false
  end
  local settings = get_unwrapped_width_settings(self)
  return settings.key == token.measurement_key
    and (self.buffer.text_revision or 0) == token.text_revision
end

local function line_source_end(text)
  return text:sub(-1) == "\n" and math.max(0, #text - 1) or #text
end

local function skip_pending_line_render(self, line)
  local owner = self.__markdown_live_owner
  local model = owner and owner.semantic_model
  local pending = owner and (
    owner.semantic_pending_line ~= nil
    or model and (
      model.status == "pending"
      or model.published_revision ~= self.buffer.text_revision
    )
  )
  return pending and (
    not owner.semantic_pending_line or line >= owner.semantic_pending_line
  ) or false
end

local function make_line_width_cursor(self, line, token)
  local text = self.buffer.lines[line] or ""
  local source_end = line_source_end(text)
  local default_font = token.font
  default_font:set_tab_size(token.indent_size)
  local skip_render = skip_pending_line_render(self, line)
  local render_line = not skip_render and self:get_line_render(line) or nil
  if render_line then
    local started = system.get_time()
    local width = self:get_col_x_offset(line, source_end + 1, nil, false)
    local elapsed = (system.get_time() - started) * 1000
    if elapsed >= UNWRAPPED_WIDTH_SCAN_BUDGET_MS then
      core.log_quiet(
        "Atomic custom Text View width measurement for %s:%d used %.1f ms",
        self.buffer:get_name(), line, elapsed
      )
    end
    return { done = true, width = width, source_bytes = source_end }
  end

  local fast_width = get_fast_ascii_monospace_x_offset(
    self, line, source_end + 1, text, default_font
  )
  if fast_width then
    return { done = true, width = fast_width, source_bytes = source_end }
  end

  local syntax_line = self.buffer.highlighter:get_line(line)
  if syntax_line.resume then
    return { waiting_for_tokens = true, width = 0 }
  end

  local token_started = system.get_time()
  local render_tokens = self.buffer.highlighter:get_render_line(line).tokens
  local token_ms = (system.get_time() - token_started) * 1000
  if token_ms >= UNWRAPPED_WIDTH_SCAN_BUDGET_MS then
    core.log_quiet(
      "Atomic Text View render-token production for %s:%d used %.1f ms",
      self.buffer:get_name(), line, token_ms
    )
  end
  return {
    done = source_end == 0,
    width = 0,
    source_end = source_end,
    source_col = 1,
    tokens = render_tokens,
    token_index = 1,
    token_byte = 1,
    default_font = default_font,
  }
end

local function ascii_measurement_boundary(text, index)
  local byte, next_byte = text:byte(index), text:byte(index + 1)
  return byte == 9 or byte == 32 or next_byte == 9 or next_byte == 32
    or not ascii_ligature_sensitive_byte(byte)
      and not ascii_ligature_sensitive_byte(next_byte)
end

local function ascii_measurement_chunk_end(text, first, limit, last)
  limit = math.min(last, limit)
  if limit >= last then return last end
  for i = limit, first, -1 do
    if ascii_measurement_boundary(text, i) then return i end
  end
  local normal_size = limit - first + 1
  local forward_limit = math.min(last - 1, first + normal_size * 4 - 1)
  for i = limit + 1, forward_limit do
    if ascii_measurement_boundary(text, i) then return i end
  end
  return nil
end

local function multibyte_measurement_chunk_end(text, first, limit, last)
  limit = math.min(last, limit)
  if limit >= last then return last end
  local function is_boundary(index)
    local byte, next_byte = text:byte(index), text:byte(index + 1)
    return byte == 9 or byte == 32 or next_byte == 9 or next_byte == 32
  end
  for i = limit, first, -1 do
    if is_boundary(i) then return i end
  end
  local normal_size = limit - first + 1
  local forward_limit = math.min(last - 1, first + normal_size * 4 - 1)
  for i = limit + 1, forward_limit do
    if is_boundary(i) then return i end
  end
  return nil
end

local function measure_line_width_chunk(self, line, token)
  local cursor = token.measurement
  if not cursor then
    cursor = make_line_width_cursor(self, line, token)
    token.measurement = cursor
    if cursor.done then return cursor.width, true, cursor.source_bytes or 0 end
    if cursor.waiting_for_tokens then return 0, false, 0, true end
  elseif cursor.waiting_for_tokens then
    local syntax_line = self.buffer.highlighter:get_line(line)
    if syntax_line.resume then return 0, false, 0, true end
    token.measurement = nil
    return measure_line_width_chunk(self, line, token)
  end

  while cursor.token_index <= #cursor.tokens do
    local token_type = cursor.tokens[cursor.token_index]
    local text = cursor.tokens[cursor.token_index + 1] or ""
    local available = math.max(0, cursor.source_end - cursor.source_col + 1)
    local remaining = math.min(#text - cursor.token_byte + 1, available)
    if remaining <= 0 then
      cursor.token_index = cursor.token_index + 2
      cursor.token_byte = 1
      if available <= 0 then
        cursor.done = true
        return cursor.width, true, 0
      end
    else
      local font = style.syntax_fonts[token_type] or cursor.default_font
      if font ~= cursor.default_font then font:set_tab_size(token.indent_size) end
      local first = cursor.token_byte
      local last = first + remaining - 1
      local chunk_limit = math.max(
        1, tonumber(self.__test_horizontal_extent_chunk_bytes)
          or UNWRAPPED_WIDTH_CHUNK_BYTES
      )
      local candidate = math.min(last, first + chunk_limit - 1)
      local chunk_end
      local multibyte_at = text:find("[\128-\255]", first)
      if multibyte_at and multibyte_at <= last then
        chunk_end = multibyte_measurement_chunk_end(
          text, first, candidate, last
        )
        if not chunk_end then
          chunk_end = last
        end
        if chunk_end - first + 1 > chunk_limit
        and not token.logged_atomic_multibyte then
          token.logged_atomic_multibyte = true
          core.log_quiet(
            "Atomic multibyte Text View width run for %s:%d has %d bytes",
            self.buffer:get_name(), line, chunk_end - first + 1
          )
        end
      else
        chunk_end = ascii_measurement_chunk_end(text, first, candidate, last)
        if not chunk_end then
          chunk_end = last
          if not token.logged_atomic_shaping then
            token.logged_atomic_shaping = true
            core.log_quiet(
              "Atomic shaping-sensitive Text View width run for %s:%d has %d bytes",
              self.buffer:get_name(), line, chunk_end - first + 1
            )
          end
        end
      end
      local chunk = text:sub(first, chunk_end)
      cursor.width = cursor.width + font:get_width(
        chunk, { tab_offset = cursor.width }
      )
      local bytes = #chunk
      cursor.token_byte = chunk_end + 1
      cursor.source_col = cursor.source_col + bytes
      if cursor.token_byte > #text then
        cursor.token_index = cursor.token_index + 2
        cursor.token_byte = 1
      end
      if cursor.source_col > cursor.source_end then cursor.done = true end
      return cursor.width, cursor.done, bytes
    end
  end
  cursor.done = true
  return cursor.width, true, 0
end

function TextView:cancel_horizontal_extent_scan()
  local state = self.__horizontal_extent_state
  return cancel_horizontal_extent_token(self, state and state.scan)
end

function TextView:is_horizontal_extent_scan_pending()
  local state = self.__horizontal_extent_state
  if state and state.scan
  and not unwrapped_width_scan_is_current(self, state.scan) then
    cancel_horizontal_extent_token(self, state.scan)
  end
  return state ~= nil and state.scan ~= nil
end

local function start_unwrapped_width_scan(self, state)
  if state.scan then return end
  local settings = state.settings
  local token = {
    buffer = self.buffer,
    state = state,
    measurement_key = state.measurement_key,
    font = settings.font,
    font_size = settings.font_size,
    indent_size = settings.indent_size,
    line_render_generation = settings.line_render_generation,
    line_render_invalidation_generation = settings.line_render_invalidation_generation,
    text_revision = state.revision,
    line_count = #self.buffer.lines,
    next_line = 1,
    max_line = 1,
    width = 0,
    work_ms = 0,
    yields = 0,
  }
  state.scan = token
  state.next_line = 1
  state.measured_width = 0
  perf_frame_add("textview_async_horizontal_extent_scans", 1)
  core.log_quiet("Started horizontal extent scan for %s", self.buffer:get_name())

  token.thread_key = core.add_background_thread(function()
    while unwrapped_width_scan_is_current(self, token) do
      local started = system.get_time()
      local lines, chunks = 0, 0
      local max_chunks = math.max(
        1, tonumber(self.__test_horizontal_extent_chunks_per_slice)
          or UNWRAPPED_WIDTH_CHUNKS_PER_SLICE
      )
      while token.next_line <= token.line_count do
        if not unwrapped_width_scan_is_current(self, token) then return end
        local line = token.next_line
        local width, done, bytes, blocked = measure_line_width_chunk(
          self, line, token
        )
        chunks = chunks + 1
        token.longest_chunk = math.max(token.longest_chunk or 0, bytes or 0)
        if width > state.measured_width then state.measured_width = width end
        if done then
          if width > token.width then
            token.width = width
            token.max_line = line
          end
          token.measurement = nil
          token.next_line = line + 1
          state.next_line = token.next_line
          lines = lines + 1
        end
        if chunks >= max_chunks
        or blocked
        or (system.get_time() - started) * 1000 >= UNWRAPPED_WIDTH_SCAN_BUDGET_MS
        then
          break
        end
      end
      token.work_ms = token.work_ms + (system.get_time() - started) * 1000
      perf_frame_add("textview_async_horizontal_extent_lines", lines)

      if not unwrapped_width_scan_is_current(self, token) then return end
      if token.next_line > token.line_count then
        state.exact_width = token.width
        state.exact_revision = token.text_revision
        state.previous_exact_width = token.width
        state.measured_width = token.width
        state.required_width = 0
        state.scan = nil
        perf_frame_add("textview_async_horizontal_extent_commits", 1)
        perf_frame_add("textview_async_horizontal_extent_ms", token.work_ms)
        perf_frame_add(
          "textview_async_horizontal_extent_longest_chunk",
          token.longest_chunk or 0
        )
        if token.yields > 0 then
          core.log_quiet(
            "Committed async horizontal extent for %s: lines=%d width=%.1f work_ms=%.1f yields=%d",
            self.buffer:get_name(), token.line_count, token.width,
            token.work_ms, token.yields
          )
        end
        self:clamp_scroll_position()
        self:sync_scrollbar_geometry()
        core.redraw = true
        return
      end

      token.yields = token.yields + 1
      perf_frame_add("textview_async_horizontal_extent_yields", 1)
      coroutine.yield(UNWRAPPED_WIDTH_SCAN_YIELD)
    end
    if state.scan == token then
      state.scan = nil
      core.redraw = true
    end
  end, token)
end

local function get_max_unwrapped_line_width(self)
  local state = horizontal_extent_state(self)
  if state.exact_revision == state.revision and state.exact_width then
    return state.exact_width
  end
  if state.scan and not unwrapped_width_scan_is_current(self, state.scan) then
    cancel_horizontal_extent_token(self, state.scan)
  end
  if not state.scan then start_unwrapped_width_scan(self, state) end
  return math.max(
    state.measured_width or 0,
    state.previous_exact_width or 0,
    state.required_width or 0
  )
end

local function require_unwrapped_horizontal_width(self, width)
  if self.wrapping_enabled then return end
  local state = horizontal_extent_state(self)
  if state.exact_revision == state.revision then return end
  width = math.max(0, tonumber(width) or 0)
  if width > (state.required_width or 0) then
    state.required_width = width
    core.log_quiet(
      "Expanded pending horizontal reveal for %s to %.1f",
      self.buffer:get_name(), width
    )
  end
end

local function get_max_line_render_horizontal_extent(self)
  local width = 0
  for _, entry in ipairs(self:line_render_provider_entries()) do
    local provider = entry.provider
    if provider.horizontal_extent then
      local ok, result = pcall(provider.horizontal_extent, provider, self)
      if ok then
        width = math.max(width, tonumber(result) or 0)
      else
        core.log_quiet(
          "TextView horizontal extent provider %s failed for %s: %s",
          entry.id, self.buffer:get_name(), tostring(result)
        )
      end
    end
  end
  return width
end

---Get the natural width of unwrapped text or overflowing rendered content.
---@return number width Horizontal content width in pixels
function TextView:get_h_content_size()
  local presentation_width = get_max_line_render_horizontal_extent(self)
  if self.wrapping_enabled and presentation_width <= 0 then return 0 end
  local gutter_width = self:get_gutter_width()
  local _, _, v_scroll_w = self.v_scrollbar:get_track_rect()
  local right_padding = math.max(style.padding.x, v_scroll_w or 0)
  local text_width = 0
  if not self.wrapping_enabled then
    text_width = get_max_unwrapped_line_width(self) or 0
  end
  return gutter_width + math.max(text_width, presentation_width) + right_padding
end

---Get the scrollable width for unwrapped text or overflowing rendered content.
---@return number width Total horizontal scrollable width in pixels
function TextView:get_h_scrollable_size()
  local content_width = self:get_h_content_size()
  if self.wrapping_enabled and content_width <= 0 then return 0 end
  return math.max(self.size.x, content_width)
end

---Clamp scrolling to the current exact or finite provisional range.
function TextView:clamp_scroll_position()
  local max = self:get_scrollable_size() - self.size.y
  self.scroll.to.y = common.clamp(self.scroll.to.y, 0, max)

  local horizontal = self:get_h_scrollable_size()
  max = horizontal - self.size.x
  self.scroll.to.x = common.clamp(self.scroll.to.x, 0, max)
end

function TextView:update_scrollbar()
  local presentation_width = get_max_line_render_horizontal_extent(self)
  local _, _, v_scroll_w = self.v_scrollbar:get_track_rect()
  local rendered_width = self:get_gutter_width() + presentation_width
    + math.max(style.padding.x, v_scroll_w or 0)
  local rendered_overflow = presentation_width > 0 and rendered_width > self.size.x
  self.h_scrollbar:set_forced_status(
    rendered_overflow and "expanded" or config.force_scrollbar_status
  )
  return TextView.super.update_scrollbar(self)
end


---Return the stable viewport width used by specialized Buffer presentations.
---Unlike `size.x`, this remains tied to the effective presentation area while
---a layout adapter temporarily substitutes drawing geometry.
---@return number width
function TextView:get_presentation_viewport_width()
  return self.size.x
end


---Return a cheap generation token for presentation geometry that can affect
---specialized line and row layout. Layout adapters should override this with
---a token that remains stable while they temporarily substitute draw geometry.
---@return any generation
function TextView:get_presentation_layout_generation()
  return self.size.x
end


---Get the font used for rendering text.
---@return renderer.font font The code font
function TextView:get_font()
  return style[self.font]
end


---Get the line height in pixels.
---@return integer height Line height including line spacing
function TextView:get_line_height()
  return math.floor(self:get_font():get_height() * config.line_height)
end

function TextView:has_visual_metric_providers()
  return next(self.visual_metric_providers or {}) ~= nil
end

function TextView:add_visual_metric_provider(id, provider, opts)
  assert(type(id) == "string" and id ~= "", "visual metric provider id must be a non-empty string")
  assert(type(provider) == "table", "visual metric provider must be a table")
  opts = opts or {}
  self.visual_metric_providers = self.visual_metric_providers or {}
  self.visual_metric_providers[id] = { id = id, provider = provider, priority = opts.priority or provider.priority or 0 }
  self.__visual_metric_provider_entries = nil
  self.__visual_metric_signature_state = nil
  self:invalidate_visual_metrics(id)
end

function TextView:remove_visual_metric_provider(id)
  if not self.visual_metric_providers or not self.visual_metric_providers[id] then return false end
  self.visual_metric_providers[id] = nil
  self.__visual_metric_provider_entries = nil
  self.__visual_metric_signature_state = nil
  self:invalidate_visual_metrics(id)
  return true
end

local metric_tree_add
local metric_tree_row_at_y
local metric_tree_build
local compute_visual_row_height

local function invalidate_visual_metric_rows(view, cache, row1, row2)
  row1 = common.clamp(math.floor(row1), 1, cache.row_count)
  row2 = common.clamp(math.floor(row2 or row1), row1, cache.row_count)
  cache.dirty_rows = cache.dirty_rows or {}
  for row = row1, row2 do cache.dirty_rows[row] = true end
  cache.invalidated_rows = (cache.invalidated_rows or 0) + row2 - row1 + 1
  view.render_cache_diagnostics.metric_invalidations =
    view.render_cache_diagnostics.metric_invalidations + row2 - row1 + 1
end

function TextView:invalidate_visual_metrics(_provider_id, line1, line2)
  self.__visual_metric_snapshot_kind = nil
  self.__visual_metric_snapshot_id = nil
  self.__visual_metric_snapshot_cache = nil
  local cache = self.__visual_metric_cache
  local wrap_change = self.__line_render_wrap_change
  self.__line_render_wrap_change = nil
  if line1 and not self:has_composed_visual_rows() then
    if not cache then return end
    if not self.wrapped_settings then
      invalidate_visual_metric_rows(self, cache, line1, line2)
      return
    end

    -- A wrapped logical line can own several metric rows. Preserve unaffected
    -- rows when the current wrap map still has the same total row count as the
    -- cache; otherwise row indices may have shifted and a full rebuild is the
    -- only safe option.
    local current_row_count = linewrapping.get_total_wrapped_lines(self)
    local current_wrap_generation = self.__wrap_layout_generation or 0
    local comparison_signature = self:get_visual_metric_signature(
      cache.wrap_layout_generation or current_wrap_generation,
      cache.row_count,
      cache.text_revision
    )
    local unchanged_except_wrap = cache.signature == comparison_signature
    if wrap_change
      and unchanged_except_wrap
      and cache.row_count == wrap_change.old_row_count
      and current_row_count == wrap_change.new_row_count
      and cache.wrap_layout_generation == wrap_change.old_wrap_generation
    then
      local old_row1, old_row2 = wrap_change.old_row1, wrap_change.old_row2
      local new_row1, new_row2 = wrap_change.new_row1, wrap_change.new_row2
      local remove_count = math.max(0, old_row2 - old_row1 + 1)
      local insert_count = math.max(0, new_row2 - new_row1 + 1)
      -- Reconstructing a line render can leave the wrapped-row topology
      -- unchanged. Keep the last resolved heights in that case: replacing
      -- them with base-line placeholders makes the viewport anchor resolve
      -- against a transient, internally inconsistent metric tree.
      if old_row1 == new_row1 and remove_count == insert_count then
        invalidate_visual_metric_rows(self, cache, new_row1, new_row2)
        cache.wrap_layout_generation = current_wrap_generation
        cache.text_revision = self.buffer.text_revision or 0
        cache.signature = self:get_visual_metric_signature()
        return
      end
      local old_anchor = metric_tree_row_at_y(
        cache.height_tree, cache.row_count, math.max(0, self.scroll and self.scroll.y or 0)
      )
      local removed_height = 0
      for row = old_row1, old_row2 do
        removed_height = removed_height + (cache.heights[row] or 0)
      end
      local default_height = self:get_line_height()
      local providers = self:visual_metric_provider_entries()
      local inserted = {}
      local inserted_height = 0
      local line_metrics_cache = {}
      -- Measure the replacement slice before publishing the new metric tree.
      -- A tree containing the new row mapping but temporary base heights can
      -- map the old scroll offset to the wrong anchor row, causing the later
      -- dirty pass to apply the same height change as a viewport correction.
      for offset = 0, insert_count - 1 do
        local height = compute_visual_row_height(
          self, new_row1 + offset, providers, default_height,
          nil, false, line_metrics_cache
        )
        inserted[offset + 1] = height
        inserted_height = inserted_height + height
      end
      common.splice(cache.heights, old_row1, remove_count, inserted)

      local shifted_dirty = {}
      local row_delta = insert_count - remove_count
      for row in pairs(cache.dirty_rows or {}) do
        if row < old_row1 then
          shifted_dirty[row] = true
        elseif row > old_row2 then
          shifted_dirty[row + row_delta] = true
        end
      end
      cache.dirty_rows = next(shifted_dirty) and shifted_dirty or nil
      cache.row_count = current_row_count
      cache.total_height = cache.total_height - removed_height + inserted_height
      cache.height_tree = metric_tree_build(cache.heights, cache.row_count)
      if old_row2 < old_anchor and self.scroll then
        local delta = inserted_height - removed_height
        self.scroll.y = self.scroll.y + delta
        self.scroll.to.y = self.scroll.to.y + delta
      end
      cache.invalidated_rows = (cache.invalidated_rows or 0) + insert_count
      cache.wrap_layout_generation = current_wrap_generation
      cache.text_revision = self.buffer.text_revision or 0
      cache.signature = self:get_visual_metric_signature()
      self.render_cache_diagnostics.metric_invalidations =
        self.render_cache_diagnostics.metric_invalidations + insert_count
      self.render_cache_diagnostics.metric_row_splices =
        self.render_cache_diagnostics.metric_row_splices + 1
      perf_frame_add("textview_visual_metric_row_splices", 1)
      perf_frame_add("textview_visual_metric_row_splice_rows", insert_count)
      return
    end
    if cache.row_count == current_row_count and self.wrapped_line_to_idx
      and unchanged_except_wrap
    then
      local logical_line1 = common.clamp(math.floor(line1), 1, #self.buffer.lines)
      local logical_line2 = common.clamp(
        math.floor(line2 or logical_line1), logical_line1, #self.buffer.lines
      )
      local row1 = self.wrapped_line_to_idx[logical_line1]
      local next_row = self.wrapped_line_to_idx[logical_line2 + 1]
      if row1 then
        invalidate_visual_metric_rows(
          self, cache, row1, next_row and next_row - 1 or current_row_count
        )
        cache.wrap_layout_generation = current_wrap_generation
        cache.text_revision = self.buffer.text_revision or 0
        cache.signature = self:get_visual_metric_signature()
        return
      end
    end
  end
  if cache then
    self.render_cache_diagnostics.metric_invalidations =
      self.render_cache_diagnostics.metric_invalidations + cache.row_count
  end
  self.__visual_metric_generation = (self.__visual_metric_generation or 0) + 1
  self.__visual_metric_cache = nil
end

function TextView:visual_metric_provider_entries()
  if self.__visual_metric_provider_entries then return self.__visual_metric_provider_entries end
  local result = {}
  for _, entry in pairs(self.visual_metric_providers or {}) do
    result[#result + 1] = entry
  end
  table.sort(result, function(a, b)
    if a.priority == b.priority then return a.id < b.id end
    return a.priority < b.priority
  end)
  self.__visual_metric_provider_entries = result
  return result
end

local function sorted_inline_provider_entries(entries)
  local result = {}
  for _, entry in pairs(entries or {}) do result[#result + 1] = entry end
  table.sort(result, function(a, b)
    if a.priority == b.priority then return a.id < b.id end
    return a.priority < b.priority
  end)
  return result
end

-- Keep line-render invalidation on the input path bounded. Larger wrapped
-- layouts are prepared in slices and atomically adopted by linewrapping.
local MAX_SYNC_LINE_RENDER_WRAP_LINES = 128

function TextView:has_line_render_providers()
  return next(self.line_render_providers or {}) ~= nil
end

function TextView:add_line_render_provider(id, provider, opts)
  -- `generation` is View-scoped. Use `line_generation` when the token can
  -- differ by line.
  assert(type(id) == "string" and id ~= "", "line render provider id must be a non-empty string")
  assert(type(provider) == "table", "line render provider must be a table")
  opts = opts or {}
  self.line_render_providers = self.line_render_providers or {}
  self.line_render_providers[id] = { id = id, provider = provider, priority = opts.priority or provider.priority or 0 }
  self.__line_render_provider_entries = nil
  self:invalidate_line_render(id)
end

function TextView:remove_line_render_provider(id)
  if not self.line_render_providers or not self.line_render_providers[id] then return false end
  self.line_render_providers[id] = nil
  self.__line_render_provider_entries = nil
  self:invalidate_line_render(id)
  return true
end

function TextView:invalidate_line_render(_provider_id, line1, line2, opts)
  opts = opts or {}
  self.__line_render_snapshot_kind = nil
  self.__line_render_snapshot_id = nil
  self.__line_render_snapshot_lines = nil
  self.__line_render_snapshot_provider_generations = nil
  self.__line_render_invalidation_generation =
    (self.__line_render_invalidation_generation or 0) + 1
  local perf = package.loaded["core.perf"]
  if perf and perf.is_recording and perf.is_recording() and perf.add_detail then
    local caller = debug.getinfo(2, "Sl") or {}
    local requested_line1 = line1 and math.max(1, math.floor(line1)) or nil
    local requested_line2 = requested_line1
      and math.max(requested_line1, math.floor(line2 or requested_line1)) or nil
    local owner = self.__markdown_live_owner
    local model = owner and owner.semantic_model
    perf.add_detail(string.format(
      "textview_line_render_invalidation:provider=%s:range=%s-%s:lines=%s:caller=%s:%s:revision=%s:model=%s:pending=%s:pending_wrap=%s:adoption=%s",
      tostring(_provider_id or "unknown"),
      tostring(requested_line1 or "full"),
      tostring(requested_line2 or "full"),
      tostring(requested_line1 and (requested_line2 - requested_line1 + 1) or "full"),
      tostring(caller.short_src or caller.source or "unknown"),
      tostring(caller.currentline or 0),
      tostring(self.buffer and self.buffer.text_revision or "none"),
      tostring(model and model.status or "none"),
      tostring(owner and owner.semantic_pending_line or "none"),
      tostring(owner and owner.semantic_pending_wrap_line or "none"),
      tostring(owner and owner.semantic_adoption_line or "none")
    ), 1)
  end
  local cache = self.__line_render_cache
  if line1 and cache and cache.generation == (self.__line_render_generation or 0) then
    local requested_line1 = math.max(1, math.floor(line1))
    local requested_line2 = math.max(requested_line1, math.floor(line2 or requested_line1))
    for line in pairs(cache.lines) do
      if line >= requested_line1 and line <= requested_line2 then cache.lines[line] = nil end
    end
    for line in pairs(self.__line_width_cache or {}) do
      if line >= requested_line1 and line <= requested_line2 then self.__line_width_cache[line] = nil end
    end
    cache.invalidated_lines = (cache.invalidated_lines or 0) + requested_line2 - requested_line1 + 1
    self.render_cache_diagnostics.line_invalidations =
      self.render_cache_diagnostics.line_invalidations + requested_line2 - requested_line1 + 1
    local layout_line1 = common.clamp(requested_line1, 1, #self.buffer.lines)
    local layout_line2 = common.clamp(requested_line2, layout_line1, #self.buffer.lines)
    if self.wrapped_settings and not self.__line_render_wrap_invalidating then
      self.__line_render_wrap_invalidating = true
      local invalidated_layout_lines = layout_line2 - layout_line1 + 1
      local defer_wrapped_reconstruction = opts.defer_wrapped_reconstruction
        or invalidated_layout_lines > MAX_SYNC_LINE_RENDER_WRAP_LINES
      local wrap_change
      if defer_wrapped_reconstruction then
        perf_frame_add("linewrapping_async_line_render_invalidation_calls", 1)
        linewrapping.reconstruct_breaks_async(
          self, self.wrapped_settings.font, self.wrapped_settings.width, {
            budget_ms = opts.wrapped_reconstruction_budget_ms,
            on_complete = opts.on_wrapped_reconstructed,
          }
        )
      else
        wrap_change = linewrapping.update_breaks(
          self, layout_line1, layout_line2, 0
        )
      end
      self.__line_render_wrap_invalidating = nil
      self.__line_render_wrap_change = wrap_change
    end
    return
  end
  if cache then
    self.render_cache_diagnostics.line_invalidations =
      self.render_cache_diagnostics.line_invalidations + #self.buffer.lines
  end
  perf_detail("textview_line_render_full_invalidation:" .. tostring(_provider_id or "unknown"), 1)
  self.__line_render_generation = (self.__line_render_generation or 0) + 1
  self.__line_render_wrap_change = nil
  self.__line_render_cache = nil
  self.__line_width_cache = {}
  if self.wrapped_settings and not self.__line_render_wrap_invalidating then
    self.__line_render_wrap_invalidating = true
    if opts.defer_wrapped_reconstruction
      or #self.buffer.lines > MAX_SYNC_LINE_RENDER_WRAP_LINES
    then
      perf_frame_add("linewrapping_async_line_render_invalidation_calls", 1)
      linewrapping.reconstruct_breaks_async(
        self, self.wrapped_settings.font, self.wrapped_settings.width, {
          budget_ms = opts.wrapped_reconstruction_budget_ms,
          on_complete = opts.on_wrapped_reconstructed,
        }
      )
    else
      perf_frame_add("linewrapping_reconstruct_line_render_invalidation_calls", 1)
      linewrapping.reconstruct_breaks(
        self, self.wrapped_settings.font, self.wrapped_settings.width
      )
    end
    self.__line_render_wrap_invalidating = nil
  end
end

function TextView:line_render_provider_entries()
  if not self.__line_render_provider_entries then
    self.__line_render_provider_entries = sorted_inline_provider_entries(self.line_render_providers)
  end
  return self.__line_render_provider_entries
end

function TextView:get_render_cache_diagnostics()
  local result = {}
  for key, value in pairs(self.render_cache_diagnostics or {}) do result[key] = value end
  result.resident_line_entries = 0
  for _ in pairs(self.__line_render_cache and self.__line_render_cache.lines or {}) do
    result.resident_line_entries = result.resident_line_entries + 1
  end
  return result
end


local MIN_LINE_NUMBER_GUTTER_DIGITS = 2

---Get the width reserved for line numbers in the gutter.
---@return number width Line number label width
function TextView:get_line_number_gutter_width()
  local digits = math.max(MIN_LINE_NUMBER_GUTTER_DIGITS, #tostring(#self.buffer.lines))
  return self:get_font():get_width(string.rep("0", digits))
end

---Whether this Text View should draw line-number labels.
---A per-view boolean overrides the global line-number setting.
---@return boolean visible
function TextView:line_numbers_visible()
  if self.show_line_numbers ~= nil then return self.show_line_numbers end
  return config.show_line_numbers
end

---Whether the gutter should reserve the line-number lane.
---Specialized presentations may hide every line number without changing the
---view's ordinary line-number preference (for example, while Source Mode is
---temporarily inactive).
---@return boolean visible
function TextView:line_number_gutter_visible()
  local visible = self:line_numbers_visible()
  for _, entry in ipairs(self:decoration_provider_entries()) do
    local provider = entry.provider
    local fn = provider and provider.line_number_gutter_visible
    if fn then
      local ok, result = pcall(fn, provider, self)
      if ok and type(result) == "boolean" then
        visible = result
      elseif not ok then
        core.log_quiet(
          "TextView decoration provider %s.line_number_gutter_visible failed for %s: %s",
          tostring(entry.id), self.buffer:get_name(), tostring(result)
        )
      end
    end
  end
  return visible
end

---Whether the line number for one logical line should be drawn.
---Decoration providers may return a boolean from `line_number_visible` to
---override the normal all-lines presentation for a specialized Editor mode.
---@param line integer Logical Buffer line
---@return boolean visible
function TextView:line_number_visible_at(line)
  if not self:line_numbers_visible() then return false end
  local visible = true
  for _, entry in ipairs(self:decoration_provider_entries()) do
    local provider = entry.provider
    local fn = provider and provider.line_number_visible
    if fn then
      local ok, result = pcall(fn, provider, self, line)
      if ok and type(result) == "boolean" then
        visible = result
      elseif not ok then
        core.log_quiet(
          "TextView decoration provider %s.line_number_visible failed for %s: %s",
          tostring(entry.id), self.buffer:get_name(), tostring(result)
        )
      end
    end
  end
  return visible
end

---Get the standard Text View gutter width.
---@return number width Total gutter width
---@return number padding Padding within gutter
function TextView:get_gutter_width()
  local padding = self.gutter_padding
  if padding == nil then padding = style.padding.x * 2 end
  if self:line_number_gutter_visible() then
    return self:get_line_number_gutter_width() + padding, padding
  end
  return padding, padding
end

local function compact_fold_views(buffer)
  local views = TextView.fold_views_by_buffer[buffer]
  if not views then return nil end
  local compacted = setmetatable({}, { __mode = "v" })
  for _, view in pairs(views) do
    if view and view.buffer == buffer then compacted[#compacted + 1] = view end
  end
  TextView.fold_views_by_buffer[buffer] = #compacted > 0 and compacted or nil
  return TextView.fold_views_by_buffer[buffer]
end

register_fold_view = function(view)
  local buffer = view and view.buffer
  if not buffer then return end
  local views = compact_fold_views(buffer)
  if not views then
    views = setmetatable({}, { __mode = "v" })
    TextView.fold_views_by_buffer[buffer] = views
  end
  for _, existing in pairs(views) do
    if existing == view then return end
  end
  views[#views + 1] = view
end

unregister_fold_view = function(view)
  local buffer = view and view.buffer
  local views = buffer and TextView.fold_views_by_buffer[buffer]
  if not views then return end
  local compacted = setmetatable({}, { __mode = "v" })
  for _, existing in pairs(views) do
    if existing and existing ~= view and existing.buffer == buffer then compacted[#compacted + 1] = existing end
  end
  TextView.fold_views_by_buffer[buffer] = #compacted > 0 and compacted or nil
end

local function clear_fold_views_for_buffer(buffer, reason)
  local views = compact_fold_views(buffer)
  if not views then return end
  for _, view in ipairs(views) do
    if view and view.clear_fold_regions then view:clear_fold_regions(reason or "buffer-close") end
    unregister_fold_view(view)
  end
end

if Buffer and not Buffer.__textview_folding_close_patched then
  Buffer.__textview_folding_close_patched = true
  local old_on_close = Buffer.on_close
  function Buffer:on_close(...)
    clear_fold_views_for_buffer(self, "buffer-close")
    return old_on_close(self, ...)
  end
end

local function sorted_provider_entries(entries)
  local list = {}
  for id, entry in pairs(entries or {}) do
    list[#list + 1] = entry
  end
  table.sort(list, function(a, b)
    if (a.priority or 0) == (b.priority or 0) then return tostring(a.id) < tostring(b.id) end
    return (a.priority or 0) < (b.priority or 0)
  end)
  return list
end

function TextView:add_decoration_provider(id, provider, opts)
  assert(type(id) == "string" and id ~= "", "decoration provider id must be a non-empty string")
  assert(type(provider) == "table", "decoration provider must be a table")
  opts = opts or {}
  self.decoration_providers = self.decoration_providers or {}
  self.decoration_providers[id] = { id = id, provider = provider, priority = opts.priority or provider.priority or 0 }
  self.__decoration_provider_entries = nil
end

function TextView:remove_decoration_provider(id)
  if not self.decoration_providers or not self.decoration_providers[id] then return false end
  self.decoration_providers[id] = nil
  self.__decoration_provider_entries = nil
  return true
end

function TextView:decoration_provider_entries()
  if not self.__decoration_provider_entries then
    self.__decoration_provider_entries = sorted_provider_entries(
      self.decoration_providers
    )
  end
  return self.__decoration_provider_entries
end

local copy_feedback_decoration_provider = {
  inline_ranges = function(_, view, line)
    return view:get_copy_feedback_ranges(line)
  end,
}

function TextView:show_copy_feedback(ranges)
  local copied_ranges = {}
  for _, range in ipairs(ranges or {}) do
    local line1, col1 = range.line1 or range[1], range.col1 or range[2]
    local line2, col2 = range.line2 or range[3], range.col2 or range[4]
    if line1 and col1 and line2 and col2 then
      copied_ranges[#copied_ranges + 1] = {
        line1 = line1, col1 = col1, line2 = line2, col2 = col2,
      }
    end
  end
  if #copied_ranges == 0 then return false end
  self.copy_feedback = copy_feedback.start { ranges = copied_ranges }
  if not self.decoration_providers["core.copy-feedback"] then
    self:add_decoration_provider("core.copy-feedback", copy_feedback_decoration_provider, { priority = 100000 })
  end
  core.log_quiet("TextView copy feedback: %s (%d range%s)", self.buffer:get_name(), #copied_ranges, #copied_ranges == 1 and "" or "s")
  core.redraw = true
  return true
end

function TextView:get_copy_feedback_ranges(line)
  local feedback = self.copy_feedback
  local color = copy_feedback.color(feedback, style.copy_feedback)
  if not color then
    self.copy_feedback = nil
    self:remove_decoration_provider("core.copy-feedback")
    return nil
  end

  local ranges = {}
  local text = self.buffer.lines[line]
  if not text then return ranges end
  for _, range in ipairs(feedback.ranges or {}) do
    if line >= range.line1 and line <= range.line2 then
      local col1 = line == range.line1 and range.col1 or 1
      local col2 = line == range.line2 and range.col2 or #text + 1
      if col2 > col1 then
        ranges[#ranges + 1] = { col1 = col1, col2 = col2, color = color }
      end
    end
  end
  core.redraw = true
  return ranges
end

function TextView:add_clipboard_paste_provider(id, provider, opts)
  assert(type(id) == "string" and id ~= "", "clipboard-paste provider id must be a non-empty string")
  assert(type(provider) == "table", "clipboard-paste provider must be a table")
  opts = opts or {}
  self.clipboard_paste_providers = self.clipboard_paste_providers or {}
  self.clipboard_paste_providers[id] = {
    id = id, provider = provider, priority = opts.priority or provider.priority or 0,
  }
end

function TextView:remove_clipboard_paste_provider(id)
  if not self.clipboard_paste_providers or not self.clipboard_paste_providers[id] then return false end
  self.clipboard_paste_providers[id] = nil
  return true
end

function TextView:paste_from_provider()
  for _, entry in ipairs(sorted_provider_entries(self.clipboard_paste_providers)) do
    local fn = entry.provider.on_clipboard_paste
    if fn then
      local ok, handled = pcall(fn, entry.provider, self)
      if not ok then
        core.log_quiet("TextView clipboard-paste provider %s failed for %s: %s",
          tostring(entry.id), self.buffer:get_name(), tostring(handled))
      elseif handled then
        return true
      end
    end
  end
  return false
end

function TextView:add_file_drop_provider(id, provider, opts)
  assert(type(id) == "string" and id ~= "", "file-drop provider id must be a non-empty string")
  assert(type(provider) == "table", "file-drop provider must be a table")
  opts = opts or {}
  self.file_drop_providers = self.file_drop_providers or {}
  self.file_drop_providers[id] = {
    id = id, provider = provider, priority = opts.priority or provider.priority or 0,
  }
end

function TextView:remove_file_drop_provider(id)
  if not self.file_drop_providers or not self.file_drop_providers[id] then return false end
  self.file_drop_providers[id] = nil
  return true
end

function TextView:on_file_dropped(filename, x, y)
  for _, entry in ipairs(sorted_provider_entries(self.file_drop_providers)) do
    local fn = entry.provider.on_file_dropped
    if fn then
      local ok, handled = pcall(fn, entry.provider, self, filename, x, y)
      if not ok then
        core.log_quiet("TextView file-drop provider %s failed for %s: %s",
          tostring(entry.id), self.buffer:get_name(), tostring(handled))
      elseif handled then
        return true
      end
    end
  end
  return TextView.super.on_file_dropped(self, filename, x, y)
end

function TextView:add_poi_provider(id, provider, opts)
  assert(type(id) == "string" and id ~= "", "POI provider id must be a non-empty string")
  assert(type(provider) == "table", "POI provider must be a table")
  opts = opts or {}
  self.poi_providers = self.poi_providers or {}
  self.poi_providers[id] = { id = id, provider = provider, priority = opts.priority or provider.priority or 0 }
end

function TextView:remove_poi_provider(id)
  if not self.poi_providers or not self.poi_providers[id] then return false end
  self.poi_providers[id] = nil
  return true
end

function TextView:get_points_of_interest(opts)
  local points = {}
  for _, entry in ipairs(sorted_provider_entries(self.poi_providers)) do
    local provider = entry.provider
    local fn = provider.points_of_interest or provider.get_points_of_interest
    if fn then
      local ok, res = pcall(fn, provider, self, opts or {})
      if ok and res then
        for _, point in ipairs(res) do points[#points + 1] = point end
      elseif not ok then
        core.log_quiet("TextView POI provider %s failed for %s: %s", tostring(entry.id), self.buffer:get_name(), tostring(res))
      end
    end
  end
  return points
end

function TextView:add_selection_listener(id, fn)
  assert(type(id) == "string" and id ~= "", "selection listener id must be a non-empty string")
  assert(type(fn) == "function", "selection listener must be a function")
  self.selection_listeners = self.selection_listeners or {}
  self.selection_listeners[id] = fn
end

function TextView:remove_selection_listener(id)
  if not self.selection_listeners or not self.selection_listeners[id] then return false end
  self.selection_listeners[id] = nil
  return true
end

function TextView:notify_selection_listeners(reason, old_state, new_state)
  for id, fn in pairs(self.selection_listeners or {}) do
    local ok, err = pcall(fn, self, new_state or self:get_selection_state(), old_state, reason)
    if not ok then core.log_quiet("TextView selection listener %s failed for %s: %s", tostring(id), self.buffer:get_name(), tostring(err)) end
  end
end

function TextView:begin_line_render_interaction(reason)
  self.__line_render_interaction_state = {
    reason = reason,
    selection_state = self:get_selection_state(),
  }
end

function TextView:end_line_render_interaction(reason)
  local interaction = self.__line_render_interaction_state
  if not interaction then return false end
  self.__line_render_interaction_state = nil
  local new_state = self:get_selection_state()
  local needs_fallback = false
  for _, entry in ipairs(self:line_render_provider_entries()) do
    local provider = entry.provider
    local fn = provider and provider.on_selection_interaction_end
    if fn then
      local ok, handled = pcall(
        fn, provider, self, new_state, interaction.selection_state,
        reason or interaction.reason or "interaction"
      )
      if not ok then
        core.log_quiet(
          "TextView line-render provider %s interaction end failed for %s: %s",
          tostring(entry.id), self.buffer:get_name(), tostring(handled)
        )
        needs_fallback = true
      elseif handled == false then
        needs_fallback = true
      end
    else
      needs_fallback = true
    end
  end
  if needs_fallback then
    self:invalidate_line_render(reason or "interaction")
    self:invalidate_visual_metrics(reason or "interaction")
  end
  return true
end

function TextView:get_line_render_selection_state()
  local state = self.__line_render_interaction_state and self.__line_render_interaction_state.selection_state
  return state or self:get_selection_state()
end

function TextView:add_scroll_listener(id, fn)
  assert(type(id) == "string" and id ~= "", "scroll listener id must be a non-empty string")
  assert(type(fn) == "function", "scroll listener must be a function")
  self.scroll_listeners = self.scroll_listeners or {}
  self.scroll_listeners[id] = fn
end

function TextView:remove_scroll_listener(id)
  if not self.scroll_listeners or not self.scroll_listeners[id] then return false end
  self.scroll_listeners[id] = nil
  return true
end

function TextView:notify_scroll_listeners(reason)
  for id, fn in pairs(self.scroll_listeners or {}) do
    local ok, err = pcall(fn, self, reason)
    if not ok then core.log_quiet("TextView scroll listener %s failed for %s: %s", tostring(id), self.buffer:get_name(), tostring(err)) end
  end
end

function TextView:add_fold_listener(id, fn)
  assert(type(id) == "string" and id ~= "", "fold listener id must be a non-empty string")
  assert(type(fn) == "function", "fold listener must be a function")
  self.fold_listeners = self.fold_listeners or {}
  self.fold_listeners[id] = fn
end

function TextView:remove_fold_listener(id)
  if not self.fold_listeners or not self.fold_listeners[id] then return false end
  self.fold_listeners[id] = nil
  return true
end

function TextView:notify_fold_listeners(event, fold, reason)
  for id, fn in pairs(self.fold_listeners or {}) do
    local ok, err = pcall(fn, self, event, fold, reason)
    if not ok then core.log_quiet("TextView fold listener %s failed for %s: %s", tostring(id), self.buffer:get_name(), tostring(err)) end
  end
end

function TextView:add_edit_guard(id, guard)
  assert(type(id) == "string" and id ~= "", "edit guard id must be a non-empty string")
  assert(type(guard) == "function" or type(guard) == "table", "edit guard must be a function or table")
  self.edit_guards = self.edit_guards or {}
  self.edit_guards[id] = guard
end

function TextView:remove_edit_guard(id)
  if not self.edit_guards or not self.edit_guards[id] then return false end
  self.edit_guards[id] = nil
  return true
end

function TextView:can_edit(reason, opts)
  opts = opts or {}
  if self.buffer.read_only then
    local why = self.buffer.read_only_reason or "This Buffer is read-only"
    if opts.warn then core.warn(why) end
    return false, why
  end
  for id, guard in pairs(self.edit_guards or {}) do
    local is_table = type(guard) == "table"
    local fn = is_table and guard.can_edit or guard
    if fn then
      local ok, allowed, why
      if is_table then
        ok, allowed, why = pcall(fn, guard, self, reason, opts)
      else
        ok, allowed, why = pcall(fn, self, reason, opts)
      end
      if not ok then
        core.log_quiet("TextView edit guard %s failed for %s: %s", tostring(id), self.buffer:get_name(), tostring(allowed))
      elseif allowed == false then
        why = why or "This view is read-only"
        if opts.warn then core.warn(why) end
        return false, why
      end
    end
  end
  return true
end

function TextView:add_visual_row_provider(id, provider, opts)
  assert(type(id) == "string" and id ~= "", "visual row provider id must be a non-empty string")
  assert(type(provider) == "table", "visual row provider must be a table")
  opts = opts or {}
  self.visual_row_providers = self.visual_row_providers or {}
  self.visual_row_providers[id] = { id = id, provider = provider, priority = opts.priority or provider.priority or 0 }
  self.__visual_row_provider_entries = nil
  self:bump_fold_generation("visual-row-provider")
end

function TextView:clear_composed_visual_row_cache()
  self.__composed_visual_row_cache = nil
  self.__composed_visual_row_snapshot_kind = nil
  self.__composed_visual_row_snapshot_id = nil
  self.__composed_visual_row_snapshot_rows = nil
end

function TextView:remove_visual_row_provider(id)
  if not self.visual_row_providers or not self.visual_row_providers[id] then return false end
  self.visual_row_providers[id] = nil
  self.__visual_row_provider_entries = nil
  self:bump_fold_generation("visual-row-provider-clear")
  return true
end

function TextView:invalidate_visual_rows(provider_id)
  self.__visual_row_invalidation_generation = (self.__visual_row_invalidation_generation or 0) + 1
  if provider_id then
    self.__visual_row_provider_invalidations = self.__visual_row_provider_invalidations or {}
    self.__visual_row_provider_invalidations[provider_id] = (self.__visual_row_provider_invalidations[provider_id] or 0) + 1
  end
  self:bump_fold_generation(provider_id and ("visual-row-invalidate:" .. tostring(provider_id)) or "visual-row-invalidate")
end

function TextView:visual_row_provider_entries()
  if not self.__visual_row_provider_entries then
    self.__visual_row_provider_entries = sorted_provider_entries(
      self.visual_row_providers
    )
  end
  return self.__visual_row_provider_entries
end

function TextView:set_visual_row_extension(id, extension)
  assert(type(id) == "string" and id ~= "", "visual row extension id must be a non-empty string")
  self.visual_row_extensions = self.visual_row_extensions or {}
  self.visual_row_extensions[id] = extension
  self:bump_fold_generation("visual-row-extension")
end

function TextView:clear_visual_row_extension(id)
  if not self.visual_row_extensions or not self.visual_row_extensions[id] then return false end
  self.visual_row_extensions[id] = nil
  self:bump_fold_generation("visual-row-extension-clear")
  return true
end

function TextView:has_extra_visual_rows()
  for _, extension in pairs(self.visual_row_extensions or {}) do
    if extension then return true end
  end
  for _, entry in pairs(self.visual_row_providers or {}) do
    if entry then return true end
  end
  return false
end

function TextView:has_composed_visual_rows()
  return self:has_collapsed_folds() or self:has_extra_visual_rows()
end

local function visual_row_count_from_provider(view, entry, method, line)
  local provider = entry.provider
  local fn = provider[method]
  if fn then
    local ok, count = pcall(fn, provider, view, line)
    if ok then return math.max(0, math.floor(tonumber(count) or 0)) end
    core.log_quiet("TextView visual row provider %s.%s failed for %s: %s", tostring(entry.id), method, view.buffer:get_name(), tostring(count))
    return 0
  end
  local table_name = method == "rows_before" and "before" or "after"
  local rows = provider[table_name]
  if type(rows) == "function" then
    local ok, count = pcall(rows, line, view)
    if ok then return math.max(0, math.floor(tonumber(count) or 0)) end
    core.log_quiet("TextView visual row provider %s.%s failed for %s: %s", tostring(entry.id), table_name, view.buffer:get_name(), tostring(count))
  elseif rows then
    return math.max(0, math.floor(tonumber(rows[line]) or 0))
  end
  return 0
end

function TextView:get_extra_visual_rows_before_line(line)
  local total = 0
  for _, extension in pairs(self.visual_row_extensions or {}) do
    local before = extension.before
    if type(before) == "function" then
      total = total + math.max(0, math.floor(tonumber(before(line, self)) or 0))
    elseif before then
      total = total + math.max(0, math.floor(tonumber(before[line]) or 0))
    end
  end
  for _, entry in ipairs(self:visual_row_provider_entries()) do
    total = total + visual_row_count_from_provider(self, entry, "rows_before", line)
  end
  return total
end

function TextView:get_extra_visual_rows_after_line(line)
  local total = 0
  for _, extension in pairs(self.visual_row_extensions or {}) do
    local after = extension.after
    if type(after) == "function" then
      total = total + math.max(0, math.floor(tonumber(after(line, self)) or 0))
    elseif after then
      total = total + math.max(0, math.floor(tonumber(after[line]) or 0))
    end
  end
  for _, entry in ipairs(self:visual_row_provider_entries()) do
    total = total + visual_row_count_from_provider(self, entry, "rows_after", line)
  end
  return total
end

local function normalize_fold_lines(buffer, line1, line2)
  line1 = common.clamp(math.floor(tonumber(line1) or 1), 1, #buffer.lines)
  line2 = common.clamp(math.floor(tonumber(line2) or line1), 1, #buffer.lines)
  if line2 < line1 then line1, line2 = line2, line1 end
  return line1, line2
end

local function fold_hidden_count(fold)
  return math.max(0, (fold.line2 or fold.line1 or 1) - (fold.line1 or 1) + 1)
end

local FOLD_PREVIEW_MAX_CHARS = 50

local function default_fold_placeholder(fold)
  local count = fold_hidden_count(fold)
  return string.format("⋯ %d line%s folded ⋯", count, count == 1 and "" or "s")
end

local function fold_preview_text(buffer, fold)
  if not buffer or not fold then return nil end
  local line1 = fold.line1 or 1
  local line2 = fold.line2 or line1
  local col1 = fold.col1 or 1
  local col2 = fold.col2 or (#(buffer.lines[line2] or "") + 1)
  local ok, text = pcall(buffer.get_text, buffer, line1, col1, line2, col2)
  if not ok or not text then return nil end
  text = tostring(text):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil end
  local len = string.ulen and string.ulen(text) or #text
  if len > FOLD_PREVIEW_MAX_CHARS then
    if string.usub then
      text = string.usub(text, 1, FOLD_PREVIEW_MAX_CHARS) .. "…"
    else
      text = text:sub(1, FOLD_PREVIEW_MAX_CHARS) .. "…"
    end
  end
  return text
end

local function fold_placeholder(buffer, fold)
  if type(fold.placeholder) == "function" then
    local ok, text = pcall(fold.placeholder, fold)
    if ok and text then return tostring(text) end
  elseif fold.placeholder then
    return tostring(fold.placeholder)
  end
  local base = default_fold_placeholder(fold)
  local preview = fold_preview_text(buffer, fold)
  return preview and (preview .. "  " .. base) or base
end

function TextView:refresh_fold_region(fold)
  if not fold or not fold.marker or not fold.marker:is_valid() then return false end
  local range = fold.marker:range()
  if not range then return false end
  fold.line1, fold.col1, fold.line2, fold.col2 = range.line1, range.col1, range.line2, range.col2
  fold.line1, fold.line2 = normalize_fold_lines(self.buffer, fold.line1, fold.line2)
  fold.hidden_count = fold_hidden_count(fold)
  return true
end

function TextView:bump_fold_generation(reason)
  self.fold_generation = (self.fold_generation or 0) + 1
  self.__collapsed_fold_cache = nil
  self.__fold_layout_cache = nil
  self:clear_composed_visual_row_cache()
  core.redraw = true
  if reason and core.log_quiet then
    core.log_quiet("TextView fold generation %d for %s: %s", self.fold_generation, self.buffer:get_name(), tostring(reason))
  end
end

function TextView:has_collapsed_folds()
  for _, fold in ipairs(self.fold_regions or {}) do
    if fold.collapsed and fold.marker and fold.marker:is_valid() then return true end
  end
  return false
end

function TextView:get_collapsed_folds()
  local generation = self.fold_generation or 0
  local cache = self.__collapsed_fold_cache
  if cache and cache.generation == generation then return cache.folds end
  local folds = {}
  for _, fold in ipairs(self.fold_regions or {}) do
    if fold.collapsed and self:refresh_fold_region(fold) then folds[#folds + 1] = fold end
  end
  table.sort(folds, function(a, b)
    if a.line1 == b.line1 then return a.line2 < b.line2 end
    return a.line1 < b.line1
  end)
  self.__collapsed_fold_cache = { generation = generation, folds = folds }
  return folds
end

function TextView:get_collapsed_fold_at_line(line)
  for _, fold in ipairs(self:get_collapsed_folds()) do
    if line >= fold.line1 and line <= fold.line2 then return fold end
  end
end

function TextView:is_line_hidden_by_fold(line)
  local fold = self:get_collapsed_fold_at_line(line)
  return fold and line > fold.line1, fold
end

function TextView:fold_aware_line_move(line, direction)
  local target = common.clamp(line + direction, 1, #self.buffer.lines)
  local fold = self:get_collapsed_fold_at_line(target)
  if fold and target > fold.line1 then
    if direction > 0 then
      target = fold.line2 < #self.buffer.lines and fold.line2 + 1 or fold.line1
    else
      target = fold.line1
    end
  end
  return target
end

function TextView:folded_visual_line_position(line, col, direction)
  line = line or 1
  col = col or 1
  local line_end = self.wrapped_settings and linewrapping.has_wrapped_line_end_affinity(self, line, col) or false
  local composed = self:has_composed_visual_rows()
  local current_row = composed and self:get_composed_visual_row_for_position(line, col, line_end) or self:get_folded_visual_row_for_position(line, col, line_end)
  local current_entry = self:get_visual_row_entry(current_row)
  if direction < 0 then
    local previous_line = math.max(1, line - 1)
    local hidden, fold = self:is_line_hidden_by_fold(previous_line)
    if hidden and (self:get_visual_row_count_for_line(line) <= 1 or not current_entry or (current_entry.row_in_line or 1) <= 1) then
      return fold.line1, 1, false
    end
  elseif direction > 0 then
    local current_fold = self:get_collapsed_fold_at_line(line)
    if current_fold and current_fold.line1 == line then
      return self:fold_aware_line_move(line, 1), 1, false
    end
  end
  local target_row = common.clamp(current_row + direction, 1, composed and self:get_composed_visual_row_count() or self:get_folded_visual_row_count())
  local entry = self:get_visual_row_entry(target_row)
  while entry and (entry.type == "provider" or entry.type == "extra") do
    local next_row = target_row + direction
    if next_row < 1 or next_row > (composed and self:get_composed_visual_row_count() or self:get_folded_visual_row_count()) then break end
    target_row = next_row
    entry = self:get_visual_row_entry(target_row)
  end
  if entry and entry.type == "fold" then return entry.fold.line1, 1, false end
  if entry and entry.line then
    if self.wrapped_settings and entry.wrapped_idx then
      local last_x_offset = self.last_x_offset or {}
      self.last_x_offset = last_x_offset
      local x
      if last_x_offset.line == line and last_x_offset.col == col and last_x_offset.line_end == line_end then
        x = last_x_offset.offset
      else
        x = self:get_col_x_offset(line, col, line_end)
      end
      local target_line, target_col, target_line_end = linewrapping.get_line_col_from_index_and_x(self, entry.wrapped_idx, x)
      target_col = common.clamp(target_col or col or 1, 1, #(self.buffer.lines[target_line] or ""))
      last_x_offset.offset = x
      last_x_offset.line = target_line
      last_x_offset.col = target_col
      last_x_offset.line_end = target_line_end
      return target_line, target_col, target_line_end
    end
    return entry.line, common.clamp(col, 1, #(self.buffer.lines[entry.line] or "")), false
  end
  return line, col, false
end

function TextView:add_fold_region(opts)
  opts = opts or {}
  local line1, line2 = normalize_fold_lines(self.buffer, opts.line1 or opts[1], opts.line2 or opts[2])
  if line2 <= line1 then return nil, "fold region must span multiple lines" end
  local contained_folds = {}
  for _, fold in ipairs(self:get_collapsed_folds()) do
    if line1 <= fold.line1 and line2 >= fold.line2 then
      if not (opts.allow_nested and fold.allow_nested) then
        contained_folds[#contained_folds + 1] = fold
      end
    elseif fold.line1 <= line1 and fold.line2 >= line2 then
      if not (opts.allow_nested and fold.allow_nested) then
        return nil, "fold region overlaps an existing collapsed fold"
      end
    elseif not (line2 < fold.line1 or line1 > fold.line2) then
      return nil, "fold region overlaps an existing collapsed fold"
    end
  end
  for _, fold in ipairs(contained_folds) do
    self:remove_fold_region(fold, "absorbed-by-parent-fold")
  end
  self.__fold_next_id = (self.__fold_next_id or 0) + 1
  local id = opts.id or self.__fold_next_id
  local fold
  local marker = range_marker.new(self.buffer, {
    line1 = line1,
    col1 = opts.col1 or 1,
    line2 = line2,
    col2 = opts.col2 or (#self.buffer.lines[line2] + 1),
    kind = "textview-fold",
    data = { view = self, id = id },
    invalidate_on_edit_overlap = opts.invalidate_on_edit_overlap ~= false,
    greedy_left = false,
    greedy_right = false,
    on_change = function(marker, reason)
      if fold and reason ~= "new" then
        if not marker:is_valid() then
          fold.collapsed = false
          if not fold.__removing then self:notify_fold_listeners("invalidate", fold, reason) end
        else
          self:refresh_fold_region(fold)
          self:notify_fold_listeners("change", fold, reason)
        end
        self:bump_fold_generation("marker-" .. tostring(reason))
      end
    end,
  })
  fold = {
    id = id,
    marker = marker,
    line1 = line1,
    col1 = opts.col1 or 1,
    line2 = line2,
    col2 = opts.col2 or (#self.buffer.lines[line2] + 1),
    collapsed = opts.collapsed ~= false,
    placeholder = opts.placeholder,
    show_widget = opts.show_widget ~= false,
    allow_nested = opts.allow_nested == true,
    kind = opts.kind,
    metadata = opts.metadata,
    hidden_count = line2 - line1 + 1,
  }
  self.fold_regions[#self.fold_regions + 1] = fold
  table.sort(self.fold_regions, function(a, b)
    if a.line1 == b.line1 then return a.line2 < b.line2 end
    return a.line1 < b.line1
  end)
  self:bump_fold_generation("add")
  self:notify_fold_listeners("add", fold, "add")
  return fold
end

function TextView:remove_fold_region(id_or_fold, reason)
  for i = #(self.fold_regions or {}), 1, -1 do
    local fold = self.fold_regions[i]
    if fold == id_or_fold or fold.id == id_or_fold then
      fold.__removing = true
      range_marker.remove(fold.marker)
      table.remove(self.fold_regions, i)
      self:bump_fold_generation(reason or "remove")
      self:notify_fold_listeners("remove", fold, reason or "remove")
      return true
    end
  end
  return false
end

function TextView:clear_fold_regions(reason)
  if not self.fold_regions or #self.fold_regions == 0 then return end
  local old_folds = self.fold_regions
  for _, fold in ipairs(old_folds) do fold.__removing = true; range_marker.remove(fold.marker) end
  self.fold_regions = {}
  self:bump_fold_generation(reason or "clear")
  for _, fold in ipairs(old_folds) do self:notify_fold_listeners("remove", fold, reason or "clear") end
end

function TextView:expand_fold_region(id_or_fold, reason)
  local fold = type(id_or_fold) == "table" and id_or_fold or nil
  if not fold then
    for _, candidate in ipairs(self.fold_regions or {}) do
      if candidate.id == id_or_fold then fold = candidate; break end
    end
  end
  if not fold or not fold.collapsed then return false end
  fold.collapsed = false
  self:bump_fold_generation(reason or "expand")
  self:notify_fold_listeners("expand", fold, reason or "expand")
  return true
end

function TextView:collapse_fold_region(id_or_fold, reason)
  local fold = type(id_or_fold) == "table" and id_or_fold or nil
  if not fold then
    for _, candidate in ipairs(self.fold_regions or {}) do
      if candidate.id == id_or_fold then fold = candidate; break end
    end
  end
  if not fold or fold.collapsed then return false end
  local line1, line2 = fold.line1, fold.line2
  local contained_folds = {}
  for _, other in ipairs(self:get_collapsed_folds()) do
    if other ~= fold then
      if line1 <= other.line1 and line2 >= other.line2 then
        if not (fold.allow_nested and other.allow_nested) then
          contained_folds[#contained_folds + 1] = other
        end
      elseif other.line1 <= line1 and other.line2 >= line2 then
        if not (fold.allow_nested and other.allow_nested) then
          return false, "fold region overlaps an existing collapsed fold"
        end
      elseif not (line2 < other.line1 or line1 > other.line2) then
        return false, "fold region overlaps an existing collapsed fold"
      end
    end
  end
  for _, other in ipairs(contained_folds) do
    self:remove_fold_region(other, "absorbed-by-parent-fold")
  end
  fold.collapsed = true
  self:bump_fold_generation(reason or "collapse")
  self:notify_fold_listeners("collapse", fold, reason or "collapse")
  return true
end

function TextView:run_fold_transaction(fn)
  local old_depth = self.__fold_transaction_depth or 0
  self.__fold_transaction_depth = old_depth + 1
  local ok, a, b, c = pcall(fn)
  self.__fold_transaction_depth = old_depth
  self:bump_fold_generation("transaction")
  if not ok then error(a) end
  return a, b, c
end

function TextView:get_line_visual_row_count(line)
  if self.wrapped_settings then return linewrapping.get_wrapped_line_count(self, line) end
  return 1
end

function TextView:get_folded_visual_row_count()
  local count, line = 0, 1
  local folds = self:get_collapsed_folds()
  local fidx = 1
  while line <= #self.buffer.lines do
    while folds[fidx] and folds[fidx].line1 < line do fidx = fidx + 1 end
    local fold = folds[fidx]
    if fold and line == fold.line1 then
      count = count + (fold.show_widget == false
        and self:get_line_visual_row_count(line) or 1)
      line = fold.line2 + 1
      fidx = fidx + 1
    else
      count = count + self:get_line_visual_row_count(line)
      line = line + 1
    end
  end
  return math.max(1, count)
end

function TextView:get_folded_visual_row_for_position(line, col, line_end)
  line = common.clamp(line or 1, 1, #self.buffer.lines)
  local row, current = 1, 1
  local folds = self:get_collapsed_folds()
  local fidx = 1
  while current <= #self.buffer.lines do
    while folds[fidx] and folds[fidx].line1 < current do fidx = fidx + 1 end
    local fold = folds[fidx]
    if fold and current == fold.line1 then
      if line >= fold.line1 and line <= fold.line2 then
        if fold.show_widget == false and line == fold.line1 and self.wrapped_settings then
          local idx = linewrapping.get_line_idx_col_count(self, line, col, line_end)
          local first_idx = self.wrapped_line_to_idx and self.wrapped_line_to_idx[line] or idx
          return row + math.max(0, idx - first_idx)
        end
        return row
      end
      row = row + (fold.show_widget == false
        and self:get_line_visual_row_count(current) or 1)
      current = fold.line2 + 1
      fidx = fidx + 1
    else
      if current == line then
        if self.wrapped_settings then
          local idx, _, _, scol = linewrapping.get_line_idx_col_count(self, line, col, line_end)
          local first_idx = self.wrapped_line_to_idx and self.wrapped_line_to_idx[line] or idx
          return row + math.max(0, idx - first_idx)
        end
        return row
      end
      row = row + self:get_line_visual_row_count(current)
      current = current + 1
    end
  end
  return row
end

local function provider_generation_value(view, entry)
  local provider = entry.provider
  local fn = provider and provider.generation
  if not fn then return nil end
  local ok, gen = pcall(fn, provider, view)
  if ok then return gen end
  core.log_quiet("TextView visual row provider %s.generation failed for %s: %s", tostring(entry.id), view.buffer:get_name(), tostring(gen))
end

function TextView:visual_row_cache_signature()
  local parts = {
    tostring(self.fold_generation or 0),
    tostring(self.buffer.text_revision or 0),
    tostring(#self.buffer.lines),
    tostring(self.wrapped_settings and linewrapping.get_total_wrapped_lines(self) or 0),
    tostring(self.__wrap_layout_generation or 0),
    tostring(self.__visual_row_invalidation_generation or 0),
  }
  for _, entry in ipairs(self:visual_row_provider_entries()) do
    parts[#parts + 1] = tostring(entry.id)
    parts[#parts + 1] = tostring(provider_generation_value(self, entry))
  end
  return table.concat(parts, "|")
end

local function append_composed_entry(entries, entry)
  entry.absolute_row = #entries + 1
  entry.row = entry.absolute_row
  entries[#entries + 1] = entry
  return entry
end

local function legacy_visual_row_count(view, entry, method, line, previous_total)
  local count = visual_row_count_from_provider(view, entry, method, line)
  if method == "rows_before" then
    local delta = math.max(0, count - (previous_total or 0))
    return delta, count
  end
  return count, count
end

local function provider_object_rows(view, entry, line, placement, previous_line_total)
  local provider = entry.provider
  if not (provider and provider.visual_rows) then return nil end
  local ok, rows = pcall(provider.visual_rows, provider, view, line, placement, previous_line_total or 0)
  if not ok then
    core.log_quiet("TextView visual row provider %s.visual_rows failed for %s: %s", tostring(entry.id), view.buffer:get_name(), tostring(rows))
    return nil
  end
  if rows == nil then return nil end
  if type(rows) ~= "table" then
    core.log_quiet("TextView visual row provider %s returned non-table rows for %s", tostring(entry.id), view.buffer:get_name())
    return nil
  end
  return rows
end

function TextView:append_provider_rows(entries, provider_entry, line, placement, previous_line_total)
  local rows = provider_object_rows(self, provider_entry, line, placement, previous_line_total)
  if not rows then return 0 end
  local seen = {}
  local added = 0
  for i, row in ipairs(rows) do
    if type(row) ~= "table" then
      core.log_quiet("TextView visual row provider %s row %d at %s:%d is not a table", tostring(provider_entry.id), i, placement, line)
    else
      local id = row.id or tostring(i)
      if seen[id] then
        core.log_quiet("TextView visual row provider %s duplicate row id %s at %s:%d", tostring(provider_entry.id), tostring(id), placement, line)
        seen[id] = seen[id] + 1
        id = tostring(id) .. "#" .. tostring(seen[id])
      else
        seen[id] = 1
      end
      if row.height_rows ~= nil and row.height_rows ~= 1 then
        core.log_quiet("TextView visual row provider %s row %s requested unsupported height_rows=%s", tostring(provider_entry.id), tostring(id), tostring(row.height_rows))
      end
      added = added + 1
      append_composed_entry(entries, {
        type = "provider",
        provider_id = provider_entry.id,
        line = line,
        placement = placement,
        row_in_provider = added,
        row_in_line = 1,
        provider_row = row,
        provider_row_id = id,
      })
    end
  end
  return added
end

function TextView:append_legacy_provider_rows(entries, provider_id, line, placement, count)
  count = math.max(0, math.floor(tonumber(count) or 0))
  for i = 1, count do
    append_composed_entry(entries, {
      type = "extra",
      provider_id = provider_id,
      line = line,
      placement = placement,
      row_in_provider = i,
      row_in_extra = i,
      row_in_line = 1,
      provider_row = { id = tostring(i), kind = "legacy-count", height_rows = 1 },
      provider_row_id = tostring(i),
    })
  end
end

function TextView:build_composed_visual_rows()
  local entries = {}
  local folds = self:get_collapsed_folds()
  local fidx = 1
  local provider_entries = self:visual_row_provider_entries()
  local previous_before = {}

  local function append_provider_placement(line, placement)
    for _, provider_entry in ipairs(provider_entries) do
      local previous_total = previous_before[provider_entry.id] or 0
      self:append_provider_rows(entries, provider_entry, line, placement, previous_total)
      local method = placement == "before" and "rows_before" or "rows_after"
      local count, total = legacy_visual_row_count(self, provider_entry, method, line, previous_total)
      if placement == "before" then previous_before[provider_entry.id] = total end
      self:append_legacy_provider_rows(entries, provider_entry.id, line, placement, count)
    end
  end

  local extension_previous_before = 0
  local function extension_count(line, placement)
    local total = 0
    for _, extension in pairs(self.visual_row_extensions or {}) do
      local source = placement == "before" and extension.before or extension.after
      local count = 0
      if type(source) == "function" then
        count = math.max(0, math.floor(tonumber(source(line, self)) or 0))
      elseif source then
        count = math.max(0, math.floor(tonumber(source[line]) or 0))
      end
      total = total + count
    end
    if placement == "before" then
      local delta = math.max(0, total - extension_previous_before)
      extension_previous_before = total
      return delta
    end
    return total
  end

  local line = 1
  while line <= #self.buffer.lines do
    while folds[fidx] and folds[fidx].line1 < line do fidx = fidx + 1 end
    self:append_legacy_provider_rows(entries, "visual-row-extension", line, "before", extension_count(line, "before"))
    append_provider_placement(line, "before")

    local fold = folds[fidx]
    if fold and line == fold.line1 then
      if fold.show_widget == false then
        local count = self:get_line_visual_row_count(line)
        for row_in_line = 1, count do
          local wrapped_idx
          if self.wrapped_settings then
            wrapped_idx = (self.wrapped_line_to_idx[line] or 1) + row_in_line - 1
          end
          append_composed_entry(entries, {
            type = "line", line = line, row_in_line = row_in_line,
            wrapped_idx = wrapped_idx, collapsed_fold = fold,
          })
        end
      else
        append_composed_entry(entries, {
          type = "fold", fold = fold, line = fold.line1, row_in_line = 1,
        })
      end
      append_provider_placement(line, "after")
      self:append_legacy_provider_rows(entries, "visual-row-extension", line, "after", extension_count(line, "after"))
      line = fold.line2 + 1
      fidx = fidx + 1
    else
      local count = self:get_line_visual_row_count(line)
      for row_in_line = 1, count do
        local wrapped_idx
        if self.wrapped_settings then
          wrapped_idx = (self.wrapped_line_to_idx[line] or 1) + row_in_line - 1
        end
        append_composed_entry(entries, { type = "line", line = line, row_in_line = row_in_line, wrapped_idx = wrapped_idx })
      end
      append_provider_placement(line, "after")
      self:append_legacy_provider_rows(entries, "visual-row-extension", line, "after", extension_count(line, "after"))
      line = line + 1
    end
  end

  if #entries == 0 then append_composed_entry(entries, { type = "line", line = 1, row_in_line = 1 }) end
  return entries
end

function TextView:composed_visual_rows()
  local snapshot_kind = core.ui_snapshot_active and "ui"
    or core.render_frame_active and "frame" or nil
  local snapshot_id = snapshot_kind == "ui" and core.ui_snapshot_id
    or snapshot_kind == "frame" and core.render_frame_id or nil
  if snapshot_id and self.__composed_visual_row_snapshot_kind == snapshot_kind
    and self.__composed_visual_row_snapshot_id == snapshot_id
  then
    return self.__composed_visual_row_snapshot_rows
  end
  local signature = self:visual_row_cache_signature()
  local cache = self.__composed_visual_row_cache
  if not cache or cache.signature ~= signature then
    local entries = self:build_composed_visual_rows()
    local position_rows = {}
    for index, entry in ipairs(entries) do
      if entry.type == "line" then
        position_rows[entry.line] = position_rows[entry.line] or index
      elseif entry.type == "fold" then
        for line = entry.fold.line1, entry.fold.line2 do
          position_rows[line] = index
        end
      end
    end
    -- A body-only fold keeps its first line as an ordinary rendered line.
    -- Hidden positions still map to that visible header row so navigation and
    -- reveal operations have a deterministic visual anchor.
    for _, fold in ipairs(self:get_collapsed_folds()) do
      if fold.show_widget == false then
        local header_row = position_rows[fold.line1]
        if header_row then
          for line = fold.line1 + 1, fold.line2 do
            if not position_rows[line] then position_rows[line] = header_row end
          end
        end
      end
    end
    cache = {
      signature = signature,
      entries = entries,
      position_rows = position_rows,
    }
    self.__composed_visual_row_cache = cache
  end
  if snapshot_id then
    self.__composed_visual_row_snapshot_kind = snapshot_kind
    self.__composed_visual_row_snapshot_id = snapshot_id
    self.__composed_visual_row_snapshot_rows = cache.entries
  end
  return cache.entries
end

function TextView:get_composed_visual_row_count()
  return #self:composed_visual_rows()
end

function TextView:get_composed_visual_row_for_position(line, col, line_end)
  line = common.clamp(line or 1, 1, #self.buffer.lines)
  local rows = self:composed_visual_rows()
  local indexed_row = self.__composed_visual_row_cache.position_rows[line]
  if indexed_row then
    local entry = rows[indexed_row]
    if entry.type == "line" and self.wrapped_settings then
      local idx = linewrapping.get_line_idx_col_count(self, line, col, line_end)
      local first_idx = self.wrapped_line_to_idx and self.wrapped_line_to_idx[line] or idx
      return common.clamp(
        indexed_row + math.max(0, idx - first_idx),
        indexed_row,
        indexed_row + self:get_line_visual_row_count(line) - 1
      )
    end
    return indexed_row
  end
  local fallback = 1
  for i, entry in ipairs(rows) do
    if entry.type == "line" and entry.line == line then
      if self.wrapped_settings then
        local idx = linewrapping.get_line_idx_col_count(self, line, col, line_end)
        local first_idx = self.wrapped_line_to_idx and self.wrapped_line_to_idx[line] or idx
        return common.clamp(i + math.max(0, idx - first_idx), i, i + self:get_line_visual_row_count(line) - 1)
      end
      return i
    elseif entry.type == "fold" and line >= entry.fold.line1 and line <= entry.fold.line2 then
      return i
    elseif entry.line and entry.line <= line then
      fallback = i
    end
  end
  return fallback
end

function TextView:get_visual_row_entry(target_row)
  target_row = common.clamp(math.floor(target_row or 1), 1, self:get_composed_visual_row_count())
  return self:composed_visual_rows()[target_row]
end

function TextView:get_metric_row_entry(row)
  if self:has_composed_visual_rows() then
    return self:get_visual_row_entry(row)
  elseif self.wrapped_settings then
    local line = linewrapping.get_idx_line_col(self, row)
    return { type = "line", line = line, row_in_line = math.max(1, row - (self.wrapped_line_to_idx[line] or row) + 1), absolute_row = row, row = row, wrapped_idx = row }
  end
  return { type = "line", line = row, row_in_line = 1, absolute_row = row, row = row }
end

function TextView:get_visual_metric_signature(
  wrap_layout_generation, row_count_override, text_revision_override
)
  local row_count = row_count_override or self:get_scrollable_line_count()
  local line_height = self:get_line_height()
  local text_revision = text_revision_override or self.buffer.text_revision or 0
  local fold_generation = self.fold_generation or 0
  local wrap_generation = wrap_layout_generation or self.__wrap_layout_generation or 0
  local metric_generation = self.__visual_metric_generation or 0
  local theme_generation = core.color_theme_generation or 0
  local presentation_generation = self:get_presentation_layout_generation()
  local entries = self:visual_metric_provider_entries()
  local cacheable = wrap_layout_generation == nil
    and row_count_override == nil and text_revision_override == nil
  for _, entry in ipairs(entries) do
    local provider = entry.provider
    if provider and provider.generation and not provider.generation_seed then
      cacheable = false
      break
    end
  end

  local state = cacheable and self.__visual_metric_signature_state
  local same = state
    and state.row_count == row_count
    and state.line_height == line_height
    and state.text_revision == text_revision
    and state.fold_generation == fold_generation
    and state.wrap_generation == wrap_generation
    and state.metric_generation == metric_generation
    and state.theme_generation == theme_generation
    and state.presentation_generation == presentation_generation
    and state.entries == entries
  if same then
    for index, entry in ipairs(entries) do
      local provider = entry.provider
      local seed_fn = provider and provider.generation and provider.generation_seed
      if seed_fn then
        local ok, seed = pcall(seed_fn, provider, self)
        if state.provider_seeds[index] ~= (ok and seed or "error") then
          same = false
          break
        end
      elseif state.provider_seeds[index] ~= nil then
        same = false
        break
      end
    end
  end
  if same then
    self.render_cache_diagnostics.metric_signature_cache_hits =
      self.render_cache_diagnostics.metric_signature_cache_hits + 1
    perf_frame_add("textview_visual_metric_signature_cache_hits", 1)
    return state.signature
  end

  local parts = {
    tostring(row_count),
    tostring(line_height),
    tostring(text_revision),
    tostring(fold_generation),
    tostring(wrap_generation),
    tostring(metric_generation),
    tostring(theme_generation),
    tostring(presentation_generation),
  }
  for _, entry in ipairs(entries) do
    parts[#parts + 1] = tostring(entry.id)
    parts[#parts + 1] = tostring(entry.priority)
    local provider = entry.provider
    if provider and provider.generation then
      local ok, gen = pcall(provider.generation, provider, self)
      parts[#parts + 1] = ok and tostring(gen) or "error"
    end
  end
  local signature = table.concat(parts, "|")
  self.render_cache_diagnostics.metric_signature_computations =
    self.render_cache_diagnostics.metric_signature_computations + 1
  perf_frame_add("textview_visual_metric_signature_computations", 1)
  if cacheable then
    local provider_seeds = {}
    for index, entry in ipairs(entries) do
      local provider = entry.provider
      local seed_fn = provider and provider.generation and provider.generation_seed
      if seed_fn then
        local ok, seed = pcall(seed_fn, provider, self)
        provider_seeds[index] = ok and seed or "error"
      end
    end
    self.__visual_metric_signature_state = {
      signature = signature,
      row_count = row_count,
      line_height = line_height,
      text_revision = text_revision,
      fold_generation = fold_generation,
      wrap_generation = wrap_generation,
      metric_generation = metric_generation,
      theme_generation = theme_generation,
      presentation_generation = presentation_generation,
      entries = entries,
      provider_seeds = provider_seeds,
    }
  end
  return signature
end

metric_tree_add = function(tree, row_count, row, delta)
  while row <= row_count do
    tree[row] = (tree[row] or 0) + delta
    row = row + bit.band(row, -row)
  end
end

metric_tree_build = function(heights, row_count)
  local tree = {}
  for row = 1, row_count do
    tree[row] = (tree[row] or 0) + (heights[row] or 0)
    local parent = row + bit.band(row, -row)
    if parent <= row_count then tree[parent] = (tree[parent] or 0) + tree[row] end
  end
  return tree
end

local function metric_tree_sum(tree, row)
  local total = 0
  while row > 0 do
    total = total + (tree[row] or 0)
    row = row - bit.band(row, -row)
  end
  return total
end

metric_tree_row_at_y = function(tree, row_count, y)
  local index, accumulated = 0, 0
  local step = 1
  while step * 2 <= row_count do step = step * 2 end
  while step > 0 do
    local next_index = index + step
    local next_total = accumulated + (tree[next_index] or 0)
    if next_index <= row_count and next_total <= y then
      index = next_index
      accumulated = next_total
    end
    step = math.floor(step / 2)
  end
  return common.clamp(index + 1, 1, row_count)
end

local function prepare_sparse_visual_metrics(view, providers, default_height, row_count)
  local prepared = {}
  for _, provider_entry in ipairs(providers) do
    local provider = provider_entry.provider
    if provider and provider.sparse_line_metrics then
      local ok, descriptor = pcall(
        provider.sparse_line_metrics, provider, view, row_count, default_height
      )
      if ok and type(descriptor) == "table" and descriptor.complete then
        prepared[provider_entry.id] = descriptor
        if descriptor.default_height then
          default_height = math.max(1, tonumber(descriptor.default_height) or default_height)
        end
      elseif not ok then
        core.log_quiet(
          "TextView visual metric provider %s.sparse_line_metrics failed for %s: %s",
          tostring(provider_entry.id), view.buffer:get_name(), tostring(descriptor)
        )
      end
    end
  end
  return prepared, default_height
end

compute_visual_row_height = function(
  view, row, providers, default_height, sparse_metrics, force, line_metrics_cache
)
  view.render_cache_diagnostics.metric_recomputations =
    view.render_cache_diagnostics.metric_recomputations + 1
  local entry = view:get_metric_row_entry(row)
  local height = default_height
  for _, provider_entry in ipairs(providers) do
    local provider = provider_entry.provider
    local sparse = sparse_metrics and sparse_metrics[provider_entry.id]
    local should_query = force or not sparse
      or (sparse.rows and sparse.rows[row])
      or (sparse.lines and sparse.lines[entry.line])
    if should_query and provider and provider.line_metrics and entry.row_in_line then
      local provider_cache = line_metrics_cache and line_metrics_cache[provider_entry.id]
      if not provider_cache and line_metrics_cache then
        provider_cache = {}
        line_metrics_cache[provider_entry.id] = provider_cache
      end
      local descriptor = provider_cache and provider_cache[entry.line]
      if descriptor == nil then
        view.render_cache_diagnostics.metric_provider_queries =
          view.render_cache_diagnostics.metric_provider_queries + 1
        local ok, value = pcall(
          provider.line_metrics, provider, view, entry.line,
          view:get_visual_row_count_for_line(entry.line)
        )
        if not ok then
          core.log_quiet(
            "TextView visual metric provider %s.line_metrics failed for %s: %s",
            tostring(provider_entry.id), view.buffer:get_name(), tostring(value)
          )
          value = false
        end
        descriptor = type(value) == "table" and value or false
        if provider_cache then provider_cache[entry.line] = descriptor end
      end
      if descriptor then
        local value = descriptor.heights and descriptor.heights[entry.row_in_line]
          or (entry.row_in_line == descriptor.row_count and descriptor.final_height)
          or descriptor.height
        if value then height = math.max(1, tonumber(value) or height) end
      elseif provider.line_height then
        local ok, value = pcall(provider.line_height, provider, view, entry.line, entry)
        if ok and value then
          height = math.max(1, tonumber(value) or height)
        elseif not ok then
          core.log_quiet(
            "TextView visual metric provider %s.line_height failed for %s: %s",
            tostring(provider_entry.id), view.buffer:get_name(), tostring(value)
          )
        end
      end
    elseif should_query and provider and provider.line_height then
      view.render_cache_diagnostics.metric_provider_queries =
        view.render_cache_diagnostics.metric_provider_queries + 1
      local ok, value = pcall(provider.line_height, provider, view, entry.line, entry)
      if ok and value then
        height = math.max(1, tonumber(value) or height)
      elseif not ok then
        core.log_quiet(
          "TextView visual metric provider %s.line_height failed for %s: %s",
          tostring(provider_entry.id), view.buffer:get_name(), tostring(value)
        )
      end
    elseif sparse and provider and provider.line_height then
      view.render_cache_diagnostics.metric_sparse_skips =
        view.render_cache_diagnostics.metric_sparse_skips + 1
    end
  end
  return height
end

function TextView:get_visual_row_metric_cache()
  if not self:has_visual_metric_providers() then return nil end
  -- One UI phase observes one coherent provider state. Explicit
  -- invalidation clears this snapshot immediately.
  local snapshot_kind = core.ui_snapshot_active and "ui"
    or core.render_frame_active and "frame" or nil
  local snapshot_id = snapshot_kind == "ui" and core.ui_snapshot_id
    or snapshot_kind == "frame" and core.render_frame_id or nil
  if snapshot_id and self.__visual_metric_snapshot_kind == snapshot_kind
    and self.__visual_metric_snapshot_id == snapshot_id
  then
    return self.__visual_metric_snapshot_cache
  end
  local perf_active = core.perf_frame_stats ~= nil
  local lookup_start = perf_active and system.get_time()
  perf_frame_add("textview_visual_metric_cache_calls", 1)
  local signature_start = perf_active and system.get_time()
  local signature = self:get_visual_metric_signature()
  perf_elapsed("textview_visual_metric_signature_ms", signature_start)
  local cache = self.__visual_metric_cache
  local providers = self:visual_metric_provider_entries()
  local default_height = self:get_line_height()
  if cache and cache.signature == signature then
    self.render_cache_diagnostics.metric_cache_hits =
      self.render_cache_diagnostics.metric_cache_hits + 1
    perf_frame_add("textview_visual_metric_cache_hits", 1)
    if cache.dirty_rows then
      local dirty_rows = 0
      for _ in pairs(cache.dirty_rows) do dirty_rows = dirty_rows + 1 end
      self.render_cache_diagnostics.metric_dirty_passes =
        self.render_cache_diagnostics.metric_dirty_passes + 1
      self.render_cache_diagnostics.metric_dirty_rows =
        self.render_cache_diagnostics.metric_dirty_rows + dirty_rows
      perf_frame_add("textview_visual_metric_dirty_passes", 1)
      perf_frame_add("textview_visual_metric_dirty_rows", dirty_rows)
      local anchor_row = metric_tree_row_at_y(
        cache.height_tree, cache.row_count, math.max(0, self.scroll and self.scroll.y or 0)
      )
      local anchor_delta = 0
      local line_metrics_cache = {}
      for row in pairs(cache.dirty_rows) do
        local height = compute_visual_row_height(
          self, row, providers, cache.default_height or default_height,
          cache.sparse_metrics, true, line_metrics_cache
        )
        local delta = height - cache.heights[row]
        if delta ~= 0 then
          cache.heights[row] = height
          cache.total_height = cache.total_height + delta
          metric_tree_add(cache.height_tree, cache.row_count, row, delta)
          if row < anchor_row then anchor_delta = anchor_delta + delta end
        end
      end
      cache.dirty_rows = nil
      if anchor_delta ~= 0 and self.scroll then
        self.scroll.y = self.scroll.y + anchor_delta
        self.scroll.to.y = self.scroll.to.y + anchor_delta
      end
    end
    perf_elapsed("textview_visual_metric_cache_lookup_ms", lookup_start)
    if snapshot_id then
      self.__visual_metric_snapshot_kind = snapshot_kind
      self.__visual_metric_snapshot_id = snapshot_id
      self.__visual_metric_snapshot_cache = cache
    end
    return cache
  end

  if cache then
    self.render_cache_diagnostics.metric_signature_changes =
      self.render_cache_diagnostics.metric_signature_changes + 1
    perf_frame_add("textview_visual_metric_signature_changes", 1)
    perf_detail(
      "textview_visual_metric_signature_transition:" ..
      tostring(cache.signature) .. " -> " .. tostring(signature),
      1
    )
  end

  local rebuild_start = perf_active and system.get_time()
  local row_count = self:get_scrollable_line_count()
  local sparse_metrics
  sparse_metrics, default_height = prepare_sparse_visual_metrics(
    self, providers, default_height, row_count
  )
  self.render_cache_diagnostics.metric_full_rebuilds =
    self.render_cache_diagnostics.metric_full_rebuilds + 1
  self.render_cache_diagnostics.metric_full_rebuild_rows =
    self.render_cache_diagnostics.metric_full_rebuild_rows + row_count
  perf_frame_add("textview_visual_metric_full_rebuilds", 1)
  perf_frame_add("textview_visual_metric_full_rebuild_rows", row_count)
  local heights = {}
  local line_metrics_cache = {}
  local total = 0
  for row = 1, row_count do
    local height = compute_visual_row_height(
      self, row, providers, default_height, sparse_metrics, false,
      line_metrics_cache
    )
    heights[row] = height
    total = total + height
  end
  local height_tree = metric_tree_build(heights, row_count)
  cache = {
    signature = signature,
    wrap_layout_generation = self.__wrap_layout_generation or 0,
    text_revision = self.buffer.text_revision or 0,
    heights = heights,
    height_tree = height_tree,
    total_height = total,
    row_count = row_count,
    invalidated_rows = 0,
    default_height = default_height,
    sparse_metrics = sparse_metrics,
  }
  self.__visual_metric_cache = cache
  if snapshot_id then
    self.__visual_metric_snapshot_kind = snapshot_kind
    self.__visual_metric_snapshot_id = snapshot_id
    self.__visual_metric_snapshot_cache = cache
  end
  perf_elapsed("textview_visual_metric_full_rebuild_ms", rebuild_start)
  perf_elapsed("textview_visual_metric_cache_lookup_ms", lookup_start)
  return cache
end

function TextView:get_visual_row_height(row)
  local cache = self:get_visual_row_metric_cache()
  return cache and cache.heights[common.clamp(row, 1, cache.row_count)] or self:get_line_height()
end

---Returns the resolved visual-row height for a Buffer position.
---@param line integer
---@param col? integer
---@param line_end? boolean
---@return number
function TextView:get_position_visual_row_height(line, col, line_end)
  return self:get_visual_row_height(self:get_visual_row(line, col or 1, line_end))
end

---Returns the caret height requested by a specialized line presentation.
---@param line integer
---@param col? integer
---@param line_end? boolean
---@return number
function TextView:get_position_caret_height(line, col, line_end)
  local row_height = self:get_position_visual_row_height(line, col, line_end)
  local render_line = self:get_line_render(line)
  local _, position_row = self:get_position_line_render_row(line, col or 1)
  if position_row and position_row.height then
    row_height = math.max(1, tonumber(position_row.height) or row_height)
  end
  local requested = render_line and render_line.caret_height
  if type(requested) == "function" then
    local ok, value = pcall(requested, self, render_line, line, col or 1, row_height)
    if ok then requested = value else
      core.log_quiet(
        "TextView line-render caret height failed for %s: %s",
        self.buffer:get_name(), tostring(value)
      )
      requested = nil
    end
  end
  return math.max(1, tonumber(requested) or row_height)
end

function TextView:get_visual_row_y_offset(row)
  local cache = self:get_visual_row_metric_cache()
  if cache then
    row = common.clamp(row, 1, cache.row_count + 1)
    return metric_tree_sum(cache.height_tree, row - 1)
  end
  return math.max(0, row - 1) * self:get_line_height()
end

function TextView:get_visual_row_at_y(y)
  local cache = self:get_visual_row_metric_cache()
  if not cache then
    return common.clamp(math.floor(y / self:get_line_height()) + 1, 1, self:get_scrollable_line_count())
  end
  return metric_tree_row_at_y(cache.height_tree, cache.row_count, y)
end

local function overscan_metric_rows(cache, first, last, total)
  if cache then
    first = math.max(1, first - 1)
    last = math.min(total, last + 1)
  end
  return first, last
end

function TextView:iter_visible_visual_rows()
  local _, y1, _, y2 = self:get_content_bounds()
  local total = self:get_scrollable_line_count()
  local cache = self:get_visual_row_metric_cache()
  local row, last
  if cache then
    row = self:get_visual_row_at_y(math.max(0, y1 - style.padding.y))
    last = self:get_visual_row_at_y(math.max(0, y2 - style.padding.y))
  else
    local lh = self:get_line_height()
    row = math.max(1, math.floor((y1 - style.padding.y) / lh) + 1)
    last = math.min(total, math.floor((y2 - style.padding.y) / lh) + 1)
  end
  row = common.clamp(row, 1, total)
  last = common.clamp(last, 1, total)
  row, last = overscan_metric_rows(cache, row, last, total)
  local x, base_y = self:get_content_offset()
  return function()
    if row > last then return nil end
    local current = row
    row = row + 1
    local entry = self:get_visual_row_entry(current)
    entry.visual_row = current
    entry.y = base_y + self:get_visual_row_y_offset(current) + style.padding.y
    entry.height = self:get_visual_row_height(current)
    return entry
  end
end

function TextView:expand_folds_covering_range(line1, col1, line2, col2, reason)
  line1, line2 = normalize_fold_lines(self.buffer, line1, line2 or line1)
  local changed = false
  for _, fold in ipairs(self:get_collapsed_folds()) do
    if not (line2 < fold.line1 or line1 > fold.line2) then
      fold.collapsed = false
      changed = true
    end
  end
  if changed then self:bump_fold_generation(reason or "expand-range") end
  return changed
end

function TextView:expand_folds_at_line(line, reason)
  return self:expand_folds_covering_range(line, 1, line, 1, reason or "expand-line")
end

function TextView:select_and_reveal(line1, col1, line2, col2, opts)
  opts = opts or {}
  if opts.fold_policy ~= "keep" then
    self:expand_folds_covering_range(line1, col1, line2 or line1, col2 or col1, opts.reason or "select-and-reveal")
  end
  self.buffer:set_selection(line1, col1, line2 or line1, col2 or col1)
  self:scroll_to_make_visible(line1, col1, opts.instant, { line2 = line2, col2 = col2 })
end

function TextView:reveal_range(line1, col1, line2, col2, opts)
  opts = opts or {}
  if opts.fold_policy ~= "keep" then
    self:expand_folds_covering_range(line1, col1, line2 or line1, col2 or col1, opts.reason or "reveal-range")
  end
  self:scroll_to_make_visible(line1, col1, opts.instant, { line2 = line2, col2 = col2 })
end

local function line_indent(text)
  return #(tostring(text or ""):match("^[ \t]*") or "")
end

local function is_blank_line(text)
  return tostring(text or ""):match("^%s*$") ~= nil
end

function TextView:get_fold_target(line1, col1, line2, col2, opts)
  line1 = common.clamp(line1 or 1, 1, #self.buffer.lines)
  line2 = common.clamp(line2 or line1, 1, #self.buffer.lines)
  col1, col2 = col1 or 1, col2 or col1 or 1
  if line2 < line1 or line2 == line1 and col2 < col1 then
    line1, col1, line2, col2 = line2, col2, line1, col1
  end

  if line2 > line1 then
    if col2 == 1 then line2 = math.max(line1, line2 - 1) end
    if line2 > line1 then
      return { line1 = line1, col1 = 1, line2 = line2, col2 = #self.buffer.lines[line2] + 1, kind = "selection" }
    end
  end

  local function indentation_target_at(start, kind)
    while start <= #self.buffer.lines and is_blank_line(self.buffer.lines[start]) do start = start + 1 end
    if start > #self.buffer.lines then return nil end
    local base_indent = line_indent(self.buffer.lines[start])
    local last = start
    for line = start + 1, #self.buffer.lines do
      local text = self.buffer.lines[line]
      if is_blank_line(text) then
        last = line
      elseif line_indent(text) > base_indent then
        last = line
      else
        break
      end
    end
    while last > start and is_blank_line(self.buffer.lines[last]) do last = last - 1 end
    if last > start then
      return { line1 = start, col1 = 1, line2 = last, col2 = #self.buffer.lines[last] + 1, kind = kind or "indent" }
    end
  end

  local syntax_target, syntax_reason = language_intelligence.fold_target(self.buffer, line1, col1, line2, col2)
  if syntax_target then return syntax_target end
  if syntax_reason and syntax_reason ~= "no-provider" and syntax_reason ~= "unsupported" and syntax_reason ~= "not-ready" then
    core.log_quiet("Syntax Fold Target unavailable for %s: %s", self.buffer:get_name(), tostring(syntax_reason))
  end

  local direct = indentation_target_at(line1, "indent")
  if direct then return direct end

  for start = line1 - 1, 1, -1 do
    if not is_blank_line(self.buffer.lines[start]) then
      local target = indentation_target_at(start, "enclosing-indent")
      if target and target.line2 >= line1 then return target end
    end
  end
end

function TextView:fold_at_caret(opts)
  opts = opts or {}
  local line1, col1, line2, col2 = self.buffer:get_selection(true)
  local target = self:get_fold_target(line1, col1, line2, col2, opts)
  if not target then return nil, "no foldable multi-line range at caret" end
  for _, fold in ipairs(self.fold_regions or {}) do
    if self:refresh_fold_region(fold) and fold.line1 == target.line1 and fold.line2 == target.line2 then
      if not fold.collapsed then self:collapse_fold_region(fold, "fold-at-caret") end
      return fold
    end
  end
  return self:add_fold_region(target)
end

function TextView:unfold_at_caret(reason)
  reason = reason or "unfold-at-caret"
  local changed = false
  for _, line1, col1, line2, col2 in self.buffer:get_selections(true) do
    if line1 ~= line2 or col1 ~= col2 then
      if self:expand_folds_covering_range(line1, col1, line2, col2, reason) then
        changed = true
      end
    end
  end
  if changed then return true end

  local line = self.buffer:get_selection()
  local fold = self:get_collapsed_fold_at_line(line)
  if fold then return self:expand_fold_region(fold, reason) end
  return false
end

function TextView:unfold_all(reason)
  local changed = false
  for _, fold in ipairs(self.fold_regions or {}) do
    if fold.collapsed then
      fold.collapsed = false
      changed = true
    end
  end
  if changed then self:bump_fold_generation(reason or "unfold-all") end
  return changed
end

local function selection_overlaps_fold(buffer, fold)
  for _, line1, col1, line2, col2 in buffer:get_selections(true) do
    if (line1 ~= line2 or col1 ~= col2) and line1 <= fold.line2 and line2 >= fold.line1 then return true end
  end
  return false
end

local function position_le(line1, col1, line2, col2)
  return line1 < line2 or line1 == line2 and col1 <= col2
end

local function position_ge(line1, col1, line2, col2)
  return line1 > line2 or line1 == line2 and col1 >= col2
end

local function line_render_content_geometry(render_line, row_height, first_row)
  local first_row_offset = first_row
    and math.max(0, tonumber(render_line.first_row_content_y_offset) or 0) or 0
  first_row_offset = math.min(first_row_offset, math.max(0, row_height - 1))
  local available_height = math.max(1, row_height - first_row_offset)
  local content_height = render_line.table_row and available_height or math.min(
    available_height, render_line.text_row_height or available_height
  )
  local y_offset = first_row_offset
  if render_line.content_vertical_alignment == "bottom" then
    y_offset = y_offset + math.max(0, available_height - content_height)
  end
  return y_offset, content_height
end

local function position_is_first_visual_row(view, line, col, line_end)
  return view:get_visual_row(line, col or 1, line_end)
    == view:get_visual_row(line, 1, false)
end

---Return the content geometry of a specialized rendered line.
---The visual row may include spacing that is not occupied by the rendered
---text (for example, Markdown block spacing before a heading). Consumers
---that draw or hit-test text-relative elements must use this geometry rather
---than treating the visual row origin as the content origin.
---@param line integer
---@param col? integer
---@param line_end? boolean
---@return number? y_offset Relative Y offset of the rendered content
---@return number? height Height of the rendered content
---@return table? render_line
---@return table? position_row
function TextView:get_line_render_content_geometry(line, col, line_end)
  local render_line = self:get_line_render(line)
  if not render_line then return nil end

  local _, position_row = self:get_position_line_render_row(line, col or 1)
  if position_row then
    return position_row.y_offset or 0,
      math.max(1, position_row.height or self:get_line_height()),
      render_line, position_row
  end

  local row_height = self:get_position_visual_row_height(
    line, col or 1, line_end
  )
  local y_offset, height = line_render_content_geometry(
    render_line, row_height,
    position_is_first_visual_row(self, line, col, line_end)
  )
  return y_offset, height, render_line, nil
end

local function selection_covers_fold(buffer, fold)
  local fold_col1 = fold.col1 or 1
  local fold_col2 = fold.col2 or (#(buffer.lines[fold.line2] or "") + 1)
  for _, line1, col1, line2, col2 in buffer:get_selections(true) do
    if (line1 ~= line2 or col1 ~= col2)
    and position_le(line1, col1, fold.line1, fold_col1)
    and position_ge(line2, col2, fold.line2, fold_col2) then
      return true
    end
  end
  return false
end

function TextView:draw_fold_widget_gutter(fold, x, y, width, height)
  local lh = height or self:get_line_height()
  renderer.draw_rect(x, y, width, lh, style.gutter_bg or style.background2)
  if self:line_number_visible_at(fold.line1) then
    local color = selection_overlaps_fold(self.buffer, fold) and style.line_number2 or style.line_number
    common.draw_text(self:get_font(), color, tostring(fold.line1), "right", x + style.padding.x, y, width - style.padding.x, lh)
  end
  return lh
end

function TextView:draw_fold_widget_body(fold, x, y, height)
  local lh = height or self:get_line_height()
  local bx = x + self.scroll.x
  local bw = math.max(0, self.position.x + self.size.x - bx)
  local bg = selection_covers_fold(self.buffer, fold) and style.selection or style.fold_widget_background
  renderer.draw_rect(bx, y, bw, lh, bg)
  local border = style.fold_widget_border or style.fold_widget_effect or style.accent
  local t = math.max(1, common.round(SCALE))
  renderer.draw_rect(bx, y, bw, t, border)
  renderer.draw_rect(bx, y + lh - t, bw, t, border)
  renderer.draw_rect(bx, y, t, lh, border)
  renderer.draw_rect(bx + bw - t, y, t, lh, border)
  common.draw_text(self:get_font(), style.fold_widget_text or style.dim, fold_placeholder(self.buffer, fold), "left", x + style.padding.x, y, self.size.x, lh)
  return lh
end


---Get the screen position of a line (and optionally column).
---@param line integer Line number
---@param col? integer Optional column number
---@return number x Screen x coordinate
---@return number y Screen y coordinate
function TextView:get_line_screen_position(line, col, line_end)
  local function render_y_offset()
    if not col then return 0 end
    local _, row = self:get_position_line_render_row(line, col)
    return row and (row.y_offset or 0) or 0
  end
  if self.wrapped_settings then
    if line_end == nil and self.__use_wrapped_caret_affinity then
      line_end = linewrapping.has_wrapped_line_end_affinity(self, line, col)
    end
    local idx
    if self:has_composed_visual_rows() then
      idx = self:get_composed_visual_row_for_position(line, col, line_end)
    else
      idx = linewrapping.get_line_idx_col_count(self, line, col, line_end)
    end
    local x, y = self:get_content_offset()
    local gw = self:get_gutter_width()
    return x + gw + (col and self:get_col_x_offset(line, col, line_end) or 0),
      y + self:get_visual_row_y_offset(idx) + style.padding.y + render_y_offset()
  end
  local x, y = self:get_content_offset()
  local gw = self:get_gutter_width()
  local row = self:has_composed_visual_rows() and self:get_composed_visual_row_for_position(line, col, line_end) or line
  y = y + self:get_visual_row_y_offset(row) + style.padding.y + render_y_offset()
  if col then
    return x + gw + self:get_col_x_offset(line, col), y
  else
    return x + gw, y
  end
end


---Get the vertical offset for centering text within a line.
---@return number offset Y offset to center text in line height
function TextView:get_line_text_y_offset()
  local lh = self:get_line_height()
  local th = self:get_font():get_height()
  return (lh - th) / 2
end


---Get an estimated range of visible columns. It is an estimate because fonts
---and their fallbacks may not be monospaced or may differ in size. This
---function provides a way of optimization on really long lines for plugins
---that perform drawing operations on them.
---
---It is good practice to set the `extra_cols` parameter to a value that leaves
---room for the differences in font sizes.
---@param line integer
---@param extra_cols? integer Amount of columns to deduce on col1 and include on col2 (default: 100)
---@return integer col1
---@return integer col2
---@return integer ucol1
---@return integer ucol2
function TextView:get_visible_cols_range(line, extra_cols)
  extra_cols = extra_cols or 100

  local text = self.buffer.lines[line]
  local line_len = #text
  if line_len == 1 then return 1, 1, 1, 1 end

  local gw = self:get_gutter_width()
  local line_x = self.position.x + gw
  local x = -self.scroll.x + self.position.x + gw
  local char_width = self:get_font():get_width("W")
  local non_visible_x = common.clamp(line_x - x, 0, math.huge)

  local non_visible_chars_left = math.floor(non_visible_x / char_width)
  local visible_chars_right = math.floor((self.size.x - gw) / char_width)

  if non_visible_chars_left > line_len then return 0, 0, 0, 0 end

  local col1 = math.max(1, non_visible_chars_left - extra_cols)
  local col2 = math.min(line_len, non_visible_chars_left + (visible_chars_right*2) + extra_cols)
  local ucol1, ucol2 = col1, col2

  -- if line shorter than estimate then handle utf8 stuff
  local cache = self.buffer.cache.ulen
  local ulen = cache[line]
  if not ulen then
    ulen = text:ulen(nil, nil, true)
    cache[line] = ulen
  end
  if ulen < line_len then
    ucol1 = text:ulen(1, col1, true)
    ucol2 = text:ulen(1, col2, true)
    col1 = text:ucharpos(ucol1)
    col2 = text:ucharpos(ucol2)
  end

  return col1, col2, ucol1, ucol2
end


---Get the range of visible lines in the current viewport.
---@return integer minline First visible line
---@return integer maxline Last visible line
function TextView:get_visible_line_range()
  local x, y, x2, y2 = self:get_content_bounds()
  local cache = self:get_visual_row_metric_cache()
  local lh = self:get_line_height()
  if self:has_composed_visual_rows() then
    local total = self:get_composed_visual_row_count()
    local minidx = cache and self:get_visual_row_at_y(math.max(0, y - style.padding.y)) or math.max(1, math.floor((y - style.padding.y) / lh) + 1)
    local maxidx = cache and self:get_visual_row_at_y(math.max(0, y2 - style.padding.y)) or math.min(total, math.floor((y2 - style.padding.y) / lh) + 1)
    minidx = common.clamp(minidx, 1, total)
    maxidx = common.clamp(maxidx, 1, total)
    minidx, maxidx = overscan_metric_rows(cache, minidx, maxidx, total)
    local first = self:get_visual_row_entry(minidx)
    local last = self:get_visual_row_entry(maxidx)
    return first and first.line or 1, last and (last.fold and last.fold.line2 or last.line) or #self.buffer.lines
  end
  if self.wrapped_settings then
    local total = linewrapping.get_total_wrapped_lines(self)
    local minidx = cache and self:get_visual_row_at_y(math.max(0, y - style.padding.y)) or math.max(1, math.floor((y - style.padding.y) / lh) + 1)
    local maxidx = cache and self:get_visual_row_at_y(math.max(0, y2 - style.padding.y)) or math.min(total, math.floor((y2 - style.padding.y) / lh) + 1)
    minidx = common.clamp(minidx, 1, total)
    maxidx = common.clamp(maxidx, 1, total)
    minidx, maxidx = overscan_metric_rows(cache, minidx, maxidx, total)
    local minline = linewrapping.get_idx_line_col(self, minidx)
    local maxline = linewrapping.get_idx_line_col(self, maxidx)
    return minline, maxline
  end
  local minline = cache and self:get_visual_row_at_y(math.max(0, y - style.padding.y)) or math.max(1, math.floor((y - style.padding.y) / lh) + 1)
  local maxline = cache and self:get_visual_row_at_y(math.max(0, y2 - style.padding.y)) or math.min(#self.buffer.lines, math.floor((y2 - style.padding.y) / lh) + 1)
  minline = common.clamp(minline, 1, #self.buffer.lines)
  maxline = common.clamp(maxline, 1, #self.buffer.lines)
  minline, maxline = overscan_metric_rows(cache, minline, maxline, #self.buffer.lines)
  return minline, maxline
end


local function line_render_signature(view, line, snapshot_provider_generations)
  local parts = {
    tostring(view.__line_render_generation or 0),
    tostring(core.color_theme_generation or 0),
  }
  for _, entry in ipairs(view:line_render_provider_entries()) do
    parts[#parts + 1] = tostring(entry.id)
    parts[#parts + 1] = tostring(entry.priority)
    local provider = entry.provider
    local line_generation = provider and provider.line_generation
    if line_generation then
      local ok, generation = pcall(line_generation, provider, view, line)
      parts[#parts + 1] = ok and tostring(generation) or "error"
    elseif provider and provider.generation then
      local resolved = snapshot_provider_generations
        and snapshot_provider_generations[entry] or nil
      if not resolved then
        local ok, generation = pcall(provider.generation, provider, view)
        resolved = { value = ok and tostring(generation) or "error" }
        if snapshot_provider_generations then
          snapshot_provider_generations[entry] = resolved
        end
      end
      parts[#parts + 1] = resolved.value
    end
  end
  return table.concat(parts, "\0")
end

function TextView:get_line_render(line)
  if not self:has_line_render_providers() then return nil end
  -- Repeated geometry and draw queries must reuse the line resolved earlier
  -- in this UI phase. Explicit invalidation clears the snapshot.
  local snapshot_kind = core.ui_snapshot_active and "ui"
    or core.render_frame_active and "frame" or nil
  local snapshot_id = snapshot_kind == "ui" and core.ui_snapshot_id
    or snapshot_kind == "frame" and core.render_frame_id or nil
  local snapshot_lines
  local invalidation_generation = self.__line_render_invalidation_generation or 0
  if snapshot_id then
    if self.__line_render_snapshot_kind ~= snapshot_kind
      or self.__line_render_snapshot_id ~= snapshot_id
      or self.__line_render_snapshot_invalidation_generation ~= invalidation_generation
    then
      self.__line_render_snapshot_kind = snapshot_kind
      self.__line_render_snapshot_id = snapshot_id
      self.__line_render_snapshot_invalidation_generation = invalidation_generation
      self.__line_render_snapshot_lines = {}
      self.__line_render_snapshot_provider_generations = {}
    end
    snapshot_lines = self.__line_render_snapshot_lines
    local snapshot_result = snapshot_lines[line]
    if snapshot_result ~= nil then return snapshot_result or nil end
  end
  local perf_active = core.perf_frame_stats ~= nil
  local lookup_start = perf_active and system.get_time()
  perf_frame_add("textview_line_render_cache_calls", 1)
  local source_line = self.buffer.lines[line] or ""
  local generation = self.__line_render_generation or 0
  local cache = self.__line_render_cache
  if not cache or cache.generation ~= generation then
    cache = { generation = generation, lines = {}, hits = 0, misses = 0, invalidated_lines = 0 }
    self.__line_render_cache = cache
  end
  local signature = line_render_signature(
    self, line, snapshot_id and self.__line_render_snapshot_provider_generations or nil
  )
  local cached = cache.lines[line]
  if cached and cached.source_line == source_line and cached.signature == signature then
    cache.hits = cache.hits + 1
    self.render_cache_diagnostics.line_hits = self.render_cache_diagnostics.line_hits + 1
    perf_frame_add("textview_line_render_cache_hits", 1)
    perf_elapsed("textview_line_render_cache_lookup_ms", lookup_start)
    if snapshot_lines then snapshot_lines[line] = cached.render_line or false end
    return cached.render_line or nil
  end
  cache.misses = cache.misses + 1
  self.render_cache_diagnostics.line_misses = self.render_cache_diagnostics.line_misses + 1
  perf_frame_add("textview_line_render_cache_misses", 1)
  if cached then
    self.render_cache_diagnostics.line_signature_misses =
      self.render_cache_diagnostics.line_signature_misses + 1
    perf_frame_add("textview_line_render_signature_misses", 1)
  else
    self.render_cache_diagnostics.line_cold_misses =
      self.render_cache_diagnostics.line_cold_misses + 1
    perf_frame_add("textview_line_render_cold_misses", 1)
  end
  local build_start = perf_active and system.get_time()
  local source_text = source_line:sub(-1) == "\n" and source_line:sub(1, -2) or source_line
  local context = { source_text = source_text, line = line }
  local resolved
  for _, entry in ipairs(self:line_render_provider_entries()) do
    local provider = entry.provider
    if provider and provider.render_line then
      local ok, render_line = pcall(provider.render_line, provider, self, line, context)
      if ok and render_line and not render_line.raw_passthrough then
        render_line.source_text = render_line.source_text or source_text
        resolved = render_line
        break
      elseif not ok then
        core.log_quiet("TextView line render provider %s.render_line failed for %s: %s", tostring(entry.id), self.buffer:get_name(), tostring(render_line))
      end
    end
  end
  cache.lines[line] = {
    source_line = source_line,
    signature = signature,
    render_line = resolved or false,
  }
  perf_elapsed("textview_line_render_build_ms", build_start)
  perf_elapsed("textview_line_render_cache_lookup_ms", lookup_start)
  if snapshot_lines then snapshot_lines[line] = resolved or false end
  return resolved
end

function TextView:get_render_fragment_at_position(x, y)
  if not self:has_line_render_providers() then return nil end
  local line, col = self:resolve_screen_position(x, y)
  local render_line = self:get_line_render(line)
  if not render_line then return nil end
  if self.wrapped_settings and not render_line.disable_wrapping then
    local idx, _, _, row_start = linewrapping.get_line_idx_col_count(self, line, col)
    local next_line, row_end = linewrapping.get_idx_line_col(self, idx + 1)
    if next_line ~= line then row_end = #(self.buffer.lines[line] or "") end
    local line_x, line_y = self:get_line_screen_position(line)
    local first_idx = self:get_visual_row(line, 1, false)
    local row_y = line_y + self:get_visual_row_y_offset(idx)
      - self:get_visual_row_y_offset(first_idx)
    local row_height = self:get_visual_row_height(idx)
    if not (type(render_line.position_rows) == "table"
      and #render_line.position_rows > 0)
    then
      local content_y_offset, content_height = line_render_content_geometry(
        render_line, row_height, idx == first_idx
      )
      if y < row_y + content_y_offset
      or y >= row_y + content_y_offset + content_height
      then
        return nil
      end
    end
    local begin_width = row_start ~= 1 and (self.wrapped_line_offsets[line] or 0) or 0
    local line_x_offset = render_line.x_offset or 0
    local row_render_x = self:get_line_render_col_x_offset(render_line, row_start)
    for _, fragment in ipairs(self:iter_line_render_fragments(render_line)) do
      local col1 = fragment.source_col1 or 1
      local col2 = fragment.source_col2 or col1
      local from, to = math.max(col1, row_start), math.min(col2, row_end)
      if not fragment.hidden and from < to and col >= from and col <= to then
        local left = line_x + line_x_offset + begin_width
          + self:get_line_render_col_x_offset(render_line, from) - row_render_x
        local right = line_x + line_x_offset + begin_width
          + self:get_line_render_col_x_offset(render_line, to) - row_render_x
        if x >= math.min(left, right) and x <= math.max(left, right) then
          return { line = line, fragment = fragment }
        end
      end
    end
    return nil
  end
  local line_x, line_y = self:get_line_screen_position(line)
  local xrel, yrel = x - line_x, y - line_y
  local row = self:get_visual_row(line, 1)
  local row_height = self:get_visual_row_height(row)
  local content_y_offset, content_height = 0, row_height
  if not (type(render_line.position_rows) == "table" and #render_line.position_rows > 0) then
    content_y_offset, content_height = self:get_line_render_content_geometry(
      line, col
    )
    content_y_offset = content_y_offset or 0
    content_height = content_height or row_height
  end
  local tx = render_line.x_offset or 0
  local _, indent_size = self.buffer:get_indent_info()
  for _, fragment in ipairs(self:iter_line_render_fragments(render_line)) do
    if not fragment.hidden then
      local col1 = fragment.source_col1 or 1
      local position_row = self:get_line_render_position_row(
        render_line, col1, (fragment.source_col2 or col1) > col1
      )
      local font = fragment.font or self:get_font()
      font:set_tab_size(indent_size)
      local text = fragment.text or ""
      local width = fragment.width or (fragment.widget and fragment.widget.width)
        or font:get_width(text, { tab_offset = tx })
      local left = fragment.layout_x ~= nil and fragment.layout_x
        or position_row and self:get_line_render_col_x_offset(
          render_line, col1, position_row
        )
        or tx
      local top = position_row and (position_row.y_offset or 0)
        or content_y_offset
      local height = position_row and (position_row.height or row_height)
        or content_height
      if xrel >= left and xrel <= left + width
        and yrel >= top and yrel <= top + height
      then
        return { line = line, fragment = fragment }
      end
      tx = tx + width
    end
  end
end

local function render_widget_rect(fragment, x, y, row_height, padding)
  local widget = fragment.widget
  if not widget then return nil end
  if padding == nil then padding = widget.padding or 0 end
  local content_height = widget.image_height or widget.height or row_height
  local width = fragment.hit_width or widget.width or fragment.width or 0
  local left = x + (fragment.draw_x_offset or 0)
  local top = fragment.draw_y_offset
    and (y + fragment.draw_y_offset - padding)
    or (y + math.max(0, (row_height - content_height) / 2) - padding)
  return left, top, width, content_height + padding * 2
end

function TextView:get_render_widget_at_position(x, y)
  if not self:has_line_render_providers() then return nil end
  local line, col = self:resolve_screen_position(x, y)
  local render_line = self:get_line_render(line)
  if not render_line then return nil end

  if self.wrapped_settings and not render_line.disable_wrapping then
    local idx, _, _, row_start = linewrapping.get_line_idx_col_count(
      self, line, col
    )
    local next_line, row_end = linewrapping.get_idx_line_col(self, idx + 1)
    local last_row = next_line ~= line
    if last_row then row_end = #(self.buffer.lines[line] or "") end
    local line_x, line_y = self:get_line_screen_position(line)
    local first_idx = self:get_visual_row(line, 1, false)
    local row_height = self:get_visual_row_height(idx)
    local row_y = line_y + self:get_visual_row_y_offset(idx)
      - self:get_visual_row_y_offset(first_idx)
    local content_y_offset, content_height = line_render_content_geometry(
      render_line, row_height, idx == first_idx
    )
    local begin_width = row_start ~= 1 and (self.wrapped_line_offsets[line] or 0) or 0
    local row_render_x = self:get_line_render_col_x_offset(render_line, row_start)
    local xrel, yrel = x - line_x, y - row_y
    local widget_hits = {}
    for _, fragment in ipairs(self:iter_line_render_fragments(render_line)) do
      if not fragment.hidden and fragment.widget then
        local col1 = fragment.source_col1 or 1
        local col2 = fragment.source_col2 or col1
        local from, to = math.max(col1, row_start), math.min(col2, row_end)
        local left
        local width = fragment.hit_width or fragment.widget.width or fragment.width or 0
        local anchored = col1 == col2 and col1 >= row_start
          and (col1 < row_end or (last_row and col1 == row_end))
        if anchored then
          left = self:get_line_render_col_x_offset(render_line, col1) - width
        elseif from < to and from == col1 and to == col2 then
          left = (render_line.x_offset or 0) + begin_width
            + self:get_line_render_col_x_offset(render_line, col1)
            - row_render_x
        end
        if left then
          local hit_left, hit_top, hit_width, hit_height = render_widget_rect(
            fragment, left, content_y_offset, content_height
          )
          widget_hits[#widget_hits + 1] = {
            fragment = fragment, widget = fragment.widget,
            left = hit_left, top = hit_top, width = hit_width,
            height = hit_height,
          }
        end
      end
    end
    for index = #widget_hits, 1, -1 do
      local hit = widget_hits[index]
      if xrel >= hit.left and xrel <= hit.left + hit.width
      and yrel >= hit.top and yrel <= hit.top + hit.height
      then
        return { line = line, fragment = hit.fragment, widget = hit.widget }
      end
    end
    return nil
  end

  local line_x, line_y = self:get_line_screen_position(line)
  local xrel, yrel = x - line_x, y - line_y
  local row = self:get_visual_row(line, 1)
  local row_height = self:get_visual_row_height(row)
  local content_y_offset, content_height = 0, row_height
  if not (type(render_line.position_rows) == "table" and #render_line.position_rows > 0) then
    content_y_offset, content_height = self:get_line_render_content_geometry(line, 1)
    content_y_offset = content_y_offset or 0
    content_height = content_height or row_height
  end
  local tx = render_line.x_offset or 0
  local _, indent_size = self.buffer:get_indent_info()
  local widget_hits = {}
  for _, fragment in ipairs(self:iter_line_render_fragments(render_line)) do
    if not fragment.hidden then
      local font = fragment.font or self:get_font()
      font:set_tab_size(indent_size)
      local widget = fragment.widget
      local text = fragment.text or ""
      local width = widget and (fragment.hit_width or widget.width or fragment.width)
        or fragment.width or font:get_width(text, { tab_offset = tx })
      if widget then
        local left, top, hit_width, hit_height = render_widget_rect(
          fragment,
          fragment.layout_x ~= nil and fragment.layout_x or tx,
          content_y_offset,
          content_height
        )
        widget_hits[#widget_hits + 1] = {
          fragment = fragment, widget = widget,
          left = left, top = top, width = hit_width,
          height = hit_height,
        }
      end
      tx = tx + width
    end
  end
  -- Later fragments draw on top of earlier ones, so overlapping interactive
  -- controls receive the hit before decorative widgets underneath them.
  for index = #widget_hits, 1, -1 do
    local hit = widget_hits[index]
    if xrel >= hit.left and xrel <= hit.left + hit.width
    and yrel >= hit.top and yrel <= hit.top + hit.height
    then
      return { line = line, fragment = hit.fragment, widget = hit.widget }
    end
  end
end

function TextView:get_render_widget_near_position(x, y)
  if not self:has_line_render_providers() then return nil end
  local resolved_line = self:resolve_screen_position(x, y)
  local best
  for line = math.max(1, resolved_line - 1), math.min(#self.buffer.lines, resolved_line + 1) do
    local render_line = self:get_line_render(line)
    if render_line then
      local line_x, line_y = self:get_line_screen_position(line)
      local row = self:get_visual_row(line, 1)
      local row_height = self:get_visual_row_height(row)
      local content_y_offset, content_height = 0, row_height
      if not (type(render_line.position_rows) == "table" and #render_line.position_rows > 0) then
        content_y_offset, content_height = self:get_line_render_content_geometry(line, 1)
        content_y_offset = content_y_offset or 0
        content_height = content_height or row_height
      end
      local tx = render_line.x_offset or 0
      local _, indent_size = self.buffer:get_indent_info()
      for _, fragment in ipairs(self:iter_line_render_fragments(render_line)) do
        if not fragment.hidden then
          local font = fragment.font or self:get_font()
          font:set_tab_size(indent_size)
          local widget = fragment.widget
          local text = fragment.text or ""
          local width = widget and (fragment.hit_width or widget.width or fragment.width)
            or fragment.width or font:get_width(text, { tab_offset = tx })
          local radius = widget and tonumber(widget.proximity_radius) or 0
          if radius > 0 then
            local left, top, hit_width, hit_height = render_widget_rect(
              fragment,
              line_x + (fragment.layout_x ~= nil and fragment.layout_x or tx),
              line_y + content_y_offset,
              content_height
            )
            local right, bottom = left + hit_width, top + hit_height
            local dx = x < left and left - x or x > right and x - right or 0
            local dy = y < top and top - y or y > bottom and y - bottom or 0
            local distance = math.sqrt(dx * dx + dy * dy)
            if distance <= radius then
              local proximity = 1 - distance / radius
              proximity = proximity * proximity * (3 - 2 * proximity)
              if not best or proximity > best.proximity then
                best = {
                  line = line, fragment = fragment, widget = widget,
                  proximity = proximity,
                }
              end
            end
          end
          tx = tx + width
        end
      end
    end
  end
  return best
end

local function render_fragment_font(view, fragment)
  return fragment.font or view:get_font()
end

local function render_fragment_color(fragment)
  return fragment.color or style.syntax.normal
end

local function fragment_uses_hand_cursor(fragment)
  return fragment and (
    fragment.cursor == "hand"
    or (fragment.widget and fragment.widget.cursor == "hand")
  )
end

---Discard normalized fragment copies after mutating a render line in place.
---@param render_line table?
function TextView:invalidate_line_render_fragment_normalization(render_line)
  if render_line then
    render_line.__normalized_fragments_cache = nil
    render_line.__native_text_layout_cache = nil
  end
end

function TextView:iter_line_render_fragments(render_line)
  local source_text = render_line.source_text or ""
  local source_fragments = render_line.fragments
  self.render_cache_diagnostics.fragment_normalization_calls =
    self.render_cache_diagnostics.fragment_normalization_calls + 1
  perf_frame_add("textview_fragment_normalization_calls", 1)
  local cache = render_line.__normalized_fragments_cache
  if cache
    and cache.source_text == source_text
    and cache.source_fragments == source_fragments
  then
    self.render_cache_diagnostics.fragment_normalization_cache_hits =
      self.render_cache_diagnostics.fragment_normalization_cache_hits + 1
    perf_frame_add("textview_fragment_normalization_cache_hits", 1)
    return cache.fragments
  end
  self.render_cache_diagnostics.fragment_normalization_builds =
    self.render_cache_diagnostics.fragment_normalization_builds + 1
  perf_frame_add("textview_fragment_normalization_builds", 1)
  local fragments = {}
  local cursor = 1
  for _, fragment in ipairs(source_fragments or {}) do
    local col1 = math.max(1, math.floor(fragment.source_col1 or cursor))
    local default_col2 = fragment.text and (col1 + #fragment.text) or col1
    local col2 = math.max(col1, math.floor(fragment.source_col2 or default_col2))
    if col1 > cursor then
      fragments[#fragments + 1] = { source_col1 = cursor, source_col2 = col1, text = source_text:sub(cursor, col1 - 1) }
    end
    local normalized = {}
    for key, value in pairs(fragment) do normalized[key] = value end
    normalized.source_col1 = col1
    normalized.source_col2 = col2
    fragments[#fragments + 1] = normalized
    cursor = math.max(cursor, col2)
  end
  if cursor <= #source_text then
    fragments[#fragments + 1] = { source_col1 = cursor, source_col2 = #source_text + 1, text = source_text:sub(cursor) }
  end
  render_line.__normalized_fragments_cache = {
    source_text = source_text,
    source_fragments = source_fragments,
    fragments = fragments,
  }
  return fragments
end

function TextView:get_line_render_position_row(render_line, col, prefer_next)
  col = math.max(1, col or 1)
  local rows = render_line and render_line.position_rows or {}
  for index, row in ipairs(rows) do
    local col1 = math.max(1, row.source_col1 or 1)
    local col2 = math.max(col1, row.source_col2 or col1)
    if col >= col1 and (col < col2 or (row.end_inclusive and col == col2)) then
      local next_row = rows[index + 1]
      if prefer_next and col == col2 and next_row
        and col >= (next_row.source_col1 or col)
      then
        return next_row, index + 1
      end
      return row, index
    end
  end
end

---Return the independently navigable caret rows exposed by a rendered line.
---@param line integer
---@return table? render_line
---@return table? rows
function TextView:get_line_render_position_rows(line)
  local render_line = self:get_line_render(line)
  local rows = render_line and render_line.position_rows
  if type(rows) ~= "table" or #rows == 0 then return render_line, nil end
  return render_line, rows
end

local function render_position_key(line, col)
  return tostring(line) .. ":" .. tostring(col)
end

---Resolve a caret row with view-local boundary affinity.
function TextView:get_position_line_render_row(line, col, prefer_next)
  local render_line, rows = self:get_line_render_position_rows(line)
  if not rows then return render_line, nil, nil end
  local affinity = self.line_render_position_row_affinity
  if affinity
  and affinity.selection_key == linewrapping.selection_state_key(self.buffer)
  and affinity.text_revision == (self.buffer.text_revision or 0)
  then
    local index = affinity.positions[render_position_key(line, col)]
    if index and rows[index] then return render_line, rows[index], index end
  end
  local row, index = self:get_line_render_position_row(render_line, col, prefer_next)
  return render_line, row, index
end

function TextView:clear_pending_line_render_position_row_affinity()
  self.__pending_line_render_position_rows = nil
end

function TextView:queue_line_render_position_row_affinity(line, col, index)
  if not (line and col and index) then return end
  self.__pending_line_render_position_rows =
    self.__pending_line_render_position_rows or {}
  self.__pending_line_render_position_rows[render_position_key(line, col)] = index
end

function TextView:apply_pending_line_render_position_row_affinity()
  local positions = self.__pending_line_render_position_rows
  self.__pending_line_render_position_rows = nil
  if positions and next(positions) then
    self.line_render_position_row_affinity = {
      selection_key = linewrapping.selection_state_key(self.buffer),
      text_revision = self.buffer.text_revision or 0,
      positions = positions,
    }
  else
    self.line_render_position_row_affinity = nil
  end
end

function TextView:apply_resolved_line_render_position_row_affinity()
  local resolved = self.resolved_line_render_position_row
  self.resolved_line_render_position_row = nil
  if not resolved then return end
  local line, col, index = resolved[1], resolved[2], resolved[3]
  for _, caret_line, caret_col in self.buffer:get_selections(false) do
    if caret_line == line and caret_col == col then
      self.line_render_position_row_affinity = {
        selection_key = linewrapping.selection_state_key(self.buffer),
        text_revision = self.buffer.text_revision or 0,
        positions = { [render_position_key(line, col)] = index },
      }
      return
    end
  end
end

---Return the source bounds of the rendered caret row containing a position.
---@param line integer
---@param col integer
---@return integer? col1
---@return integer? col2
function TextView:get_line_render_position_row_bounds(line, col)
  local _, row, index = self:get_position_line_render_row(line, col)
  if not row then return nil end
  return math.max(1, row.source_col1 or 1),
    math.max(row.source_col1 or 1, row.source_col2 or row.source_col1 or 1),
    index
end

local function position_row_target_col(view, render_line, row, x)
  local top = row.y_offset or 0
  local height = math.max(1, row.height or view:get_line_height())
  local col = view:get_line_render_position_col(render_line, x, top + height / 2)
  local col1 = math.max(1, row.source_col1 or 1)
  local col2 = math.max(col1, row.source_col2 or col1)
  return common.clamp(col or col1, col1, col2)
end

local function desired_position_row_x(view, line, col)
  local last = view.last_x_offset or {}
  view.last_x_offset = last
  if last.line == line and last.col == col then return last.offset or 0 end
  return view:get_col_x_offset(line, col)
end

local function remember_position_row_x(view, line, col, x)
  view.last_x_offset = view.last_x_offset or {}
  view.last_x_offset.offset = x
  view.last_x_offset.line = line
  view.last_x_offset.col = col
  view.last_x_offset.line_end = false
end

---Move between independently navigable caret rows inside one rendered line.
---@return integer? line
---@return integer? col
function TextView:move_within_line_render_position_rows(line, col, direction)
  local render_line, rows = self:get_line_render_position_rows(line)
  if not rows or #rows < 2 then return nil end
  local _, current, index = self:get_position_line_render_row(line, col)
  local target, target_index
  if current and current.navigation_group ~= nil then
    local wanted = (current.navigation_index or 1) + direction
    for candidate_index, candidate in ipairs(rows) do
      if candidate.navigation_group == current.navigation_group
      and (candidate.navigation_index or 1) == wanted then
        target, target_index = candidate, candidate_index
        break
      end
    end
  else
    target_index = index and index + direction
    target = target_index and rows[target_index]
  end
  if not target then return nil end
  local x = desired_position_row_x(self, line, col)
  local target_col = position_row_target_col(self, render_line, target, x)
  remember_position_row_x(self, line, target_col, x)
  self:queue_line_render_position_row_affinity(
    line, target_col, target_index
  )
  return line, target_col
end

---Land on the first/last caret row when vertical movement enters a rendered line.
---@return integer col
function TextView:land_on_line_render_position_row(line, fallback_col, direction, x)
  local render_line, rows = self:get_line_render_position_rows(line)
  if not rows or #rows < 2 then return fallback_col end
  x = x or 0
  local edge
  for _, row in ipairs(rows) do
    local y = row.y_offset or 0
    edge = edge == nil and y
      or direction < 0 and math.max(edge, y)
      or direction >= 0 and math.min(edge, y)
  end
  local target, target_index, best_distance
  for index, row in ipairs(rows) do
    if (row.y_offset or 0) == edge then
      local x1 = row.hit_x1 or row.x_offset or 0
      local x2 = row.hit_x2 or x1
      local distance = x < x1 and x1 - x or x > x2 and x - x2 or 0
      if not best_distance or distance < best_distance then
        target, target_index, best_distance = row, index, distance
      end
    end
  end
  target, target_index = target or rows[1], target_index or 1
  local col = position_row_target_col(self, render_line, target, x)
  remember_position_row_x(self, line, col, x)
  self:queue_line_render_position_row_affinity(line, col, target_index)
  return col
end

---Whether an unwrapped navigation command must honor rendered caret rows.
function TextView:needs_line_render_position_navigation(command_name)
  local direction = command_name:find("previous_line", 1, true) and -1
    or command_name:find("next_line", 1, true) and 1 or nil
  for _, line in self.buffer:get_selections(false) do
    local _, rows = self:get_line_render_position_rows(line)
    if rows and #rows > 1 then return true end
    if direction then
      local target = common.clamp(line + direction, 1, #self.buffer.lines)
      local _, target_rows = self:get_line_render_position_rows(target)
      if target_rows and #target_rows > 1 then return true end
    end
  end
  return false
end

---Resolve Current Line Highlight geometry for one caret position.
---@return number y
---@return number height
function TextView:get_position_highlight_geometry(line, col, line_end)
  local _, row = self:get_position_line_render_row(line, col or 1)
  if row then
    local _, line_y = self:get_line_screen_position(line)
    return line_y + (row.highlight_y_offset or row.y_offset or 0),
      math.max(1, row.highlight_height or row.height or self:get_line_height())
  end
  local _, y = self:get_line_screen_position(line, col, line_end)
  local row_height = self:get_position_visual_row_height(
    line, col or 1, line_end
  )
  local render_line = self:get_line_render(line)
  if render_line then
    local content_y_offset, content_height = self:get_line_render_content_geometry(
      line, col, line_end
    )
    local requested = render_line.highlight_height
      or render_line.caret_height
      or content_height
    if type(requested) == "function" then
      requested = self:get_position_caret_height(line, col, line_end)
    end
    return y + (render_line.highlight_y_offset or content_y_offset or 0), math.min(
      row_height, math.max(1, tonumber(requested) or content_height or row_height)
    )
  end
  return y, row_height
end

local function get_line_render_raw_col_x_offset(self, render_line, col)
  col = math.max(1, col or 1)
  local xoffset = render_line.x_offset or 0
  local _, indent_size = self.buffer:get_indent_info()
  local fragments = self:iter_line_render_fragments(render_line)
  local layout_cache = render_line.__native_text_layout_cache
  if not layout_cache or layout_cache.fragments ~= fragments
    or layout_cache.indent_size ~= indent_size
  then
    local entries = {}
    local tx = xoffset
    for index, fragment in ipairs(fragments) do
      local font = render_fragment_font(self, fragment)
      font:set_tab_size(indent_size)
      local text = fragment.text or ""
      local text_layout
      if not fragment.hidden and not fragment.widget and font.text_layout then
        text_layout = font:text_layout(text, { tab_offset = tx })
      end
      local width = fragment.hidden and 0
        or fragment.width or (fragment.widget and fragment.widget.width)
        or (text_layout and text_layout:width())
        or font:get_width(text, { tab_offset = tx })
      entries[index] = {
        fragment = fragment,
        x = tx,
        width = width,
        text_layout = text_layout,
      }
      if not fragment.hidden then tx = tx + width end
    end
    layout_cache = {
      fragments = fragments,
      indent_size = indent_size,
      entries = entries,
      width = tx - xoffset,
    }
    render_line.__native_text_layout_cache = layout_cache
  end
  for _, entry in ipairs(layout_cache.entries) do
    local fragment = entry.fragment
    local col1 = fragment.source_col1 or 1
    local col2 = fragment.source_col2 or col1
    -- A zero-length widget is inserted immediately before its source anchor,
    -- so the caret at that anchor belongs on the widget's right-hand side.
    local widget_before_anchor = fragment.widget and col1 == col2
    if col < col1 or (col == col1 and not widget_before_anchor) then
      return xoffset
    end
    if fragment.hidden then
      if col <= col2 then return xoffset end
    else
      local text = fragment.text or ""
      if col < col2 and not fragment.widget then
        local text_col1 = fragment.text_source_col1
        local text_col2 = fragment.text_source_col2
        if text_col1 and text_col2 then
          if col <= text_col1 then return xoffset + (fragment.text_x_offset or 0) end
          if col <= text_col2 then
            return xoffset + (fragment.text_x_offset or 0)
              + (entry.text_layout and entry.text_layout:width_at(
                math.max(0, col - text_col1)
              ) or render_fragment_font(self, fragment):get_width(
                text:sub(1, math.max(0, col - text_col1)), { tab_offset = xoffset }
              ))
          end
          return xoffset + entry.width
        end
        return xoffset + (fragment.text_x_offset or 0)
          + (entry.text_layout and entry.text_layout:width_at(math.max(0, col - col1))
            or render_fragment_font(self, fragment):get_width(
              text:sub(1, math.max(0, col - col1)), { tab_offset = xoffset }
            ))
      end
      xoffset = xoffset + entry.width
    end
  end
  return xoffset
end

---Return a source-column width mapper optimized for monotonically increasing
---columns. Wrapping scans every UTF-8 boundary in order, so retaining the
---current fragment avoids restarting the mixed-fragment search per character.
function TextView:get_line_render_col_x_cursor(render_line)
  get_line_render_raw_col_x_offset(self, render_line, 1)
  local cache = render_line.__native_text_layout_cache
  local entries = cache and cache.entries or {}
  local index = 1
  local xoffset = render_line.x_offset or 0
  local width_cursors = {}
  local function layout_width_at(entry, entry_index, byte_offset)
    if not entry.text_layout then return nil end
    local cursor = width_cursors[entry_index]
    if cursor == nil then
      cursor = entry.text_layout.width_cursor
        and entry.text_layout:width_cursor() or false
      width_cursors[entry_index] = cursor
    end
    return cursor and cursor(byte_offset) or entry.text_layout:width_at(byte_offset)
  end
  return function(col)
    col = math.max(1, col or 1)
    while index <= #entries do
      local entry = entries[index]
      local fragment = entry.fragment
      local col1 = fragment.source_col1 or 1
      local col2 = fragment.source_col2 or col1
      local widget_before_anchor = fragment.widget and col1 == col2
      if col < col1 or (col == col1 and not widget_before_anchor) then
        return xoffset
      end
      if fragment.hidden then
        if col <= col2 then return xoffset end
      elseif col < col2 then
        local text = fragment.text or ""
        if fragment.widget then
          xoffset = xoffset + entry.width
          index = index + 1
          return xoffset
        end
        local text_col1 = fragment.text_source_col1
        local text_col2 = fragment.text_source_col2
        if text_col1 and text_col2 then
          if col <= text_col1 then return xoffset + (fragment.text_x_offset or 0) end
          if col <= text_col2 then
            return xoffset + (fragment.text_x_offset or 0)
              + (layout_width_at(entry, index, math.max(0, col - text_col1))
                or render_fragment_font(self, fragment):get_width(
                text:sub(1, math.max(0, col - text_col1)), { tab_offset = xoffset }
              ))
          end
          return xoffset + entry.width
        end
        return xoffset + (fragment.text_x_offset or 0)
          + (layout_width_at(entry, index, math.max(0, col - col1))
            or render_fragment_font(self, fragment):get_width(
              text:sub(1, math.max(0, col - col1)), { tab_offset = xoffset }
            ))
      end
      if not fragment.hidden then xoffset = xoffset + entry.width end
      index = index + 1
    end
    return xoffset
  end
end

---Use retained native UTF-8 advances when a rendered line consists of one or
---more contiguous source-preserving text runs. Hidden, widget, remapped, and
---explicit-width fragments keep the general rendered-column mapping path.
function TextView:get_line_render_native_wrap(render_line, width, mode, start_col, begin_width)
  get_line_render_raw_col_x_offset(self, render_line, 1)
  local cache = render_line.__native_text_layout_cache
  if not cache or #cache.entries == 0 then return nil end
  local source_text = render_line.source_text or ""
  if #cache.entries == 1 then
    local entry = cache.entries[1]
    local fragment = entry.fragment
    if fragment.hidden or fragment.widget or not entry.text_layout
      or (fragment.source_col1 or 1) ~= 1
      or (fragment.source_col2 or 1) ~= #source_text + 1
      or fragment.text ~= source_text
      or fragment.text_source_col1 or fragment.text_source_col2
    then
      return nil
    end
    local zero_breaks = entry.text_layout:wrap(
      width, mode, math.max(0, (start_col or 1) - 1),
      render_line.x_offset or 0,
      (render_line.x_offset or 0) + (begin_width or 0)
    )
    local splits = {}
    for index, byte_offset in ipairs(zero_breaks) do splits[index] = byte_offset + 1 end
    return splits
  end

  if not renderer.wrap_text_layouts then return nil end
  local layouts = {}
  local expected_col = 1
  for index, entry in ipairs(cache.entries) do
    local fragment = entry.fragment
    local text = fragment.text or ""
    local col1 = fragment.source_col1 or expected_col
    local col2 = fragment.source_col2 or col1
    if fragment.hidden or fragment.widget or fragment.width ~= nil
      or not entry.text_layout or fragment.text_x_offset
      or fragment.text_source_col1 or fragment.text_source_col2
      or col1 ~= expected_col or col2 ~= col1 + #text
      or source_text:find(text, col1, true) ~= col1
    then
      return nil
    end
    layouts[index] = entry.text_layout
    expected_col = col2
  end
  if expected_col ~= #source_text + 1 then return nil end
  local zero_breaks = renderer.wrap_text_layouts(
    layouts,
    width, mode, math.max(0, (start_col or 1) - 1),
    render_line.x_offset or 0,
    (render_line.x_offset or 0) + (begin_width or 0)
  )
  local splits = {}
  for index, byte_offset in ipairs(zero_breaks) do splits[index] = byte_offset + 1 end
  return splits
end

function TextView:get_line_render_col_x_offset(render_line, col, position_row)
  local xoffset = get_line_render_raw_col_x_offset(self, render_line, col)
  local row = position_row or self:get_line_render_position_row(render_line, col)
  if not row then return xoffset end
  local row_start = get_line_render_raw_col_x_offset(
    self, render_line, row.source_col1 or 1
  )
  return (render_line.x_offset or 0) + (row.x_offset or 0) + xoffset - row_start
end

local function render_line_for_hit_test(render_line)
  if not render_line.hit_test_fragments then return render_line end
  local hit_line = {}
  for key, value in pairs(render_line) do hit_line[key] = value end
  hit_line.fragments = render_line.hit_test_fragments
  return hit_line
end

function TextView:get_line_render_x_offset_col(render_line, x)
  render_line = render_line_for_hit_test(render_line)
  local xoffset = render_line.x_offset or 0
  local _, indent_size = self.buffer:get_indent_info()
  -- Populate the native per-fragment layout cache shared with width mapping.
  get_line_render_raw_col_x_offset(self, render_line, 1)
  local layout_cache = render_line.__native_text_layout_cache
  for index, fragment in ipairs(self:iter_line_render_fragments(render_line)) do
    local entry = layout_cache and layout_cache.entries[index]
    local col1 = fragment.source_col1 or 1
    local col2 = fragment.source_col2 or col1
    local font = render_fragment_font(self, fragment)
    font:set_tab_size(indent_size)
    if fragment.hidden then
      if x <= xoffset then return col1 end
    else
      local text = fragment.text or ""
      local width = entry and entry.width
        or fragment.width or (fragment.widget and fragment.widget.width)
        or font:get_width(text, { tab_offset = xoffset })
      if xoffset + width >= x then
        if fragment.widget and text == "" then
          return (x <= xoffset + width / 2) and col1 or col2
        end
        local text_offset = fragment.text_x_offset or 0
        local text_col1 = fragment.text_source_col1 or col1
        local text_col2 = fragment.text_source_col2 or col2
        if x <= xoffset + text_offset then return text_col1 end
        local local_x = xoffset + text_offset
        if entry and entry.text_layout then
          return math.min(
            text_col1 + entry.text_layout:byte_at_x(math.max(0, x - local_x)),
            text_col2
          )
        end
        local col = text_col1
        for char in common.utf8_chars(text) do
          local w = font:get_width(char, { tab_offset = local_x })
          if local_x + w >= x then
            return (x <= local_x + w / 2) and col or math.min(col + #char, text_col2)
          end
          local_x = local_x + w
          col = col + #char
        end
        return text_col2
      end
      xoffset = xoffset + width
    end
  end
  return #(render_line.source_text or "") + 1
end

---Resolve a position inside a rendered fragment that owns internal text rows.
---@param render_line table
---@param x number Horizontal offset from the rendered line origin
---@param y number Vertical offset from the rendered row origin
---@return integer? col Source column, or nil when ordinary mapping should be used
function TextView:get_line_render_position_col(render_line, x, y)
  if render_line.position_rows then
    local row, row_index
    for index, candidate in ipairs(render_line.position_rows) do
      local top = candidate.y_offset or 0
      local height = candidate.height or self:get_line_height()
      local hit_x1, hit_x2 = candidate.hit_x1, candidate.hit_x2
      if y >= top and y < top + height
      and (not hit_x1 or x >= hit_x1 and x <= (hit_x2 or hit_x1))
      then
        row, row_index = candidate, index
        break
      end
    end
    if row then
      local col = row.source_col1 or 1
      local col2 = row.source_col2 or col
      local previous_x = self:get_line_render_col_x_offset(render_line, col, row)
      if x <= previous_x then return col, row_index end
      local source = render_line.source_text or ""
      for char in common.utf8_chars(source:sub(col, math.max(col, col2 - 1))) do
        local next_col = col + #char
        local next_x = self:get_line_render_col_x_offset(render_line, next_col, row)
        if x <= next_x then
          return x <= previous_x + (next_x - previous_x) / 2 and col or next_col,
            row_index
        end
        col, previous_x = next_col, next_x
      end
      return col2, row_index
    end
  end
  local xoffset = render_line.x_offset or 0
  local _, indent_size = self.buffer:get_indent_info()
  for _, fragment in ipairs(self:iter_line_render_fragments(render_line)) do
    local font = render_fragment_font(self, fragment)
    font:set_tab_size(indent_size)
    local text = fragment.text or ""
    local width = fragment.width
      or (fragment.widget and fragment.widget.width)
      or font:get_width(text, { tab_offset = xoffset })
    if x <= xoffset + width then
      if not fragment.text_lines then return nil end
      local line_height = fragment.text_line_height or font:get_height()
      local line_index = common.clamp(
        math.floor((y - (fragment.text_y_padding or 0)) / math.max(1, line_height)) + 1,
        1,
        #fragment.text_lines
      )
      local line = fragment.text_lines[line_index]
      if type(line) ~= "table" or not line.source_col1 then return nil end
      local line_text = line.text or ""
      local local_x = xoffset + (line.x_offset or fragment.text_x_offset or 0)
      if x <= local_x then return line.source_col1 end
      local col = line.source_col1
      for char in common.utf8_chars(line_text) do
        local char_width = font:get_width(char, { tab_offset = local_x })
        if local_x + char_width >= x then
          return x <= local_x + char_width / 2
            and col or math.min(col + #char, line.source_col2)
        end
        local_x = local_x + char_width
        col = col + #char
      end
      return line.source_col2
    end
    xoffset = xoffset + width
  end
end

local function rendered_position_hit_y(view, line, render_line, visual_row, y)
  if type(render_line.position_rows) == "table" and #render_line.position_rows > 0 then
    return y
  end
  local row_height = view:get_visual_row_height(visual_row)
  local content_y_offset = line_render_content_geometry(
    render_line, row_height,
    visual_row == view:get_visual_row(line, 1, false)
  )
  return y - content_y_offset
end

---Get the horizontal pixel offset for a column position.
---Accounts for tabs, syntax highlighting fonts, and caches long lines.
---@param line integer Line number
---@param col integer Column number (byte offset)
---@param line_end boolean? Whether this is the visual line end
---@param skip_render boolean? Measure source text without requesting a rendered line
---@return number offset Horizontal pixel offset
function TextView:get_col_x_offset(line, col, line_end, skip_render)
  local render_line = not skip_render and self:get_line_render(line) or nil
  if render_line then
    local _, position_row = self:get_position_line_render_row(line, col)
    local rendered_offset = self:get_line_render_col_x_offset(
      render_line, col, position_row
    )
    if self.wrapped_settings and not render_line.disable_wrapping then
      if line_end == nil and self.__use_wrapped_caret_affinity then
        line_end = linewrapping.has_wrapped_line_end_affinity(self, line, col)
      end
      local _, _, _, row_start = linewrapping.get_line_idx_col_count(self, line, col, line_end)
      local row_offset = self:get_line_render_col_x_offset(render_line, row_start)
      return (render_line.x_offset or 0)
        + (row_start ~= 1 and (self.wrapped_line_offsets[line] or 0) or 0)
        + rendered_offset - row_offset
    end
    return rendered_offset
  end
  if self.wrapped_settings then
    local perf_active = core.perf_frame_stats ~= nil
    local perf_start = perf_active and system.get_time()
    if line_end == nil and self.__use_wrapped_caret_affinity then
      line_end = linewrapping.has_wrapped_line_end_affinity(self, line, col)
    end
    local _, _, _, scol = linewrapping.get_line_idx_col_count(self, line, col, line_end)
    local xoffset, i = (scol ~= 1 and self.wrapped_line_offsets[line] or 0), 1
    local default_font = self:get_font()
    for _, type, text in self.buffer.highlighter:each_token(line) do
      if i + #text >= scol then
        if i < scol then
          text = text:sub(scol - i + 1)
          i = scol
        end
        if #text > col - i then
          text = text:sub(1, math.max(0, col - i))
        end
        local font = style.syntax_fonts[type] or default_font
        for char in common.utf8_chars(text) do
          if i >= col then
            perf_frame_add("textview_get_col_x_offset_wrapped_calls", 1)
            perf_elapsed("textview_get_col_x_offset_wrapped_ms", perf_start)
            return xoffset
          end
          xoffset = xoffset + font:get_width(char)
          i = i + #char
        end
      else
        i = i + #text
      end
    end
    perf_frame_add("textview_get_col_x_offset_wrapped_calls", 1)
    perf_elapsed("textview_get_col_x_offset_wrapped_ms", perf_start)
    return xoffset
  end
  local column = 1
  local xoffset = 0
  local cache = self.buffer.cache.col_x
  local line_text = self.buffer.lines[line]
  local line_len = #line_text
  if line_len > CACHE_LINE_LEN then
    if cache[line] and cache[line][col] then
      return cache[line][col]
    elseif not cache[line] then
      cache[line] = {}
    elseif col > 1 then
      for i=col-1, 1, -1 do
        if cache[line][i] then
          column = i
          xoffset = cache[line][i]
          break
        end
      end
    end
  end
  local default_font = self:get_font()
  local _, indent_size = self.buffer:get_indent_info()
  default_font:set_tab_size(indent_size)
  if line_len > CACHE_LINE_LEN and column == 1 then
    local fast_x = get_fast_ascii_monospace_x_offset(self, line, col, line_text, default_font)
    if fast_x then
      if cache[line] then cache[line][col] = fast_x end
      return fast_x
    end
  end
  local scol = column > 1 and column or nil
  for _, type, text in self.buffer.highlighter:each_render_token(line, scol) do
    local font = style.syntax_fonts[type] or default_font
    if font ~= default_font then font:set_tab_size(indent_size) end
    local length = #text
    if column + length <= col then
      xoffset = xoffset + font:get_width(text, {tab_offset = xoffset})
      column = column + length
      if line_len > CACHE_LINE_LEN and cache[line] then
        cache[line][column] = xoffset
      end
      if column >= col then
        return xoffset
      end
    else
      for char in common.utf8_chars(text) do
        if column >= col then
          return xoffset
        end
        xoffset = xoffset + font:get_width(char, {tab_offset = xoffset})
        column = column + #char
        if line_len > CACHE_LINE_LEN and cache[line] then
          cache[line][column] = xoffset
        end
      end
    end
  end
  if line_len > CACHE_LINE_LEN and cache[line] then
    cache[line][column] = xoffset
  end
  return xoffset
end


---Get the column at a horizontal pixel offset.
---Inverse of get_col_x_offset. Accounts for variable-width fonts.
---@param line integer Line number
---@param x number Horizontal pixel offset
---@return integer col Column number (byte offset)
function TextView:get_x_offset_col(line, x)
  local render_line = self:get_line_render(line)
  if render_line then return self:get_line_render_x_offset_col(render_line, x) end
  if self.wrapped_settings then
    local idx = linewrapping.get_line_idx_col_count(self, line)
    local _, target_col = linewrapping.get_line_col_from_index_and_x(self, idx, x)
    return target_col
  end
  local line_text = self.buffer.lines[line]
  local line_len = #line_text
  local default_font = self:get_font()
  local cell_width = get_fast_ascii_monospace_x_offset(
    self, line, 2, line_text, default_font
  )
  if cell_width and cell_width > 0 then
    local cell = math.max(0, x) / cell_width
    local cell_index = math.floor(cell)
    if cell - cell_index > 0.5 then cell_index = cell_index + 1 end
    perf_frame_add("textview_get_x_offset_col_fast_ascii_calls", 1)
    return common.clamp(cell_index + 1, 1, line_len)
  end

  -- we leverage the caching already present on col_x, this works on all lines,
  -- but for the moment lets do it only on the cached lines and keep original
  -- code logic intact
  if line_len > CACHE_LINE_LEN then
    local xo, pxo, last_col = 0, 0, 0
    for col, _ in utf8extra.next, line_text do
      pxo = xo
      xo = self:get_col_x_offset(line, col)
      if xo >= x or col >= line_len then
        local w = xo - pxo
        return (xo - x > w / 2) and last_col or col
      end
      last_col = col
    end
  end

  local xoffset, i = 0, 1
  local _, indent_size = self.buffer:get_indent_info()
  default_font:set_tab_size(indent_size)
  for _, type, text in self.buffer.highlighter:each_render_token(line) do
    local font = style.syntax_fonts[type] or default_font
    if font ~= default_font then font:set_tab_size(indent_size) end
    local width = font:get_width(text, {tab_offset = xoffset})
    -- Don't take the shortcut if the width matches x,
    -- because we need last_i which should be calculated using utf-8.
    if xoffset + width < x then
      xoffset = xoffset + width
      i = i + #text
    else
      for char in common.utf8_chars(text) do
        local w = font:get_width(char, {tab_offset = xoffset})
        if xoffset + w >= x then
          return (x <= xoffset + (w / 2)) and i or i + #char
        end
        xoffset = xoffset + w
        i = i + #char
      end
    end
  end

  return line_len
end


---Convert screen coordinates to buffer line/column.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return integer line Line number
---@return integer col Column number
function TextView:resolve_screen_position(x, y)
  self.resolved_fold_widget = nil
  self.resolved_line_render_position_row = nil
  if self.wrapped_settings then
    local content_x, content_y = self:get_content_offset()
    local ox, oy = content_x + self:get_gutter_width(), content_y + style.padding.y
    local total = self:has_composed_visual_rows() and self:get_composed_visual_row_count() or linewrapping.get_total_wrapped_lines(self)
    local idx = common.clamp(self:get_visual_row_at_y(math.max(0, y - oy)), 1, total)
    if self:has_composed_visual_rows() then
      local entry = self:get_visual_row_entry(idx)
      if entry and entry.type == "fold" then
        self.resolved_fold_widget = entry.fold
        self.wrapped_last_resolved_line_end = nil
        return entry.fold.line1, 1
      elseif entry and (entry.type == "extra" or entry.type == "provider") then
        self.resolved_provider_row = entry
        self.wrapped_last_resolved_line_end = nil
        local row = entry.provider_row
        if row and row.hit_test then
          local ok, line, col = pcall(row.hit_test, self, row, x - ox, y - (content_y + style.padding.y + self:get_visual_row_y_offset(idx)))
          if ok and line then return line, col or 1 end
          if not ok then core.log_quiet("TextView provider row hit_test failed for %s: %s", self.buffer:get_name(), tostring(line)) end
        end
        return entry.line, 1
      elseif entry then
        local render_line = self:get_line_render(entry.line)
        local rendered_col, rendered_row
        if render_line then
          rendered_col, rendered_row = self:get_line_render_position_col(
            render_line, x - ox,
            rendered_position_hit_y(
              self, entry.line, render_line, idx,
              y - (oy + self:get_visual_row_y_offset(idx))
            )
          )
        end
        if rendered_col then
          self.wrapped_last_resolved_line_end = nil
          if rendered_row then
            self.resolved_line_render_position_row = {
              entry.line, rendered_col, rendered_row,
            }
          end
          return entry.line, rendered_col
        end
        local line, col, line_end = linewrapping.get_line_col_from_index_and_x(self, entry.wrapped_idx, x - ox)
        self.wrapped_last_resolved_line_end = line_end and { line, col } or nil
        return line, col
      end
    end
    local row_line = linewrapping.get_idx_line_col(self, idx)
    local render_line = self:get_line_render(row_line)
    local rendered_col, rendered_row
    if render_line then
      rendered_col, rendered_row = self:get_line_render_position_col(
        render_line, x - ox,
        rendered_position_hit_y(
          self, row_line, render_line, idx,
          y - (oy + self:get_visual_row_y_offset(idx))
        )
      )
    end
    if rendered_col then
      self.wrapped_last_resolved_line_end = nil
      if rendered_row then
        self.resolved_line_render_position_row = {
          row_line, rendered_col, rendered_row,
        }
      end
      return row_line, rendered_col
    end
    local line, col, line_end = linewrapping.get_line_col_from_index_and_x(self, idx, x - ox)
    self.wrapped_last_resolved_line_end = line_end and { line, col } or nil
    return line, col
  end
  local content_x, content_y = self:get_content_offset()
  local ox, oy = content_x + self:get_gutter_width(), content_y + style.padding.y
  local row = self:get_visual_row_at_y(math.max(0, y - oy))
  local line = common.clamp(row, 1, #self.buffer.lines)
  if self:has_composed_visual_rows() then
    local entry = self:get_visual_row_entry(common.clamp(row, 1, self:get_composed_visual_row_count()))
    if entry and entry.type == "fold" then
      self.resolved_fold_widget = entry.fold
      return entry.fold.line1, 1
    elseif entry and (entry.type == "extra" or entry.type == "provider") then
      self.resolved_provider_row = entry
      local row_obj = entry.provider_row
      if row_obj and row_obj.hit_test then
        local ok, hit_line, hit_col = pcall(row_obj.hit_test, self, row_obj, x - ox, y - (content_y + style.padding.y + self:get_visual_row_y_offset(entry.absolute_row)))
        if ok and hit_line then return hit_line, hit_col or 1 end
        if not ok then core.log_quiet("TextView provider row hit_test failed for %s: %s", self.buffer:get_name(), tostring(hit_line)) end
      end
      line = entry.line
    elseif entry then
      line = entry.line
    end
  end
  local render_line = self:get_line_render(line)
  local rendered_col, rendered_row
  if render_line then
    rendered_col, rendered_row = self:get_line_render_position_col(
      render_line, x - ox,
      rendered_position_hit_y(
        self, line, render_line, row,
        y - (oy + self:get_visual_row_y_offset(row))
      )
    )
  end
  if rendered_col then
    if rendered_row then
      self.resolved_line_render_position_row = {
        line, rendered_col, rendered_row,
      }
    end
    return line, rendered_col
  end
  local col = self:get_x_offset_col(line, x - ox)
  return line, col
end


---Scroll to center a line in the viewport.
---@param line integer Line number to scroll to
---@param ignore_if_visible? boolean Don't scroll if line already visible
---@param instant? boolean Jump immediately without animation
---@param opts? table Optional scroll behavior options
function TextView:scroll_to_line(line, ignore_if_visible, instant, opts)
  if self.wrapping_enabled then self:update_wrap_cache() end
  local min, max = self:get_visible_line_range()
  local visible_margin_lines = opts and opts.visible_margin_lines or 0
  if visible_margin_lines > 0 then
    min = min + visible_margin_lines
    max = max - visible_margin_lines
  end
  if not (ignore_if_visible and line >= min and line <= max) then
    local x, y = self:get_line_screen_position(line)
    local ox, oy = self:get_content_offset()
    local _, _, _, scroll_h = self.h_scrollbar:get_track_rect()
    self.scroll.to.y = math.max(0, y - oy - (self.size.y - scroll_h) / 2)
    if instant then
      self.scroll.y = self.scroll.to.y
    end
  end
  self:notify_scroll_listeners("scroll_to_line")
end


---Check if this view accepts text input.
---@return boolean accepts False for a read-only Buffer
function TextView:supports_text_input()
  return not self.buffer.read_only
end


---Scroll to make a position or text range visible with context padding.
---Ensures the position is visible with surrounding context lines. When a same-line
---range is provided in opts, horizontal scrolling keeps the full range visible
---with best-effort grace padding and resets to the baseline when the range fits
---from horizontal scroll 0.
---@param line integer Line number
---@param col integer Column number
---@param instant? boolean Jump immediately without animation
---@param opts? table Optional range/scroll options
function TextView:scroll_to_make_visible(line, col, instant, opts)
  if self.wrapping_enabled then self:update_wrap_cache() end
  if self.wrapped_settings then
    with_wrapped_caret_affinity(self, TextView.scroll_to_make_visible_unwrapped, line, col, instant, opts)
    if self:get_h_scrollable_size() <= self.size.x then
      self.scroll.to.x = 0
      if instant then self.scroll.x = self.scroll.to.x end
    end
    self:notify_scroll_listeners("scroll_to_make_visible")
    return
  end
  local result = self:scroll_to_make_visible_unwrapped(line, col, instant, opts)
  self:notify_scroll_listeners("scroll_to_make_visible")
  return result
end

function TextView:scroll_to_make_visible_unwrapped(line, col, instant, opts)
  opts = opts or {}
  if opts.vertical ~= false then
    self.scroll.y = math.max(0, self.scroll.y or 0)
    self.scroll.to.y = math.max(0, self.scroll.to.y or 0)
    local _, oy = self:get_content_offset()
    local _, position_row = self:get_position_line_render_row(line, col)
    local ly, lh = self:get_position_highlight_geometry(line, col, false)
    -- The highlight may be taller or shorter than a normal editor row (for
    -- example, Markdown headings reserve leading block spacing).  Context is
    -- expressed in normal visual rows, so do not use the target highlight
    -- height as the pixel size of every surrounding context row.
    local context_lh = self:get_line_height()
    local target_row = self:get_visual_row(line, col, false)
    local target_row_height = self:get_visual_row_height(target_row)
    local target_row_y = oy + style.padding.y
      + self:get_visual_row_y_offset(target_row)
    local target_bottom
    if position_row then
      -- A rendered line can expose several caret rows.  Current Line
      -- Highlight may intentionally cover the complete layout, but scrolling
      -- must follow the row that contains the caret.  Otherwise a tall image
      -- below a revealed source row pulls the viewport to the image bottom.
      target_row_y = ly
      target_row_height = math.max(
        1, position_row.height or context_lh
      )
      target_bottom = target_row_y + target_row_height
    else
      -- Preserve any trailing layout space as part of the target row rather
      -- than treating it as one of the normal context rows below the caret.
      target_bottom = math.max(
        ly + lh,
        target_row_y + target_row_height
      )
    end
    local scroll_h = self:get_horizontal_scrollbar_height()

    local pad = self:get_visible_scroll_context_lines()
    if self.mouse_selecting then
      pad = math.min(pad, 1)
    end

    local below_pad = pad
    if config.scroll_past_end and not self.mouse_selecting then
      local end_pad = self:get_scroll_past_end_context_lines()
      if end_pad > below_pad then
        local target_idx = self:get_visual_row_at_y(
          math.max(0, ly - oy - style.padding.y)
        )
        local rows_below = math.max(0, self:get_scrollable_line_count() - target_idx)
        if rows_below < end_pad then
          below_pad = end_pad
        end
      end
    end

    local above = math.max(0, ly - oy - style.padding.y - context_lh * pad)
    local below = target_bottom - oy - self.size.y + scroll_h
      + context_lh * below_pad

    self.scroll.to.y = math.max(0, common.clamp(self.scroll.to.y, below, above))
  end

  local fixed_gutter_right = self:get_gutter_width()
  local _, _, scroll_w = self.v_scrollbar:get_track_rect()
  local viewport_left = 0
  local vertical_scrollbar_left = math.max(0, self.size.x - scroll_w)
  local text_origin = fixed_gutter_right
  local text_viewport_width = math.max(
    0, vertical_scrollbar_left - text_origin
  )
  local line2, col2 = opts.line2, opts.col2
  local range_line = line2 == line and col2 and line
  local xmargin = opts.horizontal_grace
  if xmargin == nil then
    if range_line then
      xmargin = math.min(80 * (SCALE or 1), text_viewport_width * 0.25)
    else
      xmargin = 3 * self:get_font():get_width(' ')
    end
  end

  local xinf, xsup
  if range_line then
    local x1 = self:get_col_x_offset(line, math.min(col, col2))
    local x2 = self:get_col_x_offset(line, math.max(col, col2))
    xinf, xsup = math.min(x1, x2), math.max(x1, x2)
  else
    local xoffset = self:get_col_x_offset(line, col)
    xinf, xsup = xoffset, xoffset
  end

  local desired_left = math.max(viewport_left, xinf - xmargin)
  local desired_right = xsup + xmargin
  local next_scroll_x = self.scroll.to.x or self.scroll.x or 0
  if range_line and opts.reset_x_if_fits_at_zero ~= false
  and desired_right <= text_viewport_width then
    next_scroll_x = 0
  else
    local current_x = next_scroll_x
    if desired_right > current_x + text_viewport_width then
      if xsup - xinf > text_viewport_width then
        next_scroll_x = desired_left
      else
        next_scroll_x = math.max(
          viewport_left, desired_right - text_viewport_width
        )
      end
    elseif desired_left < current_x then
      next_scroll_x = desired_left
    end
  end

  local right_padding = math.max(style.padding.x, scroll_w or 0)
  require_unwrapped_horizontal_width(self, math.max(
    xsup,
    next_scroll_x + self.size.x - fixed_gutter_right - right_padding
  ))
  self.scroll.to.x = next_scroll_x

  if instant then
    self.scroll.y = self.scroll.to.y
    self.scroll.x = self.scroll.to.x
  end
end


---Handle mouse movement for cursor changes and text selection.
---Updates cursor icon, gutter hover state, and extends selection if dragging.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
function TextView:on_mouse_moved(x, y, ...)
  local selecting = self.mouse_selecting ~= nil
  TextView.super.on_mouse_moved(self, x, y, ...)

  self.hovering_gutter = false
  local gw = self:get_gutter_width()

  if self:scrollbar_hovering() or self:scrollbar_dragging() then
    self.cursor = "arrow"
  elseif gw > 0 and x >= self.position.x and x <= (self.position.x + gw) then
    self.cursor = "arrow"
    self.hovering_gutter = true
  else
    self.cursor = "ibeam"
    self.hovered_fold_widget = nil
    if self:has_collapsed_folds() then
      local line = self:resolve_screen_position(x, y)
      local resolved_widget = self.resolved_fold_widget
      local fold = resolved_widget or self:get_collapsed_fold_at_line(line)
      self.resolved_fold_widget = nil
      if fold and (resolved_widget or fold.show_widget ~= false) then
        self.cursor = "hand"
        self.hovered_fold_widget = fold
      end
    end
  end

  local hovered_fragment
  if not selecting and not self.hovering_gutter and
    not self:scrollbar_hovering() and not self:scrollbar_dragging()
  then
    local hit = self:get_render_widget_at_position(x, y)
    if hit and hit.widget.cursor then
      self.cursor = hit.widget.cursor
      if self.cursor == "hand" then hovered_fragment = hit.fragment end
    else
      hit = self:get_render_fragment_at_position(x, y)
      if hit and hit.fragment.cursor then
        self.cursor = hit.fragment.cursor
        if self.cursor == "hand" then hovered_fragment = hit.fragment end
      end
    end
  end

  if self.hovered_render_fragment ~= hovered_fragment then
    if self.hovered_render_fragment then self.hovered_render_fragment.hovered = nil end
    self.hovered_render_fragment = hovered_fragment
    if hovered_fragment then hovered_fragment.hovered = true end
    core.redraw = true
  end

  local proximity_fragment, proximity = nil, 0
  if not selecting and not self.hovering_gutter and
    not self:scrollbar_hovering() and not self:scrollbar_dragging()
  then
    local near = self:get_render_widget_near_position(x, y)
    if near then
      proximity_fragment, proximity = near.fragment, near.proximity
    end
  end
  local previous_proximity = self.proximity_render_fragment
  local previous_value = previous_proximity and previous_proximity.proximity or 0
  if previous_proximity ~= proximity_fragment then
    if previous_proximity then previous_proximity.proximity = nil end
    self.proximity_render_fragment = proximity_fragment
    if proximity_fragment then proximity_fragment.proximity = proximity end
    core.redraw = true
  elseif proximity_fragment and math.abs(previous_value - proximity) > 0.01 then
    proximity_fragment.proximity = proximity
    core.redraw = true
  end

  if self.mouse_selecting then
    local l1, c1 = self:resolve_screen_position(x, y)
    local l2, c2, snap_type = table.unpack(self.mouse_selecting)
    local special_handled = false
    local anchor_render = self:get_line_render(l2)
    if anchor_render and anchor_render.on_mouse_selection then
      local ok, handled = pcall(
        anchor_render.on_mouse_selection, self, l2, c2, l1, c1
      )
      if not ok then
        core.log_quiet(
          "TextView rendered selection handler failed for %s: %s",
          self.buffer:get_name(), tostring(handled)
        )
      end
      special_handled = ok and handled == true
    end
    if special_handled then
      -- The rendered interaction owns Selection State for this drag.
    elseif keymap.modkeys["ctrl"] then
      if l1 > l2 then l1, l2 = l2, l1 end
      self.buffer.selections = { }
      for i = l1, l2 do
        self.buffer:set_selections(i - l1 + 1, i, math.min(c1, #self.buffer.lines[i]), i, math.min(c2, #self.buffer.lines[i]))
      end
    else
      if snap_type then
        l1, c1, l2, c2 = self:mouse_selection(self.buffer, snap_type, l1, c1, l2, c2)
      end
      self.buffer:set_selection(l1, c1, l2, c2)
    end
  end
  if selecting then
    apply_resolved_line_end_affinity(self)
  end
end

function TextView:on_mouse_left()
  TextView.super.on_mouse_left(self)
  if self.hovered_render_fragment then
    self.hovered_render_fragment.hovered = nil
    self.hovered_render_fragment = nil
    core.redraw = true
  end
  if self.proximity_render_fragment then
    self.proximity_render_fragment.proximity = nil
    self.proximity_render_fragment = nil
    core.redraw = true
  end
end


---Adjust selection based on snap type (word, line).
---@param buffer core.buffer Buffer
---@param snap_type string Snap type: "word" or "lines"
---@param line1 integer Start line
---@param col1 integer Start column
---@param line2 integer End line
---@param col2 integer End column
---@return integer line1 Adjusted start line
---@return integer col1 Adjusted start column
---@return integer line2 Adjusted end line
---@return integer col2 Adjusted end column
function TextView:mouse_selection(buffer, snap_type, line1, col1, line2, col2)
  local swap = line2 < line1 or line2 == line1 and col2 <= col1
  if swap then
    line1, col1, line2, col2 = line2, col2, line1, col1
  end
  if snap_type == "word" then
    line1, col1 = translate.start_of_word(buffer, line1, col1)
    line2, col2 = translate.end_of_word(buffer, line2, col2)
  elseif snap_type == "lines" then
    col1, col2, line2 = 1, 1, line2 + 1
  end
  if swap then
    return line2, col2, line1, col1
  end
  return line1, col1, line2, col2
end


---Handle mouse press for text selection and gutter clicks.
---Supports single/double click, shift-selection, and gutter line selection.
---@param button core.view.mousebutton
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param clicks integer Number of clicks
---@return boolean? handled True if event was handled
function TextView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" then self.buffer:clear_search_selections() end
  if button == "left" and not self.hovering_gutter then
    local widget_hit = self:get_render_widget_at_position(x, y)
    if widget_hit and widget_hit.widget.on_mouse_pressed then
      local ok, handled = pcall(
        widget_hit.widget.on_mouse_pressed,
        widget_hit.widget, self, widget_hit, button, x, y, clicks
      )
      if not ok then
        core.log_quiet(
          "TextView render widget click failed for %s: %s",
          self.buffer:get_name(), tostring(handled)
        )
      end
      if ok and handled ~= false then return true end
    end
    local fragment_hit = self:get_render_fragment_at_position(x, y)
    if fragment_hit and fragment_hit.fragment.on_mouse_pressed then
      local ok, handled = pcall(
        fragment_hit.fragment.on_mouse_pressed,
        fragment_hit.fragment, self, fragment_hit, button, x, y, clicks
      )
      if not ok then
        core.log_quiet(
          "TextView render fragment click failed for %s: %s",
          self.buffer:get_name(), tostring(handled)
        )
      end
      if ok and handled ~= false then return true end
    end
    self.resolved_provider_row = nil
    local line = self:resolve_screen_position(x, y)
    local provider_entry = self.resolved_provider_row
    self.resolved_provider_row = nil
    if provider_entry then
      local row = provider_entry.provider_row
      if row and row.on_click then
        local ok, handled = pcall(row.on_click, self, row, button, x, y, clicks)
        if not ok then core.log_quiet("TextView provider row click failed for %s: %s", self.buffer:get_name(), tostring(handled)) end
      end
      return true
    end
    local resolved_widget = self.resolved_fold_widget
    local fold = resolved_widget or self:get_collapsed_fold_at_line(line)
    self.resolved_fold_widget = nil
    if fold and (resolved_widget or fold.show_widget ~= false) then
      self:expand_fold_region(fold.id, "mouse")
      self.buffer:set_selection(fold.line1, 1, fold.line1, 1)
      return true
    end
  end
  if button ~= "left" or not self.hovering_gutter then
    local result = TextView.super.on_mouse_pressed(self, button, x, y, clicks)
    if button == "left" then
      apply_resolved_line_end_affinity(self)
    end
    return result
  end
  local line = self:resolve_screen_position(x, y)
  if keymap.modkeys["shift"] then
    local sline, scol, sline2, scol2 = self.buffer:get_selection(true)
    if line > sline then
      self.buffer:set_selection(sline, 1, line,  #self.buffer.lines[line])
    else
      self.buffer:set_selection(line, 1, sline2, #self.buffer.lines[sline2])
    end
  else
    if clicks == 1 then
      self.buffer:set_selection(line, 1, line, 1)
    elseif clicks == 2 then
      self.buffer:set_selection(line, 1, line, #self.buffer.lines[line])
    end
  end
  return true
end


---Handle mouse release to end text selection.
function TextView:on_mouse_released(...)
  TextView.super.on_mouse_released(self, ...)
  self.mouse_selecting = nil
  self:end_line_render_interaction("mouse-release")
end


---Handle text input from keyboard.
---@param text string Input text
function TextView:on_text_input(text)
  if not self:can_edit("text input", { warn = true, text = text }) then return false end
  self.buffer:clear_search_selections()
  local line = self.buffer:get_selection()
  local render_line = self:get_line_render(line)
  if render_line and render_line.on_text_input then
    local ok, handled = pcall(render_line.on_text_input, self, text)
    if not ok then
      core.log_quiet(
        "TextView rendered text input failed for %s: %s",
        self.buffer:get_name(), tostring(handled)
      )
    elseif handled then
      return true
    end
  end
  self.buffer:text_input(text)
  return true
end


---Handle IME text composition events.
---Updates IME decoration and scrolls to keep composition visible.
---@param text string Composition text
---@param start integer Selection start within composition
---@param length integer Selection length within composition
function TextView:on_ime_text_editing(text, start, length)
  if not self:can_edit("IME text input", { warn = true, text = text }) then return false end
  local was_composing = self.ime_status
  local composing = #text > 0
  if composing and not was_composing then
    self:begin_line_render_interaction("ime-composition")
  end
  self.buffer:clear_search_selections()
  local handled, adjusted_start, adjusted_length = false, start, length
  local line = self.buffer:get_selection()
  local render_line = self:get_line_render(line)
  if render_line and render_line.on_ime_text_editing then
    local ok, result, result_start, result_length = pcall(
      render_line.on_ime_text_editing, self, text, start, length
    )
    if not ok then
      core.log_quiet(
        "TextView rendered IME input failed for %s: %s",
        self.buffer:get_name(), tostring(result)
      )
    elseif result then
      handled = true
      adjusted_start = tonumber(result_start) or start
      adjusted_length = tonumber(result_length) or length
    end
  end
  if not handled then self.buffer:ime_text_editing(text, start, length) end
  self.ime_status = composing
  self.ime_selection.from = adjusted_start
  self.ime_selection.size = adjusted_length
  if not composing and was_composing then
    self:end_line_render_interaction("ime-composition-end")
  end

  -- Set the composition bounding box that the system IME
  -- will consider when drawing its interface
  local line1, col1, line2, col2 = self.buffer:get_selection(true)
  local col = math.min(col1, col2)
  self:update_ime_location()
  self:scroll_to_make_visible(line1, col + adjusted_start)
end


---Update IME composition window location.
---Sets the bounding box for the system IME composition window.
function TextView:update_ime_location()
  if core.active_view ~= self then return end

  local line1, col1, line2, col2 = self.buffer:get_selection(true)
  if
    not self.ime_status and core.active_view == IME_VIEW
    and
    IME_STATE.line1 == line1 and IME_STATE.col1 == col1
    and
    IME_STATE.line2 == line2 and IME_STATE.col2 == col2
    and
    IME_STATE.w == self.size.x and IME_STATE.h == self.size.y
  then
    return
  end

  IME_VIEW = self
  IME_STATE.line1 = line1
  IME_STATE.col1 = col1
  IME_STATE.line2 = line2
  IME_STATE.col2 = col2
  IME_STATE.w = self.size.x
  IME_STATE.h = self.size.y

  local col = math.min(col1, col2)
  local from_line, from_col, to_line, to_col = line1, col1, line2, col2

  if self.ime_selection.size > 0 then
    -- focus on a part of the text
    from_line, to_line = line1, line1
    from_col = col + self.ime_selection.from
    to_col = from_col + self.ime_selection.size
  end

  local x1, y, x2, h
  if from_line == to_line then
    x1, y, x2, h = self:iter_text_range_screen_segments(
      from_line, from_col, to_col
    )()
  end
  if not x1 then
    x1 = self:get_line_screen_position(from_line, from_col)
    y, h = self:get_position_highlight_geometry(from_line, from_col, false)
    x2 = x1
  end
  ime.set_location(x1, y, math.max(0, x2 - x1), h)
end


function TextView:active_window_has_focus()
  local focused_window = core.active_window or core.window
  return not system.window_has_focus or system.window_has_focus(focused_window)
end

---Discard cached provider output that contains scale-dependent measurements.
---@param reason string
function TextView:invalidate_measurement_dependent_layout(reason)
  if self:has_line_render_providers() then
    self:invalidate_line_render(reason)
  end
  if self:has_visual_metric_providers() then
    self:invalidate_visual_metrics(reason)
  end
  self.__measurement_layout_scale = SCALE
end

function TextView:on_scale_change(new_scale)
  if self.__measurement_layout_scale ~= new_scale then
    self:invalidate_measurement_dependent_layout("scale-change")
  end
end

---Update the view state each frame.
---Handles cache invalidation, auto-scrolling to caret, and blink timing.
function TextView:update()
  local perf_active = core.perf_frame_stats ~= nil
  local update_start = perf_active and system.get_time()
  local file_open_update = file_open_view_update_begin(self)

  -- clear cache if font or indent size changed
  local phase_start = perf_active and system.get_time()
  local font = self:get_font()
  local _, indent_size = self.buffer:get_indent_info()
  local font_changed = self.cache_font ~= font
    or self.cache_font_size ~= font:get_size()
  if
    self.cache_indent_size ~= indent_size
    or
    font_changed
  then
    self.buffer.cache.col_x = {}
    self.buffer.cache.line_width = {}
    self.__line_width_cache = {}
    self.cache_font = font
    self.cache_font_size = font:get_size()
    self.cache_indent_size = indent_size
  end
  if font_changed then
    self:invalidate_measurement_dependent_layout("font-change")
  end
  perf_elapsed("textview_update_cache_ms", phase_start)

  if self.wrapping_enabled and self.size.x > 0 then
    local wrap_start = perf_active and system.get_time()
    self:update_wrap_cache()
    perf_elapsed("textview_update_wrap_cache_ms", wrap_start)
  end

  -- scroll to make caret visible and reset blink timer if it moved
  phase_start = perf_active and system.get_time()
  local line1, col1, line2, col2 = self.buffer:get_selection()
  local selection_moved = line1 ~= self.last_line1 or col1 ~= self.last_col1 or
      line2 ~= self.last_line2 or col2 ~= self.last_col2
  if (selection_moved or self.needs_initial_scroll_validation) and self.size.x > 0 then
    if core.active_view == self and not ime.editing then
      local scroll_start = perf_active and system.get_time()
      self:scroll_to_make_visible(line1, col1, self.needs_initial_scroll_validation)
      perf_elapsed("textview_scroll_to_make_visible_ms", scroll_start)
      self.needs_initial_scroll_validation = nil
    end
    core.blink_reset()
    self.last_line1, self.last_col1 = line1, col1
    self.last_line2, self.last_col2 = line2, col2
  end
  perf_elapsed("textview_update_selection_ms", phase_start)

  -- update blink timer
  phase_start = perf_active and system.get_time()
  local active_window_has_focus = false
  if not config.disable_blink then
    local focus_start = perf_active and system.get_time()
    active_window_has_focus = self:active_window_has_focus()
    perf_elapsed("textview_update_active_focus_ms", focus_start)
  end
  if not config.disable_blink and active_window_has_focus and self == core.active_view and not self.mouse_selecting then
    local T, t0 = config.blink_period, core.blink_start
    local ta, tb = core.blink_timer, system.get_time()
    if ((tb - t0) % T < T / 2) ~= ((ta - t0) % T < T / 2) then
      core.redraw = true
    end
    core.blink_timer = tb
  end
  perf_elapsed("textview_update_blink_ms", phase_start)

  phase_start = perf_active and system.get_time()
  self:update_ime_location()
  perf_elapsed("textview_update_ime_ms", phase_start)

  phase_start = perf_active and system.get_time()
  TextView.super.update(self)
  line_packets.update_contributors(self)
  perf_elapsed("textview_update_super_ms", phase_start)
  perf_elapsed("textview_update_ms", update_start)
  file_open_view_update_end(file_open_update)
end


---Draw the current line highlight bar.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
function TextView:get_line_highlight_rect(x, y, height)
  local lh = height or self:get_line_height()
  local pos_x = self.__full_width_highlight_position_x or self.position.x
  local size_x = self.__full_width_highlight_size_x or self.size.x
  return pos_x, y, size_x, lh
end

function TextView:draw_line_highlight(x, y, height)
  local rx, ry, rw, rh = self:get_line_highlight_rect(x, y, height)
  renderer.draw_rect(rx, ry, rw, rh, style.line_highlight)
end

function TextView:draw_content_left_edge()
  local edge_w = math.max(1, math.floor(SCALE))
  local edge_padding = style.padding.x * 0.25
  local x = self:get_line_screen_position(1) - edge_padding - edge_w
  renderer.draw_rect(x, self.position.y, edge_w, self.size.y, style.textview_content_left_edge)
end

function TextView:get_current_line_highlight_mode()
  if self.show_current_line_highlight == false then return false end
  return config.highlight_current_line
end

function TextView:line_has_current_line_highlight(line)
  local highlight_cache = self.__line_body_highlight_cache
  if highlight_cache then return highlight_cache[line] or false end

  local hcl = self:get_current_line_highlight_mode()
  if hcl == false then return false end
  for lidx, line1, col1, line2, col2 in self.buffer:get_selections(false) do
    if line1 > line then break end
    if line1 == line then
      if hcl == "no_selection" and ((line1 ~= line2) or (col1 ~= col2)) then
        return false
      end
      return true
    end
  end
  return false
end

function TextView:draw_current_line_highlights(minline, maxline, draw_highlight)
  draw_highlight = draw_highlight or function(x, y, height)
    self:draw_line_highlight(x, y, height)
  end
  local hcl = self:get_current_line_highlight_mode()
  if hcl == false then return end
  if self:has_composed_visual_rows() then
    local highlighted_rows = {}
    for _, line1, col1, line2, col2 in self.buffer:get_selections(false) do
      if line1 > maxline then break end
      if line1 >= minline and (hcl ~= "no_selection" or (line1 == line2 and col1 == col2)) then
        local line_end = self.wrapped_settings
          and linewrapping.has_wrapped_line_end_affinity(self, line1, col1)
          or false
        highlighted_rows[self:get_composed_visual_row_for_position(line1, col1, line_end)] = {
          line = line1, col = col1, line_end = line_end,
        }
      end
    end
    for entry in self:iter_visible_visual_rows() do
      local position = highlighted_rows[entry.visual_row]
      if position then
        local y, height = self:get_position_highlight_geometry(
          position.line, position.col, position.line_end
        )
        draw_highlight(self.position.x, y, height)
      end
    end
    return
  end
  if self.wrapped_settings then
    for _, line1, col1, line2, col2 in self.buffer:get_selections(false) do
      if line1 > maxline then break end
      if line1 >= minline and (hcl ~= "no_selection" or (line1 == line2 and col1 == col2)) then
        local line_end = linewrapping.has_wrapped_line_end_affinity(self, line1, col1)
        local y, height = self:get_position_highlight_geometry(
          line1, col1, line_end
        )
        draw_highlight(self.position.x, y, height)
      end
    end
    return
  end
  for _, line1, col1, line2, col2 in self.buffer:get_selections(false) do
    if line1 > maxline then break end
    if line1 >= minline
    and (hcl ~= "no_selection" or (line1 == line2 and col1 == col2))
    then
      local y, height = self:get_position_highlight_geometry(line1, col1, false)
      draw_highlight(self.position.x, y, height)
    end
  end
end

---Draw the full-width underlay and content edge before gutter and row contents.
---The content portion is drawn again later over semantic line decoration backgrounds.
function TextView:draw_current_line_underlay_highlights(minline, maxline)
  self:draw_current_line_highlights(minline, maxline)
  self:draw_content_left_edge()
end


---Return a non-interactive visual hint for a line.
---Override this in Text View subclasses or plugins. The result can be a
---string, a single segment table `{ text, color?, font? }`, or a list of
---segment tables. Hints are drawn right-aligned by default and are never part
---of the Buffer text.
---@param line integer Line number
---@return string|table|nil hint
function TextView:get_line_hint(line)
  return nil
end

---Minimum horizontal gap between Buffer text and a Line Hint.
---@param line integer Line number
---@param hint_options? table Normalized Line Hint options
---@return number gap Pixel gap
function TextView:get_line_hint_gap(line, hint_options)
  local gap_spaces = hint_options and hint_options.gap_spaces
  if gap_spaces then
    return self:get_font():get_width(string.rep(" ", math.max(0, gap_spaces)))
  end
  if hint_options and hint_options.gap then return math.max(0, hint_options.gap) end
  return style.padding.x * 2
end

function TextView:normalize_line_hint(hint)
  if hint == nil or hint == false then return nil end

  local default_font = self:get_font()
  local default_color = style.line_hint
  local base_font = type(hint) == "table" and hint.font or nil
  local base_color = type(hint) == "table" and hint.color or nil
  local segments = {}

  local function add_segment(segment)
    if segment == nil or segment == false then return end
    if type(segment) ~= "table" then
      segment = { text = tostring(segment) }
    end
    if segment.text == nil then return end
    local text = tostring(segment.text)
    if text == "" then return end
    segments[#segments + 1] = {
      text = text,
      font = segment.font or base_font or default_font,
      color = segment.color or base_color or default_color,
    }
  end

  if type(hint) == "table" and hint.text == nil and #hint > 0 then
    for _, segment in ipairs(hint) do add_segment(segment) end
  else
    add_segment(hint)
  end

  if #segments == 0 then return nil end

  if type(hint) == "table" then
    segments.placement = hint.placement
    segments.gap = hint.gap
    segments.gap_spaces = hint.gap_spaces
    segments.truncate = hint.truncate
  end

  return segments
end

function TextView:measure_line_hint_segments(segments)
  local width = 0
  for _, segment in ipairs(segments or {}) do
    width = width + segment.font:get_width(segment.text)
  end
  return width
end

local function copy_line_hint_segment(segment, text)
  return {
    text = text,
    font = segment.font,
    color = segment.color,
  }
end

local function copy_line_hint_options(target, source)
  target.placement = source.placement
  target.gap = source.gap
  target.gap_spaces = source.gap_spaces
  target.truncate = source.truncate
  return target
end

function TextView:truncate_line_hint_segments(segments, max_width, direction)
  max_width = math.max(0, max_width or 0)
  if self:measure_line_hint_segments(segments) <= max_width then
    return segments, false
  end

  local default_font = self:get_font()
  local default_color = style.line_hint
  local ellipsis_font = default_font
  local ellipsis_width = ellipsis_font:get_width(LINE_HINT_ELLIPSIS)
  if ellipsis_width > max_width then return nil, true end

  local remaining = max_width - ellipsis_width
  local kept = {}
  local kept_width = 0
  direction = direction or segments.truncate or "left"

  if direction == "right" then
    for i = 1, #segments do
      local segment = segments[i]
      local chars = {}
      for ch in common.utf8_chars(segment.text) do chars[#chars + 1] = ch end

      local prefix = ""
      local prefix_width = 0
      for j = 1, #chars do
        local candidate = prefix .. chars[j]
        local candidate_width = segment.font:get_width(candidate)
        if kept_width + candidate_width <= remaining then
          prefix = candidate
          prefix_width = candidate_width
        else
          break
        end
      end

      if prefix ~= "" then
        kept[#kept + 1] = copy_line_hint_segment(segment, prefix)
        kept_width = kept_width + prefix_width
      end
      if prefix ~= segment.text then break end
    end

    if #kept == 0 then
      return copy_line_hint_options({{ text = LINE_HINT_ELLIPSIS, font = ellipsis_font, color = default_color }}, segments), true
    end

    kept[#kept + 1] = {
      text = LINE_HINT_ELLIPSIS,
      font = ellipsis_font,
      color = kept[#kept].color or default_color,
    }
    return copy_line_hint_options(kept, segments), true
  end

  for i = #segments, 1, -1 do
    local segment = segments[i]
    local chars = {}
    for ch in common.utf8_chars(segment.text) do chars[#chars + 1] = ch end

    local suffix = ""
    local suffix_width = 0
    for j = #chars, 1, -1 do
      local candidate = chars[j] .. suffix
      local candidate_width = segment.font:get_width(candidate)
      if kept_width + candidate_width <= remaining then
        suffix = candidate
        suffix_width = candidate_width
      else
        break
      end
    end

    if suffix ~= "" then
      table.insert(kept, 1, copy_line_hint_segment(segment, suffix))
      kept_width = kept_width + suffix_width
    end
    if suffix ~= segment.text then break end
  end

  if #kept == 0 then
    return copy_line_hint_options({{ text = LINE_HINT_ELLIPSIS, font = ellipsis_font, color = default_color }}, segments), true
  end

  table.insert(kept, 1, {
    text = LINE_HINT_ELLIPSIS,
    font = ellipsis_font,
    color = kept[1].color or default_color,
  })
  return copy_line_hint_options(kept, segments), true
end

function TextView:get_line_hint_text_end_x(line, x)
  local text = self.buffer.lines[line] or ""
  local text_len = #text
  if text:sub(-1) == "\n" then text_len = text_len - 1 end
  return x + self:get_col_x_offset(line, text_len + 1)
end

---Draw a Line Hint for a line, clipped/truncated so it never covers Buffer text.
---@param line integer Line number
---@param x number Screen x coordinate of the line's text origin
---@param y number Screen y coordinate of the line
---@return number? x_advance
---@return number? x
---@return number? width
function TextView:draw_line_hint(line, x, y)
  local stats = core.textview_frame_stats
  local total_start = stats and system.get_time()
  if stats then stats.line_hint_calls = stats.line_hint_calls + 1 end

  local function finish(skip_key)
    if stats then
      if skip_key then stats[skip_key] = (stats[skip_key] or 0) + 1 end
      stats.line_hint_ms = stats.line_hint_ms + (system.get_time() - total_start) * 1000
    end
  end

  local phase_start = stats and system.get_time()
  local hint = self:get_line_hint(line)
  if stats then stats.line_hint_get_ms = stats.line_hint_get_ms + (system.get_time() - phase_start) * 1000 end

  phase_start = stats and system.get_time()
  local segments = self:normalize_line_hint(hint)
  if stats then stats.line_hint_normalize_ms = stats.line_hint_normalize_ms + (system.get_time() - phase_start) * 1000 end
  if not segments then finish("line_hint_skip_no_hint"); return end

  phase_start = stats and system.get_time()
  local gw = self:get_gutter_width()
  local _, _, vscroll_w = self.v_scrollbar:get_track_rect()
  local content_left = self.position.x + gw
  local content_right = self.position.x + self.size.x - (vscroll_w or 0) - style.padding.x
  if content_right <= content_left then
    if stats then stats.line_hint_layout_ms = stats.line_hint_layout_ms + (system.get_time() - phase_start) * 1000 end
    finish("line_hint_skip_no_space")
    return
  end

  local gap = self:get_line_hint_gap(line, segments)
  local placement = segments.placement
  local text_end_x = self:get_line_hint_text_end_x(line, x)
  local hint_left_limit = math.max(content_left, text_end_x) + gap
  local available = content_right - hint_left_limit
  if stats then stats.line_hint_layout_ms = stats.line_hint_layout_ms + (system.get_time() - phase_start) * 1000 end
  if available <= 0 then finish("line_hint_skip_no_space"); return end

  phase_start = stats and system.get_time()
  local width = self:measure_line_hint_segments(segments)
  if stats then stats.line_hint_measure_ms = stats.line_hint_measure_ms + (system.get_time() - phase_start) * 1000 end
  if width > available then
    phase_start = stats and system.get_time()
    segments = self:truncate_line_hint_segments(segments, available, segments.truncate)
    if stats then stats.line_hint_truncate_ms = stats.line_hint_truncate_ms + (system.get_time() - phase_start) * 1000 end
    if not segments then finish("line_hint_skip_truncated"); return end
    phase_start = stats and system.get_time()
    width = self:measure_line_hint_segments(segments)
    if stats then stats.line_hint_measure_ms = stats.line_hint_measure_ms + (system.get_time() - phase_start) * 1000 end
    if width > available + 0.5 then finish("line_hint_skip_truncated"); return end
  end

  local draw_x = placement == "after_line_buffer_text" and hint_left_limit or content_right - width
  local tx = draw_x
  local line_text = self.buffer.lines[line] or ""
  local hint_col = self.wrapped_settings and #line_text + 1 or 1
  local content_y_offset, content_height = self:get_line_render_content_geometry(
    line, hint_col, self.wrapped_settings and true or false
  )
  local hint_y = content_y_offset and y + content_y_offset or y
  local hint_height = content_height or self:get_line_height()
  local ty = y + self:get_line_text_y_offset()
  local lh = self:get_line_height()

  phase_start = stats and system.get_time()
  core.push_clip_rect(
    hint_left_limit, hint_y, math.max(0, content_right - hint_left_limit), hint_height
  )
  for _, segment in ipairs(segments) do
    local draw_text_start = stats and system.get_time()
    local segment_y = content_y_offset
      and hint_y + math.max(0, (hint_height - segment.font:get_height()) / 2)
      or ty
    tx = renderer.draw_text(
      segment.font, segment.text, tx, segment_y, segment.color
    )
    if stats then
      local elapsed = (system.get_time() - draw_text_start) * 1000
      stats.draw_text_calls = stats.draw_text_calls + 1
      stats.renderer_draw_text_ms = stats.renderer_draw_text_ms + elapsed
      stats.line_hint_draw_text_calls = stats.line_hint_draw_text_calls + 1
      stats.line_hint_draw_text_ms = stats.line_hint_draw_text_ms + elapsed
    end
  end
  core.pop_clip_rect()
  if stats then
    stats.line_hint_draw_ms = stats.line_hint_draw_ms + (system.get_time() - phase_start) * 1000
    stats.line_hint_drawn = stats.line_hint_drawn + 1
  end
  finish()
  return tx, draw_x, width
end

local function fast_ascii_monospace_width(text, space_width, tab_width, tab_offset)
  local x = tab_offset or 0
  local start_x = x
  for i = 1, #text do
    if text:byte(i) == 9 then
      x = (math.floor(x / tab_width) + 1) * tab_width
    else
      x = x + space_width
    end
  end
  return x - start_x
end

local function draw_render_fragment_background(fragment, x, y, width, height, force)
  if fragment.background and (force or not fragment.background_under_selection) then
    renderer.draw_rect(x, y, width, height, fragment.background)
  end
  if fragment.hovered and fragment_uses_hand_cursor(fragment) then
    renderer.draw_rect(
      x, y, width, height,
      fragment.hover_background or style.interactive_hover_background
    )
  end
end

local function draw_render_fragment_text(
  fragment, font, text, x, y, color, opts, background_y, background_height
)
  local text_width = font:get_width(text, opts)
  local width
  if fragment.text_lines then
    width = fragment.width
    if not width then
      width = 0
      for _, line in ipairs(fragment.text_lines) do
        local line_text = type(line) == "table" and line.text or line
        local line_x_offset = type(line) == "table" and line.x_offset
          or fragment.text_x_offset or 0
        width = math.max(width, line_x_offset + font:get_width(line_text or "", opts))
      end
    end
  else
    width = math.max(text_width, fragment.width or 0)
  end
  local text_x = x + (fragment.text_x_offset or 0)
  if fragment.text_lines then
    draw_render_fragment_background(
      fragment, x, background_y or y, width,
      background_height or font:get_height()
    )
    local border_width = math.max(1, math.floor(SCALE))
    if fragment.background_border_top then
      renderer.draw_rect(
        x, background_y or y, width, border_width, fragment.background_border_top
      )
    end
    if fragment.background_border_bottom then
      local height = background_height or font:get_height()
      renderer.draw_rect(
        x, (background_y or y) + height - border_width,
        width, border_width, fragment.background_border_bottom
      )
    end
    local line_height = fragment.text_line_height or font:get_height()
    local line_y = (background_y or y) + (fragment.text_y_padding or 0)
    for _, line in ipairs(fragment.text_lines) do
      local line_text = type(line) == "table" and line.text or line
      local line_x_offset = type(line) == "table" and line.x_offset
        or fragment.text_x_offset or 0
      if fragment.text_line_background and line_text and line_text ~= "" then
        local padding = fragment.text_line_background_padding or 0
        renderer.draw_rect(
          x + line_x_offset - padding,
          line_y,
          font:get_width(line_text, opts) + padding * 2,
          line_height,
          fragment.text_line_background
        )
      end
      if line_text and line_text ~= "" then
        renderer.draw_text(
          font, line_text, x + line_x_offset, line_y, color, opts
        )
      end
      line_y = line_y + line_height
    end
    return x + width
  end
  draw_render_fragment_background(
    fragment,
    x,
    fragment.background_full_height and (background_y or y) or y,
    width,
    fragment.background_full_height and (background_height or font:get_height())
      or math.max(1, font:get_height())
  )
  local next_x = renderer.draw_text(font, text, text_x, y, color, opts)
  if fragment.overdraw then
    renderer.draw_text(
      font, text, text_x + (fragment.overdraw_dx or math.max(1, common.round(SCALE))), y, color, opts
    )
  end
  if fragment.strikethrough then
    renderer.draw_rect(
      text_x, y + math.floor(font:get_height() / 2), text_width, math.max(1, common.round(SCALE)), color
    )
  end
  if fragment.underline then
    renderer.draw_rect(
      text_x, y + font:get_height() - math.max(1, common.round(SCALE)), text_width, math.max(1, common.round(SCALE)), color
    )
  end
  return math.max(next_x, x + width)
end

local function draw_render_widget_outline(
  outline_left, outline_top, outline_width, outline_height, outline_border, color
)
  if not color or outline_width <= 0 or outline_height <= 0 then return end
  renderer.draw_rect(
    outline_left, outline_top, outline_width, outline_border, color
  )
  renderer.draw_rect(
    outline_left, outline_top + math.max(0, outline_height - outline_border),
    outline_width, outline_border, color
  )
  local vertical_height = outline_height - outline_border * 2
  if vertical_height > 0 then
    renderer.draw_rect(
      outline_left, outline_top + outline_border,
      outline_border, vertical_height, color
    )
    renderer.draw_rect(
      outline_left + math.max(0, outline_width - outline_border),
      outline_top + outline_border, outline_border, vertical_height, color
    )
  end
end

local function draw_render_widget(view, fragment, x, y, row_height, context)
  local widget = fragment.widget
  local ok, err = pcall(widget.draw, view, fragment, x, y, row_height)
  if not ok then
    core.log_quiet(
      "TextView %s draw failed for %s: %s",
      context or "render widget", view.buffer:get_name(), tostring(err)
    )
    return false
  end
  if widget.suppress_hover_overlay
  or not (fragment.hovered and fragment_uses_hand_cursor(fragment))
  then
    return true
  end

  local left, top, width, height = render_widget_rect(
    fragment, x, y, row_height, widget.hover_outline_padding
  )

  if not widget.suppress_hover_background then
    renderer.draw_rect(left, top, width, height, style.interactive_hover_overlay)
  end
  local border = widget.hover_outline_width
  if border == nil then
    border = math.max(1, math.floor(SCALE))
  else
    border = math.max(1, math.floor(border))
  end
  local outline_left, outline_top = left, top
  local outline_width, outline_height = width, height
  if widget.hover_outline_outside then
    -- Keep the outline outside the widget bounds so image pixels are not
    -- covered by the feedback. Clamp to the content clip so an image at the
    -- viewport edge still has a visible, closed outline instead of losing
    -- its outer edge to the clip.
    local clip_left = view.position.x + (view:get_gutter_width() or 0)
    local clip_top = view.position.y
    local clip_right = view.position.x + view.size.x
    local clip_bottom = view.position.y + view.size.y
    local outer_left = left - border
    local outer_top = top - border
    local outer_right = left + width + border
    local outer_bottom = top + height + border
    if outer_left < clip_left then outer_left = left end
    if outer_top < clip_top then outer_top = top end
    if outer_right > clip_right then outer_right = left + width end
    if outer_bottom > clip_bottom then outer_bottom = top + height end
    outline_left = outer_left
    outline_top = outer_top
    outline_width = math.max(0, outer_right - outer_left)
    outline_height = math.max(0, outer_bottom - outer_top)
  end
  draw_render_widget_outline(
    outline_left, outline_top, outline_width, outline_height,
    border, style.interactive_hover_border
  )

  local inner_color = widget.hover_inner_outline_color
  if inner_color then
    local inner_border = widget.hover_inner_outline_width
    if inner_border == nil then
      inner_border = border
    else
      inner_border = math.max(1, math.floor(inner_border))
    end
    local inset = widget.hover_inner_outline_padding
    if inset == nil then inset = inner_border end
    inset = math.max(0, math.floor(inset))
    draw_render_widget_outline(
      left + inset, top + inset,
      width - inset * 2, height - inset * 2,
      inner_border, inner_color
    )
  end
  return true
end

---Draw a visual prefix in the indent of each visible soft-wrap continuation.
---@param line integer Logical buffer line
---@param x number Screen x coordinate of the line body
---@param y number Screen y coordinate of the first visual row
function TextView:draw_soft_wrap_continuation_indicators(line, x, y)
  if not self.wrapped_settings then return end
  local indicator = config.plugins.linewrapping.continuation_indicator
  if type(indicator) ~= "string" or indicator == "" then return end

  local first_idx, _, count = linewrapping.get_line_idx_col_count(self, line)
  if count <= 1 then return end
  local visible_idx1 = math.max(
    first_idx + 1, self.__wrapped_draw_first_idx or first_idx + 1
  )
  local visible_idx2 = math.min(
    first_idx + count - 1,
    self.__wrapped_draw_last_idx or first_idx + count - 1
  )
  if visible_idx2 < visible_idx1 then return end

  local render_line = self:get_line_render(line)
  local font = style.soft_wrap_indicator_font
  local gap = font:get_width(" ")
  local indicator_width = font:get_width(indicator)
  local begin_width = self.wrapped_line_offsets[line] or 0
  if begin_width < indicator_width + gap then return end
  local indicator_x = x + (render_line and render_line.x_offset or 0)
    + begin_width - indicator_width - gap
  local color = style.soft_wrap_indicator

  for idx = visible_idx1, visible_idx2 do
    local row_y, row_height = wrapped_row_geometry(self, y, first_idx, idx)
    local content_y, content_height = row_y, row_height
    if render_line then
      local offset
      offset, content_height = line_render_content_geometry(
        render_line, row_height, false
      )
      content_y = row_y + offset
    end
    renderer.draw_text(
      font,
      indicator,
      indicator_x,
      content_y + math.max(0, (content_height - font:get_height()) / 2),
      color
    )
  end
end

---Draw the text content of a line with syntax highlighting.
---@param line integer Line number
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return integer height Line height
function TextView:draw_line_text(line, x, y)
  if not self.buffer.lines[line] then
    core.log_quiet(
      "TextView draw_line_text: skipped stale line for %s (line=%s buffer_lines=%d)",
      self.buffer:get_name(), tostring(line), #self.buffer.lines
    )
    if self.wrapped_settings then self.wrapped_buffer_line_count = nil end
    return self:get_line_height()
  end

  line_packets.draw_legacy_before_text(self, line, x, y)

  local render_line = self:get_line_render(line)
  if render_line and self.wrapped_settings and not render_line.disable_wrapping then
    local first_idx, _, count = linewrapping.get_line_idx_col_count(self, line)
    local visible_idx1 = math.max(first_idx, self.__wrapped_draw_first_idx or first_idx)
    local visible_idx2 = math.min(first_idx + count - 1, self.__wrapped_draw_last_idx or (first_idx + count - 1))
    local begin_width = self.wrapped_line_offsets[line] or 0
    local first_visual_row = self:get_visual_row(line, 1)
    local first_row_y_offset = self:get_visual_row_y_offset(first_visual_row)
    local _, indent_size = self.buffer:get_indent_info()
    local fragments = self:iter_line_render_fragments(render_line)
    for idx = visible_idx1, visible_idx2 do
      local _, row_start = linewrapping.get_idx_line_col(self, idx)
      local next_line, row_end = linewrapping.get_idx_line_col(self, idx + 1)
      local last_row = next_line ~= line
      if last_row then row_end = #(self.buffer.lines[line] or "") end
      local tx = x + (render_line.x_offset or 0)
        + (row_start ~= 1 and begin_width or 0)
      local visual_row = self:get_visual_row(line, row_start)
      local row_y = y + self:get_visual_row_y_offset(visual_row) - first_row_y_offset
      local row_height = self:get_visual_row_height(visual_row)
      local content_y_offset, content_height = line_render_content_geometry(
        render_line, row_height, idx == first_idx
      )
      local content_y = row_y + content_y_offset
      for _, fragment in ipairs(fragments) do
        local col1 = fragment.source_col1 or 1
        local col2 = fragment.source_col2 or col1
        local from = math.max(col1, row_start)
        local to = math.min(col2, row_end)
        local anchored_widget = col1 == col2
          and fragment.widget and fragment.widget.draw
          and col1 >= row_start
          and (col1 < row_end or (last_row and col1 == row_end))
        if anchored_widget and not fragment.hidden then
          local width = fragment.width or fragment.widget.width or 0
          -- Column mapping places the anchor caret after this widget; drawing
          -- still starts one widget width before that caret.
          local anchor_x = x
            + self:get_line_render_col_x_offset(render_line, col1) - width
          draw_render_widget(
            self, fragment, anchor_x, content_y, content_height,
            "wrapped anchored widget"
          )
        elseif from < to and not fragment.hidden then
          local font = render_fragment_font(self, fragment)
          font:set_tab_size(indent_size)
          if fragment.widget and fragment.widget.draw and from == col1 and to == col2 then
            draw_render_widget(
              self, fragment, tx, content_y, content_height,
              "wrapped render widget"
            )
            tx = tx + (fragment.width or fragment.widget.width or 0)
          else
            local text = fragment.text or ""
            local text_col1 = fragment.text_source_col1 or col1
            local text_col2 = fragment.text_source_col2 or col2
            local visible_from = math.max(from, text_col1)
            local visible_to = math.min(to, text_col2)
            local text_from = math.min(#text + 1, visible_from - text_col1 + 1)
            local text_to = math.min(#text, visible_to - text_col1)
            local segment = text_to >= text_from and text:sub(text_from, text_to) or ""
            if segment ~= "" then
              local color = render_fragment_color(fragment)
              local segment_y = content_y
                + math.max(0, (content_height - font:get_height()) / 2)
              tx = draw_render_fragment_text(
                fragment, font, segment, tx, segment_y, color,
                { tab_offset = tx - x }
              )
            elseif fragment.width and from == col1 and to == col2 then
              tx = tx + fragment.width
            end
          end
        end
      end
    end
    return self:get_visual_row_y_offset(first_visual_row + count) - first_row_y_offset
  end
  if render_line then
    if render_line.position_rows and not render_line.position_rows_draw_full_line then
      local fragments = self:iter_line_render_fragments(render_line)
      local _, indent_size = self.buffer:get_indent_info()
      local layout_height = render_line.layout_height
        or self:get_position_visual_row_height(line, 1)

      -- Block widgets are anchored to the rendered Buffer line rather than
      -- to one text caret row. Draw each exactly once; text fragments below
      -- are then sliced through the same source ranges used for navigation.
      for _, fragment in ipairs(fragments) do
        if fragment.image_block and fragment.widget and fragment.widget.draw
        and not fragment.hidden then
          local draw_x = x + (fragment.layout_x or 0)
          draw_render_widget(
            self, fragment, draw_x, y, layout_height,
            "positioned render widget"
          )
        end
      end

      for _, row in ipairs(render_line.position_rows) do
        local row_start = row.source_col1 or 1
        local row_end = row.source_col2 or row_start
        local row_height = math.max(1, row.height or self:get_line_height())
        local row_y = y + (row.y_offset or 0)
        local tx = x + (render_line.x_offset or 0) + (row.x_offset or 0)
        for _, fragment in ipairs(fragments) do
          if not fragment.image_block and not fragment.hidden then
            local col1 = fragment.source_col1 or 1
            local col2 = fragment.source_col2 or col1
            local from = math.max(col1, row_start)
            local to = math.min(col2, row_end)
            if from < to then
              local font = render_fragment_font(self, fragment)
              font:set_tab_size(indent_size)
              if fragment.widget and fragment.widget.draw
              and from == col1 and to == col2 then
                draw_render_widget(
                  self, fragment, tx, row_y, row_height,
                  "positioned inline widget"
                )
                tx = tx + (fragment.width or fragment.widget.width or 0)
              else
                local text = fragment.text or ""
                local text_col1 = fragment.text_source_col1 or col1
                local text_col2 = fragment.text_source_col2 or col2
                local visible_from = math.max(from, text_col1)
                local visible_to = math.min(to, text_col2)
                local text_from = math.min(
                  #text + 1, visible_from - text_col1 + 1
                )
                local text_to = math.min(#text, visible_to - text_col1)
                local segment = text_to >= text_from
                  and text:sub(text_from, text_to) or ""
                if segment ~= "" then
                  local ty = row_y + math.max(0, (row_height - font:get_height()) / 2)
                  tx = draw_render_fragment_text(
                    fragment, font, segment, tx, ty,
                    render_fragment_color(fragment), { tab_offset = tx - x },
                    row_y, row_height
                  )
                elseif fragment.width and from == col1 and to == col2 then
                  tx = tx + fragment.width
                end
              end
            end
          end
        end
      end
      return layout_height
    end
    local tx = x + (render_line.x_offset or 0)
    local row = self:get_visual_row(line, 1)
    local row_height = self:get_visual_row_height(row)
    local content_y_offset, content_height = line_render_content_geometry(
      render_line, row_height, true
    )
    local content_y = y + content_y_offset
    local _, indent_size = self.buffer:get_indent_info()
    for _, fragment in ipairs(self:iter_line_render_fragments(render_line)) do
      if not fragment.hidden then
        local col1 = fragment.source_col1 or 1
        local position_row = self:get_line_render_position_row(
          render_line, col1, (fragment.source_col2 or col1) > col1
        )
        local draw_x = fragment.layout_x ~= nil and x + fragment.layout_x
        or position_row and x + self:get_line_render_col_x_offset(
          render_line, col1, position_row
        )
          or tx
        local draw_y = content_y
          + (position_row and (position_row.y_offset or 0) or 0)
        local draw_height = position_row and (position_row.height or row_height)
          or content_height
        local font = render_fragment_font(self, fragment)
        font:set_tab_size(indent_size)
        local text = fragment.text or ""
        local ty = draw_y + math.max(0, (draw_height - font:get_height()) / 2)
        if fragment.widget and fragment.widget.draw then
          draw_render_widget(
            self, fragment, draw_x, content_y, content_height,
            "render widget"
          )
          tx = draw_x + (fragment.width or fragment.widget.width or 0)
        elseif text ~= "" or fragment.text_lines then
          local color = render_fragment_color(fragment)
          tx = draw_render_fragment_text(
            fragment, font, text, draw_x, ty, color,
            { tab_offset = draw_x - x }, draw_y, draw_height
          )
        elseif fragment.width then
          tx = draw_x + fragment.width
        end
      end
    end
    return row_height
  end
  local provider_text_color = self:decoration_text_color(line)
  if provider_text_color then
    local text_y_offset = self:get_line_text_y_offset()
    local lh = self:get_line_height()
    if self.wrapped_settings then
      local first_idx, _, count = linewrapping.get_line_idx_col_count(self, line)
      local visible_idx1 = math.max(first_idx, self.__wrapped_draw_first_idx or first_idx)
      local visible_idx2 = math.min(first_idx + count - 1, self.__wrapped_draw_last_idx or (first_idx + count - 1))
      for idx = visible_idx1, visible_idx2 do
        local row_line, row_start_col = linewrapping.get_idx_line_col(self, idx)
        if row_line == line then
          local next_line, row_end_col = linewrapping.get_idx_line_col(self, idx + 1)
          if next_line ~= line then row_end_col = #self.buffer.lines[line] end
          local tx = x + (row_start_col ~= 1 and (self.wrapped_line_offsets[line] or 0) or 0)
          renderer.draw_text(self:get_font(), self.buffer.lines[line]:sub(row_start_col, math.max(row_start_col, row_end_col - 1)), tx, y + text_y_offset + (idx - first_idx) * lh, provider_text_color)
        end
      end
      return lh * count
    end
    renderer.draw_text(self:get_font(), self.buffer.lines[line], x, y + text_y_offset, provider_text_color)
    return lh
  end
  local packet_height = line_packets.draw_content(self, line, x, y)
  if packet_height then return packet_height end
  if self.wrapped_settings then
    local wrapped_text_scope = perf_scope_begin("wrapped_text", true)
    local perf_active = core.perf_frame_stats ~= nil
    local perf_start = perf_active and system.get_time()
    local perf_segments, perf_bytes, perf_known_bounds_segments = 0, 0, 0
    local substring_ms, enqueue_known_ms, enqueue_measured_ms = 0, 0, 0
    local substring_calls, enqueue_known_calls, enqueue_measured_calls = 0, 0, 0
    local default_font = self:get_font()
    local default_font_height = default_font:get_height()
    local default_ascii_cell_width = default_font:get_width(" ")
    local text_y_offset = self:get_line_text_y_offset()
    local begin_width = self.wrapped_line_offsets[line]
    local lh = self:get_line_height()
    local first_idx, _, count = linewrapping.get_line_idx_col_count(self, line)
    local last_idx = first_idx + count - 1
    local visible_idx1 = math.max(first_idx, self.__wrapped_draw_first_idx or first_idx)
    local visible_idx2 = math.min(last_idx, self.__wrapped_draw_last_idx or last_idx)
    local drawn_rows = math.max(0, visible_idx2 - visible_idx1 + 1)
    local can_use_known_bounds = renderer.draw_text_known_bounds ~= nil

    local function draw_segment(font, text, sx, sy, color, uses_default_font)
      if text == "" then return sx end
      perf_segments = perf_segments + 1
      perf_bytes = perf_bytes + #text
      if can_use_known_bounds
      and uses_default_font
      and not text:find("[\t\128-\255]")
      and not has_ligature_sensitive_ascii(text) then
        perf_known_bounds_segments = perf_known_bounds_segments + 1
        local width = #text * default_ascii_cell_width
        local enqueue_start = perf_active and system.get_time()
        local result = draw_text_known_advance(
          font, text, sx, sy,
          width,
          default_font_height,
          color
        )
        if enqueue_start then
          enqueue_known_ms = enqueue_known_ms + (system.get_time() - enqueue_start) * 1000
          enqueue_known_calls = enqueue_known_calls + 1
        end
        return result
      end
      local enqueue_start = perf_active and system.get_time()
      local result = renderer.draw_text(font, text, sx, sy, color)
      if enqueue_start then
        enqueue_measured_ms = enqueue_measured_ms + (system.get_time() - enqueue_start) * 1000
        enqueue_measured_calls = enqueue_measured_calls + 1
      end
      return result
    end

    local row_idx = visible_idx1
    local _, row_start_col = linewrapping.get_idx_line_col(self, row_idx)
    local row_next_line, row_end_col = linewrapping.get_idx_line_col(self, row_idx + 1)
    if row_next_line ~= line then row_end_col = #self.buffer.lines[line] end
    local tx = x + (row_start_col ~= 1 and begin_width or 0)
    local ty = y + text_y_offset + (row_idx - first_idx) * lh
    local token_start_col = 1

    local function advance_row()
      row_idx = row_idx + 1
      if row_idx > visible_idx2 then return false end
      _, row_start_col = linewrapping.get_idx_line_col(self, row_idx)
      row_next_line, row_end_col = linewrapping.get_idx_line_col(self, row_idx + 1)
      if row_next_line ~= line then row_end_col = #self.buffer.lines[line] end
      tx = x + (row_start_col ~= 1 and begin_width or 0)
      ty = y + text_y_offset + (row_idx - first_idx) * lh
      return true
    end

    local token_loop_scope = perf_scope_begin("token_and_wrap_loop")
    for _, type, text in self.buffer.highlighter:each_token(line) do
      if row_idx > visible_idx2 then break end
      local token_end_col = token_start_col + #text
      local color = style.syntax[type] or style.syntax["normal"]
      local syntax_font = style.syntax_fonts[type]
      local font = syntax_font or default_font
      while row_idx <= visible_idx2 and token_end_col > row_start_col do
        if token_start_col >= row_end_col then
          if not advance_row() then break end
        else
          local draw_start_col = math.max(token_start_col, row_start_col)
          local draw_end_col = math.min(token_end_col, row_end_col)
          local substring_start = perf_active and system.get_time()
          local rendered_text = text:sub(draw_start_col - token_start_col + 1, draw_end_col - token_start_col)
          if substring_start then
            substring_ms = substring_ms + (system.get_time() - substring_start) * 1000
            substring_calls = substring_calls + 1
          end
          tx = draw_segment(font, rendered_text, tx, ty, color, syntax_font == nil)
          if token_end_col >= row_end_col then
            if not advance_row() then break end
          else
            break
          end
        end
      end
      token_start_col = token_end_col
    end
    local scope_perf = token_loop_scope and package.loaded["core.perf"]
    if scope_perf and scope_perf.scope_add_child then
      scope_perf.scope_add_child(token_loop_scope, "substring", substring_ms, substring_calls)
      scope_perf.scope_add_child(token_loop_scope, "enqueue_known_bounds", enqueue_known_ms, enqueue_known_calls)
      scope_perf.scope_add_child(token_loop_scope, "enqueue_measured", enqueue_measured_ms, enqueue_measured_calls)
    end
    perf_scope_end(token_loop_scope)
    perf_frame_add("linewrapping_draw_line_text_calls", 1)
    perf_frame_add("linewrapping_draw_line_text_rows", drawn_rows)
    perf_frame_add("linewrapping_draw_line_text_segments", perf_segments)
    perf_frame_add("linewrapping_draw_line_text_bytes", perf_bytes)
    perf_frame_add("linewrapping_draw_line_text_known_bounds_segments", perf_known_bounds_segments)
    perf_elapsed("linewrapping_draw_line_text_ms", perf_start)
    perf_scope_end(wrapped_text_scope)
    return lh * count
  end

  local stats = core.textview_frame_stats
  local text_start = stats and system.get_time()
  local default_font = self:get_font()
  local tx, ty = x, y + self:get_line_text_y_offset()
  local last_token = nil
  local get_line_start = stats and system.get_time()
  local render_line = self.buffer.highlighter:get_render_line(line)
  local tokens = render_line.tokens
  if stats then stats.highlighter_get_line_ms = stats.highlighter_get_line_ms + (system.get_time() - get_line_start) * 1000 end
  local syntax = style.syntax
  local syntax_fonts = style.syntax_fonts
  local normal_color = syntax.normal
  local tokens_count = #tokens
  if tokens_count > 0 and string.sub(tokens[tokens_count], -1) == "\n" then
    last_token = tokens_count - 1
  end
  local _, indent_size = self.buffer:get_indent_info()
  local token_loop_start = stats and system.get_time()
  local line_start_tx = tx
  local unwrapped_default_ascii_width = default_font:get_width(" ")
  local unwrapped_tab_width = unwrapped_default_ascii_width * indent_size
  local unwrapped_default_font_height = default_font:get_height()
  local line_text = self.buffer.lines[line]
  local line_len = #line_text
  local draw_start_col = 1
  local draw_end_col = line_len
  if line_len > CACHE_LINE_LEN and self.scroll.x > 0 then
    local col1, col2 = self:get_visible_cols_range(line, 512)
    if col1 and col1 > 1 then
      local visible_left = x + self.scroll.x
      local target_x = visible_left - default_font:get_width("W") * 64
      local has_syntax_font = false
      for i = 1, tokens_count, 2 do
        if syntax_fonts[tokens[i]] then
          has_syntax_font = true
          break
        end
      end
      local can_fast_monospace_anchor = not has_syntax_font and not render_line.text:find("[\t\128-\255]")
      local function col_tx(col)
        if can_fast_monospace_anchor then
          return x + (col - 1) * unwrapped_default_ascii_width
        end
        return x + self:get_col_x_offset(line, col)
      end
      local candidate_tx = col_tx(col1)
      if candidate_tx > target_x then
        local lo, hi = 1, col1 - 1
        col1 = 1
        candidate_tx = x
        while lo <= hi do
          local mid = math.floor((lo + hi) / 2)
          local mid_tx = col_tx(mid)
          if mid_tx <= target_x then
            col1 = mid
            candidate_tx = mid_tx
            lo = mid + 1
          else
            hi = mid - 1
          end
        end
      elseif candidate_tx < target_x - default_font:get_width("W") * 128 then
        local lo, hi = col1 + 1, #self.buffer.lines[line]
        while lo <= hi do
          local mid = math.floor((lo + hi) / 2)
          local mid_tx = col_tx(mid)
          if mid_tx <= target_x then
            col1 = mid
            candidate_tx = mid_tx
            lo = mid + 1
          else
            hi = mid - 1
          end
        end
      end
      if col1 > 1 then
        draw_start_col = col1
        tx = candidate_tx
        local estimated_visible_cols = math.ceil((self.size.x + default_font:get_width("W") * 256) / math.max(1, unwrapped_default_ascii_width))
        draw_end_col = math.min(line_len, math.max(col2 or 0, draw_start_col + estimated_visible_cols))
      end
    end
  end

  if
    renderer.draw_text_known_bounds
    and core.window
    and (not package.loaded["core.test"] or self.__test_force_known_bounds)
    and tokens_count == 2
    and tokens[1] == "normal"
    and not style.syntax_fonts.normal
    and render_line.text:find("[\128-\255]") == nil
    and not has_ligature_sensitive_ascii(render_line.text)
  then
    local text = tokens[2]
    if text:sub(-1) == "\n" then text = text:sub(1, -2) end
    if draw_start_col > 1 or draw_end_col < #text then
      text = text:sub(draw_start_col, draw_end_col)
    end
    if text ~= "" then
      local draw_text_start = stats and system.get_time()
      local char_width = unwrapped_default_ascii_width
      local tab_width = unwrapped_tab_width
      local width = #text * char_width
      local text_has_tabs = false

      -- Cull text that extends past the right edge of the view.
      -- Without this, very long unwrapped lines feed their entire text
      -- (potentially 100KB+) through the GPU command buffer and per-glyph
      -- iteration, making every redraw frame take hundreds of milliseconds.
      local right_edge = self.position.x + self.size.x
      if tx + width > right_edge then
        local available = right_edge - tx
        if available <= 0 then
          if stats then
            stats.tokens = stats.tokens + 1
            stats.token_loop_ms = stats.token_loop_ms + (system.get_time() - token_loop_start) * 1000
            stats.text_ms = stats.text_ms + (system.get_time() - text_start) * 1000
            stats.text_lines = stats.text_lines + 1
          end
          return self:get_line_height()
        end
        -- Include a small right-edge margin so the renderer can clip the
        -- partially-visible final cell and any normal glyph overhang instead
        -- of leaving a blank strip at the viewport edge.
        local max_chars = math.ceil((available + char_width * 4) / char_width)
        local tab_scan_chars = math.min(#text, max_chars + indent_size * 2)
        text_has_tabs = text:sub(1, tab_scan_chars):find("\t", 1, true) ~= nil
        if text_has_tabs then
          -- Tab expansion can push past the naive char-width estimate.
          max_chars = max_chars + indent_size * 2
        end
        if max_chars < #text then
          text = text:sub(1, max_chars)
        end
      else
        text_has_tabs = text:find("\t", 1, true) ~= nil
      end
      width = text_has_tabs
        and fast_ascii_monospace_width(text, char_width, tab_width, tx - line_start_tx)
        or (#text * char_width)

      tx = draw_text_known_advance(
        default_font,
        text,
        tx,
        ty,
        width,
        unwrapped_default_font_height,
        normal_color,
        text_has_tabs and { tab_offset = tx - line_start_tx } or nil
      )
      if stats then
        stats.tokens = stats.tokens + 1
        stats.draw_text_calls = stats.draw_text_calls + 1
        stats.renderer_draw_text_ms = stats.renderer_draw_text_ms + (system.get_time() - draw_text_start) * 1000
        stats.token_loop_ms = stats.token_loop_ms + (system.get_time() - token_loop_start) * 1000
        stats.text_ms = stats.text_ms + (system.get_time() - text_start) * 1000
        stats.text_lines = stats.text_lines + 1
      end
      return self:get_line_height()
    end
  end

  local start_tx = line_start_tx
  local pending_font, pending_color, pending_chunks, pending_len, pending_has_tabs
  local max_pending_bytes = self.buffer.binary and 256 or 512
  local function flush_pending_text()
    if not pending_font then return false end
    local draw_text_start = stats and system.get_time()
    local text = #pending_chunks == 1 and pending_chunks[1] or table.concat(pending_chunks)
    if renderer.draw_text_known_bounds
    and (not package.loaded["core.test"] or self.__test_force_known_bounds)
    and (core.window or self.__test_force_known_bounds)
    and pending_font == default_font
    and not text:find("[\128-\255]")
    and not has_ligature_sensitive_ascii(text) then
      local tab_offset = tx - start_tx
      local width = pending_has_tabs
        and fast_ascii_monospace_width(text, unwrapped_default_ascii_width, unwrapped_tab_width, tab_offset)
        or (#text * unwrapped_default_ascii_width)
      tx = draw_text_known_advance(
        pending_font,
        text,
        tx,
        ty,
        width,
        unwrapped_default_font_height,
        pending_color,
        pending_has_tabs and { tab_offset = tab_offset } or nil
      )
    elseif pending_has_tabs then
      tx = renderer.draw_text(pending_font, text, tx, ty, pending_color, {tab_offset = tx - start_tx})
    else
      tx = renderer.draw_text(pending_font, text, tx, ty, pending_color)
    end
    if stats then
      stats.draw_text_calls = stats.draw_text_calls + 1
      stats.renderer_draw_text_ms = stats.renderer_draw_text_ms + (system.get_time() - draw_text_start) * 1000
    end
    pending_font, pending_color, pending_chunks, pending_len, pending_has_tabs = nil, nil, nil, nil, nil
    return tx > self.position.x + self.size.x
  end
  local function ascii_strong_boundary(text, j)
    local byte = text:byte(j)
    local next_byte = text:byte(j + 1)
    return byte == 32 or byte == 9 or byte == 34 or byte == 39
        or byte == 44 or byte == 59 or byte == 93 or byte == 125
        or next_byte == 32 or next_byte == 9 or next_byte == 34 or next_byte == 39
        or next_byte == 40 or next_byte == 91 or next_byte == 123
  end
  local function ascii_safe_boundary(text, j)
    local byte = text:byte(j)
    local next_byte = text:byte(j + 1)
    return not ascii_ligature_sensitive_byte(byte) and not ascii_ligature_sensitive_byte(next_byte)
  end
  local function utf8_safe_chunk_end(text, first, last)
    last = math.min(#text, last)
    while last >= first do
      local next_byte = text:byte(last + 1)
      if not (next_byte and next_byte >= 128 and next_byte < 192) then return last end
      last = last - 1
    end
    last = first
    while last < #text do
      local next_byte = text:byte(last + 1)
      if not (next_byte and next_byte >= 128 and next_byte < 192) then break end
      last = last + 1
    end
    return last
  end

  local function ascii_preferred_chunk_end(text, first, last)
    if last >= #text then return #text end
    for j = last, first, -1 do
      if ascii_strong_boundary(text, j) then return j end
    end
    for j = last, first, -1 do
      if ascii_safe_boundary(text, j) then return j end
    end
    local forward_limit = math.min(#text - 1, first + max_pending_bytes * 4)
    for j = last + 1, forward_limit do
      if ascii_strong_boundary(text, j) then return j end
    end
    for j = last + 1, forward_limit do
      if ascii_safe_boundary(text, j) then return j end
    end
    return nil
  end
  local stop_drawing = false
  local token_start_col = 1
  for tidx = 1, tokens_count, 2 do
    local type = tokens[tidx]
    local raw_text = tokens[tidx + 1] or ""
    local raw_len = #raw_text
    local token_end_col = token_start_col + raw_len
    local token_draw_end_col = tidx == last_token and token_end_col - 1 or token_end_col
    if token_draw_end_col > draw_start_col and token_start_col <= draw_end_col then
      if stats then stats.tokens = stats.tokens + 1 end
      local slice_start_col = math.max(token_start_col, draw_start_col)
      local slice_end_col = math.min(token_draw_end_col - 1, draw_end_col)
      local text = slice_start_col <= slice_end_col
        and raw_text:sub(slice_start_col - token_start_col + 1, slice_end_col - token_start_col + 1)
        or ""
      local color = syntax[type] or normal_color
      local font = syntax_fonts[type] or default_font
      if font ~= default_font then font:set_tab_size(indent_size) end
      if text ~= "" then
        local text_chunkable = self.buffer.binary
          or (#text > max_pending_bytes * 4)
          or text:find("[\128-\255]") == nil
        if not text_chunkable then
        -- Avoid splitting complex/shaped scripts across draw calls; HarfBuzz
        -- needs the full run to preserve joining and ligatures. Pathological
        -- ASCII tokens and binary data can use bounded chunks.
        if pending_font ~= font or pending_color ~= color or (pending_len or 0) + #text > max_pending_bytes then
          if flush_pending_text() then break end
        end
        if not pending_font then
          pending_font, pending_color, pending_chunks, pending_len = font, color, {}, 0
        end
        pending_len = pending_len + #text
        if text:find("\t", 1, true) then pending_has_tabs = true end
        pending_chunks[#pending_chunks + 1] = text
      else
        if pending_font ~= font or pending_color ~= color then
          if flush_pending_text() then break end
        end
        local i = 1
        while i <= #text do
          if not pending_font then
            pending_font, pending_color, pending_chunks, pending_len = font, color, {}, 0
          end
          local available = max_pending_bytes - (pending_len or 0)
          if available <= 0 then
            if flush_pending_text() then stop_drawing = true; break end
            pending_font, pending_color, pending_chunks, pending_len = font, color, {}, 0
            available = max_pending_bytes
          end
          local j = ascii_preferred_chunk_end(text, i, math.min(#text, i + available - 1))
          if not j then
            -- A token made entirely of ligature-sensitive ASCII (for example
            -- a long run of 'f' or '=') has no shaping-safe split nearby.
            -- Do not draw the whole remainder as one batch: on very long
            -- unwrapped lines that can feed hundreds of KB through the
            -- renderer before right-edge culling gets a chance to stop.  Split
            -- at the pending chunk limit; preserving pathological ligatures is
            -- less important than keeping input responsive.
            j = math.min(#text, i + available - 1)
          end
          local next_byte = text:byte(j + 1)
          if next_byte and next_byte >= 128 then
            j = j - 1
          end
          local chunk = j >= i and text:sub(i, j) or ""
          if chunk == "" or chunk:find("[\128-\255]") then
            if flush_pending_text() then stop_drawing = true; break end
            local utf8_end = utf8_safe_chunk_end(text, i, i + available - 1)
            chunk = text:sub(i, utf8_end)
            pending_font, pending_color, pending_chunks, pending_len = font, color, {}, 0
            pending_len = #chunk
            if chunk:find("\t", 1, true) then pending_has_tabs = true end
            pending_chunks[#pending_chunks + 1] = chunk
            i = utf8_end + 1
            if flush_pending_text() then stop_drawing = true; break end
          else
            pending_len = pending_len + #chunk
            if chunk:find("\t", 1, true) then pending_has_tabs = true end
            pending_chunks[#pending_chunks + 1] = chunk
            i = j + 1
            if pending_len >= max_pending_bytes then
              if flush_pending_text() then stop_drawing = true; break end
            end
          end
        end
        end
      end
      if stop_drawing then break end
    end
    token_start_col = token_end_col
    if token_start_col > draw_end_col then break end
  end
  if not stop_drawing then flush_pending_text() end
  if stats then
    stats.token_loop_ms = stats.token_loop_ms + (system.get_time() - token_loop_start) * 1000
    stats.text_ms = stats.text_ms + (system.get_time() - text_start) * 1000
    stats.text_lines = stats.text_lines + 1
  end
  return self:get_line_height()
end


---Draw the caret at a position.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param line integer Line number (for overwrite mode char width)
---@param col integer Column number (for overwrite mode char width)
function TextView:draw_caret(x, y, line, col, caret_idx, color)
  color = color or style.caret
  if config.animated_caret then
    self.animated_caret_positions = self.animated_caret_positions or {}
    caret_idx = caret_idx or 1
    local pos = self.animated_caret_positions[caret_idx]
    if not pos then
      pos = { x = x, y = y }
      self.animated_caret_positions[caret_idx] = pos
    end

    local now = system.get_time()
    local last = pos.last_time or now
    pos.last_time = now
    -- Keep the first frame after an idle period from consuming the whole
    -- animation. If this cap is too large, a caret move after a short pause can
    -- almost snap to the target, making the animation feel like it vanished.
    local dt = math.min(now - last, 1 / 120)
    local dx = x - pos.x
    local dy = y - pos.y

    if math.abs(dy) > 0.1 then
      -- Line changes must not animate at all. Snap both axes so clicks or
      -- vertical navigation never glide diagonally from the old line.
      pos.x = x
      pos.y = y
    else
      local distance = math.abs(dx)
      local char_width = self:get_font():get_width("n")
      if distance <= char_width then
        -- Per-character caret movement should feel immediate; animation here
        -- reads as input lag rather than polish.
        pos.x = x
        pos.y = y
      else
        local distance_min = config.animated_caret_distance_min or 4
        local distance_max = config.animated_caret_distance_max or 160
        local distance_span = math.max(1, distance_max - distance_min)
        local distance_t = math.max(0, math.min(1, (distance - distance_min) / distance_span))
        local min_speed = config.animated_caret_min_speed or 35
        local max_speed = config.animated_caret_max_speed or 100
        local speed = min_speed + (max_speed - min_speed) * distance_t
        local linear_t = 1 - math.exp(-speed * dt)
        local t = 1 - math.pow(1 - linear_t, 3)
        pos.x = pos.x + dx * t
        pos.y = y
      end

      if math.abs(x - pos.x) > 0.1 then
        core.redraw = true
      else
        pos.x = x
      end
    end
    x, y = pos.x, pos.y
  end

  local stats = core.textview_frame_stats
  if stats then stats.caret_draw_calls = stats.caret_draw_calls + 1 end
  local line_end = self.wrapped_settings
    and linewrapping.has_wrapped_line_end_affinity(self, line, col)
    or false
  local lh = self:get_position_caret_height(line, col, line_end)
  local render_line = self:get_line_render(line)
  local _, position_row = self:get_position_line_render_row(line, col)
  if render_line and not position_row then
    local row_height = self:get_position_visual_row_height(line, col, line_end)
    local content_y_offset = line_render_content_geometry(
      render_line, row_height,
      position_is_first_visual_row(self, line, col, line_end)
    )
    y = y + content_y_offset
  end
  if self.buffer.overwrite then
    local w = self:get_font():get_width(self.buffer:get_char(line, col))
    renderer.draw_rect(x, y + lh, w, style.caret_width * 2, color)
  else
    renderer.draw_rect(x, y, style.caret_width, lh, color)
  end
end


function TextView:search_match_style(primary)
  if primary then
    return style.search_selection, style.search_selection_outline
  end
  return style.search_selection_secondary, style.search_selection_secondary_outline
end

---Iterate the screen rectangles occupied by a single-line Buffer range.
---Soft-wrapped ranges are split into one rectangle per Wrapped Visual Row.
---@param line integer
---@param col1 integer
---@param col2 integer
---@param origin_x? number Optional draw-line x origin
---@param origin_y? number Optional draw-line y origin
---@return function iterator
function TextView:iter_text_range_screen_segments(line, col1, col2, origin_x, origin_y)
  local text = self.buffer.lines[line] or ""
  col1 = common.clamp(math.floor(tonumber(col1) or 1), 1, #text + 1)
  col2 = common.clamp(math.floor(tonumber(col2) or col1), 1, #text + 1)
  if col2 < col1 then col1, col2 = col2, col1 end

  local base_x, base_y = self:get_line_screen_position(line)
  origin_x = origin_x or base_x
  origin_y = origin_y or base_y

  local render_line = self:get_line_render(line)
  local position_rows = render_line and render_line.position_rows
  if type(position_rows) == "table" and #position_rows > 0 then
    local index = 0
    return function()
      while true do
        index = index + 1
        local row = position_rows[index]
        if not row then return nil end
        local row_col1 = math.max(1, row.source_col1 or 1)
        local row_col2 = math.max(row_col1, row.source_col2 or row_col1)
        local segment_col1 = math.max(col1, row_col1)
        local segment_col2 = math.min(col2, row_col2)
        if segment_col2 > segment_col1 then
          local x1 = origin_x + self:get_line_render_col_x_offset(
            render_line, segment_col1, row
          )
          local x2 = origin_x + self:get_line_render_col_x_offset(
            render_line, segment_col2, row
          )
          return x1, origin_y + (row.y_offset or 0), x2,
            math.max(1, row.height or self:get_line_height()),
            segment_col1, segment_col2, index
        end
      end
    end
  end

  local row_count = self:get_visual_row_count_for_line(line)
  local first_visual_row = self:get_visual_row(line, 1, false)
  local first_row = math.max(
    1, self:get_visual_row(line, col1, false) - first_visual_row + 1
  )
  local last_row = math.min(
    row_count, self:get_visual_row(line, col2, true) - first_visual_row + 1
  )
  local row = first_row - 1
  return function()
    while true do
      row = row + 1
      if row > last_row then return nil end
      local row_col1, row_col2 = self:get_visual_row_bounds_for_line(line, row)
      if not row_col1 then return nil end
      if col2 > row_col1 and col1 < row_col2 then
        local segment_col1 = math.max(col1, row_col1)
        local segment_col2 = math.min(col2, row_col2)
        local screen_x1, screen_y = self:get_line_screen_position(
          line, segment_col1, false
        )
        local screen_x2 = self:get_line_screen_position(
          line, segment_col2, segment_col2 == row_col2
        )
        local x1 = origin_x + screen_x1 - base_x
        local x2 = origin_x + screen_x2 - base_x
        local y = origin_y + screen_y - base_y
        local caret_height = self:get_position_caret_height(
          line, segment_col1, false
        )
        if render_line then
          -- Specialized render lines can reserve visual-row space around
          -- their text (Markdown headings use a leading block gap). Keep
          -- range decorations on the same content row as the text draw.
          local row_height = self:get_visual_row_height(
            first_visual_row + row - 1
          )
          local content_y_offset, content_height = line_render_content_geometry(
            render_line, row_height, row == 1
          )
          y = y + content_y_offset
            + math.max(0, (content_height - caret_height) / 2)
        end
        return x1, y, x2, caret_height,
          segment_col1, segment_col2, row
      end
    end
  end
end

local function draw_render_line_under_selection_backgrounds(view, render_line, x, y, line)
  if not (render_line and render_line.under_selection_backgrounds) then return end
  local tx = x + (render_line.x_offset or 0)
  local row_height = render_line.layout_height
    or view:get_position_visual_row_height(line, 1)
  for _, fragment in ipairs(view:iter_line_render_fragments(render_line)) do
    local font = render_fragment_font(view, fragment)
    local width = fragment.width or (fragment.widget and fragment.widget.width)
      or font:get_width(fragment.text or "")
    local draw_x = fragment.layout_x ~= nil and x + fragment.layout_x or tx
    if fragment.background_under_selection and fragment.background then
      local background_y, background_height = y, font:get_height()
      if fragment.background_full_height then
        background_height = row_height
      else
        local content_y_offset, content_height = view:get_line_render_content_geometry(
          line, fragment.source_col1 or 1
        )
        if content_y_offset then
          background_y = y + content_y_offset
            + math.max(0, (content_height - font:get_height()) / 2)
        end
      end
      draw_render_fragment_background(
        fragment, draw_x, background_y, width, background_height, true
      )
    end
    tx = draw_x + width
  end
end

function TextView:draw_search_match_background(line, col1, col2, primary)
  local bg = self:search_match_style(primary)
  for x1, y, x2, h in self:iter_text_range_screen_segments(
    line, col1, col2
  ) do
    if x2 > x1 then renderer.draw_rect(x1, y, x2 - x1, h, bg) end
  end
end

function TextView:draw_search_match_outline(line, col1, col2, primary)
  local _, outline = self:search_match_style(primary)
  local t = math.max(1, common.round(SCALE))
  for x1, y, x2, h in self:iter_text_range_screen_segments(
    line, col1, col2
  ) do
    if x2 > x1 then
      renderer.draw_rect(x1, y, x2 - x1, t, outline)
      renderer.draw_rect(x1, y + h - t, x2 - x1, t, outline)
      renderer.draw_rect(x1, y, t, h, outline)
      renderer.draw_rect(x2 - t, y, t, h, outline)
    end
  end
end

---Prepare per-visible-line selection/highlight data for draw_line_body().
---This avoids scanning every selection once per visible line and merges
---overlapping same-color ranges into one rectangle.
---@param minline integer First visible line
---@param maxline integer Last visible line
function TextView:prepare_line_body_draw_cache(minline, maxline)
  local stats = core.textview_frame_stats
  local prepare_start = stats and system.get_time()
  local highlight_cache = {}
  local selection_cache = {}
  local search_match_cache = {}
  local gutter_selection_cache = {}
  local visible_caret_cache = {}
  local hcl = self:get_current_line_highlight_mode()

  local phase_start = stats and system.get_time()
  if hcl ~= false then
    for _, line1, col1, line2, col2 in self.buffer:get_selections(false) do
      if stats then stats.prepare_highlight_iters = stats.prepare_highlight_iters + 1 end
      local top_line = math.min(line1, line2)
      if top_line > maxline then break end
      if line1 >= minline and line1 <= maxline then
        if hcl == "no_selection" and ((line1 ~= line2) or (col1 ~= col2)) then
          highlight_cache[line1] = false
        elseif highlight_cache[line1] == nil then
          highlight_cache[line1] = true
        end
      end
    end
  end
  if stats then stats.prepare_highlight_ms = stats.prepare_highlight_ms + (system.get_time() - phase_start) * 1000 end

  phase_start = stats and system.get_time()
  local selections = self.buffer.selections
  for i = 1, #selections, 4 do
    if stats then stats.prepare_caret_scan_count = stats.prepare_caret_scan_count + 1 end
    local raw_line1, raw_col1 = selections[i], selections[i + 1]
    local raw_line2, raw_col2 = selections[i + 2], selections[i + 3]
    local top_line = math.min(raw_line1, raw_line2)
    if top_line > maxline then break end
    if raw_line1 >= minline and raw_line1 <= maxline then
      visible_caret_cache[#visible_caret_cache + 1] = { raw_line1, raw_col1, raw_line2, raw_col2 }
    end
  end
  if stats then
    stats.visible_carets = stats.visible_carets + #visible_caret_cache
    stats.prepare_caret_ms = stats.prepare_caret_ms + (system.get_time() - phase_start) * 1000
  end

  phase_start = stats and system.get_time()
  for _, line1, col1, line2, col2 in self.buffer:get_selections(true) do
    if stats then stats.prepare_selection_iters = stats.prepare_selection_iters + 1 end
    if line1 > maxline then break end
    if line2 >= minline then
      if stats then stats.visible_selection_ranges = stats.visible_selection_ranges + 1 end
      local from_line = math.max(line1, minline)
      local to_line = math.min(line2, maxline)
      for line = from_line, to_line do
        gutter_selection_cache[line] = true
        local text = self.buffer.lines[line]
        local c1 = line1 ~= line and 1 or col1
        local c2 = line2 ~= line and #text + 1 or col2
        if c1 ~= c2 then
          local is_search_selection = self.buffer:is_search_selection(line1, c1, line, c2)
          if is_search_selection then
            local search_list = search_match_cache[line]
            if not search_list then
              search_list = {}
              search_match_cache[line] = search_list
            end
            search_list[#search_list + 1] = { c1, c2, true }
          else
            local list = selection_cache[line]
            if not list then
              list = {}
              selection_cache[line] = list
            end
            list[#list + 1] = { c1, c2, style.selection, false }
            if stats then stats.selection_cache_ranges = stats.selection_cache_ranges + 1 end
          end
        end
      end
    end
  end
  if stats then stats.prepare_selection_ms = stats.prepare_selection_ms + (system.get_time() - phase_start) * 1000 end

  phase_start = stats and system.get_time()
  for line, list in pairs(selection_cache) do
    if stats then stats.selection_cache_lines = stats.selection_cache_lines + 1 end
    if #list > 1 then
      table.sort(list, function(a, b)
        if a[4] ~= b[4] then return not a[4] end
        if a[1] ~= b[1] then return a[1] < b[1] end
        return a[2] < b[2]
      end)
      local merged = {}
      for _, sel in ipairs(list) do
        local last = merged[#merged]
        if last and last[3] == sel[3] and sel[1] <= last[2] then
          if sel[2] > last[2] then last[2] = sel[2] end
        else
          merged[#merged + 1] = sel
        end
      end
      selection_cache[line] = merged
      if stats then stats.selection_cache_merged_ranges = stats.selection_cache_merged_ranges + #merged end
    elseif stats then
      stats.selection_cache_merged_ranges = stats.selection_cache_merged_ranges + #list
    end
  end
  if stats then
    stats.prepare_merge_ms = stats.prepare_merge_ms + (system.get_time() - phase_start) * 1000
    stats.prepare_ms = stats.prepare_ms + (system.get_time() - prepare_start) * 1000
  end

  self.__line_body_highlight_cache = highlight_cache
  self.__line_body_selection_cache = selection_cache
  self.__line_body_search_match_cache = search_match_cache
  self.__line_gutter_selection_cache = gutter_selection_cache
  self.__visible_caret_cache = visible_caret_cache
end

local function provider_call(view, entry, method, ...)
  local provider = entry.provider
  local fn = provider and provider[method]
  if not fn then return nil end
  local ok, res = pcall(fn, provider, ...)
  if not ok then
    core.log_quiet("TextView decoration provider %s.%s failed for %s: %s", tostring(entry.id), method, view.buffer:get_name(), tostring(res))
    return nil
  end
  return res
end

local function draw_decoration_line_backgrounds(view, line, x, y)
  local function draw_descriptor(descriptor, row_y, row_height, first, last)
    if type(descriptor) ~= "table" or not descriptor.color then return end
    local bx = x + (tonumber(descriptor.x_offset) or 0)
    local available = math.max(0, view.position.x + view.size.x - bx)
    local bw = math.max(0, math.min(
      tonumber(descriptor.width) or available,
      available - (tonumber(descriptor.right_inset) or 0)
    ))
    local by = row_y + (tonumber(descriptor.y_offset) or 0)
    local bh = math.max(0, row_height - (tonumber(descriptor.y_offset) or 0)
      - (tonumber(descriptor.bottom_inset) or 0))
    if bw <= 0 or bh <= 0 then return end
    local radius = math.max(0, math.min(
      tonumber(descriptor.radius) or 0, bw / 2, bh / 2
    ))
    if radius > 0 and (first or last) then
      renderer.draw_rounded_rect(bx, by, bw, bh, radius, descriptor.color)
      -- Join adjacent rows without leaving rounded notches inside the block.
      if first and not last then
        renderer.draw_rect(bx, by + bh / 2, bw, bh / 2, descriptor.color)
      elseif last and not first then
        renderer.draw_rect(bx, by, bw, bh / 2, descriptor.color)
      end
    else
      renderer.draw_rect(bx, by, bw, bh, descriptor.color)
    end
    local rail_width = math.max(0, tonumber(descriptor.rail_width) or 0)
    if rail_width > 0 and descriptor.rail_color then
      renderer.draw_rect(bx, by, math.min(rail_width, bw), bh, descriptor.rail_color)
    end
  end

  for _, entry in ipairs(view:decoration_provider_entries()) do
    local descriptor = provider_call(
      view, entry, "line_background_descriptor", view, line
    )
    if descriptor then
      if view.wrapped_settings and view.__wrapped_draw_first_idx then
        local first_idx = view.wrapped_line_to_idx and view.wrapped_line_to_idx[line]
        if first_idx then
          local final_idx = first_idx + view:get_visual_row_count_for_line(line) - 1
          for idx = view.__wrapped_draw_first_idx, view.__wrapped_draw_last_idx do
            local row_y, row_height = wrapped_row_geometry(view, y, first_idx, idx)
            draw_descriptor(
              descriptor, row_y, row_height,
              descriptor.first and idx == first_idx,
              descriptor.last and idx == final_idx
            )
          end
        end
      else
        draw_descriptor(
          descriptor, y, view:get_position_visual_row_height(line, 1),
          descriptor.first, descriptor.last
        )
      end
    end
    local color = provider_call(view, entry, "line_background", view, line)
    if color then
      if view.wrapped_settings and view.__wrapped_draw_first_idx then
        local first_idx = view.wrapped_line_to_idx and view.wrapped_line_to_idx[line]
        if first_idx then
          for idx = view.__wrapped_draw_first_idx, view.__wrapped_draw_last_idx do
            local row_y, row_height = wrapped_row_geometry(view, y, first_idx, idx)
            renderer.draw_rect(
              view.position.x, row_y, view.size.x, row_height, color
            )
          end
        end
      else
        renderer.draw_rect(
          view.position.x, y, view.size.x,
          view:get_position_visual_row_height(line, 1), color
        )
      end
    end
  end
end

local function draw_decoration_inline_ranges(view, line, x, y)
  local render_line = view:get_line_render(line)
  for _, entry in ipairs(view:decoration_provider_entries()) do
    local ranges = provider_call(view, entry, "inline_ranges", view, line)
    for _, range in ipairs(ranges or {}) do
      local col1 = math.max(1, math.floor(tonumber(range.col1 or range[1]) or 1))
      local col2 = math.max(col1, math.floor(tonumber(range.col2 or range[2]) or col1))
      local color = range.color or range[3]
      if color then
        if render_line and not view.wrapped_settings
        and not (type(render_line.position_rows) == "table"
          and #render_line.position_rows > 0)
        then
          local tx1 = view:get_col_x_offset(line, col1)
          local tx2 = view:get_col_x_offset(line, col2)
          local width = tx2 - tx1
          if width > 0 then
            local content_y_offset, content_height =
              view:get_line_render_content_geometry(line, col1)
            renderer.draw_rect(
              x + tx1, y + (content_y_offset or 0), width,
              content_height or view:get_position_visual_row_height(line, col1),
              color
            )
          end
        elseif render_line then
          for x1, row_y, x2, row_height in view:iter_text_range_screen_segments(
            line, col1, col2, x, y
          ) do
            if x2 > x1 then
              renderer.draw_rect(x1, row_y, x2 - x1, row_height, color)
            end
          end
        elseif view.wrapped_settings and view.__wrapped_draw_first_idx then
          local first_idx = view.wrapped_line_to_idx and view.wrapped_line_to_idx[line]
          if first_idx then
            for idx = view.__wrapped_draw_first_idx, view.__wrapped_draw_last_idx do
              local row_start, row_end = view:get_visual_row_bounds_for_line(line, idx - first_idx + 1)
              if row_start and row_end and col2 > row_start and col1 < row_end then
                local seg_col1 = math.max(col1, row_start)
                local seg_col2 = math.min(col2, row_end)
                local tx1 = view:get_col_x_offset(line, seg_col1, false)
                local tx2 = view:get_col_x_offset(line, seg_col2, seg_col2 == row_end)
                if tx2 > tx1 then
                  local row_y, row_height = wrapped_row_geometry(
                    view, y, first_idx, idx
                  )
                  renderer.draw_rect(
                    x + tx1, row_y, tx2 - tx1, row_height, color
                  )
                end
              end
            end
          end
        else
          local tx1 = view:get_col_x_offset(line, col1)
          local tx2 = view:get_col_x_offset(line, col2)
          local width = tx2 - tx1
          if width > 0 then
            renderer.draw_rect(
              x + tx1, y, width, view:get_position_visual_row_height(line, col1), color
            )
          end
        end
      end
    end
  end
end

function TextView:decoration_text_color(line)
  for _, entry in ipairs(self:decoration_provider_entries()) do
    local color = provider_call(self, entry, "text_color", self, line)
    if color then return color end
  end
end

---Draw a complete line including highlight and selections.
---@param line integer Line number
  ---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return integer height Line height
local function draw_line_render_full_cell(view, row, x, y, color)
  local x1 = x + (row.selection_x1 or row.hit_x1 or 0)
  local x2 = x + (row.selection_x2 or row.hit_x2 or x1)
  if x2 <= x1 then return false end
  local sy = y + (row.selection_y or 0)
  local sh = math.max(
    1, row.selection_height or row.height or view:get_line_height()
  )
  renderer.draw_rect(x1, sy, x2 - x1, sh, color)
  if row.selection_outline then
    local border = math.max(1, math.floor(SCALE))
    renderer.draw_rect(x1, sy, x2 - x1, border, row.selection_outline)
    renderer.draw_rect(
      x1, sy + math.max(0, sh - border), x2 - x1, border,
      row.selection_outline
    )
    renderer.draw_rect(x1, sy, border, sh, row.selection_outline)
    renderer.draw_rect(x2 - border, sy, border, sh, row.selection_outline)
  end
  return true
end

local function draw_line_render_position_row_range(
  view, render_line, col1, col2, x, y, color
)
  local rows = render_line and render_line.position_rows
  if type(rows) ~= "table" or #rows == 0 then return false end
  local drawn = false
  for _, row in ipairs(rows) do
    if row.selection_full_cell
    and col1 <= (row.cell_source_col1 or math.huge)
    and col2 >= (row.cell_source_col2 or -math.huge)
    then
      drawn = draw_line_render_full_cell(view, row, x, y, color) or drawn
      goto continue_position_row_selection
    end
    local row_col1 = math.max(1, row.source_col1 or 1)
    local row_col2 = math.max(row_col1, row.source_col2 or row_col1)
    local from = math.max(col1, row_col1)
    local to = math.min(col2, row_col2)
    if from < to then
      local x1 = x + view:get_line_render_col_x_offset(render_line, from, row)
      local x2 = x + view:get_line_render_col_x_offset(render_line, to, row)
      if x2 > x1 then
        renderer.draw_rect(
          x1, y + (row.y_offset or 0), x2 - x1,
          math.max(1, row.height or view:get_line_height()), color
        )
        drawn = true
      end
    end
    ::continue_position_row_selection::
  end
  return drawn
end

local function draw_line_render_source_range(
  view, line, render_line, col1, col2, x, y, color
)
  if type(render_line.position_rows) == "table" and #render_line.position_rows > 0 then
    return draw_line_render_position_row_range(
      view, render_line, col1, col2, x, y, color
    )
  end
  local drawn = false
  for x1, row_y, x2, row_height in view:iter_text_range_screen_segments(
    line, col1, col2, x, y
  ) do
    if x2 > x1 then
      renderer.draw_rect(x1, row_y, x2 - x1, row_height, color)
      drawn = true
    end
  end
  return drawn
end

local function draw_line_render_empty_cell_selections(
  view, line, render_line, x, y, color
)
  local rows = render_line and render_line.position_rows
  if type(rows) ~= "table" then return false end
  local carets = {}
  for _, caret_line, caret_col, anchor_line, anchor_col in
    view.buffer:get_selections(false)
  do
    if caret_line == line and anchor_line == line and caret_col == anchor_col then
      carets[caret_col] = true
    end
  end
  if not next(carets) then return false end
  local drawn = false
  for _, row in ipairs(rows) do
    if row.selection_empty_cell and carets[row.cell_source_col1] then
      drawn = draw_line_render_full_cell(view, row, x, y, color) or drawn
    end
  end
  return drawn
end

function TextView:draw_line_body(line, x, y)
  if not self.buffer.lines[line] then
    core.log_quiet(
      "TextView draw_line_body: skipped stale line for %s (line=%s buffer_lines=%d)",
      self.buffer:get_name(), tostring(line), #self.buffer.lines
    )
    if self.wrapped_settings then self.wrapped_buffer_line_count = nil end
    return line_packets.finish_line_body(
      self, line, x, y, self:get_line_height()
    )
  end

  if self.wrapped_settings then
    local wrapped_body_scope = perf_scope_begin("wrapped_line_body")
    local body_phase_scope = perf_scope_begin("geometry")
    local lh = self:get_line_height()
    local idx0, _, count = linewrapping.get_line_idx_col_count(self, line)
    local first_row, last_row = 1, count
    local metric_cache = self:get_visual_row_metric_cache()
    if self.size and self.size.y > 0 then
      local viewport_y1 = self.position.y
      local viewport_y2 = self.position.y + self.size.y
      if metric_cache then
        first_row, last_row = count + 1, 0
        local row0_y_offset = self:get_visual_row_y_offset(idx0)
        for row = 1, count do
          local idx = idx0 + row - 1
          local row_y = y + self:get_visual_row_y_offset(idx) - row0_y_offset
          local row_height = self:get_visual_row_height(idx)
          if row_y + row_height >= viewport_y1 and row_y <= viewport_y2 then
            first_row = math.min(first_row, row)
            last_row = math.max(last_row, row)
          end
        end
      else
        first_row = math.max(1, math.floor((viewport_y1 - y) / lh) + 1)
        last_row = math.min(count, math.floor((viewport_y2 - y) / lh) + 1)
      end
    end
    if last_row < first_row then
      if metric_cache then
        local height = 0
        for row = 1, count do
          height = height + self:get_visual_row_height(idx0 + row - 1)
        end
        perf_scope_end(body_phase_scope)
        perf_scope_end(wrapped_body_scope)
        return line_packets.finish_line_body(self, line, x, y, height)
      end
      perf_scope_end(body_phase_scope)
      perf_scope_end(wrapped_body_scope)
      return line_packets.finish_line_body(self, line, x, y, lh * count)
    end
    local visible_idx1 = idx0 + first_row - 1
    local visible_idx2 = idx0 + last_row - 1
    local old_visible_idx1 = self.__wrapped_draw_first_idx
    local old_visible_idx2 = self.__wrapped_draw_last_idx
    self.__wrapped_draw_first_idx = visible_idx1
    self.__wrapped_draw_last_idx = visible_idx2
    perf_scope_end(body_phase_scope)
    body_phase_scope = perf_scope_begin("backgrounds_and_selections")
    draw_decoration_line_backgrounds(self, line, x, y)
    local highlight_rows
    local hcl = self:get_current_line_highlight_mode()
    if hcl ~= false then
      for _, line1, col1, line2, col2 in self.buffer:get_selections(false) do
        if line1 == line and (hcl ~= "no_selection" or (line1 == line2 and col1 == col2)) then
          local line_end = linewrapping.has_wrapped_line_end_affinity(self, line, col1)
          local idx = linewrapping.get_line_idx_col_count(self, line, col1, line_end)
          if idx >= idx0 and idx < idx0 + count then
            highlight_rows = highlight_rows or {}
            highlight_rows[idx] = { col = col1, line_end = line_end }
          end
        end
      end
    end
    if highlight_rows then
      for i = visible_idx1, visible_idx2 do
        local position = highlight_rows[i]
        if position then
          local highlight_y, highlight_height =
            self:get_position_highlight_geometry(
              line, position.col, position.line_end
            )
          self:draw_line_highlight(
            x + self.scroll.x, highlight_y, highlight_height
          )
        end
      end
    end
    draw_render_line_under_selection_backgrounds(
      self, self:get_line_render(line), x, y, line
    )

    local search_matches
    local render_line = self:get_line_render(line)
    draw_line_render_empty_cell_selections(
      self, line, render_line, x, y, style.selection
    )
    for _, line1, col1, line2, col2 in self.buffer:get_selections(true) do
      if line >= line1 and line <= line2 then
        if line1 ~= line then col1 = 1 end
        if line2 ~= line then col2 = #self.buffer.lines[line] + 1 end
        if col1 ~= col2 then
          if self.buffer:is_search_selection(line1, col1, line, col2) then
            search_matches = search_matches or {}
            search_matches[#search_matches + 1] = { col1, col2, true }
          elseif render_line and render_line.position_rows then
            draw_line_render_position_row_range(
              self, render_line, col1, col2, x, y, style.selection
            )
          elseif render_line then
            draw_line_render_source_range(
              self, line, render_line, col1, col2, x, y, style.selection
            )
          else
            local idx1 = linewrapping.get_line_idx_col_count(self, line, col1)
            local idx2 = linewrapping.get_line_idx_col_count(self, line, col2)
            for i = math.max(idx1, visible_idx1), math.min(idx2, visible_idx2) do
              local x1, x2 = get_wrapped_segment_bounds(self, line, col1, col2, idx1, idx2, i)
              if x1 and x2 and x2 > x1 then
                local row_y, row_height = wrapped_row_geometry(self, y, idx0, i)
                renderer.draw_rect(
                  x + x1, row_y, x2 - x1, row_height, style.selection
                )
              end
            end
          end
        end
      end
    end
    for _, match in ipairs(search_matches or {}) do
      draw_wrapped_search_match(
        self, line, match[1], match[2], x, y, idx0,
        match[3], false, visible_idx1, visible_idx2
      )
    end
    draw_decoration_inline_ranges(self, line, x, y)
    perf_scope_end(body_phase_scope)

    body_phase_scope = perf_scope_begin("text")
    self:draw_soft_wrap_continuation_indicators(line, x, y)
    local line_height = self:draw_line_text(line, x, y)
    perf_scope_end(body_phase_scope)

    body_phase_scope = perf_scope_begin("post_text_overlays")
    for _, match in ipairs(search_matches or {}) do
      draw_wrapped_search_match(
        self, line, match[1], match[2], x, y, idx0,
        match[3], true, visible_idx1, visible_idx2
      )
    end

    local underline_module = TextView.__lsp_diagnostic_underlines_module or package.loaded["core.lsp.diagnostic_underlines"]
    if underline_module and underline_module.draw_line then
      local underline_scope = perf_scope_begin("diagnostic_underlines")
      underline_module.draw_line(self, line, x, y)
      perf_scope_end(underline_scope)
    end
    if visible_idx2 == idx0 + count - 1 then
      local hint_y = wrapped_row_geometry(self, y, idx0, idx0 + count - 1)
      self:draw_line_hint(line, x, hint_y)
    end

    self.__wrapped_draw_first_idx = old_visible_idx1
    self.__wrapped_draw_last_idx = old_visible_idx2
    perf_scope_end(body_phase_scope)
    perf_scope_end(wrapped_body_scope)
    return line_packets.finish_line_body(self, line, x, y, line_height)
  end

  draw_decoration_line_backgrounds(self, line, x, y)

  if self:line_has_current_line_highlight(line) then
    for _, line1, col1, line2, col2 in self.buffer:get_selections(false) do
      if line1 == line
      and (self:get_current_line_highlight_mode() ~= "no_selection"
        or (line1 == line2 and col1 == col2))
      then
        local highlight_y, highlight_height =
          self:get_position_highlight_geometry(line, col1, false)
        self:draw_line_highlight(
          x + self.scroll.x, highlight_y, highlight_height
        )
        break
      end
    end
  end
  draw_render_line_under_selection_backgrounds(
    self, self:get_line_render(line), x, y, line
  )

  -- draw selection if it overlaps this line
  local lh = self:get_position_visual_row_height(line, 1)
  local selection_cache = self.__line_body_selection_cache
  local render_line = self:get_line_render(line)
  draw_line_render_empty_cell_selections(
    self, line, render_line, x, y, style.selection
  )
  local fallback_search_matches
  local cached_selections = selection_cache and selection_cache[line]
  if cached_selections then
    for _, sel in ipairs(cached_selections) do
      if render_line and render_line.position_rows then
        draw_line_render_position_row_range(
          self, render_line, sel[1], sel[2], x, y, sel[3]
        )
      elseif render_line then
        draw_line_render_source_range(
          self, line, render_line, sel[1], sel[2], x, y, sel[3]
        )
      else
        local x1 = x + self:get_col_x_offset(line, sel[1])
        local x2 = x + self:get_col_x_offset(line, sel[2])
        if x1 ~= x2 then
          local stats = core.textview_frame_stats
          if stats then stats.selection_rect_calls = stats.selection_rect_calls + 1 end
          renderer.draw_rect(x1, y, x2 - x1, lh, sel[3])
        end
      end
    end
  elseif not selection_cache then
    for lidx, line1, col1, line2, col2 in self.buffer:get_selections(true) do
      if line1 > line then break end
      if line >= line1 and line <= line2 then
        local text = self.buffer.lines[line]
        if line1 ~= line then col1 = 1 end
        if line2 ~= line then col2 = #text + 1 end
        if self.buffer:is_search_selection(line1, col1, line, col2) then
          fallback_search_matches = fallback_search_matches or {}
          fallback_search_matches[#fallback_search_matches + 1] = { col1, col2, true }
        elseif render_line and render_line.position_rows then
          draw_line_render_position_row_range(
            self, render_line, col1, col2, x, y, style.selection
          )
        elseif render_line then
          draw_line_render_source_range(
            self, line, render_line, col1, col2, x, y, style.selection
          )
        else
          local x1 = x + self:get_col_x_offset(line, col1)
          local x2 = x + self:get_col_x_offset(line, col2)
          if x1 ~= x2 then
            local stats = core.textview_frame_stats
            if stats then stats.selection_rect_calls = stats.selection_rect_calls + 1 end
            renderer.draw_rect(x1, y, x2 - x1, lh, style.selection)
          end
        end
      end
    end
  end

  local search_match_cache = self.__line_body_search_match_cache
  local cached_search_matches = (search_match_cache and search_match_cache[line]) or fallback_search_matches
  if cached_search_matches then
    for _, match in ipairs(cached_search_matches) do
      self:draw_search_match_background(line, match[1], match[2], match[3])
    end
  end

  draw_decoration_inline_ranges(self, line, x, y)

  -- draw line's text
  local line_height = self:draw_line_text(line, x, y)

  if cached_search_matches then
    for _, match in ipairs(cached_search_matches) do
      self:draw_search_match_outline(line, match[1], match[2], match[3])
    end
  end

  local underline_module = TextView.__lsp_diagnostic_underlines_module
    or package.loaded["core.lsp.diagnostic_underlines"]
  if underline_module and underline_module.draw_line then
    local underline_scope = perf_scope_begin("diagnostic_underlines")
    underline_module.draw_line(self, line, x, y)
    perf_scope_end(underline_scope)
  end

  self:draw_line_hint(line, x, y)

  return line_packets.finish_line_body(self, line, x, y, line_height)
end


---Draw the gutter with line numbers.
---@param line integer Line number
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param width number Gutter width
---@return integer height Line height
function TextView:draw_line_gutter(line, x, y, width)
  local render_line = self:get_line_render(line)
  local uses_wrapped_rows = self.wrapped_settings
    and not (render_line and render_line.disable_wrapping)
  local first_visual_row = self:get_visual_row(line, 1, false)
  local row_height = uses_wrapped_rows
    and self:get_visual_row_height(first_visual_row)
    or self:get_position_visual_row_height(line, 1)
  local height = row_height
  local text_y, text_height = y, row_height
  if render_line then
    local content_y_offset, content_height = self:get_line_render_content_geometry(line, 1)
    if content_y_offset then
      text_y = y + content_y_offset
      text_height = content_height
    end
  end
  if self:line_number_visible_at(line) and text_height >= self:get_font():get_height() then
    local color = style.line_number
    local gutter_selection_cache = self.__line_gutter_selection_cache
    if gutter_selection_cache then
      if gutter_selection_cache[line] then color = style.line_number2 end
    else
      for _, line1, _, line2 in self.buffer:get_selections(true) do
        if line1 > line then break end
        if line >= line1 and line <= line2 then
          color = style.line_number2
          break
        end
      end
    end
    x = x + style.padding.x
    common.draw_text(self:get_font(), color, line, "right", x, text_y, width, text_height)
  end
  if uses_wrapped_rows then
    local row_count = linewrapping.get_wrapped_line_count(self, line)
    height = math.max(
      height,
      self:get_visual_row_y_offset(first_visual_row + row_count)
        - self:get_visual_row_y_offset(first_visual_row)
    )
  end
  return height
end


---Draw IME composition decoration (underline and selection).
---@param line1 integer Start line
---@param col1 integer Start column
---@param line2 integer End line
---@param col2 integer End column
function TextView:draw_ime_decoration(line1, col1, line2, col2)
  local line_size = math.max(1, common.round(SCALE))
  if line2 < line1 or line1 == line2 and col2 < col1 then
    line1, col1, line2, col2 = line2, col2, line1, col1
  end

  -- Draw IME underline
  for line = line1, line2 do
    local range_col1 = line == line1 and col1 or 1
    local range_col2 = line == line2 and col2 or #(self.buffer.lines[line] or "") + 1
    for x1, y, x2, row_height in self:iter_text_range_screen_segments(
      line, range_col1, range_col2
    ) do
      renderer.draw_rect(
        x1, y + row_height - line_size,
        x2 - x1, line_size, style.text
      )
    end
  end

  -- Draw IME selection
  local from = col1 + self.ime_selection.from
  local to = from + self.ime_selection.size
  if from ~= to then
    line_size = style.caret_width
    for x1, y, x2, row_height in self:iter_text_range_screen_segments(
      line1, from, to
    ) do
      renderer.draw_rect(
        x1, y + row_height - line_size,
        x2 - x1, line_size, style.caret
      )
    end
  end
  local caret_x, caret_y = self:get_line_screen_position(line1, from)
  self:draw_caret(caret_x, caret_y, line1, from)
end


---Draw overlay elements (carets, IME decoration).
---Called after main text to draw on top.
function TextView:draw_overlay()
  if self.wrapped_settings then
    linewrapping.draw_guide(self)
    return with_wrapped_caret_affinity(self, TextView.draw_overlay_unwrapped)
  end
  return self:draw_overlay_unwrapped()
end

function TextView:draw_overlay_unwrapped()
  local scope = perf_scope_begin("core_overlay")
  local stats = core.textview_frame_stats
  local overlay_start = stats and system.get_time()
  local minline, maxline = self:get_visible_line_range()
  local is_active = core.active_view == self
  if not is_active or not self:active_window_has_focus() then
    perf_scope_end(scope)
    return
  end

  -- draw caret if it overlaps this line
  local T = config.blink_period
  local blink_visible = config.disable_blink
    or not is_active
    or (core.blink_timer - core.blink_start) % T < T / 2
  local caret_color = is_active and style.caret or style.dim
  local visible_carets = self.__visible_caret_cache
  if visible_carets then
    for caret_idx, caret in ipairs(visible_carets) do
      local line1, col1, line2, col2 = caret[1], caret[2], caret[3], caret[4]
      if is_active and ime.editing then
        self:draw_ime_decoration(line1, col1, line2, col2)
      elseif blink_visible then
        local x, y = self:get_line_screen_position(line1, col1)
        self:draw_caret(x, y, line1, col1, caret_idx, caret_color)
      end
    end
  else
    local caret_idx = 0
    for _, line1, col1, line2, col2 in self.buffer:get_selections() do
      caret_idx = caret_idx + 1
      if line1 >= minline and line1 <= maxline then
        if is_active and ime.editing then
          self:draw_ime_decoration(line1, col1, line2, col2)
        elseif blink_visible then
          local x, y = self:get_line_screen_position(line1, col1)
          self:draw_caret(x, y, line1, col1, caret_idx, caret_color)
        end
      end
    end
  end
  if stats then stats.overlay_ms = stats.overlay_ms + (system.get_time() - overlay_start) * 1000 end
  perf_scope_end(scope)
end

function TextView:draw_folded()
  local draw_scope = perf_scope_begin("draw_folded")
  self:draw_background(style.background)
  local _, indent_size = self.buffer:get_indent_info()
  self:get_font():set_tab_size(indent_size)

  local minline, maxline = self:get_visible_line_range()
  self:prepare_line_body_draw_cache(minline, maxline)
  self:draw_current_line_underlay_highlights(minline, maxline)

  local x = self.position.x - self.scroll.x
  local gw, gpad = self:get_gutter_width()
  local gutter_w = gpad and gw - gpad or gw
  local function line_origin_y(entry)
    local first_row = self:get_visual_row(entry.line, 1, false)
    local visual_row = entry.visual_row
      or first_row + (entry.row_in_line or 1) - 1
    return entry.y - (
      self:get_visual_row_y_offset(visual_row)
      - self:get_visual_row_y_offset(first_row)
    )
  end
  local drawn_gutters = {}
  for entry in self:iter_visible_visual_rows() do
    if entry.type == "fold" then
      self:draw_fold_widget_gutter(
        entry.fold, self.position.x, entry.y, gutter_w, entry.height
      )
    elseif entry.type == "extra" or entry.type == "provider" then
      -- provider-owned visual row; no default gutter
    elseif not drawn_gutters[entry.line] then
      drawn_gutters[entry.line] = true
      local line_y = line_origin_y(entry)
      self:draw_line_gutter(entry.line, self.position.x, line_y, gutter_w)
    end
  end

  core.push_clip_rect(self.position.x + gw, self.position.y, math.max(0, self.size.x - gw), self.size.y)
  local drawn_bodies = {}
  for entry in self:iter_visible_visual_rows() do
    if entry.type == "fold" then
      self:draw_fold_widget_body(entry.fold, x + gw, entry.y, entry.height)
    elseif entry.type == "extra" or entry.type == "provider" then
      local row = entry.provider_row
      if entry.type == "provider" and row and row.draw then
        local ok, err = pcall(
          row.draw, self, row, x + gw, entry.y,
          math.max(0, self.size.x - gw), entry.height or self:get_line_height()
        )
        if not ok then core.log_quiet("TextView provider row draw failed for %s: %s", self.buffer:get_name(), tostring(err)) end
      end
    elseif not drawn_bodies[entry.line] then
      drawn_bodies[entry.line] = true
      local line_y = line_origin_y(entry)
      self:draw_line_body(entry.line, x + gw, line_y)
    end
  end
  self:draw_overlay()
  core.pop_clip_rect()

  self.__line_body_highlight_cache = nil
  self.__line_body_selection_cache = nil
  self.__line_body_search_match_cache = nil
  self.__line_gutter_selection_cache = nil
  self.__visible_caret_cache = nil

  self:draw_scrollbar()
  perf_scope_end(draw_scope)
end

local function table_key_count(values)
  local count = 0
  for _ in pairs(values or {}) do count = count + 1 end
  return count
end

local function log_wrapped_geometry_mismatch(view, reason, details)
  details = details or {}
  local cache = view.__visual_metric_cache
  local owner = view.__markdown_live_owner
  local revision = view.buffer.text_revision or 0
  local key = table.concat({
    reason, revision, view.__wrap_layout_generation or 0,
    details.line or "", details.first_idx or "", details.next_idx or "",
    details.drawn_height or "", details.expected_height or "",
  }, ":")
  if view.__wrapped_geometry_diagnostic_key == key then return end
  view.__wrapped_geometry_diagnostic_key = key

  local semantic_status, semantic_revision
  local markdown_model = package.loaded["core.markdown.model"]
  if markdown_model and markdown_model.peek then
    local instance = markdown_model.peek(view.buffer)
    semantic_status = instance and instance.status
    semantic_revision = instance and instance.published_revision
  end

  core.log_quiet(
    "TextView wrapped geometry mismatch reason=%s file=%s revision=%d line=%s next_line=%s "
      .. "idx=%s next_idx=%s y=%s next_y=%s drawn_height=%s expected_height=%s "
      .. "wrapped_rows=%s wrapped_generation=%s wrapped_revision=%s wrapped_lines=%s "
      .. "metric_rows=%s metric_generation=%s metric_revision=%s metric_dirty=%d "
      .. "scroll=%s scroll_to=%s markdown=%s semantic_status=%s semantic_revision=%s "
      .. "pending_from=%s pending_lines=%d",
    tostring(reason), view.buffer:get_name(), revision,
    tostring(details.line), tostring(details.next_line),
    tostring(details.first_idx), tostring(details.next_idx),
    tostring(details.y), tostring(details.next_y),
    tostring(details.drawn_height), tostring(details.expected_height),
    tostring(details.total_rows), tostring(view.__wrap_layout_generation),
    tostring(view.wrapped_text_revision), tostring(view.wrapped_buffer_line_count),
    tostring(cache and cache.row_count), tostring(view.__visual_metric_generation),
    tostring(cache and cache.text_revision),
    table_key_count(cache and cache.dirty_rows),
    tostring(view.scroll and view.scroll.y),
    tostring(view.scroll and view.scroll.to and view.scroll.to.y),
    tostring(owner ~= nil), tostring(semantic_status), tostring(semantic_revision),
    tostring(owner and owner.semantic_pending_line),
    table_key_count(owner and owner.pending_lines)
  )
end

function TextView:draw_wrapped()
  local draw_scope = perf_scope_begin("draw_wrapped", true)
  if self:has_composed_visual_rows() then
    local result = self:draw_folded()
    perf_scope_end(draw_scope)
    return result
  end
  if self.__markdown_live_owner and not self.__wrapped_geometry_diagnostics_armed then
    self.__wrapped_geometry_diagnostics_armed = true
    core.log_quiet(
      "TextView wrapped geometry diagnostics active for %s",
      self.buffer:get_name()
    )
  end
  local phase_scope = perf_scope_begin("background")
  self:draw_background(style.background)
  local _, indent_size = self.buffer:get_indent_info()
  self:get_font():set_tab_size(indent_size)
  perf_scope_end(phase_scope)

  phase_scope = perf_scope_begin("visible_geometry")
  local lh = self:get_line_height()
  local _, y1, _, y2 = self:get_content_bounds()
  local total = linewrapping.get_total_wrapped_lines(self)
  local cache = self:get_visual_row_metric_cache()
  local minidx = cache and self:get_visual_row_at_y(math.max(0, y1 - style.padding.y)) or math.max(1, math.floor((y1 - style.padding.y) / lh) + 1)
  local maxidx = cache and self:get_visual_row_at_y(math.max(0, y2 - style.padding.y)) or math.min(total, math.floor((y2 - style.padding.y) / lh) + 1)
  minidx = common.clamp(minidx, 1, total)
  maxidx = common.clamp(maxidx, 1, total)
  minidx, maxidx = overscan_metric_rows(cache, minidx, maxidx, total)
  if maxidx < minidx then
    perf_scope_end(phase_scope)
    phase_scope = perf_scope_begin("scrollbar")
    self:draw_scrollbar()
    perf_scope_end(phase_scope)
    perf_scope_end(draw_scope)
    return
  end

  local x, base_y = self:get_content_offset()
  local gw, gpad = self:get_gutter_width()
  local gutter_w = gpad and gw - gpad or gw
  local first_line = linewrapping.get_idx_line_col(self, minidx)
  local last_line = linewrapping.get_idx_line_col(self, maxidx)
  local previous_line, previous_idx
  for line = first_line, last_line do
    local first_idx = self.wrapped_line_to_idx[line]
    if type(first_idx) ~= "number" then
      log_wrapped_geometry_mismatch(self, "missing-line-map", {
        line = line,
        total_rows = total,
      })
    elseif previous_idx and first_idx <= previous_idx then
      log_wrapped_geometry_mismatch(self, "non-increasing-line-map", {
        line = previous_line,
        next_line = line,
        first_idx = previous_idx,
        next_idx = first_idx,
        y = self:get_visual_row_y_offset(previous_idx),
        next_y = self:get_visual_row_y_offset(first_idx),
        total_rows = total,
      })
    end
    if type(first_idx) == "number" then
      previous_line, previous_idx = line, first_idx
    end
  end
  perf_scope_end(phase_scope)

  phase_scope = perf_scope_begin("prepare")
  self:prepare_line_body_draw_cache(first_line, last_line)
  self:draw_current_line_underlay_highlights(first_line, last_line)
  perf_scope_end(phase_scope)

  phase_scope = perf_scope_begin("gutters")
  for line = first_line, last_line do
    local first_idx = self.wrapped_line_to_idx[line]
    if first_idx then
      local y = base_y + self:get_visual_row_y_offset(first_idx) + style.padding.y
      self:draw_line_gutter(line, self.position.x, y, gutter_w)
    end
  end
  perf_scope_end(phase_scope)

  phase_scope = perf_scope_begin("line_bodies", true)
  core.push_clip_rect(self.position.x + gw, self.position.y, math.max(0, self.size.x - gw), self.size.y)
  for line = first_line, last_line do
    local first_idx = self.wrapped_line_to_idx[line]
    if first_idx then
      local y = base_y + self:get_visual_row_y_offset(first_idx) + style.padding.y
      local drawn_height = self:draw_line_body(line, x + gw, y)
      local next_idx = self.wrapped_line_to_idx[line + 1]
      if not next_idx and line == #self.buffer.lines then next_idx = total + 1 end
      if next_idx then
        local line_y = self:get_visual_row_y_offset(first_idx)
        local next_y = self:get_visual_row_y_offset(next_idx)
        local expected_height = next_y - line_y
        if expected_height <= 0 then
          log_wrapped_geometry_mismatch(self, "non-positive-line-height", {
            line = line,
            next_line = line + 1,
            first_idx = first_idx,
            next_idx = next_idx,
            y = line_y,
            next_y = next_y,
            drawn_height = drawn_height,
            expected_height = expected_height,
            total_rows = total,
          })
        elseif type(drawn_height) == "number"
          and math.abs(drawn_height - expected_height) > 0.5
        then
          log_wrapped_geometry_mismatch(self, "draw-height-disagrees", {
            line = line,
            next_line = line + 1,
            first_idx = first_idx,
            next_idx = next_idx,
            y = line_y,
            next_y = next_y,
            drawn_height = drawn_height,
            expected_height = expected_height,
            total_rows = total,
          })
        end
      end
    end
  end
  perf_scope_end(phase_scope)
  phase_scope = perf_scope_begin("overlay")
  self:draw_overlay()
  perf_scope_end(phase_scope)
  core.pop_clip_rect()

  self.__line_body_highlight_cache = nil
  self.__line_body_selection_cache = nil
  self.__line_body_search_match_cache = nil
  self.__line_gutter_selection_cache = nil
  self.__visible_caret_cache = nil

  phase_scope = perf_scope_begin("scrollbar")
  self:draw_scrollbar()
  perf_scope_end(phase_scope)
  perf_scope_end(draw_scope)
end

---Draw the entire Text View.
---Renders background, gutters, text, selections, carets, and scrollbars.
local function draw_textview(self)
  if self.wrapped_settings then
    local buffer_lines = #self.buffer.lines
    local wrapped_last_line = self.wrapped_lines
      and #self.wrapped_lines >= 2
      and self.wrapped_lines[#self.wrapped_lines - 1]
      or nil
    local stale_line_count = self.wrapped_buffer_line_count ~= buffer_lines
    local stale_text = self.wrapped_text_revision ~= (self.buffer.text_revision or 0)
    local stale_mapping = type(wrapped_last_line) == "number" and wrapped_last_line > buffer_lines
    if stale_line_count or stale_text or stale_mapping then
      core.log_quiet(
        "TextView draw: rebuilding stale wrapped rows for %s (cached_lines=%s buffer_lines=%d cached_last_line=%s stale_text=%s)",
        self.buffer:get_name(), tostring(self.wrapped_buffer_line_count), buffer_lines,
        tostring(wrapped_last_line), tostring(stale_text)
      )
      -- A stale mapping can survive when external buffer replacement also
      -- overwrote the line-count metadata. Force update_wrap_cache() to perform
      -- a full reconstruction instead of accepting that metadata as current.
      if stale_mapping then self.wrapped_buffer_line_count = nil end
      self:update_wrap_cache()
    end
  end

  if self:has_composed_visual_rows() then
    if self.wrapped_settings then
      local centered = core.centered_editor
      if centered and centered.should_center and centered.should_center(self)
      and not self.__centered_editor_in_lane_geometry then
        self:draw_background(style.background)
        return centered.with_lane_geometry(self, function()
          return self:draw_folded()
        end)
      end
    end
    return self:draw_folded()
  end
  if self.wrapped_settings then
    local centered = core.centered_editor
    if centered and centered.should_center and centered.should_center(self)
    and not self.__centered_editor_in_lane_geometry then
      self:draw_background(style.background)
      return centered.with_lane_geometry(self, function()
        return self:draw_wrapped()
      end)
    end
    return self:draw_wrapped()
  end
  self:draw_background(style.background)
  local _, indent_size = self.buffer:get_indent_info()
  self:get_font():set_tab_size(indent_size)

  local minline, maxline = self:get_visible_line_range()
  local lh = self:get_line_height()

  local stats = core.textview_frame_stats
  if stats then stats.visible_lines = stats.visible_lines + math.max(0, maxline - minline + 1) end
  self:prepare_line_body_draw_cache(minline, maxline)
  self:draw_current_line_underlay_highlights(minline, maxline)

  local x, y = self:get_line_screen_position(minline)
  local gw, gpad = self:get_gutter_width()
  local gutter_start = stats and system.get_time()
  for i = minline, maxline do
    local _, line_y = self:get_line_screen_position(i)
    self:draw_line_gutter(i, self.position.x, line_y, gpad and gw - gpad or gw)
  end
  if stats then stats.gutter_ms = stats.gutter_ms + (system.get_time() - gutter_start) * 1000 end

  local pos = self.position
  x, y = self:get_line_screen_position(minline)
  -- the clip below ensure we don't write on the gutter region. On the
  -- right side it is redundant with the Node's clip.
  core.push_clip_rect(pos.x + gw, pos.y, self.size.x - gw, self.size.y)
  local body_start = stats and system.get_time()
  for i = minline, maxline do
    local line_x, line_y = self:get_line_screen_position(i)
    self:draw_line_body(i, line_x, line_y)
  end
  if stats then stats.body_ms = stats.body_ms + (system.get_time() - body_start) * 1000 end
  self:draw_overlay()
  core.pop_clip_rect()
  self.__line_body_highlight_cache = nil
  self.__line_body_selection_cache = nil
  self.__line_gutter_selection_cache = nil

  self:draw_scrollbar()
end

function TextView:draw()
  local file_open_draw = file_open_view_draw_begin(self)
  local stats = core.textview_frame_stats
  if not stats then
    local result = draw_textview(self)
    file_open_view_draw_end(file_open_draw)
    return result
  end
  local draw_scope = perf_scope_begin("textview_core", true)
  local draw_start = system.get_time()
  local result = draw_textview(self)
  stats.draw_ms = stats.draw_ms + (system.get_time() - draw_start) * 1000
  perf_scope_end(draw_scope)
  file_open_view_draw_end(file_open_draw)
  return result
end

local function bind_selection_method(name)
  local fn = TextView[name]
  TextView[name] = function(self, ...)
    return self:with_selection_state(fn, self, ...)
  end
end

Buffer.register_text_transaction_handler("textview-render-caches", function(buffer, transaction)
  if not (transaction and transaction.changed) then return end
  local line1, line2
  local line_structure_changed = false
  for _, range in ipairs(transaction.changed_ranges or {}) do
    local old_line1 = range.old_line1 or range.new_line1 or 1
    local old_line2 = range.old_line2 or old_line1
    local new_line1 = range.new_line1 or old_line1
    local new_line2 = range.new_line2 or new_line1
    line1 = math.min(line1 or old_line1, old_line1, new_line1)
    line2 = math.max(line2 or old_line2, old_line2, new_line2)
    if old_line2 - old_line1 ~= new_line2 - new_line1 then line_structure_changed = true end
  end
  for view in pairs(TextView.registry[buffer] or {}) do
    if view and view.buffer == buffer then
      view.__composed_visual_row_snapshot_kind = nil
      view.__composed_visual_row_snapshot_id = nil
      view.__composed_visual_row_snapshot_rows = nil
      line_packets.apply_transaction(view, transaction)
      local invalid_line1, invalid_line2 = line1, line2
      local provider_entries = view:line_render_provider_entries()
      local providers_handle_line_structure = line_structure_changed and #provider_entries > 0
      for _, entry in ipairs(provider_entries) do
        local fn = entry.provider and entry.provider.on_text_transaction
        if fn then
          local ok, provider_line1, provider_line2, handles_line_structure = pcall(
            fn, entry.provider, view, transaction, line1, line2
          )
          providers_handle_line_structure = providers_handle_line_structure
            and ok and handles_line_structure == true
          if ok and provider_line1 then
            invalid_line1 = math.min(invalid_line1 or provider_line1, provider_line1)
            invalid_line2 = math.max(invalid_line2 or provider_line2 or provider_line1, provider_line2 or provider_line1)
          elseif not ok then
            core.log_quiet(
              "TextView line render provider %s transaction hook failed for %s: %s",
              tostring(entry.id), buffer:get_name(), tostring(provider_line1)
            )
          end
        else
          providers_handle_line_structure = false
        end
      end
      if line_structure_changed and not providers_handle_line_structure and line1 then
        invalid_line2 = math.max(invalid_line2 or line1, #buffer.lines)
      end
      if view:has_line_render_providers() then
        -- Line wrapping observes the text transaction before render providers
        -- build their pending presentation. Remeasure after the provider hooks
        -- so wrapping never exposes breaks computed from an interim fallback.
        view:invalidate_line_render("text-change", invalid_line1, invalid_line2)
      end
      if view:has_visual_metric_providers() then
        view:invalidate_visual_metrics("text-change", invalid_line1, invalid_line2)
      end
    end
  end
end)

for _, name in ipairs {
  "on_mouse_moved",
  "on_mouse_pressed",
  "on_mouse_released",
  "on_text_input",
  "on_ime_text_editing",
  "update_ime_location",
  "update",
  "draw",
} do
  bind_selection_method(name)
end

return TextView
