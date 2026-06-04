local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local keymap = require "core.keymap"
local translate = require "core.doc.translate"
local ime = require "core.ime"
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

local next_selection_owner_id = 0

DocView.registry = DocView.registry or setmetatable({}, { __mode = "k" })
DocView.mirror_owner = DocView.mirror_owner or setmetatable({}, { __mode = "k" })
DocView.owner_views = DocView.owner_views or DocView.session_views or setmetatable({}, { __mode = "v" })
DocView.session_views = DocView.owner_views -- deprecated compatibility alias

local function copy_array(t)
  local res = {}
  if t then
    for i = 1, #t do res[i] = t[i] end
  end
  return res
end

local function pack(...)
  return { n = select("#", ...), ... }
end

local function new_selection_owner_id()
  next_selection_owner_id = next_selection_owner_id + 1
  return next_selection_owner_id
end

local function selection_count(selections)
  return math.max(1, math.floor(#(selections or {}) / 4))
end

local function normalize_selection_state(doc, state)
  state = state or {}
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
  state.last_selection = common.clamp(math.floor(tonumber(state.last_selection) or 1), 1, selection_count(normalized))
  return state
end

local function ensure_selection_state(state, doc)
  if not state or type(state.selections) ~= "table" or #state.selections < 4 then
    return normalize_selection_state(doc, state)
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
  })
  return {
    selections = copy_array(state.selections),
    last_selection = state.last_selection,
  }
end

function DocView:set_selection_state(state)
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
end

function DocView:capture_selection_state()
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
    })
    self.selection_state.owner_id = owner_id
    self.selection_state.session_id = owner_id -- deprecated compatibility alias
  end
  DocView.owner_views[owner_id] = self
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
        normalize_selection_state(doc, view.selection_state)
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

