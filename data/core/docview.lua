local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local keymap = require "core.keymap"
local translate = require "core.doc.translate"
local tokenizer = require "core.tokenizer"
local ime = require "core.ime"
local linewrapping = require "core.linewrapping"
local language_intelligence = require "core.language_intelligence"
local range_marker = require "core.range_marker"
local Doc = require "core.doc"
local View = require "core.view"

local CACHE_LINE_LEN = 500
local LINE_HINT_ELLIPSIS = "…"

local IME_VIEW = nil
local IME_STATE = {line1 = 0, col1 = 0, line2 = 0, col2 = 0, w = 0, h = 0}

---@class core.docview.position
---@field line integer
---@field col integer
---@field offset number

---@class core.docview.ime_selection
---@field from integer
---@field size integer

---View for editing documents with syntax highlighting and text editing.
---Extends View to provide text editing capabilities including selection,
---scrolling, IME support, and rendering with syntax highlighting.
---@class core.docview : core.view
---@overload fun(doc: core.doc):core.docview
---@field super core.view
---@field doc core.doc
---@field font string
---@field last_x_offset core.docview.position
---@field ime_selection core.docview.ime_selection
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
local DocView = View:extend()

function DocView:__tostring() return "DocView" end

DocView.context = "workspace"

function DocView:is_wrapping_enabled()
  return not not self.wrapping_enabled
end

function DocView:has_wrapping()
  return self.wrapped_settings ~= nil
end

DocView.is_wrapped = DocView.has_wrapping

function DocView:clear_wrap_cache()
  linewrapping.clear_wrap_cache(self)
end

function DocView:compute_wrap_width()
  return linewrapping.compute_wrap_width(self)
end

function DocView:update_wrap_cache()
  return linewrapping.update_docview_breaks(self)
end

function DocView:set_wrapping_enabled(enabled)
  self.wrapping_enabled = not not enabled
  if self.wrapping_enabled then
    if self.size and self.size.x > 0 then self:update_wrap_cache() end
  else
    self:clear_wrap_cache()
  end
end

function DocView:get_total_visual_lines()
  if self:has_composed_visual_rows() then return self:get_composed_visual_row_count() end
  return linewrapping.get_total_wrapped_lines(self)
end

function DocView:get_visual_row(line, col, line_end)
  if self:has_composed_visual_rows() then return self:get_composed_visual_row_for_position(line, col, line_end) end
  return linewrapping.get_line_idx_col_count(self, line, col, line_end)
end

function DocView:get_visual_row_line_col(idx)
  if self:has_composed_visual_rows() then
    local entry = self:get_visual_row_entry(idx)
    if entry and entry.type == "fold" then return entry.fold.line1, 1 end
    if entry and entry.wrapped_idx then return linewrapping.get_idx_line_col(self, entry.wrapped_idx) end
    return entry and entry.line or 1, 1
  end
  return linewrapping.get_idx_line_col(self, idx)
end

function DocView:get_visual_row_count_for_line(line)
  if self:has_collapsed_folds() then
    local hidden, fold = self:is_line_hidden_by_fold(line)
    if hidden then return 0 end
    if fold and fold.line1 == line then return 1 end
  end
  return linewrapping.get_wrapped_line_count(self, line)
end