function DocView:with_selection_state(fn, ...)
  local doc = self.doc
  if doc.bound_selection_view == self then
    return fn(...)
  end

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
    self:capture_selection_state()
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
    if line == 1 then
      return 1, 1
    end
    return move_to_line_offset(dv, line, col, -1)
  end,

  ["next_line"] = function(doc, line, col, dv)
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
  })
  register_view(self)
  self.doc.cache.col_x = {}
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
  if self.doc:is_dirty()
  and #core.get_views_referencing_doc(self.doc) == 1 then
    core.global_prompt_bar:enter("Unsaved Changes; Confirm Close", {
      submit = function(_, item)
        if item.text:match("^[cC]") then
          do_close()
        elseif item.text:match("^[sS]") then
          local ok, err = pcall(self.doc.save, self.doc)
          if ok then
            do_close()
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
    do_close()
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
---@return integer count Context line count
function DocView:get_scroll_past_end_context_lines()
  local lh = self:get_line_height()
  if lh <= 0 then return 0 end
  local max_context = math.max(0, math.floor((self:get_vertical_viewport_height() - style.padding.y - lh) / lh))
  return math.min(normalize_scroll_context_lines(), max_context)
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
  if text_height <= self.size.y then
    return self.size.y
  end
  return content_height
end


---Get the total scrollable height of the document.
---@return number height Total height in pixels
function DocView:get_scrollable_size()
  return self:get_scrollable_size_for_line_count(self:get_scrollable_line_count())
end


---Get the scrollable width (infinite for horizontal scrolling).
---@return number width Always returns math.huge
function DocView:get_h_scrollable_size()
  return math.huge
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


---Get the gutter width (line numbers area).
---@return number width Total gutter width
---@return number padding Padding within gutter
function DocView:get_gutter_width()
  local padding = style.padding.x * 2
  if config.show_line_numbers then
    return self:get_font():get_width(#self.doc.lines) + padding, padding
  end
  return style.padding.x, padding
end


---Get the screen position of a line (and optionally column).
---@param line integer Line number
---@param col? integer Optional column number
---@return number x Screen x coordinate
---@return number y Screen y coordinate
function DocView:get_line_screen_position(line, col)
  local x, y = self:get_content_offset()
  local lh = self:get_line_height()
  local gw = self:get_gutter_width()
  y = y + (line-1) * lh + style.padding.y
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
  local minline = math.max(1, math.floor((y - style.padding.y) / lh) + 1)
  local maxline = math.min(#self.doc.lines, math.floor((y2 - style.padding.y) / lh) + 1)
  return minline, maxline
end


---Get the horizontal pixel offset for a column position.
---Accounts for tabs, syntax highlighting fonts, and caches long lines.
---@param line integer Line number
---@param col integer Column number (byte offset)
---@return number offset Horizontal pixel offset
function DocView:get_col_x_offset(line, col)
  local column = 1
  local xoffset = 0
  local cache = self.doc.cache.col_x
  local line_len = #self.doc.lines[line]
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
  local scol = column > 1 and column or nil
  for _, type, text in self.doc.highlighter:each_token(line, scol) do
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
  for _, type, text in self.doc.highlighter:each_token(line) do
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
  local ox, oy = self:get_line_screen_position(1)
  local line = math.floor((y - oy) / self:get_line_height()) + 1
  line = common.clamp(line, 1, #self.doc.lines)
  local col = self:get_x_offset_col(line, x - ox)
  return line, col
end


---Scroll to center a line in the viewport.
---@param line integer Line number to scroll to
---@param ignore_if_visible? boolean Don't scroll if line already visible
---@param instant? boolean Jump immediately without animation
function DocView:scroll_to_line(line, ignore_if_visible, instant)
  local min, max = self:get_visible_line_range()
  if not (ignore_if_visible and line >= min and line <= max) then
    local x, y = self:get_line_screen_position(line)
    local ox, oy = self:get_content_offset()
    local _, _, _, scroll_h = self.h_scrollbar:get_track_rect()
    self.scroll.to.y = math.max(0, y - oy - (self.size.y - scroll_h) / 2)
    if instant then
      self.scroll.y = self.scroll.to.y
    end
  end
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
  if button ~= "left" or not self.hovering_gutter then
    return DocView.super.on_mouse_pressed(self, button, x, y, clicks)
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


---Update the view state each frame.
---Handles cache invalidation, auto-scrolling to caret, and blink timing.
function DocView:update()
  -- clear cache if font or indent size changed
  local font = self:get_font()
  local _, indent_size = self.doc:get_indent_info()
  if
    self.cache_indent_size ~= indent_size
    or
    self.cache_font ~= font or self.cache_font_size ~= font:get_size()
  then
    self.doc.cache.col_x = {}
    self.cache_font = font
    self.cache_font_size = font:get_size()
    self.cache_indent_size = indent_size
  end

  -- scroll to make caret visible and reset blink timer if it moved
  local line1, col1, line2, col2 = self.doc:get_selection()
  local selection_moved = line1 ~= self.last_line1 or col1 ~= self.last_col1 or
      line2 ~= self.last_line2 or col2 ~= self.last_col2
  if (selection_moved or self.needs_initial_scroll_validation) and self.size.x > 0 then
    if core.active_view == self and not ime.editing then
      self:scroll_to_make_visible(line1, col1, self.needs_initial_scroll_validation)
      self.needs_initial_scroll_validation = nil
    end
    core.blink_reset()
    self.last_line1, self.last_col1 = line1, col1
    self.last_line2, self.last_col2 = line2, col2
  end

  -- update blink timer
  if not config.disable_blink and system.window_has_focus(core.window) and self == core.active_view and not self.mouse_selecting then
    local T, t0 = config.blink_period, core.blink_start
    local ta, tb = core.blink_timer, system.get_time()
    if ((tb - t0) % T < T / 2) ~= ((ta - t0) % T < T / 2) then
      core.redraw = true
    end
    core.blink_timer = tb
  end

  self:update_ime_location()

  DocView.super.update(self)
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
  if core.active_view ~= self then return false end
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
  if core.active_view ~= self or config.highlight_current_line == false then return end
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
---segment tables. Hints are drawn right-aligned and are never part of the
---Document text.
---@param line integer Line number
---@return string|table|nil hint
function DocView:get_line_hint(line)
  return nil
end

---Minimum horizontal gap between Document text and a Line Hint.
---@param line integer Line number
---@return number gap Pixel gap
function DocView:get_line_hint_gap(line)
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

  return #segments > 0 and segments or nil
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

function DocView:truncate_line_hint_segments(segments, max_width)
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
    return {{ text = LINE_HINT_ELLIPSIS, font = ellipsis_font, color = default_color }}, true
  end

  table.insert(kept, 1, {
    text = LINE_HINT_ELLIPSIS,
    font = ellipsis_font,
    color = kept[1].color or default_color,
  })
  return kept, true
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
  local segments = self:normalize_line_hint(self:get_line_hint(line))
  if not segments then return end

  local gw = self:get_gutter_width()
  local _, _, vscroll_w = self.v_scrollbar:get_track_rect()
  local content_left = self.position.x + gw
  local content_right = self.position.x + self.size.x - (vscroll_w or 0) - style.padding.x
  if content_right <= content_left then return end

  local gap = self:get_line_hint_gap(line)
  local text_end_x = self:get_line_hint_text_end_x(line, x)
  local hint_left_limit = math.max(content_left, text_end_x) + gap
  local available = content_right - hint_left_limit
  if available <= 0 then return end

  local width = self:measure_line_hint_segments(segments)
  if width > available then
    segments = self:truncate_line_hint_segments(segments, available)
    if not segments then return end
    width = self:measure_line_hint_segments(segments)
    if width > available + 0.5 then return end
  end

  local draw_x = content_right - width
  local tx = draw_x
  local ty = y + self:get_line_text_y_offset()
  local lh = self:get_line_height()
  local stats = core.docview_frame_stats

  core.push_clip_rect(hint_left_limit, y, math.max(0, content_right - hint_left_limit), lh)
  for _, segment in ipairs(segments) do
    local draw_text_start = stats and system.get_time()
    tx = renderer.draw_text(segment.font, segment.text, tx, ty, segment.color)
    if stats then
      stats.draw_text_calls = stats.draw_text_calls + 1
      stats.renderer_draw_text_ms = stats.renderer_draw_text_ms + (system.get_time() - draw_text_start) * 1000
    end
  end
  core.pop_clip_rect()
  return tx, draw_x, width
end

---Draw the text content of a line with syntax highlighting.
---@param line integer Line number
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return integer height Line height
function DocView:draw_line_text(line, x, y)
  local stats = core.docview_frame_stats
  local text_start = stats and system.get_time()
  local default_font = self:get_font()
  local tx, ty = x, y + self:get_line_text_y_offset()
  local last_token = nil
  local get_line_start = stats and system.get_time()
  local tokens = self.doc.highlighter:get_line(line).tokens
  if stats then stats.highlighter_get_line_ms = stats.highlighter_get_line_ms + (system.get_time() - get_line_start) * 1000 end
  local tokens_count = #tokens
  if tokens_count > 0 and string.sub(tokens[tokens_count], -1) == "\n" then
    last_token = tokens_count - 1
  end
  local _, indent_size = self.doc:get_indent_info()

  local start_tx = tx
  local pending_font, pending_color, pending_chunks, pending_len
  local function flush_pending_text()
    if not pending_font then return false end
    local draw_text_start = stats and system.get_time()
    local text = #pending_chunks == 1 and pending_chunks[1] or table.concat(pending_chunks)
    tx = renderer.draw_text(pending_font, text, tx, ty, pending_color, {tab_offset = tx - start_tx})
    if stats then
      stats.draw_text_calls = stats.draw_text_calls + 1
      stats.renderer_draw_text_ms = stats.renderer_draw_text_ms + (system.get_time() - draw_text_start) * 1000
    end
    pending_font, pending_color, pending_chunks, pending_len = nil, nil, nil, nil
    return tx > self.position.x + self.size.x
  end
  local token_loop_start = stats and system.get_time()
  for tidx, type, text in self.doc.highlighter:each_token(line) do
    if stats then stats.tokens = stats.tokens + 1 end
    local color = style.syntax[type] or style.syntax["normal"]
    local font = style.syntax_fonts[type] or default_font
    if font ~= default_font then font:set_tab_size(indent_size) end
    -- do not render newline, fixes issue #1164
    if tidx == last_token then text = text:sub(1, -2) end
    if text ~= "" then
      if pending_font ~= font or pending_color ~= color or (pending_len or 0) + #text > 512 then
        if flush_pending_text() then break end
      end
      if not pending_font then
        pending_font, pending_color, pending_chunks, pending_len = font, color, {}, 0
      end
      pending_len = pending_len + #text
      pending_chunks[#pending_chunks + 1] = text
    end
  end
  flush_pending_text()
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
  local highlight_cache = {}
  local selection_cache = {}
  local search_match_cache = {}
  local gutter_selection_cache = {}
  local visible_caret_cache = {}
  local hcl = config.highlight_current_line

  if hcl ~= false then
    for _, line1, col1, line2, col2 in self.doc:get_selections(false) do
      if line1 > maxline then break end
      if line1 >= minline then
        if hcl == "no_selection" and ((line1 ~= line2) or (col1 ~= col2)) then
          highlight_cache[line1] = false
        elseif highlight_cache[line1] == nil then
          highlight_cache[line1] = true
        end
      end
    end
  end

  for _, raw_line1, raw_col1, raw_line2, raw_col2 in self.doc:get_selections(false) do
    if raw_line1 >= minline and raw_line1 <= maxline then
      visible_caret_cache[#visible_caret_cache + 1] = { raw_line1, raw_col1, raw_line2, raw_col2 }
    end
  end

  for _, line1, col1, line2, col2 in self.doc:get_selections(true) do
    if line1 > maxline then break end
    if line2 >= minline then
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
          end
        end
      end
    end
  end

  for line, list in pairs(selection_cache) do
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
    end
  end

  self.__line_body_highlight_cache = highlight_cache
  self.__line_body_selection_cache = selection_cache
  self.__line_body_search_match_cache = search_match_cache
  self.__line_gutter_selection_cache = gutter_selection_cache
  self.__visible_caret_cache = visible_caret_cache
end

---Draw a complete line including highlight and selections.
---@param line integer Line number
  ---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return integer height Line height
function DocView:draw_line_body(line, x, y)
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
  return lh
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
  local minline, maxline = self:get_visible_line_range()
  local is_active = core.active_view == self
  local window_focused = system.window_has_focus(core.window)
  if not window_focused then return end

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
end


---Draw the entire document view.
---Renders background, gutters, text, selections, carets, and scrollbars.
function DocView:draw()
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