function DocView:get_visual_row_bounds_for_line(line, row_idx)
  if self:has_collapsed_folds() then
    local hidden, fold = self:is_line_hidden_by_fold(line)
    if hidden then return nil, nil end
    if fold and fold.line1 == line then return 1, 1 end
  end
  if not self.wrapped_settings then return 1, #(self.doc.lines[line] or "") + 1 end
  local first_idx = self.wrapped_line_to_idx[line]
  if not first_idx then return nil, nil end
  local idx = first_idx + math.max(0, (row_idx or 1) - 1)
  local row_line, row_start_col = linewrapping.get_idx_line_col(self, idx)
  if row_line ~= line then return nil, nil end
  local next_line, next_col = linewrapping.get_idx_line_col(self, idx + 1)
  local row_end_col = next_line == line and next_col or (#self.doc.lines[line] + 1)
  return row_start_col, row_end_col
end

function DocView:iter_visible_wrap_rows_for_line(line, y)
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

DocView.registry = DocView.registry or setmetatable({}, { __mode = "k" })
DocView.fold_views_by_doc = DocView.fold_views_by_doc or setmetatable({}, { __mode = "k" })
DocView.mirror_owner = DocView.mirror_owner or setmetatable({}, { __mode = "k" })
DocView.owner_views = DocView.owner_views or DocView.session_views or setmetatable({}, { __mode = "v" })
DocView.session_views = DocView.owner_views -- deprecated compatibility alias

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
  local perf = package.loaded["core.perf"]
  if perf and perf.frame_add then perf.frame_add(key, amount or 1) end
end

local function perf_elapsed(key, start_time)
  if start_time then perf_frame_add(key, (system.get_time() - start_time) * 1000) end
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

local function has_relevant_syntax_fonts(doc)
  local syntax_name = tostring(doc.syntax and doc.syntax.name or ""):lower()
  local is_markdown = syntax_name:find("markdown", 1, true) ~= nil
  for name in pairs(style.syntax_fonts) do
    if is_markdown or not tostring(name):match("^markdown_") then
      return true
    end
  end
  return false
end

local function get_fast_ascii_monospace_x_offset(self, line, col, line_text, font)
  if col <= 1 then return 0 end
  if has_relevant_syntax_fonts(self.doc) or not font_looks_monospace(font) then return nil end

  local change_id = self.doc:get_change_id()
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

  perf_frame_add("docview_get_col_x_offset_fast_ascii_calls", 1)
  return (col - 1) * font:get_width(" ")
end

local function with_wrapped_caret_affinity(docview, fn, ...)
  local old = docview.__use_wrapped_caret_affinity
  docview.__use_wrapped_caret_affinity = true
  local results = { pcall(fn, docview, ...) }
  docview.__use_wrapped_caret_affinity = old
  if not results[1] then error(results[2], 0) end
  return table.unpack(results, 2)
end

local function apply_resolved_line_end_affinity(docview)
  linewrapping.apply_resolved_line_end_affinity(docview)
end

local function draw_wrapped_search_match_segment(view, x1, y, x2, h, primary, outline)
  if x2 <= x1 then return end
  local bg, border = view:search_match_style(primary)
  if not outline then
    renderer.draw_rect(x1, y, x2 - x1, h, bg)
    return
  end
  local t = math.max(1, SCALE)
  renderer.draw_rect(x1, y, x2 - x1, t, border)
  renderer.draw_rect(x1, y + h - t, x2 - x1, t, border)
  renderer.draw_rect(x1, y, t, h, border)
  renderer.draw_rect(x2 - t, y, t, h, border)
end

local function get_wrapped_segment_bounds(view, line, col1, col2, idx1, idx2, idx)
  local row_line, row_start_col = linewrapping.get_idx_line_col(view, idx)
  if row_line ~= line then return nil, nil end
  local next_line, next_start_col = linewrapping.get_idx_line_col(view, idx + 1)
  local row_end_col = next_line == line and next_start_col or (#view.doc.lines[line] + 1)
  local x1 = idx == idx1 and view:get_col_x_offset(line, col1, false) or view:get_col_x_offset(line, row_start_col, false)
  local x2 = idx == idx2 and view:get_col_x_offset(line, col2, false) or view:get_col_x_offset(line, row_end_col, true)
  return x1, x2
end

local function draw_wrapped_search_match(view, line, col1, col2, x, y, idx0, lh, primary, outline, visible_idx1, visible_idx2)
  local idx1 = linewrapping.get_line_idx_col_count(view, line, col1)
  local idx2 = linewrapping.get_line_idx_col_count(view, line, col2)
  local from_idx = math.max(idx1, visible_idx1 or idx1)
  local to_idx = math.min(idx2, visible_idx2 or idx2)
  for i = from_idx, to_idx do
    local x1, x2 = get_wrapped_segment_bounds(view, line, col1, col2, idx1, idx2, i)
    if x1 and x2 then
      draw_wrapped_search_match_segment(view, x + x1, y + (i - idx0) * lh, x + x2, lh, primary, outline)
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

local function normalize_selection_state(doc, state, force)
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
      line1, col1 = doc:sanitize_position(line1, col1)
      line2, col2 = doc:sanitize_position(line2, col2)
      normalized[#normalized + 1] = line1
      normalized[#normalized + 1] = col1
      normalized[#normalized + 1] = line2
      normalized[#normalized + 1] = col2
    end
  end
  if #normalized == 0 then
    local line, col = doc:sanitize_position(1, 1)
    normalized = { line, col, line, col }
  end
  state.selections = normalized
  state.normalized = true
  state.last_selection = common.clamp(math.floor(tonumber(state.last_selection) or 1), 1, selection_count(normalized))
  return state
end

local function ensure_selection_state(state, doc)
  if not state or type(state.selections) ~= "table" or #state.selections < 4 then
    return normalize_selection_state(doc, state, true)
  end
  state.last_selection = common.clamp(math.floor(tonumber(state.last_selection) or 1), 1, selection_count(state.selections))
  return state
end

local function get_mirror_owner_view(doc)
  local owner_id = DocView.mirror_owner[doc]
  local view = owner_id and DocView.owner_views[owner_id]
  if view and view.doc == doc and view.selection_state then
    local view_owner_id = view.selection_state.owner_id or view.selection_state.session_id
    if view_owner_id == owner_id then return view end
  end
end

local function register_view(view)
  local doc = view.doc
  local views = DocView.registry[doc]
  if not views then
    views = setmetatable({}, { __mode = "k" })
    DocView.registry[doc] = views
  end
  views[view] = true
  local owner_id = view.selection_state.owner_id or view.selection_state.session_id
  view.selection_state.owner_id = owner_id
  view.selection_state.session_id = owner_id -- deprecated compatibility alias
  DocView.owner_views[owner_id] = view
  if not get_mirror_owner_view(doc) then
    DocView.mirror_owner[doc] = owner_id
  end
end

function DocView.get_doc_mirror_owner_view(doc)
  return get_mirror_owner_view(doc)
end

function DocView.get_doc_mirror_owner_id(doc)
  local view = get_mirror_owner_view(doc)
  return view and (view.selection_state.owner_id or view.selection_state.session_id)
end

---@deprecated Use `DocView.get_doc_mirror_owner_id` instead.
function DocView.get_doc_mirror_owner_session_id(doc)
  core.deprecation_log("DocView.get_doc_mirror_owner_session_id")
  return DocView.get_doc_mirror_owner_id(doc)
end

function DocView.count_registered_docviews(doc)
  local count = 0
  local views = DocView.registry[doc]
  if views then
    for view in pairs(views) do
      if view.doc == doc then count = count + 1 end
    end
  end
  return count
end

function DocView:owns_doc_selection_mirror()
  return get_mirror_owner_view(self.doc) == self
end

function DocView:get_selection_state()
  local selections = self.selection_state and self.selection_state.selections
  local last_selection = self.selection_state and self.selection_state.last_selection or 1
  if self.doc.bound_selection_view == self then
    selections = self.doc.selections
    last_selection = self.doc.last_selection
  end
  local state = normalize_selection_state(self.doc, {
    selections = copy_array(selections),
    last_selection = last_selection,
    normalized = true,
  })
  return {
    selections = copy_array(state.selections),
    last_selection = state.last_selection,
  }
end

function DocView:set_selection_state(state)
  local old_state = self:get_selection_state()
  local owner_id = self.selection_state and (self.selection_state.owner_id or self.selection_state.session_id) or new_selection_owner_id()
  self.selection_state = normalize_selection_state(self.doc, {
    selections = copy_array(state and state.selections or state),
    last_selection = state and state.last_selection or 1,
    owner_id = owner_id,
  })
  self.selection_state.owner_id = owner_id
  self.selection_state.session_id = owner_id -- deprecated compatibility alias
  DocView.owner_views[owner_id] = self
  if self.doc.bound_selection_view == self then
    self.doc.selections = self.selection_state.selections
    self.doc.last_selection = self.selection_state.last_selection
  elseif not self.doc.bound_selection_view and self:owns_doc_selection_mirror() then
    self:apply_selection_state()
  end
  local new_state = self:get_selection_state()
  if self.notify_selection_listeners and not selection_states_equal(old_state, new_state) then
    self:notify_selection_listeners("set", old_state, new_state)
  end
end

function DocView:capture_selection_state(old_state)
  old_state = old_state or self:get_selection_state()
  local owner_id = self.selection_state and (self.selection_state.owner_id or self.selection_state.session_id) or new_selection_owner_id()
  if self.selection_state and self.doc.selections == self.selection_state.selections then
    self.selection_state.last_selection = self.doc.last_selection
    self.selection_state.owner_id = owner_id
    self.selection_state.session_id = owner_id -- deprecated compatibility alias
  else
    self.selection_state = normalize_selection_state(self.doc, {
      selections = copy_array(self.doc.selections),
      last_selection = self.doc.last_selection,
      owner_id = owner_id,
      normalized = true,
    })
    self.selection_state.owner_id = owner_id
    self.selection_state.session_id = owner_id -- deprecated compatibility alias
  end
  DocView.owner_views[owner_id] = self
  local new_state = self:get_selection_state()
  if self.notify_selection_listeners and not selection_states_equal(old_state, new_state) then
    self:notify_selection_listeners("capture", old_state, new_state)
  end
end

function DocView:apply_selection_state()
  normalize_selection_state(self.doc, self.selection_state)
  self.doc.selections = copy_array(self.selection_state.selections)
  self.doc.last_selection = self.selection_state.last_selection
end

function DocView:become_selection_mirror_owner()
  local owner_id = self.selection_state.owner_id or self.selection_state.session_id
  self.selection_state.owner_id = owner_id
  self.selection_state.session_id = owner_id -- deprecated compatibility alias
  DocView.mirror_owner[self.doc] = owner_id
  DocView.owner_views[owner_id] = self
  if not self.doc.bound_selection_view then
    self:apply_selection_state()
  end
end

function DocView.refresh_doc_selection_mirror(doc)
  if doc.bound_selection_view then return false end
  local view = get_mirror_owner_view(doc)
  if view then
    view:apply_selection_state()
    return true
  end
  return false
end

function DocView.sync_doc_mirror_owner_state(doc)
  if doc.bound_selection_view or doc.__selection_text_adjusting then return end
  local view = get_mirror_owner_view(doc)
  if view then view:capture_selection_state() end
end

function DocView.reset_registered_selection_states(doc)
  local views = DocView.registry[doc]
  if views then
    for view in pairs(views) do
      if view.doc == doc then
        view:set_selection_state({ selections = doc.selections, last_selection = doc.last_selection })
      end
    end
  end
  DocView.refresh_doc_selection_mirror(doc)
end

function DocView.sanitize_registered_selection_states(doc)
  local views = DocView.registry[doc]
  if views then
    for view in pairs(views) do
      if view.doc == doc and view.selection_state then
        normalize_selection_state(doc, view.selection_state, true)
      end
    end
  end
  DocView.refresh_doc_selection_mirror(doc)
end

function DocView.snapshot_registered_selection_states(doc)
  local snapshots = {}
  local views = DocView.registry[doc]
  if views then
    for view in pairs(views) do
      if view.doc == doc then
        snapshots[view] = view:get_selection_state()
      end
    end
  end
  return snapshots
end

function DocView.restore_registered_selection_states(doc, snapshots)
  for view, state in pairs(snapshots or {}) do
    if view.doc == doc then view:set_selection_state(state) end
  end
  DocView.sanitize_registered_selection_states(doc)
end

function DocView.adjust_registered_selection_states(doc, kind, active_view, ...)
  local views = DocView.registry[doc]
  if views then
    for view in pairs(views) do
      if view.doc == doc and view.selection_state
      and view ~= active_view
      and view.selection_state.selections ~= doc.selections then
        if kind == "insert" then
          doc:adjust_selection_state_for_insert(view.selection_state, ...)
        elseif kind == "remove" then
          doc:adjust_selection_state_for_remove(view.selection_state, ...)
        end
      end
    end
  end
  if not doc.bound_selection_view then
    DocView.refresh_doc_selection_mirror(doc)
  end
end

function DocView.adjust_registered_selection_states_for_batch(doc, active_view, mapper, transaction)
  local views = DocView.registry[doc]
  if views then
    for view in pairs(views) do
      if view.doc == doc and view.selection_state
      and view ~= active_view
      and view.selection_state.selections ~= doc.selections then
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
        normalize_selection_state(doc, view.selection_state, true)
      end
    end
  end
  if not doc.bound_selection_view then
    DocView.refresh_doc_selection_mirror(doc)
  end
end

function DocView:with_selection_state(fn, ...)
  local doc = self.doc
  if doc.bound_selection_view == self then
    return fn(...)
  end

  local old_self_selection_state = self:get_selection_state()
  local old_selections = doc.selections
  local old_last_selection = doc.last_selection
  local old_bound_view = doc.bound_selection_view
  local old_bound_owner_id = doc.bound_selection_owner_id or doc.bound_selection_session_id

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

  local stack = doc.__selection_binding_stack or {}
  doc.__selection_binding_stack = stack
  stack[#stack + 1] = {
    view = self,
    old_bound_view = old_bound_view,
    old_selections = old_selections,
    old_last_selection = old_last_selection,
  }

  self.selection_state = ensure_selection_state(self.selection_state, doc)
  if not self.selection_state.owner_id then
    self.selection_state.owner_id = self.selection_state.session_id or new_selection_owner_id()
  end
  self.selection_state.session_id = self.selection_state.owner_id -- deprecated compatibility alias
  DocView.owner_views[self.selection_state.owner_id] = self
  doc.bound_selection_view = self
  doc.bound_selection_owner_id = self.selection_state.owner_id
  doc.bound_selection_session_id = self.selection_state.owner_id -- deprecated compatibility alias
  doc.selections = self.selection_state.selections
  doc.last_selection = self.selection_state.last_selection

  local args = pack(...)
  local ok, res = xpcall(function()
    return pack(fn(table.unpack(args, 1, args.n)))
  end, debug.traceback)

  local capture_ok, capture_err = xpcall(function()
    self:capture_selection_state(old_self_selection_state)
  end, debug.traceback)

  stack[#stack] = nil
  if #stack == 0 then doc.__selection_binding_stack = nil end
  local restore_selections = old_selections
  local restore_last_selection = old_last_selection
  if old_bound_view and old_bound_view.selection_state then
    restore_selections = old_bound_view.selection_state.selections
    restore_last_selection = old_bound_view.selection_state.last_selection
  end
  doc.selections = restore_selections
  doc.last_selection = restore_last_selection
  doc.bound_selection_view = old_bound_view
  doc.bound_selection_owner_id = old_bound_owner_id
  doc.bound_selection_session_id = old_bound_owner_id

  local mirror_ok, mirror_err = true, nil
  if not old_bound_view then
    mirror_ok, mirror_err = xpcall(function()
      DocView.refresh_doc_selection_mirror(doc)
    end, debug.traceback)
  end

  if not ok then error(res, 0) end
  if not capture_ok then error(capture_err, 0) end
  if not mirror_ok then error(mirror_err, 0) end
  return table.unpack(res, 1, res.n)
end

---Helper to move cursor vertically while preserving horizontal offset.
---@param dv core.docview
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


DocView.translate = {
  ["previous_page"] = function(doc, line, col, dv)
    local min, max = dv:get_visible_line_range()
    return line - (max - min), 1
  end,

  ["next_page"] = function(doc, line, col, dv)
    if line == #doc.lines then
      return #doc.lines, #doc.lines[line]
    end
    local min, max = dv:get_visible_line_range()
    return line + (max - min), 1
  end,

  ["previous_line"] = function(doc, line, col, dv)
    if dv and dv.wrapped_settings then
      return linewrapping.wrapped_visual_line_position(dv, line, col, -1)
    end
    if line == 1 then
      return 1, 1
    end
    return move_to_line_offset(dv, line, col, -1)
  end,

  ["next_line"] = function(doc, line, col, dv)
    if dv and dv.wrapped_settings then
      return linewrapping.wrapped_visual_line_position(dv, line, col, 1)
    end
    if line == #doc.lines then
      return #doc.lines, math.huge
    end
    return move_to_line_offset(dv, line, col, 1)
  end,
}


---Constructor - initializes a document view.
---@param doc core.doc Document to display
function DocView:new(doc)
  DocView.super.new(self)
  self.cursor = "ibeam"
  self.scrollable = true
  self.doc = assert(doc)
  local owner_id = new_selection_owner_id()
  self.selection_state = normalize_selection_state(self.doc, {
    selections = copy_array(self.doc.selections),
    last_selection = self.doc.last_selection,
    owner_id = owner_id,
    session_id = owner_id, -- deprecated compatibility alias
    normalized = true,
  })
  register_view(self)
  self.doc.cache.col_x = {}
  self.doc.cache.line_width = {}
  self.doc.cache.ulen = {}
  self.font = "code_font"
  self.last_x_offset = {}
  self.ime_selection = { from = 0, size = 0 }
  self.ime_status = false
  self.hovering_gutter = false
  self.v_scrollbar:set_forced_status(config.force_scrollbar_status)
  self.h_scrollbar:set_forced_status(config.force_scrollbar_status)
  self.cache_font = self:get_font()
  self.cache_font_size = self.cache_font:get_size()
  local _, indent_size = self.doc:get_indent_info()
  self.cache_indent_size = indent_size
  self.fold_regions = {}
  self.fold_generation = 0
  self.__fold_next_id = 0
  self.visual_row_extensions = {}
  self.decoration_providers = {}
  self.poi_providers = {}
  self.selection_listeners = {}
  self.scroll_listeners = {}
  register_fold_view(self)
  linewrapping.register_docview(self)
  self:set_wrapping_enabled(config.plugins.linewrapping.enable_by_default)
end


function DocView:get_state()
  local selection_state = self:get_selection_state()
  return {
    filename = self.doc.filename,
    selection = copy_array(selection_state.selections),
    selection_state = selection_state,
    scroll = { x = self.scroll.to.x, y = self.scroll.to.y },
    crlf = self.doc.crlf,
    text = self.doc.new_file and self.doc:get_text(1, 1, math.huge, math.huge)
  }
end


function DocView.from_state(state)
  local file_context = require "core.file_context"
  local dv
  if not state.filename then
    -- document not associated to a file
    dv = DocView(core.open_doc())
  else
    -- we have a filename, try to read the file
    local ok, doc = pcall(core.open_doc, state.filename)
    if ok then
      dv = DocView(doc)
    end
  end
  if dv and dv.doc then
    file_context.mark_editor_view(dv)
    if dv.doc.new_file and state.text then
      dv.doc:insert(1, 1, state.text)
      dv.doc.crlf = state.crlf
    end
    if state.selection_state then
      dv:set_selection_state(state.selection_state)
    elseif state.selection then
      dv:set_selection_state({ selections = state.selection, last_selection = 1 })
    end
    dv.last_line1, dv.last_col1, dv.last_line2, dv.last_col2 = table.unpack(dv.selection_state.selections, 1, 4)
    dv.scroll.x, dv.scroll.to.x = state.scroll.x, state.scroll.x
    dv.scroll.y, dv.scroll.to.y = state.scroll.y, state.scroll.y
    dv.needs_initial_scroll_validation = true
  end
  return dv
end


---Attempt to close the view, prompting to save if document is dirty.
---Shows "Unsaved Changes" dialog if this is the last view of a dirty document.
---@param do_close function Callback to execute when close is confirmed
function DocView:try_close(do_close)
  local function unregister_and_close()
    self:clear_fold_regions("view-close")
    unregister_fold_view(self)
    linewrapping.unregister_docview(self)
    do_close()
  end
  if self.doc:is_dirty()
  and #core.get_views_referencing_doc(self.doc) == 1 then
    core.global_prompt_bar:enter("Unsaved Changes; Confirm Close", {
      submit = function(_, item)
        if item.text:match("^[cC]") then
          unregister_and_close()
        elseif item.text:match("^[sS]") then
          local ok, err = pcall(self.doc.save, self.doc)
          if ok then
            unregister_and_close()
          elseif not tostring(err):find("file changed on disk", 1, true) then
            core.error("Couldn't save file \"%s\": %s", self.doc.filename, err)
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
    unregister_and_close()
  end
end


---Get the display name for the tab (filename with * if dirty).
---@return string name Document name with asterisk if modified
function DocView:get_name()
  local post = self.doc:is_dirty() and "*" or ""
  local name = self.doc:get_name()
  return name:match("[^/%\\]*$") .. post
end


---Get the full filename path for display (with home directory encoded).
---@return string filename Full path or name with asterisk if modified
function DocView:get_filename()
  if self.doc.abs_filename then
    local post = self.doc:is_dirty() and "*" or ""
    return common.home_encode(self.doc.abs_filename) .. post
  end
  return self:get_name()
end


---Get the height reserved for the horizontal scrollbar, if it is visible.
---@return number height Reserved height in pixels
function DocView:get_horizontal_scrollbar_height()
  local _, _, _, h_scroll = self.h_scrollbar:get_track_rect()
  return math.max(0, h_scroll or 0)
end


---Get the vertical viewport height available for document rows.
---@return number height Viewport height in pixels
function DocView:get_vertical_viewport_height()
  return math.max(0, self.size.y - self:get_horizontal_scrollbar_height())
end


---Get the number of visual rows in the document scroll model.
---@return integer count Visual row count
function DocView:get_scrollable_line_count()
  if self:has_composed_visual_rows() then return self:get_composed_visual_row_count() end
  if self.wrapped_settings then return linewrapping.get_total_wrapped_lines(self) end
  return #self.doc.lines
end


local function normalize_scroll_context_lines()
  return math.max(0, math.floor(tonumber(config.scroll_context_lines) or 0))
end


---Get the normal caret scroll context that can fit above and below the caret.
---@return integer count Context line count
function DocView:get_visible_scroll_context_lines()
  local lh = self:get_line_height()
  if lh <= 0 then return 0 end
  local visible_span = math.max(0, math.floor((self:get_vertical_viewport_height() - style.padding.y) / lh))
  return math.min(normalize_scroll_context_lines(), math.floor(visible_span / 2))
end


---Get the bottom overscroll context used when scroll-past-end is enabled.
---Keep this aligned with normal caret context so end-of-file scrolling moves
---smoothly into the same visible band instead of pinning the caret near the top.
---@return integer count Context line count
function DocView:get_scroll_past_end_context_lines()
  return self:get_visible_scroll_context_lines()
end


---Get scrollable height for a document with the given visual row count.
---@param line_count integer Visual row count
---@return number height Total scrollable height in pixels
function DocView:get_scrollable_size_for_line_count(line_count)
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


---Get the total scrollable height of the document.
---@return number height Total height in pixels
function DocView:get_scrollable_size()
  return self:get_scrollable_size_for_line_count(self:get_scrollable_line_count())
end


local function get_unwrapped_line_width(self, line)
  local cache = self.doc.cache.line_width
  if not cache then
    cache = {}
    self.doc.cache.line_width = cache
  end

  local text = self.doc.lines[line] or ""
  local font = self:get_font()
  local _, indent_size = self.doc:get_indent_info()
  local font_size = font:get_size()
  local entry = cache[line]
  if entry
    and entry.text == text
    and entry.font == font
    and entry.font_size == font_size
    and entry.indent_size == indent_size
  then
    return entry.width
  end

  local width = self:get_col_x_offset(line, #text + 1)
  cache[line] = {
    text = text,
    font = font,
    font_size = font_size,
    indent_size = indent_size,
    width = width,
  }
  return width
end

local function cache_unwrapped_max_line(cache, doc, line, width)
  cache.line = line
  cache.line_text = doc.lines[line] or ""
  cache.width = width
  cache.line_count = #doc.lines
end

local function update_unwrapped_width_from_active_lines(self, cache)
  local function consider(line)
    if not line or line < 1 or line > #self.doc.lines then return end
    local width = get_unwrapped_line_width(self, line)
    if width > cache.width then
      cache_unwrapped_max_line(cache, self.doc, line, width)
    end
  end

  for _, line1, _, line2 in self.doc:get_selections() do
    consider(line1)
    consider(line2)
  end
end

local function get_max_unwrapped_line_width(self)
  local font = self:get_font()
  local _, indent_size = self.doc:get_indent_info()
  local font_size = font:get_size()
  local cache = self.__unwrapped_content_width_cache
  if cache
    and cache.font == font
    and cache.font_size == font_size
    and cache.indent_size == indent_size
    and cache.line_count == #self.doc.lines
    and cache.line
    and self.doc.lines[cache.line] == cache.line_text
  then
    update_unwrapped_width_from_active_lines(self, cache)
    return cache.width
  end

  cache = {
    font = font,
    font_size = font_size,
    indent_size = indent_size,
    width = 0,
    line_count = #self.doc.lines,
  }
  for line = 1, #self.doc.lines do
    local width = get_unwrapped_line_width(self, line)
    if width > cache.width then
      cache_unwrapped_max_line(cache, self.doc, line, width)
    end
  end
  self.__unwrapped_content_width_cache = cache
  return cache.width
end

---Get the scrollable width for unwrapped document text.
---@return number width Total horizontal scrollable width in pixels
function DocView:get_h_scrollable_size()
  if self.wrapping_enabled then return 0 end
  local gutter_width = self:get_gutter_width()
  local _, _, v_scroll_w = self.v_scrollbar:get_track_rect()
  local right_padding = math.max(style.padding.x, v_scroll_w or 0)
  local content_width = gutter_width + get_max_unwrapped_line_width(self) + right_padding
  return math.max(self.size.x, content_width)
end


---Get the font used for rendering text.
---@return renderer.font font The code font
function DocView:get_font()
  return style[self.font]
end


---Get the line height in pixels.
---@return integer height Line height including line spacing
function DocView:get_line_height()
  return math.floor(self:get_font():get_height() * config.line_height)
end


local MIN_LINE_NUMBER_GUTTER_DIGITS = 2

---Get the width reserved for line numbers in the gutter.
---@return number width Line number label width
function DocView:get_line_number_gutter_width()
  local digits = math.max(MIN_LINE_NUMBER_GUTTER_DIGITS, #tostring(#self.doc.lines))
  return self:get_font():get_width(string.rep("0", digits))
end

---Get the gutter width (line numbers area).
---@return number width Total gutter width
---@return number padding Padding within gutter
function DocView:get_gutter_width()
  local padding = style.padding.x * 2
  if config.show_line_numbers then
    return self:get_line_number_gutter_width() + padding, padding
  end
  return style.padding.x, padding
end

local function compact_fold_views(doc)
  local views = DocView.fold_views_by_doc[doc]
  if not views then return nil end
  local compacted = setmetatable({}, { __mode = "v" })
  for _, view in pairs(views) do
    if view and view.doc == doc then compacted[#compacted + 1] = view end
  end
  DocView.fold_views_by_doc[doc] = #compacted > 0 and compacted or nil
  return DocView.fold_views_by_doc[doc]
end

register_fold_view = function(view)
  local doc = view and view.doc
  if not doc then return end
  local views = compact_fold_views(doc)
  if not views then
    views = setmetatable({}, { __mode = "v" })
    DocView.fold_views_by_doc[doc] = views
  end
  for _, existing in pairs(views) do
    if existing == view then return end
  end
  views[#views + 1] = view
end

unregister_fold_view = function(view)
  local doc = view and view.doc
  local views = doc and DocView.fold_views_by_doc[doc]
  if not views then return end
  local compacted = setmetatable({}, { __mode = "v" })
  for _, existing in pairs(views) do
    if existing and existing ~= view and existing.doc == doc then compacted[#compacted + 1] = existing end
  end
  DocView.fold_views_by_doc[doc] = #compacted > 0 and compacted or nil
end

local function clear_fold_views_for_doc(doc, reason)
  local views = compact_fold_views(doc)
  if not views then return end
  for _, view in ipairs(views) do
    if view and view.clear_fold_regions then view:clear_fold_regions(reason or "doc-close") end
    unregister_fold_view(view)
  end
end

if Doc and not Doc.__docview_folding_close_patched then
  Doc.__docview_folding_close_patched = true
  local old_on_close = Doc.on_close
  function Doc:on_close(...)
    clear_fold_views_for_doc(self, "doc-close")
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

function DocView:add_decoration_provider(id, provider, opts)
  assert(type(id) == "string" and id ~= "", "decoration provider id must be a non-empty string")
  assert(type(provider) == "table", "decoration provider must be a table")
  opts = opts or {}
  self.decoration_providers = self.decoration_providers or {}
  self.decoration_providers[id] = { id = id, provider = provider, priority = opts.priority or provider.priority or 0 }
end

function DocView:remove_decoration_provider(id)
  if not self.decoration_providers or not self.decoration_providers[id] then return false end
  self.decoration_providers[id] = nil
  return true
end

function DocView:decoration_provider_entries()
  return sorted_provider_entries(self.decoration_providers)
end

function DocView:add_poi_provider(id, provider, opts)
  assert(type(id) == "string" and id ~= "", "POI provider id must be a non-empty string")
  assert(type(provider) == "table", "POI provider must be a table")
  opts = opts or {}
  self.poi_providers = self.poi_providers or {}
  self.poi_providers[id] = { id = id, provider = provider, priority = opts.priority or provider.priority or 0 }
end

function DocView:remove_poi_provider(id)
  if not self.poi_providers or not self.poi_providers[id] then return false end
  self.poi_providers[id] = nil
  return true
end

function DocView:get_points_of_interest(opts)
  local points = {}
  for _, entry in ipairs(sorted_provider_entries(self.poi_providers)) do
    local provider = entry.provider
    local fn = provider.points_of_interest or provider.get_points_of_interest
    if fn then
      local ok, res = pcall(fn, provider, self, opts or {})
      if ok and res then
        for _, point in ipairs(res) do points[#points + 1] = point end
      elseif not ok then
        core.log_quiet("DocView POI provider %s failed for %s: %s", tostring(entry.id), self.doc:get_name(), tostring(res))
      end
    end
  end
  return points
end

function DocView:add_selection_listener(id, fn)
  assert(type(id) == "string" and id ~= "", "selection listener id must be a non-empty string")
  assert(type(fn) == "function", "selection listener must be a function")
  self.selection_listeners = self.selection_listeners or {}
  self.selection_listeners[id] = fn
end

function DocView:remove_selection_listener(id)
  if not self.selection_listeners or not self.selection_listeners[id] then return false end
  self.selection_listeners[id] = nil
  return true
end

function DocView:notify_selection_listeners(reason, old_state, new_state)
  for id, fn in pairs(self.selection_listeners or {}) do
    local ok, err = pcall(fn, self, new_state or self:get_selection_state(), old_state, reason)
    if not ok then core.log_quiet("DocView selection listener %s failed for %s: %s", tostring(id), self.doc:get_name(), tostring(err)) end
  end
end

function DocView:add_scroll_listener(id, fn)
  assert(type(id) == "string" and id ~= "", "scroll listener id must be a non-empty string")
  assert(type(fn) == "function", "scroll listener must be a function")
  self.scroll_listeners = self.scroll_listeners or {}
  self.scroll_listeners[id] = fn
end

function DocView:remove_scroll_listener(id)
  if not self.scroll_listeners or not self.scroll_listeners[id] then return false end
  self.scroll_listeners[id] = nil
  return true
end

function DocView:notify_scroll_listeners(reason)
  for id, fn in pairs(self.scroll_listeners or {}) do
    local ok, err = pcall(fn, self, reason)
    if not ok then core.log_quiet("DocView scroll listener %s failed for %s: %s", tostring(id), self.doc:get_name(), tostring(err)) end
  end
end

function DocView:set_visual_row_extension(id, extension)
  assert(type(id) == "string" and id ~= "", "visual row extension id must be a non-empty string")
  self.visual_row_extensions = self.visual_row_extensions or {}
  self.visual_row_extensions[id] = extension
  self:bump_fold_generation("visual-row-extension")
end

function DocView:clear_visual_row_extension(id)
  if not self.visual_row_extensions or not self.visual_row_extensions[id] then return false end
  self.visual_row_extensions[id] = nil
  self:bump_fold_generation("visual-row-extension-clear")
  return true
end

function DocView:has_extra_visual_rows()
  for _, extension in pairs(self.visual_row_extensions or {}) do
    if extension then return true end
  end
  return false
end

function DocView:has_composed_visual_rows()
  return self:has_collapsed_folds() or self:has_extra_visual_rows()
end

function DocView:get_extra_visual_rows_before_line(line)
  local total = 0
  for _, extension in pairs(self.visual_row_extensions or {}) do
    local before = extension.before
    if type(before) == "function" then
      total = total + math.max(0, math.floor(tonumber(before(line, self)) or 0))
    elseif before then
      total = total + math.max(0, math.floor(tonumber(before[line]) or 0))
    end
  end
  return total
end

function DocView:get_extra_visual_rows_after_line(line)
  local total = 0
  for _, extension in pairs(self.visual_row_extensions or {}) do
    local after = extension.after
    if type(after) == "function" then
      total = total + math.max(0, math.floor(tonumber(after(line, self)) or 0))
    elseif after then
      total = total + math.max(0, math.floor(tonumber(after[line]) or 0))
    end
  end
  return total
end

local function normalize_fold_lines(doc, line1, line2)
  line1 = common.clamp(math.floor(tonumber(line1) or 1), 1, #doc.lines)
  line2 = common.clamp(math.floor(tonumber(line2) or line1), 1, #doc.lines)
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

local function fold_preview_text(doc, fold)
  if not doc or not fold then return nil end
  local line1 = fold.line1 or 1
  local line2 = fold.line2 or line1
  local col1 = fold.col1 or 1
  local col2 = fold.col2 or (#(doc.lines[line2] or "") + 1)
  local ok, text = pcall(doc.get_text, doc, line1, col1, line2, col2)
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

local function fold_placeholder(doc, fold)
  if type(fold.placeholder) == "function" then
    local ok, text = pcall(fold.placeholder, fold)
    if ok and text then return tostring(text) end
  elseif fold.placeholder then
    return tostring(fold.placeholder)
  end
  local base = default_fold_placeholder(fold)
  local preview = fold_preview_text(doc, fold)
  return preview and (preview .. "  " .. base) or base
end

function DocView:refresh_fold_region(fold)
  if not fold or not fold.marker or not fold.marker:is_valid() then return false end
  local range = fold.marker:range()
  if not range then return false end
  fold.line1, fold.col1, fold.line2, fold.col2 = range.line1, range.col1, range.line2, range.col2
  fold.line1, fold.line2 = normalize_fold_lines(self.doc, fold.line1, fold.line2)
  fold.hidden_count = fold_hidden_count(fold)
  return true
end

function DocView:bump_fold_generation(reason)
  self.fold_generation = (self.fold_generation or 0) + 1
  self.__fold_layout_cache = nil
  core.redraw = true
  if reason and core.log_quiet then
    core.log_quiet("DocView fold generation %d for %s: %s", self.fold_generation, self.doc:get_name(), tostring(reason))
  end
end

function DocView:has_collapsed_folds()
  for _, fold in ipairs(self.fold_regions or {}) do
    if fold.collapsed and fold.marker and fold.marker:is_valid() then return true end
  end
  return false
end

function DocView:get_collapsed_folds()
  local folds = {}
  for _, fold in ipairs(self.fold_regions or {}) do
    if fold.collapsed and self:refresh_fold_region(fold) then folds[#folds + 1] = fold end
  end
  table.sort(folds, function(a, b)
    if a.line1 == b.line1 then return a.line2 < b.line2 end
    return a.line1 < b.line1
  end)
  return folds
end

function DocView:get_collapsed_fold_at_line(line)
  for _, fold in ipairs(self:get_collapsed_folds()) do
    if line >= fold.line1 and line <= fold.line2 then return fold end
  end
end

function DocView:is_line_hidden_by_fold(line)
  local fold = self:get_collapsed_fold_at_line(line)
  return fold and line > fold.line1, fold
end

function DocView:fold_aware_line_move(line, direction)
  local target = common.clamp(line + direction, 1, #self.doc.lines)
  local fold = self:get_collapsed_fold_at_line(target)
  if fold and target > fold.line1 then
    if direction > 0 then
      target = fold.line2 < #self.doc.lines and fold.line2 + 1 or fold.line1
    else
      target = fold.line1
    end
  end
  return target
end

function DocView:folded_visual_line_position(line, col, direction)
  line = line or 1
  col = col or 1
  local line_end = self.wrapped_settings and linewrapping.has_wrapped_line_end_affinity(self, line, col) or false
  local current_row = self:get_folded_visual_row_for_position(line, col, line_end)
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
  local target_row = common.clamp(current_row + direction, 1, self:get_folded_visual_row_count())
  local entry = self:get_visual_row_entry(target_row)
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
      target_col = common.clamp(target_col or col or 1, 1, #(self.doc.lines[target_line] or ""))
      last_x_offset.offset = x
      last_x_offset.line = target_line
      last_x_offset.col = target_col
      last_x_offset.line_end = target_line_end
      return target_line, target_col, target_line_end
    end
    return entry.line, common.clamp(col, 1, #(self.doc.lines[entry.line] or "")), false
  end
  return line, col, false
end

function DocView:add_fold_region(opts)
  opts = opts or {}
  local line1, line2 = normalize_fold_lines(self.doc, opts.line1 or opts[1], opts.line2 or opts[2])
  if line2 <= line1 then return nil, "fold region must span multiple lines" end
  local contained_folds = {}
  for _, fold in ipairs(self:get_collapsed_folds()) do
    if line1 <= fold.line1 and line2 >= fold.line2 then
      contained_folds[#contained_folds + 1] = fold
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
  local marker = range_marker.new(self.doc, {
    line1 = line1,
    col1 = opts.col1 or 1,
    line2 = line2,
    col2 = opts.col2 or (#self.doc.lines[line2] + 1),
    kind = "docview-fold",
    data = { view = self, id = id },
    invalidate_on_edit_overlap = true,
    greedy_left = false,
    greedy_right = false,
    on_change = function(marker, reason)
      if fold and reason ~= "new" then
        if not marker:is_valid() then
          fold.collapsed = false
        else
          self:refresh_fold_region(fold)
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
    col2 = opts.col2 or (#self.doc.lines[line2] + 1),
    collapsed = opts.collapsed ~= false,
    placeholder = opts.placeholder,
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
  return fold
end

function DocView:remove_fold_region(id_or_fold, reason)
  for i = #(self.fold_regions or {}), 1, -1 do
    local fold = self.fold_regions[i]
    if fold == id_or_fold or fold.id == id_or_fold then
      range_marker.remove(fold.marker)
      table.remove(self.fold_regions, i)
      self:bump_fold_generation(reason or "remove")
      return true
    end
  end
  return false
end

function DocView:clear_fold_regions(reason)
  if not self.fold_regions or #self.fold_regions == 0 then return end
  for _, fold in ipairs(self.fold_regions) do range_marker.remove(fold.marker) end
  self.fold_regions = {}
  self:bump_fold_generation(reason or "clear")
end

function DocView:expand_fold_region(id_or_fold, reason)
  local fold = type(id_or_fold) == "table" and id_or_fold or nil
  if not fold then
    for _, candidate in ipairs(self.fold_regions or {}) do
      if candidate.id == id_or_fold then fold = candidate; break end
    end
  end
  if not fold or not fold.collapsed then return false end
  fold.collapsed = false
  self:bump_fold_generation(reason or "expand")
  return true
end

function DocView:collapse_fold_region(id_or_fold, reason)
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
        contained_folds[#contained_folds + 1] = other
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
  return true
end

function DocView:run_fold_transaction(fn)
  local old_depth = self.__fold_transaction_depth or 0
  self.__fold_transaction_depth = old_depth + 1
  local ok, a, b, c = pcall(fn)
  self.__fold_transaction_depth = old_depth
  self:bump_fold_generation("transaction")
  if not ok then error(a) end
  return a, b, c
end

function DocView:get_line_visual_row_count(line)
  if self.wrapped_settings then return linewrapping.get_wrapped_line_count(self, line) end
  return 1
end

function DocView:get_folded_visual_row_count()
  local count, line = 0, 1
  local folds = self:get_collapsed_folds()
  local fidx = 1
  while line <= #self.doc.lines do
    local fold = folds[fidx]
    if fold and line == fold.line1 then
      count = count + 1
      line = fold.line2 + 1
      fidx = fidx + 1
    else
      count = count + self:get_line_visual_row_count(line)
      line = line + 1
    end
  end
  return math.max(1, count)
end

function DocView:get_folded_visual_row_for_position(line, col, line_end)
  line = common.clamp(line or 1, 1, #self.doc.lines)
  local row, current = 1, 1
  local folds = self:get_collapsed_folds()
  local fidx = 1
  while current <= #self.doc.lines do
    local fold = folds[fidx]
    if fold and current == fold.line1 then
      if line >= fold.line1 and line <= fold.line2 then return row end
      row = row + 1
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

function DocView:get_composed_visual_row_count()
  local last_line = math.max(1, #self.doc.lines)
  return self:get_folded_visual_row_count()
    + self:get_extra_visual_rows_before_line(last_line)
    + self:get_extra_visual_rows_after_line(last_line)
end

function DocView:get_composed_visual_row_for_position(line, col, line_end)
  line = common.clamp(line or 1, 1, #self.doc.lines)
  return self:get_folded_visual_row_for_position(line, col, line_end)
    + self:get_extra_visual_rows_before_line(line)
end

function DocView:get_visual_row_entry(target_row)
  target_row = math.max(1, math.floor(target_row or 1))
  local row, line = 1, 1
  local folds = self:get_collapsed_folds()
  local fidx = 1
  local previous_extra_before = 0
  while line <= #self.doc.lines do
    local extra_before = self:get_extra_visual_rows_before_line(line)
    local extra_delta = math.max(0, extra_before - previous_extra_before)
    if target_row >= row and target_row < row + extra_delta then
      return { type = "extra", line = line, placement = "before", row = row, row_in_extra = target_row - row + 1 }
    end
    row = row + extra_delta
    previous_extra_before = extra_before

    local fold = folds[fidx]
    if fold and line == fold.line1 then
      if row == target_row then return { type = "fold", fold = fold, line = fold.line1, row = row } end
      row = row + 1
      line = fold.line2 + 1
      fidx = fidx + 1
    else
      local count = self:get_line_visual_row_count(line)
      if target_row >= row and target_row < row + count then
        local wrapped_idx
        if self.wrapped_settings then
          wrapped_idx = (self.wrapped_line_to_idx[line] or 1) + (target_row - row)
        end
        return { type = "line", line = line, row = row, row_in_line = target_row - row + 1, wrapped_idx = wrapped_idx }
      end
      row = row + count
      line = line + 1
    end
  end

  local trailing = self:get_extra_visual_rows_after_line(#self.doc.lines)
  if target_row >= row and target_row < row + trailing then
    return { type = "extra", line = #self.doc.lines, placement = "after", row = row, row_in_extra = target_row - row + 1 }
  end
  return { type = "line", line = #self.doc.lines, row = math.max(1, row - 1) }
end

function DocView:iter_visible_visual_rows()
  local _, y1, _, y2 = self:get_content_bounds()
  local lh = self:get_line_height()
  local total = self:get_scrollable_line_count()
  local row = math.max(1, math.floor((y1 - style.padding.y) / lh) + 1)
  local last = math.min(total, math.floor((y2 - style.padding.y) / lh) + 1)
  local x, base_y = self:get_content_offset()
  return function()
    if row > last then return nil end
    local current = row
    row = row + 1
    local entry = self:get_visual_row_entry(current)
    entry.visual_row = current
    entry.y = base_y + (current - 1) * lh + style.padding.y
    return entry
  end
end

function DocView:expand_folds_covering_range(line1, col1, line2, col2, reason)
  line1, line2 = normalize_fold_lines(self.doc, line1, line2 or line1)
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

function DocView:expand_folds_at_line(line, reason)
  return self:expand_folds_covering_range(line, 1, line, 1, reason or "expand-line")
end

function DocView:select_and_reveal(line1, col1, line2, col2, opts)
  opts = opts or {}
  if opts.fold_policy ~= "keep" then
    self:expand_folds_covering_range(line1, col1, line2 or line1, col2 or col1, opts.reason or "select-and-reveal")
  end
  self.doc:set_selection(line1, col1, line2 or line1, col2 or col1)
  self:scroll_to_make_visible(line1, col1, opts.instant, { line2 = line2, col2 = col2 })
end

function DocView:reveal_range(line1, col1, line2, col2, opts)
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

function DocView:get_fold_target(line1, col1, line2, col2, opts)
  line1 = common.clamp(line1 or 1, 1, #self.doc.lines)
  line2 = common.clamp(line2 or line1, 1, #self.doc.lines)
  col1, col2 = col1 or 1, col2 or col1 or 1
  if line2 < line1 or line2 == line1 and col2 < col1 then
    line1, col1, line2, col2 = line2, col2, line1, col1
  end

  if line2 > line1 then
    if col2 == 1 then line2 = math.max(line1, line2 - 1) end
    if line2 > line1 then
      return { line1 = line1, col1 = 1, line2 = line2, col2 = #self.doc.lines[line2] + 1, kind = "selection" }
    end
  end

  local function indentation_target_at(start, kind)
    while start <= #self.doc.lines and is_blank_line(self.doc.lines[start]) do start = start + 1 end
    if start > #self.doc.lines then return nil end
    local base_indent = line_indent(self.doc.lines[start])
    local last = start
    for line = start + 1, #self.doc.lines do
      local text = self.doc.lines[line]
      if is_blank_line(text) then
        last = line
      elseif line_indent(text) > base_indent then
        last = line
      else
        break
      end
    end
    while last > start and is_blank_line(self.doc.lines[last]) do last = last - 1 end
    if last > start then
      return { line1 = start, col1 = 1, line2 = last, col2 = #self.doc.lines[last] + 1, kind = kind or "indent" }
    end
  end

  local syntax_target, syntax_reason = language_intelligence.fold_target(self.doc, line1, col1, line2, col2)
  if syntax_target then return syntax_target end
  if syntax_reason and syntax_reason ~= "no-provider" and syntax_reason ~= "unsupported" and syntax_reason ~= "not-ready" then
    core.log_quiet("Syntax Fold Target unavailable for %s: %s", self.doc:get_name(), tostring(syntax_reason))
  end

  local direct = indentation_target_at(line1, "indent")
  if direct then return direct end

  for start = line1 - 1, 1, -1 do
    if not is_blank_line(self.doc.lines[start]) then
      local target = indentation_target_at(start, "enclosing-indent")
      if target and target.line2 >= line1 then return target end
    end
  end
end

function DocView:fold_at_caret(opts)
  opts = opts or {}
  local line1, col1, line2, col2 = self.doc:get_selection(true)
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

function DocView:unfold_at_caret(reason)
  reason = reason or "unfold-at-caret"
  local changed = false
  for _, line1, col1, line2, col2 in self.doc:get_selections(true) do
    if line1 ~= line2 or col1 ~= col2 then
      if self:expand_folds_covering_range(line1, col1, line2, col2, reason) then
        changed = true
      end
    end
  end
  if changed then return true end

  local line = self.doc:get_selection()
  local fold = self:get_collapsed_fold_at_line(line)
  if fold then return self:expand_fold_region(fold, reason) end
  return false
end

function DocView:unfold_all(reason)
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

local function selection_overlaps_fold(doc, fold)
  for _, line1, col1, line2, col2 in doc:get_selections(true) do
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

local function selection_covers_fold(doc, fold)
  local fold_col1 = fold.col1 or 1
  local fold_col2 = fold.col2 or (#(doc.lines[fold.line2] or "") + 1)
  for _, line1, col1, line2, col2 in doc:get_selections(true) do
    if (line1 ~= line2 or col1 ~= col2)
    and position_le(line1, col1, fold.line1, fold_col1)
    and position_ge(line2, col2, fold.line2, fold_col2) then
      return true
    end
  end
  return false
end

function DocView:draw_fold_widget_gutter(fold, x, y, width)
  local lh = self:get_line_height()
  renderer.draw_rect(x, y, width, lh, style.gutter_bg or style.background2)
  if config.show_line_numbers then
    local color = selection_overlaps_fold(self.doc, fold) and style.line_number2 or style.line_number
    common.draw_text(self:get_font(), color, tostring(fold.line1), "right", x + style.padding.x, y, width - style.padding.x, lh)
  end
  return lh
end

function DocView:draw_fold_widget_body(fold, x, y)
  local lh = self:get_line_height()
  local bx = x + self.scroll.x
  local bw = math.max(0, self.position.x + self.size.x - bx)
  local bg = selection_covers_fold(self.doc, fold) and style.selection or style.fold_widget_background
  renderer.draw_rect(bx, y, bw, lh, bg)
  local border = style.fold_widget_border or style.fold_widget_effect or style.accent
  local t = math.max(1, SCALE)
  renderer.draw_rect(bx, y, bw, t, border)
  renderer.draw_rect(bx, y + lh - t, bw, t, border)
  renderer.draw_rect(bx, y, t, lh, border)
  renderer.draw_rect(bx + bw - t, y, t, lh, border)
  common.draw_text(self:get_font(), style.fold_widget_text or style.dim, fold_placeholder(self.doc, fold), "left", x + style.padding.x, y, self.size.x, lh)
  return lh
end


---Get the screen position of a line (and optionally column).
---@param line integer Line number
---@param col? integer Optional column number
---@return number x Screen x coordinate
---@return number y Screen y coordinate
function DocView:get_line_screen_position(line, col, line_end)
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
    local lh = self:get_line_height()
    local gw = self:get_gutter_width()
    return x + gw + (col and self:get_col_x_offset(line, col, line_end) or 0), y + (idx - 1) * lh + style.padding.y
  end
  local x, y = self:get_content_offset()
  local lh = self:get_line_height()
  local gw = self:get_gutter_width()
  local row = self:has_composed_visual_rows() and self:get_composed_visual_row_for_position(line, col, line_end) or line
  y = y + (row-1) * lh + style.padding.y
  if col then
    return x + gw + self:get_col_x_offset(line, col), y
  else
    return x + gw, y
  end
end


---Get the vertical offset for centering text within a line.
---@return number offset Y offset to center text in line height
function DocView:get_line_text_y_offset()
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
function DocView:get_visible_cols_range(line, extra_cols)
  extra_cols = extra_cols or 100

  local text = self.doc.lines[line]
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
  local cache = self.doc.cache.ulen
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
function DocView:get_visible_line_range()
  local x, y, x2, y2 = self:get_content_bounds()
  local lh = self:get_line_height()
  if self:has_composed_visual_rows() then
    local total = self:get_composed_visual_row_count()
    local minidx = math.max(1, math.floor((y - style.padding.y) / lh) + 1)
    local maxidx = math.min(total, math.floor((y2 - style.padding.y) / lh) + 1)
    local first = self:get_visual_row_entry(minidx)
    local last = self:get_visual_row_entry(maxidx)
    return first and first.line or 1, last and (last.fold and last.fold.line2 or last.line) or #self.doc.lines
  end
  if self.wrapped_settings then
    local minidx = math.max(1, math.floor((y - style.padding.y) / lh) + 1)
    local maxidx = math.min(linewrapping.get_total_wrapped_lines(self), math.floor((y2 - style.padding.y) / lh) + 1)
    local minline = linewrapping.get_idx_line_col(self, minidx)
    local maxline = linewrapping.get_idx_line_col(self, maxidx)
    return minline, maxline
  end
  local minline = math.max(1, math.floor((y - style.padding.y) / lh) + 1)
  local maxline = math.min(#self.doc.lines, math.floor((y2 - style.padding.y) / lh) + 1)
  return minline, maxline
end


---Get the horizontal pixel offset for a column position.
---Accounts for tabs, syntax highlighting fonts, and caches long lines.
---@param line integer Line number
---@param col integer Column number (byte offset)
---@return number offset Horizontal pixel offset
function DocView:get_col_x_offset(line, col, line_end)
  if self.wrapped_settings then
    local perf_active = core.perf_frame_stats ~= nil
    local perf_start = perf_active and system.get_time()
    if line_end == nil and self.__use_wrapped_caret_affinity then
      line_end = linewrapping.has_wrapped_line_end_affinity(self, line, col)
    end
    local _, _, _, scol = linewrapping.get_line_idx_col_count(self, line, col, line_end)
    local xoffset, i = (scol ~= 1 and self.wrapped_line_offsets[line] or 0), 1
    local default_font = self:get_font()
    for _, type, text in self.doc.highlighter:each_token(line) do
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
            perf_frame_add("docview_get_col_x_offset_wrapped_calls", 1)
            perf_elapsed("docview_get_col_x_offset_wrapped_ms", perf_start)
            return xoffset
          end
          xoffset = xoffset + font:get_width(char)
          i = i + #char
        end
      else
        i = i + #text
      end
    end
    perf_frame_add("docview_get_col_x_offset_wrapped_calls", 1)
    perf_elapsed("docview_get_col_x_offset_wrapped_ms", perf_start)
    return xoffset
  end
  local column = 1
  local xoffset = 0
  local cache = self.doc.cache.col_x
  local line_text = self.doc.lines[line]
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
  local _, indent_size = self.doc:get_indent_info()
  default_font:set_tab_size(indent_size)
  if line_len > CACHE_LINE_LEN and column == 1 then
    local fast_x = get_fast_ascii_monospace_x_offset(self, line, col, line_text, default_font)
    if fast_x then
      if cache[line] then cache[line][col] = fast_x end
      return fast_x
    end
  end
  local scol = column > 1 and column or nil
  for _, type, text in self.doc.highlighter:each_render_token(line, scol) do
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
function DocView:get_x_offset_col(line, x)
  if self.wrapped_settings then
    local idx = linewrapping.get_line_idx_col_count(self, line)
    local _, target_col = linewrapping.get_line_col_from_index_and_x(self, idx, x)
    return target_col
  end
  local line_text = self.doc.lines[line]
  local line_len = #line_text

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
  local default_font = self:get_font()
  local _, indent_size = self.doc:get_indent_info()
  default_font:set_tab_size(indent_size)
  for _, type, text in self.doc.highlighter:each_render_token(line) do
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


---Convert screen coordinates to document line/column.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return integer line Line number
---@return integer col Column number
function DocView:resolve_screen_position(x, y)
  self.resolved_fold_widget = nil
  if self.wrapped_settings then
    local content_x, content_y = self:get_content_offset()
    local ox, oy = content_x + self:get_gutter_width(), content_y + style.padding.y
    local total = self:has_composed_visual_rows() and self:get_composed_visual_row_count() or linewrapping.get_total_wrapped_lines(self)
    local idx = common.clamp(math.floor((y - oy) / self:get_line_height()) + 1, 1, total)
    if self:has_composed_visual_rows() then
      local entry = self:get_visual_row_entry(idx)
      if entry and entry.type == "fold" then
        self.resolved_fold_widget = entry.fold
        self.wrapped_last_resolved_line_end = nil
        return entry.fold.line1, 1
      elseif entry and entry.type == "extra" then
        self.wrapped_last_resolved_line_end = nil
        return entry.line, 1
      elseif entry then
        local line, col, line_end = linewrapping.get_line_col_from_index_and_x(self, entry.wrapped_idx, x - ox)
        self.wrapped_last_resolved_line_end = line_end and { line, col } or nil
        return line, col
      end
    end
    local line, col, line_end = linewrapping.get_line_col_from_index_and_x(self, idx, x - ox)
    self.wrapped_last_resolved_line_end = line_end and { line, col } or nil
    return line, col
  end
  local content_x, content_y = self:get_content_offset()
  local ox, oy = content_x + self:get_gutter_width(), content_y + style.padding.y
  local row = math.floor((y - oy) / self:get_line_height()) + 1
  local line = common.clamp(row, 1, #self.doc.lines)
  if self:has_composed_visual_rows() then
    local entry = self:get_visual_row_entry(common.clamp(row, 1, self:get_composed_visual_row_count()))
    if entry and entry.type == "fold" then
      self.resolved_fold_widget = entry.fold
      return entry.fold.line1, 1
    elseif entry then
      line = entry.line
    end
  end
  local col = self:get_x_offset_col(line, x - ox)
  return line, col
end


---Scroll to center a line in the viewport.
---@param line integer Line number to scroll to
---@param ignore_if_visible? boolean Don't scroll if line already visible
---@param instant? boolean Jump immediately without animation
---@param opts? table Optional scroll behavior options
function DocView:scroll_to_line(line, ignore_if_visible, instant, opts)
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
---@return boolean accepts Always returns true for DocView
function DocView:supports_text_input()
  return true
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
function DocView:scroll_to_make_visible(line, col, instant, opts)
  if self.wrapping_enabled then self:update_wrap_cache() end
  if self.wrapped_settings then
    with_wrapped_caret_affinity(self, DocView.scroll_to_make_visible_unwrapped, line, col, instant, opts)
    self.scroll.to.x = 0
    if instant then self.scroll.x = self.scroll.to.x end
    self:notify_scroll_listeners("scroll_to_make_visible")
    return
  end
  local result = self:scroll_to_make_visible_unwrapped(line, col, instant, opts)
  self:notify_scroll_listeners("scroll_to_make_visible")
  return result
end

function DocView:scroll_to_make_visible_unwrapped(line, col, instant, opts)
  opts = opts or {}
  if opts.vertical ~= false then
    self.scroll.y = math.max(0, self.scroll.y or 0)
    self.scroll.to.y = math.max(0, self.scroll.to.y or 0)
    local _, oy = self:get_content_offset()
    local _, ly = self:get_line_screen_position(line, col)
    local lh = self:get_line_height()
    local scroll_h = self:get_horizontal_scrollbar_height()

    local pad = self:get_visible_scroll_context_lines()
    if self.mouse_selecting then
      pad = math.min(pad, 1)
    end

    local below_pad = pad
    if config.scroll_past_end and not self.mouse_selecting then
      local end_pad = self:get_scroll_past_end_context_lines()
      if end_pad > below_pad then
        local target_idx = math.max(1, math.floor((ly - oy - style.padding.y) / lh) + 1)
        local rows_below = math.max(0, self:get_scrollable_line_count() - target_idx)
        if rows_below < end_pad then
          below_pad = end_pad
        end
      end
    end

    local above = math.max(0, ly - oy - style.padding.y - lh * pad)
    local below = ly - oy - self.size.y + scroll_h + lh * (below_pad + 1)

    self.scroll.to.y = math.max(0, common.clamp(self.scroll.to.y, below, above))
  end

  local gw = self:get_gutter_width()
  local _, _, scroll_w = self.v_scrollbar:get_track_rect()
  local size_x = math.max(0, self.size.x - scroll_w)
  local line2, col2 = opts.line2, opts.col2
  local range_line = line2 == line and col2 and line
  local xmargin = opts.horizontal_grace
  if xmargin == nil then
    if range_line then
      xmargin = math.min(80 * (SCALE or 1), size_x * 0.25)
    else
      xmargin = 3 * self:get_font():get_width(' ')
    end
  end

  local xinf, xsup
  if range_line then
    local x1 = self:get_col_x_offset(line, math.min(col, col2)) + gw
    local x2 = self:get_col_x_offset(line, math.max(col, col2)) + gw
    xinf, xsup = math.min(x1, x2), math.max(x1, x2)
  else
    local xoffset = self:get_col_x_offset(line, col)
    xsup = xoffset + gw
    xinf = xoffset
  end

  local desired_left = math.max(0, xinf - xmargin)
  local desired_right = xsup + xmargin
  if range_line and opts.reset_x_if_fits_at_zero ~= false and desired_right <= size_x then
    self.scroll.to.x = 0
  else
    local current_x = self.scroll.to.x or self.scroll.x or 0
    if (xsup + xmargin) > current_x + size_x then
      if xsup - xinf > size_x then
        self.scroll.to.x = desired_left
      else
        self.scroll.to.x = math.max(0, xsup + xmargin - size_x)
      end
    elseif desired_left < current_x then
      self.scroll.to.x = desired_left
    end
  end

  if instant then
    self.scroll.y = self.scroll.to.y
    self.scroll.x = self.scroll.to.x
  end
end


---Handle mouse movement for cursor changes and text selection.
---Updates cursor icon, gutter hover state, and extends selection if dragging.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
function DocView:on_mouse_moved(x, y, ...)
  local selecting = self.mouse_selecting ~= nil
  DocView.super.on_mouse_moved(self, x, y, ...)

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
      local fold = self.resolved_fold_widget or self:get_collapsed_fold_at_line(line)
      self.resolved_fold_widget = nil
      if fold then
        self.cursor = "hand"
        self.hovered_fold_widget = fold
      end
    end
  end

  if self.mouse_selecting then
    local l1, c1 = self:resolve_screen_position(x, y)
    local l2, c2, snap_type = table.unpack(self.mouse_selecting)
    if keymap.modkeys["ctrl"] then
      if l1 > l2 then l1, l2 = l2, l1 end
      self.doc.selections = { }
      for i = l1, l2 do
        self.doc:set_selections(i - l1 + 1, i, math.min(c1, #self.doc.lines[i]), i, math.min(c2, #self.doc.lines[i]))
      end
    else
      if snap_type then
        l1, c1, l2, c2 = self:mouse_selection(self.doc, snap_type, l1, c1, l2, c2)
      end
      self.doc:set_selection(l1, c1, l2, c2)
    end
  end
  if self.wrapped_settings and selecting then
    apply_resolved_line_end_affinity(self)
  end
end


---Adjust selection based on snap type (word, line).
---@param doc core.doc Document
---@param snap_type string Snap type: "word" or "lines"
---@param line1 integer Start line
---@param col1 integer Start column
---@param line2 integer End line
---@param col2 integer End column
---@return integer line1 Adjusted start line
---@return integer col1 Adjusted start column
---@return integer line2 Adjusted end line
---@return integer col2 Adjusted end column
function DocView:mouse_selection(doc, snap_type, line1, col1, line2, col2)
  local swap = line2 < line1 or line2 == line1 and col2 <= col1
  if swap then
    line1, col1, line2, col2 = line2, col2, line1, col1
  end
  if snap_type == "word" then
    line1, col1 = translate.start_of_word(doc, line1, col1)
    line2, col2 = translate.end_of_word(doc, line2, col2)
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
function DocView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" then self.doc:clear_search_selections() end
  if button == "left" and not self.hovering_gutter then
    local line = self:resolve_screen_position(x, y)
    local fold = self.resolved_fold_widget or self:get_collapsed_fold_at_line(line)
    self.resolved_fold_widget = nil
    if fold then
      self:expand_fold_region(fold.id, "mouse")
      self.doc:set_selection(fold.line1, 1, fold.line1, 1)
      return true
    end
  end
  if button ~= "left" or not self.hovering_gutter then
    local result = DocView.super.on_mouse_pressed(self, button, x, y, clicks)
    if self.wrapped_settings and button == "left" then
      apply_resolved_line_end_affinity(self)
    end
    return result
  end
  local line = self:resolve_screen_position(x, y)
  if keymap.modkeys["shift"] then
    local sline, scol, sline2, scol2 = self.doc:get_selection(true)
    if line > sline then
      self.doc:set_selection(sline, 1, line,  #self.doc.lines[line])
    else
      self.doc:set_selection(line, 1, sline2, #self.doc.lines[sline2])
    end
  else
    if clicks == 1 then
      self.doc:set_selection(line, 1, line, 1)
    elseif clicks == 2 then
      self.doc:set_selection(line, 1, line, #self.doc.lines[line])
    end
  end
  return true
end


---Handle mouse release to end text selection.
function DocView:on_mouse_released(...)
  DocView.super.on_mouse_released(self, ...)
  self.mouse_selecting = nil
end


---Handle text input from keyboard.
---@param text string Input text
function DocView:on_text_input(text)
  self.doc:clear_search_selections()
  self.doc:text_input(text)
end


---Handle IME text composition events.
---Updates IME decoration and scrolls to keep composition visible.
---@param text string Composition text
---@param start integer Selection start within composition
---@param length integer Selection length within composition
function DocView:on_ime_text_editing(text, start, length)
  self.doc:clear_search_selections()
  self.doc:ime_text_editing(text, start, length)
  self.ime_status = #text > 0
  self.ime_selection.from = start
  self.ime_selection.size = length

  -- Set the composition bounding box that the system IME
  -- will consider when drawing its interface
  local line1, col1, line2, col2 = self.doc:get_selection(true)
  local col = math.min(col1, col2)
  self:update_ime_location()
  self:scroll_to_make_visible(line1, col + start)
end


---Update IME composition window location.
---Sets the bounding box for the system IME composition window.
function DocView:update_ime_location()
  if core.active_view ~= self then return end

  local line1, col1, line2, col2 = self.doc:get_selection(true)
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

  local x, y = self:get_line_screen_position(line1)
  local h = self:get_line_height()
  local col = math.min(col1, col2)

  local x1, x2 = 0, 0

  if self.ime_selection.size > 0 then
    -- focus on a part of the text
    local from = col + self.ime_selection.from
    local to = from + self.ime_selection.size
    x1 = self:get_col_x_offset(line1, from)
    x2 = self:get_col_x_offset(line1, to)
  else
    -- focus the whole text
    x1 = self:get_col_x_offset(line1, col1)
    x2 = self:get_col_x_offset(line2, col2)
  end

  ime.set_location(x + x1, y, x2 - x1, h)
end


function DocView:active_window_has_focus()
  local focused_window = core.active_window or core.window
  return not system.window_has_focus or system.window_has_focus(focused_window)
end

---Update the view state each frame.
---Handles cache invalidation, auto-scrolling to caret, and blink timing.
function DocView:update()
  local perf_active = core.perf_frame_stats ~= nil
  local update_start = perf_active and system.get_time()

  -- clear cache if font or indent size changed
  local phase_start = perf_active and system.get_time()
  local font = self:get_font()
  local _, indent_size = self.doc:get_indent_info()
  if
    self.cache_indent_size ~= indent_size
    or
    self.cache_font ~= font or self.cache_font_size ~= font:get_size()
  then
    self.doc.cache.col_x = {}
    self.doc.cache.line_width = {}
    self.__unwrapped_content_width_cache = nil
    self.cache_font = font
    self.cache_font_size = font:get_size()
    self.cache_indent_size = indent_size
  end
  perf_elapsed("docview_update_cache_ms", phase_start)

  if self.wrapping_enabled and self.size.x > 0 then
    local wrap_start = perf_active and system.get_time()
    self:update_wrap_cache()
    perf_elapsed("docview_update_wrap_cache_ms", wrap_start)
  end

  -- scroll to make caret visible and reset blink timer if it moved
  phase_start = perf_active and system.get_time()
  local line1, col1, line2, col2 = self.doc:get_selection()
  local selection_moved = line1 ~= self.last_line1 or col1 ~= self.last_col1 or
      line2 ~= self.last_line2 or col2 ~= self.last_col2
  if (selection_moved or self.needs_initial_scroll_validation) and self.size.x > 0 then
    if core.active_view == self and not ime.editing then
      local scroll_start = perf_active and system.get_time()
      self:scroll_to_make_visible(line1, col1, self.needs_initial_scroll_validation)
      perf_elapsed("docview_scroll_to_make_visible_ms", scroll_start)
      self.needs_initial_scroll_validation = nil
    end
    core.blink_reset()
    self.last_line1, self.last_col1 = line1, col1
    self.last_line2, self.last_col2 = line2, col2
  end
  perf_elapsed("docview_update_selection_ms", phase_start)

  -- update blink timer
  phase_start = perf_active and system.get_time()
  local active_window_has_focus = false
  if not config.disable_blink then
    local focus_start = perf_active and system.get_time()
    active_window_has_focus = self:active_window_has_focus()
    perf_elapsed("docview_update_active_focus_ms", focus_start)
  end
  if not config.disable_blink and active_window_has_focus and self == core.active_view and not self.mouse_selecting then
    local T, t0 = config.blink_period, core.blink_start
    local ta, tb = core.blink_timer, system.get_time()
    if ((tb - t0) % T < T / 2) ~= ((ta - t0) % T < T / 2) then
      core.redraw = true
    end
    core.blink_timer = tb
  end
  perf_elapsed("docview_update_blink_ms", phase_start)

  phase_start = perf_active and system.get_time()
  self:update_ime_location()
  perf_elapsed("docview_update_ime_ms", phase_start)

  phase_start = perf_active and system.get_time()
  DocView.super.update(self)
  perf_elapsed("docview_update_super_ms", phase_start)
  perf_elapsed("docview_update_ms", update_start)
end


---Draw the current line highlight bar.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
function DocView:get_line_highlight_rect(x, y)
  local lh = self:get_line_height()
  local pos_x = self.__full_width_highlight_position_x or self.position.x
  local size_x = self.__full_width_highlight_size_x or self.size.x
  return pos_x, y, size_x, lh
end

function DocView:draw_line_highlight(x, y)
  local rx, ry, rw, rh = self:get_line_highlight_rect(x, y)
  renderer.draw_rect(rx, ry, rw, rh, style.line_highlight)
end

function DocView:draw_content_left_edge()
  local edge_w = math.max(1, math.floor(SCALE))
  local edge_padding = style.padding.x * 0.25
  local x = self:get_line_screen_position(1) - edge_padding - edge_w
  renderer.draw_rect(x, self.position.y, edge_w, self.size.y, style.docview_content_left_edge)
end

function DocView:line_has_current_line_highlight(line)
  local highlight_cache = self.__line_body_highlight_cache
  if highlight_cache then return highlight_cache[line] or false end

  local hcl = config.highlight_current_line
  if hcl == false then return false end
  for lidx, line1, col1, line2, col2 in self.doc:get_selections(false) do
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

function DocView:draw_current_line_highlights(minline, maxline)
  if self.wrapped_settings then
    if core.active_view ~= self or config.highlight_current_line == false then return end
    local lh = self:get_line_height()
    local hcl = config.highlight_current_line
    for _, line1, col1, line2, col2 in self.doc:get_selections(false) do
      if line1 > maxline then break end
      if line1 >= minline and (hcl ~= "no_selection" or (line1 == line2 and col1 == col2)) then
        local line_end = linewrapping.has_wrapped_line_end_affinity(self, line1, col1)
        local idx = linewrapping.get_line_idx_col_count(self, line1, col1, line_end)
        local _, y = self:get_line_screen_position(line1)
        local first_idx = linewrapping.get_line_idx_col_count(self, line1)
        self:draw_line_highlight(self.position.x, y + lh * (idx - first_idx))
      end
    end
    self:draw_content_left_edge()
    return
  end
  if config.highlight_current_line == false then return end
  local _, y = self:get_line_screen_position(minline)
  local lh = self:get_line_height()
  for line = minline, maxline do
    if self:line_has_current_line_highlight(line) then
      self:draw_line_highlight(self.position.x, y)
    end
    y = y + lh
  end
  self:draw_content_left_edge()
end


---Return a non-interactive visual hint for a line.
---Override this in Document View subclasses or plugins. The result can be a
---string, a single segment table `{ text, color?, font? }`, or a list of
---segment tables. Hints are drawn right-aligned by default and are never part
---of the Document text.
---@param line integer Line number
---@return string|table|nil hint
function DocView:get_line_hint(line)
  return nil
end

---Minimum horizontal gap between Document text and a Line Hint.
---@param line integer Line number
---@param hint_options? table Normalized Line Hint options
---@return number gap Pixel gap
function DocView:get_line_hint_gap(line, hint_options)
  local gap_spaces = hint_options and hint_options.gap_spaces
  if gap_spaces then
    return self:get_font():get_width(string.rep(" ", math.max(0, gap_spaces)))
  end
  if hint_options and hint_options.gap then return math.max(0, hint_options.gap) end
  return style.padding.x * 2
end

function DocView:normalize_line_hint(hint)
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

function DocView:measure_line_hint_segments(segments)
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

function DocView:truncate_line_hint_segments(segments, max_width, direction)
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

function DocView:get_line_hint_text_end_x(line, x)
  local text = self.doc.lines[line] or ""
  local text_len = #text
  if text:sub(-1) == "\n" then text_len = text_len - 1 end
  return x + self:get_col_x_offset(line, text_len + 1)
end

---Draw a Line Hint for a line, clipped/truncated so it never covers Document text.
---@param line integer Line number
---@param x number Screen x coordinate of the line's text origin
---@param y number Screen y coordinate of the line
---@return number? x_advance
---@return number? x
---@return number? width
function DocView:draw_line_hint(line, x, y)
  local stats = core.docview_frame_stats
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

  local draw_x = placement == "after_line_document_text" and hint_left_limit or content_right - width
  local tx = draw_x
  local ty = y + self:get_line_text_y_offset()
  local lh = self:get_line_height()

  phase_start = stats and system.get_time()
  core.push_clip_rect(hint_left_limit, y, math.max(0, content_right - hint_left_limit), lh)
  for _, segment in ipairs(segments) do
    local draw_text_start = stats and system.get_time()
    tx = renderer.draw_text(segment.font, segment.text, tx, ty, segment.color)
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

local function cached_fast_ascii_monospace_width(self, line, text, font, indent_size)
  local font_size = font:get_size()
  local change_id = self.doc:get_change_id()
  local cache = self.__fast_ascii_monospace_width_cache
  if
    not cache
    or cache.change_id ~= change_id
    or cache.font ~= font
    or cache.font_size ~= font_size
    or cache.indent_size ~= indent_size
  then
    cache = {
      change_id = change_id,
      font = font,
      font_size = font_size,
      indent_size = indent_size,
      space_width = font:get_width(" "),
      lines = {},
    }
    cache.tab_width = cache.space_width * (indent_size or 2)
    self.__fast_ascii_monospace_width_cache = cache
  end

  local entry = cache.lines[line]
  if entry and entry.text == text then return entry.width end
  local width = fast_ascii_monospace_width(text, cache.space_width, cache.tab_width, 0)
  cache.lines[line] = { text = text, width = width }
  return width
end

---Draw the text content of a line with syntax highlighting.
---@param line integer Line number
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return integer height Line height
function DocView:draw_line_text(line, x, y)
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
          if next_line ~= line then row_end_col = #self.doc.lines[line] end
          local tx = x + (row_start_col ~= 1 and (self.wrapped_line_offsets[line] or 0) or 0)
          renderer.draw_text(self:get_font(), self.doc.lines[line]:sub(row_start_col, math.max(row_start_col, row_end_col - 1)), tx, y + text_y_offset + (idx - first_idx) * lh, provider_text_color)
        end
      end
      return lh * count
    end
    renderer.draw_text(self:get_font(), self.doc.lines[line], x, y + text_y_offset, provider_text_color)
    return lh
  end
  if self.wrapped_settings then
    local perf_active = core.perf_frame_stats ~= nil
    local perf_start = perf_active and system.get_time()
    local perf_segments, perf_bytes, perf_known_bounds_segments = 0, 0, 0
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
      if can_use_known_bounds and uses_default_font and not text:find("[\t\128-\255]") then
        perf_known_bounds_segments = perf_known_bounds_segments + 1
        local width = #text * default_ascii_cell_width
        return renderer.draw_text_known_bounds(
          font, text, sx, sy,
          math.floor(sx), math.floor(sy),
          math.max(1, math.ceil(width)),
          math.max(1, math.ceil(default_font_height)),
          color
        )
      end
      return renderer.draw_text(font, text, sx, sy, color)
    end

    local row_idx = visible_idx1
    local _, row_start_col = linewrapping.get_idx_line_col(self, row_idx)
    local row_next_line, row_end_col = linewrapping.get_idx_line_col(self, row_idx + 1)
    if row_next_line ~= line then row_end_col = #self.doc.lines[line] end
    local tx = x + (row_start_col ~= 1 and begin_width or 0)
    local ty = y + text_y_offset + (row_idx - first_idx) * lh
    local token_start_col = 1

    local function advance_row()
      row_idx = row_idx + 1
      if row_idx > visible_idx2 then return false end
      _, row_start_col = linewrapping.get_idx_line_col(self, row_idx)
      row_next_line, row_end_col = linewrapping.get_idx_line_col(self, row_idx + 1)
      if row_next_line ~= line then row_end_col = #self.doc.lines[line] end
      tx = x + (row_start_col ~= 1 and begin_width or 0)
      ty = y + text_y_offset + (row_idx - first_idx) * lh
      return true
    end

    for _, type, text in self.doc.highlighter:each_token(line) do
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
          local rendered_text = text:sub(draw_start_col - token_start_col + 1, draw_end_col - token_start_col)
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
    perf_frame_add("linewrapping_draw_line_text_calls", 1)
    perf_frame_add("linewrapping_draw_line_text_rows", drawn_rows)
    perf_frame_add("linewrapping_draw_line_text_segments", perf_segments)
    perf_frame_add("linewrapping_draw_line_text_bytes", perf_bytes)
    perf_frame_add("linewrapping_draw_line_text_known_bounds_segments", perf_known_bounds_segments)
    perf_elapsed("linewrapping_draw_line_text_ms", perf_start)
    return lh * count
  end

  local stats = core.docview_frame_stats
  local text_start = stats and system.get_time()
  local default_font = self:get_font()
  local tx, ty = x, y + self:get_line_text_y_offset()
  local last_token = nil
  local get_line_start = stats and system.get_time()
  local render_line = self.doc.highlighter:get_render_line(line)
  local tokens = render_line.tokens
  if stats then stats.highlighter_get_line_ms = stats.highlighter_get_line_ms + (system.get_time() - get_line_start) * 1000 end
  local syntax = style.syntax
  local syntax_fonts = style.syntax_fonts
  local normal_color = syntax.normal
  local tokens_count = #tokens
  if tokens_count > 0 and string.sub(tokens[tokens_count], -1) == "\n" then
    last_token = tokens_count - 1
  end
  local _, indent_size = self.doc:get_indent_info()
  local token_loop_start = stats and system.get_time()
  local line_start_tx = tx
  local unwrapped_default_ascii_width = default_font:get_width(" ")
  local unwrapped_tab_width = unwrapped_default_ascii_width * indent_size
  local unwrapped_default_font_height = default_font:get_height()
  local line_text = self.doc.lines[line]
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
        local lo, hi = col1 + 1, #self.doc.lines[line]
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

      tx = renderer.draw_text_known_bounds(
        default_font,
        text,
        tx,
        ty,
        math.floor(tx),
        math.floor(ty),
        math.max(1, math.ceil(width)),
        math.max(1, math.ceil(unwrapped_default_font_height)),
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
  local max_pending_bytes = 512
  local function flush_pending_text()
    if not pending_font then return false end
    local draw_text_start = stats and system.get_time()
    local text = #pending_chunks == 1 and pending_chunks[1] or table.concat(pending_chunks)
    if renderer.draw_text_known_bounds
    and (not package.loaded["core.test"] or self.__test_force_known_bounds)
    and (core.window or self.__test_force_known_bounds)
    and pending_font == default_font
    and not text:find("[\128-\255]") then
      local tab_offset = tx - start_tx
      local width = pending_has_tabs
        and fast_ascii_monospace_width(text, unwrapped_default_ascii_width, unwrapped_tab_width, tab_offset)
        or (#text * unwrapped_default_ascii_width)
      tx = renderer.draw_text_known_bounds(
        pending_font,
        text,
        tx,
        ty,
        math.floor(tx),
        math.floor(ty),
        math.max(1, math.ceil(width)),
        math.max(1, math.ceil(unwrapped_default_font_height)),
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
  local function ascii_ligature_sensitive_byte(byte)
    return byte == 45  -- -
        or byte == 46  -- .
        or byte == 47  -- /
        or byte == 58  -- :
        or byte == 60  -- <
        or byte == 61  -- =
        or byte == 62  -- >
        or byte == 33  -- !
        or byte == 38  -- &
        or byte == 42  -- *
        or byte == 102 -- f
        or byte == 124 -- |
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
        local ascii_chunkable = (#text > max_pending_bytes * 4)
          or text:find("[\128-\255]") == nil
        if not ascii_chunkable then
        -- Avoid splitting complex/shaped scripts across draw calls; HarfBuzz
        -- needs the full run to preserve joining and ligatures. Pathological
        -- ASCII tokens are the common long-line case we chunk aggressively.
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
          end
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
function DocView:draw_caret(x, y, line, col, caret_idx, color)
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

  local stats = core.docview_frame_stats
  if stats then stats.caret_draw_calls = stats.caret_draw_calls + 1 end
  local lh = self:get_line_height()
  if self.doc.overwrite then
    local w = self:get_font():get_width(self.doc:get_char(line, col))
    renderer.draw_rect(x, y + lh, w, style.caret_width * 2, color)
  else
    renderer.draw_rect(x, y, style.caret_width, lh, color)
  end
end


function DocView:search_match_style(primary)
  if primary then
    return style.search_selection, style.search_selection_outline
  end
  return style.selectionhighlight, style.search_selection_secondary_outline
end

function DocView:search_match_screen_rect(line, col1, col2)
  local x1, y1 = self:get_line_screen_position(line, col1)
  local x2, y2 = self:get_line_screen_position(line, col2)
  if y2 ~= y1 then
    -- A very long match can cross a soft-wrap boundary. Draw a useful
    -- first-segment marker rather than placing the whole match on the physical
    -- line's first visual row.
    x2 = self.position.x + self.size.x
  end
  return x1, y1, x2, self:get_line_height()
end

function DocView:draw_search_match_background(line, col1, col2, primary)
  local x1, y, x2, h = self:search_match_screen_rect(line, col1, col2)
  if x2 <= x1 then return end
  local bg = self:search_match_style(primary)
  renderer.draw_rect(x1, y, x2 - x1, h, bg)
end

function DocView:draw_search_match_outline(line, col1, col2, primary)
  local x1, y, x2, h = self:search_match_screen_rect(line, col1, col2)
  if x2 <= x1 then return end
  local _, outline = self:search_match_style(primary)
  local t = math.max(1, SCALE)
  renderer.draw_rect(x1, y, x2 - x1, t, outline)
  renderer.draw_rect(x1, y + h - t, x2 - x1, t, outline)
  renderer.draw_rect(x1, y, t, h, outline)
  renderer.draw_rect(x2 - t, y, t, h, outline)
end

---Prepare per-visible-line selection/highlight data for draw_line_body().
---This avoids scanning every selection once per visible line and merges
---overlapping same-color ranges into one rectangle.
---@param minline integer First visible line
---@param maxline integer Last visible line
function DocView:prepare_line_body_draw_cache(minline, maxline)
  local stats = core.docview_frame_stats
  local prepare_start = stats and system.get_time()
  local highlight_cache = {}
  local selection_cache = {}
  local search_match_cache = {}
  local gutter_selection_cache = {}
  local visible_caret_cache = {}
  local hcl = config.highlight_current_line

  local phase_start = stats and system.get_time()
  if hcl ~= false then
    for _, line1, col1, line2, col2 in self.doc:get_selections(false) do
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
  local selections = self.doc.selections
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
  for _, line1, col1, line2, col2 in self.doc:get_selections(true) do
    if stats then stats.prepare_selection_iters = stats.prepare_selection_iters + 1 end
    if line1 > maxline then break end
    if line2 >= minline then
      if stats then stats.visible_selection_ranges = stats.visible_selection_ranges + 1 end
      local from_line = math.max(line1, minline)
      local to_line = math.min(line2, maxline)
      for line = from_line, to_line do
        gutter_selection_cache[line] = true
        local text = self.doc.lines[line]
        local c1 = line1 ~= line and 1 or col1
        local c2 = line2 ~= line and #text + 1 or col2
        if c1 ~= c2 then
          local is_search_selection = self.doc:is_search_selection(line1, c1, line, c2)
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
    core.log_quiet("DocView decoration provider %s.%s failed for %s: %s", tostring(entry.id), method, view.doc:get_name(), tostring(res))
    return nil
  end
  return res
end

local function draw_decoration_line_backgrounds(view, line, x, y)
  local lh = view:get_line_height()
  for _, entry in ipairs(view:decoration_provider_entries()) do
    local color = provider_call(view, entry, "line_background", view, line)
    if color then
      if view.wrapped_settings and view.__wrapped_draw_first_idx then
        local first_idx = view.wrapped_line_to_idx and view.wrapped_line_to_idx[line]
        if first_idx then
          for idx = view.__wrapped_draw_first_idx, view.__wrapped_draw_last_idx do
            renderer.draw_rect(view.position.x, y + (idx - first_idx) * lh, view.size.x, lh, color)
          end
        end
      else
        renderer.draw_rect(view.position.x, y, view.size.x, lh, color)
      end
    end
  end
end

local function draw_decoration_inline_ranges(view, line, x, y)
  local lh = view:get_line_height()
  for _, entry in ipairs(view:decoration_provider_entries()) do
    local ranges = provider_call(view, entry, "inline_ranges", view, line)
    for _, range in ipairs(ranges or {}) do
      local col1 = math.max(1, math.floor(tonumber(range.col1 or range[1]) or 1))
      local col2 = math.max(col1, math.floor(tonumber(range.col2 or range[2]) or col1))
      local color = range.color or range[3]
      if color then
        if view.wrapped_settings and view.__wrapped_draw_first_idx then
          local first_idx = view.wrapped_line_to_idx and view.wrapped_line_to_idx[line]
          if first_idx then
            for idx = view.__wrapped_draw_first_idx, view.__wrapped_draw_last_idx do
              local row_start, row_end = view:get_visual_row_bounds_for_line(line, idx - first_idx + 1)
              if row_start and row_end and col2 > row_start and col1 < row_end then
                local seg_col1 = math.max(col1, row_start)
                local seg_col2 = math.min(col2, row_end)
                local tx1 = view:get_col_x_offset(line, seg_col1, false)
                local tx2 = view:get_col_x_offset(line, seg_col2, seg_col2 == row_end)
                if tx2 > tx1 then renderer.draw_rect(x + tx1, y + (idx - first_idx) * lh, tx2 - tx1, lh, color) end
              end
            end
          end
        else
          local tx1 = view:get_col_x_offset(line, col1)
          local text = view.doc.lines[line] or ""
          local width = view:get_font():get_width(text:sub(col1, math.max(col1, col2 - 1)))
          if width > 0 then renderer.draw_rect(x + tx1, y, width, lh, color) end
        end
      end
    end
  end
end

function DocView:decoration_text_color(line)
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
function DocView:draw_line_body(line, x, y)
  if self.wrapped_settings then
    local lh = self:get_line_height()
    local idx0, _, count = linewrapping.get_line_idx_col_count(self, line)
    local first_row, last_row = 1, count
    if self.size and self.size.y > 0 then
      local viewport_y1 = self.position.y
      local viewport_y2 = self.position.y + self.size.y
      first_row = math.max(1, math.floor((viewport_y1 - y) / lh) + 1)
      last_row = math.min(count, math.floor((viewport_y2 - y) / lh) + 1)
    end
    if last_row < first_row then return lh * count end
    local visible_idx1 = idx0 + first_row - 1
    local visible_idx2 = idx0 + last_row - 1
    local old_visible_idx1 = self.__wrapped_draw_first_idx
    local old_visible_idx2 = self.__wrapped_draw_last_idx
    self.__wrapped_draw_first_idx = visible_idx1
    self.__wrapped_draw_last_idx = visible_idx2
    draw_decoration_line_backgrounds(self, line, x, y)
    local highlight_rows
    local hcl = config.highlight_current_line
    if not self.__current_line_highlights_drawn_before_content
    and hcl ~= false and core.active_view == self then
      for _, line1, col1, line2, col2 in self.doc:get_selections(false) do
        if line1 == line and (hcl ~= "no_selection" or (line1 == line2 and col1 == col2)) then
          local line_end = linewrapping.has_wrapped_line_end_affinity(self, line, col1)
          local idx = linewrapping.get_line_idx_col_count(self, line, col1, line_end)
          if idx >= idx0 and idx < idx0 + count then
            highlight_rows = highlight_rows or {}
            highlight_rows[idx] = true
          end
        end
      end
    end
    if highlight_rows then
      for i = visible_idx1, visible_idx2 do
        if highlight_rows[i] then
          self:draw_line_highlight(x + self.scroll.x, y + lh * (i - idx0))
        end
      end
    end

    local search_matches
    for _, line1, col1, line2, col2 in self.doc:get_selections(true) do
      if line >= line1 and line <= line2 then
        if line1 ~= line then col1 = 1 end
        if line2 ~= line then col2 = #self.doc.lines[line] + 1 end
        if col1 ~= col2 then
          if self.doc:is_search_selection(line1, col1, line, col2) then
            search_matches = search_matches or {}
            search_matches[#search_matches + 1] = { col1, col2, true }
          else
            local idx1 = linewrapping.get_line_idx_col_count(self, line, col1)
            local idx2 = linewrapping.get_line_idx_col_count(self, line, col2)
            for i = math.max(idx1, visible_idx1), math.min(idx2, visible_idx2) do
              local x1, x2 = get_wrapped_segment_bounds(self, line, col1, col2, idx1, idx2, i)
              if x1 and x2 and x2 > x1 then
                renderer.draw_rect(x + x1, y + (i - idx0) * lh, x2 - x1, lh, style.selection)
              end
            end
          end
        end
      end
    end
    for _, match in ipairs(search_matches or {}) do
      draw_wrapped_search_match(self, line, match[1], match[2], x, y, idx0, lh, match[3], false, visible_idx1, visible_idx2)
    end
    draw_decoration_inline_ranges(self, line, x, y)

    local line_height = self:draw_line_text(line, x, y)

    for _, match in ipairs(search_matches or {}) do
      draw_wrapped_search_match(self, line, match[1], match[2], x, y, idx0, lh, match[3], true, visible_idx1, visible_idx2)
    end

    local underline_module = DocView.__lsp_diagnostic_underlines_module or package.loaded["core.lsp.diagnostic_underlines"]
    if underline_module and underline_module.draw_line then
      underline_module.draw_line(self, line, x, y)
    end
    if visible_idx2 == idx0 + count - 1 then
      self:draw_line_hint(line, x, y + lh * (count - 1))
    end

    self.__wrapped_draw_first_idx = old_visible_idx1
    self.__wrapped_draw_last_idx = old_visible_idx2
    return line_height
  end

  draw_decoration_line_backgrounds(self, line, x, y)

  if not self.__current_line_highlights_drawn_before_content
  and self:line_has_current_line_highlight(line) then
    self:draw_line_highlight(x + self.scroll.x, y)
  end

  -- draw selection if it overlaps this line
  local lh = self:get_line_height()
  local selection_cache = self.__line_body_selection_cache
  local fallback_search_matches
  local cached_selections = selection_cache and selection_cache[line]
  if cached_selections then
    for _, sel in ipairs(cached_selections) do
      local x1 = x + self:get_col_x_offset(line, sel[1])
      local x2 = x + self:get_col_x_offset(line, sel[2])
      if x1 ~= x2 then
        local stats = core.docview_frame_stats
        if stats then stats.selection_rect_calls = stats.selection_rect_calls + 1 end
        renderer.draw_rect(x1, y, x2 - x1, lh, sel[3])
      end
    end
  elseif not selection_cache then
    for lidx, line1, col1, line2, col2 in self.doc:get_selections(true) do
      if line1 > line then break end
      if line >= line1 and line <= line2 then
        local text = self.doc.lines[line]
        if line1 ~= line then col1 = 1 end
        if line2 ~= line then col2 = #text + 1 end
        if self.doc:is_search_selection(line1, col1, line, col2) then
          fallback_search_matches = fallback_search_matches or {}
          fallback_search_matches[#fallback_search_matches + 1] = { col1, col2, true }
        else
          local x1 = x + self:get_col_x_offset(line, col1)
          local x2 = x + self:get_col_x_offset(line, col2)
          if x1 ~= x2 then
            local stats = core.docview_frame_stats
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

  self:draw_line_hint(line, x, y)

  return line_height
end


---Draw the gutter with line numbers.
---@param line integer Line number
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param width number Gutter width
---@return integer height Line height
function DocView:draw_line_gutter(line, x, y, width)
  local lh = self:get_line_height()
  local height = lh
  if config.show_line_numbers then
    local color = style.line_number
    local gutter_selection_cache = self.__line_gutter_selection_cache
    if gutter_selection_cache then
      if gutter_selection_cache[line] then color = style.line_number2 end
    else
      for _, line1, _, line2 in self.doc:get_selections(true) do
        if line1 > line then break end
        if line >= line1 and line <= line2 then
          color = style.line_number2
          break
        end
      end
    end
    x = x + style.padding.x
    common.draw_text(self:get_font(), color, line, "right", x, y, width, lh)
  end
  if self.wrapped_settings then
    height = math.max(height, lh * linewrapping.get_wrapped_line_count(self, line))
  end
  return height
end


---Draw IME composition decoration (underline and selection).
---@param line1 integer Start line
---@param col1 integer Start column
---@param line2 integer End line
---@param col2 integer End column
function DocView:draw_ime_decoration(line1, col1, line2, col2)
  local x, y = self:get_line_screen_position(line1)
  local line_size = math.max(1, SCALE)
  local lh = self:get_line_height()

  -- Draw IME underline
  local x1 = self:get_col_x_offset(line1, col1)
  local x2 = self:get_col_x_offset(line2, col2)
  renderer.draw_rect(x + math.min(x1, x2), y + lh - line_size, math.abs(x1 - x2), line_size, style.text)

  -- Draw IME selection
  local col = math.min(col1, col2)
  local from = col + self.ime_selection.from
  local to = from + self.ime_selection.size
  x1 = self:get_col_x_offset(line1, from)
  if from ~= to then
    x2 = self:get_col_x_offset(line1, to)
    line_size = style.caret_width
    renderer.draw_rect(x + math.min(x1, x2), y + lh - line_size, math.abs(x1 - x2), line_size, style.caret)
  end
  self:draw_caret(x + x1, y, line1, col)
end


---Draw overlay elements (carets, IME decoration).
---Called after main text to draw on top.
function DocView:draw_overlay()
  if self.wrapped_settings then
    linewrapping.draw_guide(self)
    return with_wrapped_caret_affinity(self, DocView.draw_overlay_unwrapped)
  end
  return self:draw_overlay_unwrapped()
end

function DocView:draw_overlay_unwrapped()
  local stats = core.docview_frame_stats
  local overlay_start = stats and system.get_time()
  local minline, maxline = self:get_visible_line_range()
  local is_active = core.active_view == self
  if not is_active or not self:active_window_has_focus() then return end

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
    for _, line1, col1, line2, col2 in self.doc:get_selections() do
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
end


function DocView:draw_folded()
  self:draw_background(style.background)
  local _, indent_size = self.doc:get_indent_info()
  self:get_font():set_tab_size(indent_size)

  local minline, maxline = self:get_visible_line_range()
  self:prepare_line_body_draw_cache(minline, maxline)
  self.__current_line_highlights_drawn_before_content = false

  local x = self.position.x - self.scroll.x
  local gw, gpad = self:get_gutter_width()
  local gutter_w = gpad and gw - gpad or gw
  local drawn_gutters = {}
  for entry in self:iter_visible_visual_rows() do
    if entry.type == "fold" then
      self:draw_fold_widget_gutter(entry.fold, self.position.x, entry.y, gutter_w)
    elseif entry.type == "extra" then
      -- provider-owned visual spacer row; no default gutter
    elseif not drawn_gutters[entry.line] then
      drawn_gutters[entry.line] = true
      local line_y = entry.y - (entry.row_in_line - 1) * self:get_line_height()
      self:draw_line_gutter(entry.line, self.position.x, line_y, gutter_w)
    end
  end

  core.push_clip_rect(self.position.x + gw, self.position.y, math.max(0, self.size.x - gw), self.size.y)
  local drawn_bodies = {}
  for entry in self:iter_visible_visual_rows() do
    if entry.type == "fold" then
      self:draw_fold_widget_body(entry.fold, x + gw, entry.y)
    elseif entry.type == "extra" then
      -- provider-owned visual spacer row; no default body
    elseif not drawn_bodies[entry.line] then
      drawn_bodies[entry.line] = true
      local line_y = entry.y - (entry.row_in_line - 1) * self:get_line_height()
      self:draw_line_body(entry.line, x + gw, line_y)
    end
  end
  self:draw_overlay()
  core.pop_clip_rect()

  self.__current_line_highlights_drawn_before_content = nil
  self.__line_body_highlight_cache = nil
  self.__line_body_selection_cache = nil
  self.__line_body_search_match_cache = nil
  self.__line_gutter_selection_cache = nil
  self.__visible_caret_cache = nil

  self:draw_scrollbar()
end

function DocView:draw_wrapped()
  if self:has_composed_visual_rows() then return self:draw_folded() end
  self:draw_background(style.background)
  local _, indent_size = self.doc:get_indent_info()
  self:get_font():set_tab_size(indent_size)

  local lh = self:get_line_height()
  local _, y1, _, y2 = self:get_content_bounds()
  local total = linewrapping.get_total_wrapped_lines(self)
  local minidx = math.max(1, math.floor((y1 - style.padding.y) / lh) + 1)
  local maxidx = math.min(total, math.floor((y2 - style.padding.y) / lh) + 1)
  if maxidx < minidx then
    self:draw_scrollbar()
    return
  end

  local x, base_y = self:get_content_offset()
  local gw, gpad = self:get_gutter_width()
  local gutter_w = gpad and gw - gpad or gw
  local first_line = linewrapping.get_idx_line_col(self, minidx)
  local last_line = linewrapping.get_idx_line_col(self, maxidx)

  self:prepare_line_body_draw_cache(first_line, last_line)
  self:draw_current_line_highlights(first_line, last_line)
  self.__current_line_highlights_drawn_before_content = true

  for line = first_line, last_line do
    local first_idx = self.wrapped_line_to_idx[line]
    if first_idx then
      local y = base_y + (first_idx - 1) * lh + style.padding.y
      self:draw_line_gutter(line, self.position.x, y, gutter_w)
    end
  end

  core.push_clip_rect(self.position.x + gw, self.position.y, math.max(0, self.size.x - gw), self.size.y)
  for line = first_line, last_line do
    local first_idx = self.wrapped_line_to_idx[line]
    if first_idx then
      local y = base_y + (first_idx - 1) * lh + style.padding.y
      self:draw_line_body(line, x + gw, y)
    end
  end
  self:draw_overlay()
  core.pop_clip_rect()

  self.__current_line_highlights_drawn_before_content = nil
  self.__line_body_highlight_cache = nil
  self.__line_body_selection_cache = nil
  self.__line_body_search_match_cache = nil
  self.__line_gutter_selection_cache = nil
  self.__visible_caret_cache = nil

  self:draw_scrollbar()
end

---Draw the entire document view.
---Renders background, gutters, text, selections, carets, and scrollbars.
function DocView:draw()
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
  local _, indent_size = self.doc:get_indent_info()
  self:get_font():set_tab_size(indent_size)

  local minline, maxline = self:get_visible_line_range()
  local lh = self:get_line_height()

  local stats = core.docview_frame_stats
  local draw_start = stats and system.get_time()
  if stats then stats.visible_lines = stats.visible_lines + math.max(0, maxline - minline + 1) end
  self:prepare_line_body_draw_cache(minline, maxline)
  self:draw_current_line_highlights(minline, maxline)
  self.__current_line_highlights_drawn_before_content = true

  local x, y = self:get_line_screen_position(minline)
  local gw, gpad = self:get_gutter_width()
  local gutter_start = stats and system.get_time()
  for i = minline, maxline do
    y = y + (self:draw_line_gutter(i, self.position.x, y, gpad and gw - gpad or gw) or lh)
  end
  if stats then stats.gutter_ms = stats.gutter_ms + (system.get_time() - gutter_start) * 1000 end

  local pos = self.position
  x, y = self:get_line_screen_position(minline)
  -- the clip below ensure we don't write on the gutter region. On the
  -- right side it is redundant with the Node's clip.
  core.push_clip_rect(pos.x + gw, pos.y, self.size.x - gw, self.size.y)
  local body_start = stats and system.get_time()
  for i = minline, maxline do
    y = y + (self:draw_line_body(i, x, y) or lh)
  end
  if stats then stats.body_ms = stats.body_ms + (system.get_time() - body_start) * 1000 end
  self:draw_overlay()
  core.pop_clip_rect()
  self.__current_line_highlights_drawn_before_content = nil
  self.__line_body_highlight_cache = nil
  self.__line_body_selection_cache = nil
  self.__line_gutter_selection_cache = nil

  self:draw_scrollbar()
  if stats then stats.draw_ms = stats.draw_ms + (system.get_time() - draw_start) * 1000 end
end

local function bind_selection_method(name)
  local fn = DocView[name]
  DocView[name] = function(self, ...)
    return self:with_selection_state(fn, self, ...)
  end
end

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

return DocView
