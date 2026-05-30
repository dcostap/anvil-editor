-- mod-version:3
-- View-local in-file find/replace overlay.
--
-- This intentionally does not use core.global_prompt_bar: find is editor-local UI.
-- Each DocView owns its own find state, so two splits of the same Doc can keep
-- independent queries, current match, highlights, and visible input bars.

local core = require "core"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local common = require "core.common"
local file_context = require "core.file_context"
local translate = require "core.doc.translate"
local Doc = require "core.doc"
local Highlighter = require "core.doc.highlighter"
local DocView = require "core.docview"
local GlobalPromptBar = require "core.global_prompt_bar"
local MessageBox = require "widget.messagebox"

local find_state_by_view = setmetatable({}, { __mode = "k" })
local last_global_query = ""
local update_after_input

local SingleLineHighlighter = Highlighter:extend()
function SingleLineHighlighter:get_line(idx)
  return { text = self.doc.lines[1], tokens = { "normal", self.doc.lines[1] } }
end
function SingleLineHighlighter:start() end

local SingleLineDoc = Doc:extend()
function SingleLineDoc:reset()
  SingleLineDoc.super.reset(self)
  self.highlighter = SingleLineHighlighter(self)
  self:reset_syntax()
end
function SingleLineDoc:insert(line, col, text)
  SingleLineDoc.super.insert(self, line, col, tostring(text or ""):gsub("[\r\n]", ""))
end

local LocalFindInputView = DocView:extend()
function LocalFindInputView:__tostring() return "LocalFindInputView" end

function LocalFindInputView:new(state, field_name)
  LocalFindInputView.super.new(self, SingleLineDoc())
  self.local_find_input = true
  self.local_find_state = state
  self.local_find_field = field_name
  self.scrollable = false
  self.hide_scrollbars = true
  self.font = "font"
  self.label = ""
  self.gutter_width = 0
  self.size.y = 0

  local input = self
  local raw_insert = self.doc.raw_insert
  function self.doc:raw_insert(...)
    raw_insert(self, ...)
    input:on_doc_text_change()
  end
  local raw_remove = self.doc.raw_remove
  function self.doc:raw_remove(...)
    raw_remove(self, ...)
    input:on_doc_text_change()
  end
end

function LocalFindInputView:on_doc_text_change()
  local state = self.local_find_state
  if not state or state.suppress_input_change then return end
  if self.local_find_field == "find" then
    if update_after_input and state.owner_view then
      update_after_input(state.owner_view, state)
    end
  else
    core.redraw = true
  end
end

function LocalFindInputView:get_text()
  return self.doc:get_text(1, 1, 1, math.huge)
end

function LocalFindInputView:set_text(text, select)
  self.doc:remove(1, 1, math.huge, math.huge)
  self.doc:text_input(text or "")
  if select then
    self.doc:set_selection(math.huge, math.huge, 1, 1)
  else
    self.doc:set_selection(1, math.huge, 1, math.huge)
  end
end

function LocalFindInputView:select_all()
  self.doc:set_selection(math.huge, math.huge, 1, 1)
end

function LocalFindInputView:move_to_end()
  self.doc:set_selection(1, math.huge, 1, math.huge)
end

function LocalFindInputView:get_gutter_width()
  return 0, 0
end

function LocalFindInputView:get_scrollable_size()
  return self:get_line_height()
end

function LocalFindInputView:get_h_scrollable_size()
  return math.huge
end

function LocalFindInputView:draw_scrollbar() end
function LocalFindInputView:draw_line_highlight() end

function LocalFindInputView:get_line_screen_position(line, col)
  local x = self.position.x - self.scroll.x
  local y = self.position.y + math.floor((self.size.y - self:get_line_height()) / 2)
  if col then
    return x + self:get_col_x_offset(1, col), y
  end
  return x, y
end

function LocalFindInputView:draw()
  local _, indent_size = self.doc:get_indent_info()
  self:get_font():set_tab_size(indent_size)
  self:prepare_line_body_draw_cache(1, 1)
  local x, y = self:get_line_screen_position(1)
  self:draw_line_body(1, x, y)
  self:draw_overlay()
  self.__line_body_highlight_cache = nil
  self.__line_body_selection_cache = nil
  self.__line_gutter_selection_cache = nil
end

local function field_text(field)
  return field and field:get_text() or ""
end

local function is_searchable_docview(view)
  return view and view.extends and view:extends(DocView)
    and not view:is(GlobalPromptBar)
    and not view.local_find_input
    and view.doc
end

local function active_docview()
  local view = core.active_view
  if view and view.local_find_input then
    local owner = view.local_find_state and view.local_find_state.owner_view
    if is_searchable_docview(owner) then return true, owner end
  end
  if is_searchable_docview(view) then return true, view end
  return false
end

local function copy_selection(view)
  return view:with_selection_state(function()
    return { view.doc:get_selection() }
  end)
end

local function set_selection(view, sel)
  if not view or not view.doc or not sel then return end
  return view:with_selection_state(function()
    view.doc:set_selection(table.unpack(sel))
  end)
end

local function ensure_state(view)
  local state = find_state_by_view[view]
  if not state then
    state = {
      owner_view = view,
      visible = false,
      input_active = false,
      mode = "find",
      focus = "find",
      origin = nil,
      matches = {},
      match_indexes_by_line = {},
      current = 0,
      found = false,
      error = false,
      case_sensitive = config.find_case_sensitive or false,
      regex = config.find_regex or false,
      change_id = -1,
    }
    state.find = LocalFindInputView(state, "find")
    state.replace = LocalFindInputView(state, "replace")
    file_context.exclude_main_panel_view(state.find)
    file_context.exclude_main_panel_view(state.replace)
    find_state_by_view[view] = state
  else
    state.owner_view = view
  end
  return state
end

local function focus_field(view, state, field_name)
  state.input_active = true
  state.focus = field_name or state.focus or "find"
  local field = state.focus == "replace" and state.replace or state.find
  field.local_find_owner = view
  field.__sidepanel_focus_owner = view
  core.set_active_view(field)
  core.blink_reset()
  core.redraw = true
end

local function active_find_state()
  local active = core.active_view
  if active and active.local_find_input then
    local state = active.local_find_state
    local view = state and state.owner_view
    if state and state.visible and state.input_active and view then return true, view, state end
  end
  local ok, view = active_docview()
  if not ok then return false end
  local state = find_state_by_view[view]
  if state and state.visible and state.input_active then return true, view, state end
  return false
end

local function active_visible_find_state()
  local ok, view = active_docview()
  if not ok then return false end
  local state = find_state_by_view[view]
  if state and state.visible then return true, view, state end
  return false
end

local function visible_find_state(view)
  local state = view and find_state_by_view[view]
  if state and state.visible then return state end
end

local function build_match_indexes_by_line(matches)
  local by_line = {}
  for i, match in ipairs(matches or {}) do
    local list = by_line[match.line]
    if not list then
      list = {}
      by_line[match.line] = list
    end
    list[#list + 1] = i
  end
  return by_line
end

local function find_all_matches(doc, state)
  local query = field_text(state.find)
  if not doc or query == "" then return {}, nil end

  local matches = {}
  local compiled
  if state.regex then
    local ok, result = pcall(regex.compile, query, state.case_sensitive and "" or "i")
    if not ok or not result then return {}, "Invalid regex" end
    compiled = result
  elseif not state.case_sensitive then
    query = query:lower()
  end

  for line_nr, line_text in ipairs(doc.lines) do
    local source = (not state.regex and not state.case_sensitive) and line_text:lower() or line_text
    local pos = 1
    while pos <= #source do
      local s, e
      if state.regex then
        s, e = regex.find_offsets(compiled, source, pos)
      else
        s, e = source:find(query, pos, true)
      end
      if not s then break end
      if e and e >= s and (e ~= #source or s ~= e) then
        matches[#matches + 1] = { line = line_nr, col1 = s, col2 = e == #source and e or e + 1 }
      end
      pos = math.max((e or s) + 1, s + 1)
    end
  end

  return matches, nil
end

local function selection_match_index(view, matches)
  local l1, c1, l2, c2 = table.unpack(view:with_selection_state(function()
    return { view.doc:get_selection(true) }
  end))
  for i, match in ipairs(matches or {}) do
    if match.line == l1 and match.line == l2 and match.col1 == c1 and match.col2 == c2 then
      return i
    end
  end
  return 0
end

local function compare_pos(line_a, col_a, line_b, col_b)
  if line_a ~= line_b then return line_a < line_b and -1 or 1 end
  if col_a ~= col_b then return col_a < col_b and -1 or 1 end
  return 0
end

local function selection_search_start(sel)
  if not sel then return 1, 1 end
  local l1, c1, l2, c2 = sel[1], sel[2], sel[3], sel[4]
  if not l1 or not c1 then return 1, 1 end
  if
    l2 and c2
    and (l1 ~= l2 or c1 ~= c2)
    and compare_pos(l2, c2, l1, c1) < 0
  then
    return l2, c2
  end
  return l1, c1
end

local function choose_match_from_position(matches, line, col)
  if not matches or #matches == 0 then return 0 end
  line, col = line or 1, col or 1
  for i, match in ipairs(matches) do
    if match.line == line and match.col1 == col then return i end
  end
  for i, match in ipairs(matches) do
    if compare_pos(match.line, match.col1, line, col) >= 0 then return i end
  end
  return 1
end

local function choose_match(view, state, reverse, from_origin)
  local matches = state.matches or {}
  if #matches == 0 then return 0 end

  if from_origin then
    local line, col = selection_search_start(state.origin or copy_selection(view))
    return choose_match_from_position(matches, line, col)
  end

  local l1, c1, l2, c2 = table.unpack(view:with_selection_state(function()
    return { view.doc:get_selection(true) }
  end))
  local line, col = reverse and l1 or l2, reverse and c1 or c2

  if reverse then
    for i = #matches, 1, -1 do
      local match = matches[i]
      if compare_pos(match.line, match.col1, line, col) < 0 then return i end
    end
    return #matches
  end

  for i, match in ipairs(matches) do
    if compare_pos(match.line, match.col2, line, col) > 0 then return i end
  end
  return 1
end

local function set_status(state)
  if field_text(state.find) == "" then
    state.info = ""
    state.error = false
  elseif state.error and state.error ~= true then
    state.info = tostring(state.error)
  elseif #(state.matches or {}) == 0 then
    state.info = "0 results"
    state.error = "0 results"
  else
    state.info = string.format("%d / %d", state.current or 0, #state.matches)
    state.error = false
  end
end

local function select_match(view, state, index, scroll)
  local match = state.matches and state.matches[index]
  state.current = match and index or 0
  if not match then return false end
  view:with_selection_state(function()
    view.doc:set_selection(match.line, match.col2, match.line, match.col1)
  end)
  if scroll ~= false then
    -- Match navigation should behave like the built-in find command: only move
    -- the vertical camera if the match is outside the visible range.  Horizontal
    -- range reveal is handled separately so long-line matches stay visible.
    view:scroll_to_line(match.line, true)
    view:scroll_to_make_visible(match.line, match.col1, false, {
      line2 = match.line,
      col2 = match.col2,
      vertical = false,
    })
  end
  state.found = true
  set_status(state)
  return true
end

local function refresh_matches(view, state, opts)
  opts = opts or {}
  state.error = false
  state.matches, state.error = find_all_matches(view.doc, state)
  state.match_indexes_by_line = build_match_indexes_by_line(state.matches)
  state.change_id = view.doc:get_change_id()

  if state.error then
    state.current = 0
    state.found = false
    set_status(state)
    return
  end

  if field_text(state.find) == "" then
    state.current = 0
    state.found = false
    set_status(state)
    return
  end

  local current = selection_match_index(view, state.matches)
  if opts.select == false then
    if current == 0 then
      current = common.clamp(state.current or 0, 0, #state.matches)
      if current == 0 and #state.matches > 0 then
        current = choose_match(view, state, false, false)
      end
    end
    state.current = current
    state.found = current > 0
    set_status(state)
    return
  end

  if current == 0 or opts.from_origin then
    current = choose_match(view, state, false, opts.from_origin)
  end

  if current > 0 then
    select_match(view, state, current, opts.scroll)
  elseif opts.restore_origin ~= false and state.origin then
    set_selection(view, state.origin)
    state.current = 0
    state.found = false
    set_status(state)
  else
    state.current = 0
    state.found = false
    set_status(state)
  end
end

function update_after_input(view, state)
  local origin = copy_selection(view)
  local restore_origin = false
  if state.preserve_current_after_input == false then
    origin = state.origin or origin
    restore_origin = true
    state.preserve_current_after_input = true
  end

  refresh_matches(view, state, { select = false, scroll = false })
  if field_text(state.find) ~= "" and #(state.matches or {}) > 0 then
    local line, col = selection_search_start(origin)
    local index = choose_match_from_position(state.matches, line, col)
    select_match(view, state, index, true)
  elseif restore_origin and state.origin then
    set_selection(view, state.origin)
    state.current = 0
    state.found = false
    set_status(state)
  end

  last_global_query = field_text(state.find)
  core.redraw = true
end

local function single_line_selection_text(view)
  local text = view:with_selection_state(function()
    local l1, c1, l2, c2 = view.doc:get_selection(true)
    if l1 ~= l2 or c1 == c2 then return "" end
    return view.doc:get_text(l1, c1, l2, c2)
  end)
  if text and not text:find("\n", 1, true) then return text end
  return ""
end

local function open_find(view, as_replace)
  local state = ensure_state(view)
  state.visible = true
  state.input_active = true
  state.mode = as_replace and "replace" or "find"
  state.focus = "find"
  state.origin = copy_selection(view)
  state.found = false
  state.error = false
  state.preserve_current_after_input = false

  state.suppress_input_change = true
  local selected = single_line_selection_text(view)
  if selected ~= "" then
    state.find:set_text(selected)
  elseif field_text(state.find) == "" and last_global_query ~= "" then
    state.find:set_text(last_global_query)
  end
  state.find:select_all()
  state.replace:move_to_end()
  state.suppress_input_change = false

  refresh_matches(view, state, { from_origin = true, restore_origin = false, scroll = true })
  focus_field(view, state, "find")
  core.log_quiet("Local find: opened %s overlay for %s", state.mode, view.doc.filename or "<untitled>")
  core.redraw = true
end

local function close_find(view, state, hide)
  state = state or find_state_by_view[view]
  if not state then return end
  state.input_active = false
  if hide then
    state.visible = false
    state.matches = {}
    state.match_indexes_by_line = {}
    state.current = 0
  end
  if core.active_view and core.active_view.local_find_input and view then
    core.set_active_view(view)
  end
  core.log_quiet("Local find: %s overlay for %s", hide and "closed" or "deactivated", view and view.doc and (view.doc.filename or "<untitled>") or "<no doc>")
  core.redraw = true
end

local core_set_active_view_for_find = core.intellij_find_base_set_active_view or core.set_active_view
core.intellij_find_base_set_active_view = core_set_active_view_for_find
function core.set_active_view(view)
  local previous = core.active_view
  local previous_state = previous and previous.local_find_input and previous.local_find_state
  local result = core_set_active_view_for_find(view)
  local next = core.active_view
  if previous_state and previous_state.visible and next ~= previous then
    local next_state = next and next.local_find_input and next.local_find_state
    if next_state ~= previous_state then
      previous_state.input_active = false
      if next == previous_state.owner_view then
        -- A DocView Prompt Bar closes when focus returns to its owning DocView.
        -- It may stay visible when focus moves elsewhere, such as from a Side
        -- Editor prompt to the corresponding Main Editor.
        previous_state.visible = false
        previous_state.matches = {}
        previous_state.match_indexes_by_line = {}
        previous_state.current = 0
        core.log_quiet("Local find: closed overlay because focus returned to owner")
      else
        core.log_quiet("Local find: deactivated overlay because focus moved elsewhere")
      end
      core.redraw = true
    end
  end
  return result
end

local function navigate(view, state, reverse)
  if not state or field_text(state.find) == "" then return end
  if state.change_id ~= view.doc:get_change_id() then
    refresh_matches(view, state, { scroll = false })
  end
  if #(state.matches or {}) == 0 then
    state.current = 0
    set_status(state)
    core.error("Couldn't find %q", field_text(state.find))
    return
  end
  local index = choose_match(view, state, reverse, false)
  select_match(view, state, index, true)
  core.redraw = true
end

local function add_match_to_selection(view, state, reverse)
  if not state or field_text(state.find) == "" then return end
  if state.change_id ~= view.doc:get_change_id() then
    refresh_matches(view, state, { scroll = false })
  end
  local index = choose_match(view, state, reverse, false)
  local match = state.matches and state.matches[index]
  if not match then return end
  view:with_selection_state(function()
    local existing
    for idx, l1, c1, l2, c2 in view.doc:get_selections(true, true) do
      if l1 == match.line and l2 == match.line and c1 == match.col1 and c2 == match.col2 then
        existing = idx
        break
      end
    end
    if existing then
      view.doc.last_selection = existing
    else
      view.doc:add_selection(match.line, match.col2, match.line, match.col1)
    end
  end)
  state.current = index
  set_status(state)
  view:scroll_to_line(match.line, true)
  core.redraw = true
end

local function replace_current_match(view, state)
  if not state or field_text(state.find) == "" then return end
  if state.change_id ~= view.doc:get_change_id() then
    refresh_matches(view, state, { scroll = false })
  end

  local replaced = false
  view:with_selection_state(function()
    local d = view.doc
    local l1, c1, l2, c2 = d:get_selection(true)
    local match = state.matches and state.matches[state.current]
    if not (match and match.line == l1 and match.line == l2 and match.col1 == c1 and match.col2 == c2) then
      match = nil
      for _, candidate in ipairs(state.matches or {}) do
        if candidate.line == l1 and candidate.line == l2 and candidate.col1 == c1 and candidate.col2 == c2 then
          match = candidate
          break
        end
      end
    end
    if not match then return end
    d:set_selection(match.line, match.col2, match.line, match.col1)
    d:text_input(field_text(state.replace), d.last_selection)
    replaced = true
  end)

  if not replaced then
    set_status(state)
    core.redraw = true
    return
  end
  state.origin = copy_selection(view)
  refresh_matches(view, state, { scroll = true })
end

local function perform_replace_all(view, state, matches, replacement)
  if not view or not state or not matches or #matches == 0 then return end
  view:with_selection_state(function()
    local d = view.doc
    for i = #matches, 1, -1 do
      local match = matches[i]
      d:remove(match.line, match.col1, match.line, match.col2)
      d:insert(match.line, match.col1, replacement or "")
    end
  end)
  state.origin = copy_selection(view)
  refresh_matches(view, state, { from_origin = true, scroll = true })
end

local function confirm_replace_all(view, state)
  if not state or field_text(state.find) == "" then return end
  refresh_matches(view, state, { scroll = false })
  local matches = {}
  for i, match in ipairs(state.matches or {}) do
    matches[i] = { line = match.line, col1 = match.col1, col2 = match.col2 }
  end
  local count = #matches
  if count == 0 then
    set_status(state)
    return
  end
  local replacement = field_text(state.replace)
  local query = field_text(state.find)
  local restore = core.active_view
  MessageBox.warning(
    "Replace All",
    string.format("Will replace %d instance%s of %q with %q.", count, count == 1 and "" or "s", query, replacement),
    function(_, button_id)
      if button_id == 1 then
        perform_replace_all(view, state, matches, replacement)
      end
      if restore then core.set_active_view(restore) end
    end,
    MessageBox.BUTTONS_OK_CANCEL
  )
end

local function toggle_field_focus(view, state)
  if state.mode ~= "replace" then return end
  local next_focus = state.focus == "find" and "replace" or "find"
  focus_field(view, state, next_focus)
  local field = next_focus == "replace" and state.replace or state.find
  field:select_all()
end

local function find_bar_layout(view, state)
  local font = style.font
  local pad = style.padding.x
  local row_h = math.floor(font:get_height() * 1.45)
  local h = row_h + math.max(2, SCALE * 2)
  return {
    x = view.position.x,
    y = view.position.y + view.size.y - h,
    w = view.size.x,
    h = h,
    row_h = row_h,
    pad = pad,
    sep = math.max(1, style.divider_size or SCALE),
    font = font,
  }
end

local function find_info_text(state)
  local flags = {}
  if state.regex then flags[#flags + 1] = "Regex" end
  if state.case_sensitive then flags[#flags + 1] = "Aa" end
  local suffix = #flags > 0 and (" [" .. table.concat(flags, " ") .. "]") or ""
  return tostring(state.info or "") .. suffix
end

local function make_field_row(layout, label, x, input_x, input_w)
  return {
    label = label,
    x = x,
    y = layout.y + math.floor((layout.h - (layout.row_h - layout.pad / 2)) / 2),
    input_x = input_x,
    input_w = math.max(32 * SCALE, input_w),
    input_h = layout.row_h - layout.pad / 2,
    font = layout.font,
  }
end

local function find_bar_rows(layout, state, info_text)
  local font, pad, sep = layout.font, layout.pad, layout.sep
  local x = layout.x + pad
  local right = layout.x + layout.w - pad
  local info_w = info_text ~= "" and math.min(font:get_width(info_text) + pad, math.max(80 * SCALE, layout.w * 0.24)) or 0
  local find_label = "Find:"
  local replace_label = "Replace:"
  local find_label_w = font:get_width(find_label) + pad
  local replace_label_w = font:get_width(replace_label) + pad

  if state.mode == "replace" then
    local available = right - x - find_label_w - replace_label_w - info_w - sep * 2 - pad
    available = math.max(96 * SCALE, available)
    local find_w = math.max(72 * SCALE, math.floor(available * 0.48))
    local replace_w = math.max(72 * SCALE, available - find_w)
    local find_row = make_field_row(layout, find_label, x, x + find_label_w, find_w)
    local replace_x = find_row.input_x + find_row.input_w + sep + pad
    local replace_row = make_field_row(layout, replace_label, replace_x, replace_x + replace_label_w, replace_w)
    local info_x = replace_row.input_x + replace_row.input_w + sep + pad
    return find_row, replace_row, { text = info_text, x = info_x, w = math.max(0, right - info_x) }
  end

  local available = right - x - find_label_w - info_w - sep
  local find_row = make_field_row(layout, find_label, x, x + find_label_w, math.max(80 * SCALE, available))
  local info_x = find_row.input_x + find_row.input_w + sep + pad
  return find_row, nil, { text = info_text, x = info_x, w = math.max(0, right - info_x) }
end

local function draw_input_field(view, state, field, row, active)
  local font = row.font or style.font
  local pad = style.padding.x / 2
  local x, y, w, h = row.input_x, row.y, row.input_w, row.input_h
  local border = style.divider
  local bg = active and (style.background3 or style.background) or (style.background2 or style.background)
  local line = math.max(1, SCALE)
  renderer.draw_rect(x, y, w, h, bg)
  renderer.draw_rect(x, y, w, line, border)
  renderer.draw_rect(x, y + h - line, w, line, active and (style.accent or style.caret) or border)
  renderer.draw_rect(x, y, line, h, border)
  renderer.draw_rect(x + w - line, y, line, h, border)

  field.position.x = x + pad
  field.position.y = y + 1
  field.size.x = math.max(1, w - pad * 2)
  field.size.y = math.max(1, h - 2)
  local caret_line, caret_col = field.doc:get_selection()
  field:scroll_to_make_visible(caret_line or 1, caret_col or 1, true)
  field:update()

  core.push_clip_rect(field.position.x, field.position.y, field.size.x, field.size.y)
  if field_text(field) == "" then
    local placeholder = row.label == "Replace:" and "replacement" or "search"
    local py = field.position.y + math.floor((field.size.y - font:get_height()) / 2)
    renderer.draw_text(font, placeholder, field.position.x - field.scroll.x, py, style.dim or style.text)
  end
  field:draw()
  core.pop_clip_rect()
end

local function draw_local_find(view)
  local state = visible_find_state(view)
  if not state then return end
  local layout = find_bar_layout(view, state)
  local active = state.input_active
  local bg = style.background2 or style.background
  local top = math.max(1, SCALE)
  renderer.draw_rect(layout.x, layout.y, layout.w, layout.h, bg)
  renderer.draw_rect(layout.x, layout.y, layout.w, top, style.divider)

  local info_text = find_info_text(state)
  local find_row, replace_row, info = find_bar_rows(layout, state, info_text)
  local label_y = find_row.y + (find_row.input_h - layout.font:get_height()) / 2
  renderer.draw_text(layout.font, find_row.label, find_row.x, label_y, style.dim or style.text)
  draw_input_field(view, state, state.find, find_row, active and core.active_view == state.find)

  if replace_row then
    local sep_x = find_row.input_x + find_row.input_w + math.floor(layout.sep / 2)
    renderer.draw_rect(sep_x, layout.y, layout.sep, layout.h, style.divider)
    renderer.draw_text(layout.font, replace_row.label, replace_row.x, label_y, style.dim or style.text)
    draw_input_field(view, state, state.replace, replace_row, active and core.active_view == state.replace)
  end

  if info and info.text ~= "" and info.w > 0 then
    local color = state.error and (style.error or style.text) or (style.dim or style.text)
    core.push_clip_rect(info.x, layout.y, info.w, layout.h)
    renderer.draw_text(layout.font, info.text, info.x, label_y, color)
    core.pop_clip_rect()
  end
end

local function point_in_rect(x, y, r)
  return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

local function point_in_field(x, y, row)
  return row and x >= row.x and x <= row.input_x + row.input_w and y >= row.y and y <= row.y + row.input_h
end

local function handle_find_mouse_pressed(view, state, x, y, clicks)
  local layout = find_bar_layout(view, state)
  if not point_in_rect(x, y, layout) then return false end
  local find_row, replace_row = find_bar_rows(layout, state, find_info_text(state))
  local target_field, target_name = state.find, "find"
  if replace_row and point_in_field(x, y, replace_row) then
    target_field, target_name = state.replace, "replace"
  end
  focus_field(view, state, target_name)

  local line, col = target_field:resolve_screen_position(x, y)
  if keymap.modkeys["shift"] then
    local l1, c1 = target_field.doc:get_selection()
    target_field.doc:set_selection(l1, c1, line, col)
  else
    target_field.doc:set_selection(line, col, line, col)
  end
  if clicks == 2 then
    local line1, col1 = translate.start_of_word(target_field.doc, line, col)
    local line2, col2 = translate.end_of_word(target_field.doc, line1, col1)
    target_field.doc:set_selection(line2, col2, line1, col1)
  elseif clicks == 3 then
    target_field:select_all()
  end
  core.blink_reset()
  core.redraw = true
  return true
end

-- Draw per-view find highlights. These are intentionally keyed by DocView, not
-- Doc, so the same Doc open in two splits can show independent search state.
--
-- Other plugins (notably linewrapping) replace DocView draw/update methods
-- after this module is first required from anvil_defaults.  Install these as
-- re-wrappable shims and run the installer again after startup so local find is
-- still outermost and split-local even when later plugins patch DocView.  Each
-- shim captures its base function in an upvalue; do not read the base through a
-- mutable DocView field from inside the shim, because later wrappers may have
-- captured an older shim and would recurse when we re-wrap them.
local docview_draw_line_body_wrapper
local docview_draw_wrapper
local docview_update_wrapper
local docview_on_mouse_pressed_wrapper

local function make_local_find_draw_line_body(base)
  return function(self, line, x, y)
    if (DocView.__local_find_draw_line_body_depth or 0) > 0 then
      return base(self, line, x, y)
    end

    local old_depth = DocView.__local_find_draw_line_body_depth or 0
    DocView.__local_find_draw_line_body_depth = old_depth + 1

    local state = visible_find_state(self)
    local line_matches = state and state.match_indexes_by_line and state.match_indexes_by_line[line]
    if line_matches and #line_matches > 0 then
      for _, idx in ipairs(line_matches) do
        local match = state.matches[idx]
        self:draw_search_match_background(match.line, match.col1, match.col2, idx == state.current)
      end
    end

    local lh = base(self, line, x, y)

    if line_matches and #line_matches > 0 then
      for _, idx in ipairs(line_matches) do
        local match = state.matches[idx]
        self:draw_search_match_outline(match.line, match.col1, match.col2, idx == state.current)
      end
    end

    DocView.__local_find_draw_line_body_depth = old_depth
    return lh
  end
end

local function make_local_find_draw(base)
  return function(self, ...)
    if (DocView.__local_find_draw_depth or 0) > 0 then
      return base(self, ...)
    end

    local old_depth = DocView.__local_find_draw_depth or 0
    DocView.__local_find_draw_depth = old_depth + 1
    local result = base(self, ...)
    if result ~= false then
      core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
      draw_local_find(self)
      core.pop_clip_rect()
    end
    DocView.__local_find_draw_depth = old_depth
    return result
  end
end

local function make_local_find_update(base)
  return function(self, ...)
    if (DocView.__local_find_update_depth or 0) > 0 then
      return base(self, ...)
    end

    local old_depth = DocView.__local_find_update_depth or 0
    DocView.__local_find_update_depth = old_depth + 1
    local state = visible_find_state(self)
    if state and state.change_id ~= self.doc:get_change_id() then
      refresh_matches(self, state, {
        scroll = false,
        restore_origin = false,
        select = state.input_active and core.active_view == self,
      })
    end
    local result = base(self, ...)
    DocView.__local_find_update_depth = old_depth
    return result
  end
end

local function make_local_find_on_mouse_pressed(base)
  return function(self, button, x, y, clicks)
    if (DocView.__local_find_on_mouse_pressed_depth or 0) > 0 then
      return base(self, button, x, y, clicks)
    end

    local state = find_state_by_view[self]
    if button == "left" and state and state.visible then
      if handle_find_mouse_pressed(self, state, x, y, clicks) then return true end
      state.input_active = false
    end

    local old_depth = DocView.__local_find_on_mouse_pressed_depth or 0
    DocView.__local_find_on_mouse_pressed_depth = old_depth + 1
    local result = base(self, button, x, y, clicks)
    DocView.__local_find_on_mouse_pressed_depth = old_depth
    return result
  end
end

local function patch_docview_method(name, wrapper_field, base_field, current_wrapper, make_wrapper)
  if DocView[name] == current_wrapper then return current_wrapper end

  local base = DocView[name]
  if DocView[wrapper_field] and base == DocView[wrapper_field] then
    base = DocView[base_field]
  end

  local wrapper = make_wrapper(base)
  DocView[base_field] = base
  DocView[wrapper_field] = wrapper
  DocView[name] = wrapper
  core.log_quiet("Local find: patched DocView.%s", name)
  return wrapper
end

local function install_docview_patches()
  docview_draw_line_body_wrapper = patch_docview_method(
    "draw_line_body",
    "__local_find_draw_line_body_wrapper",
    "__local_find_draw_line_body_base",
    docview_draw_line_body_wrapper,
    make_local_find_draw_line_body
  )
  docview_draw_wrapper = patch_docview_method(
    "draw",
    "__local_find_draw_wrapper",
    "__local_find_draw_base",
    docview_draw_wrapper,
    make_local_find_draw
  )
  docview_update_wrapper = patch_docview_method(
    "update",
    "__local_find_update_wrapper",
    "__local_find_update_base",
    docview_update_wrapper,
    make_local_find_update
  )
  docview_on_mouse_pressed_wrapper = patch_docview_method(
    "on_mouse_pressed",
    "__local_find_on_mouse_pressed_wrapper",
    "__local_find_on_mouse_pressed_base",
    docview_on_mouse_pressed_wrapper,
    make_local_find_on_mouse_pressed
  )
end

install_docview_patches()

command.add(function()
  return active_docview()
end, {
  ["find-replace:find"] = function(view)
    open_find(view, false)
  end,
  ["find-replace:replace"] = function(view)
    open_find(view, true)
  end,
  ["user:find"] = function(view)
    open_find(view, false)
  end,
})

command.add(function()
  local ok, view = active_docview()
  if not ok then return false end
  local state = find_state_by_view[view]
  if state and state.visible and field_text(state.find) ~= "" then return true, view, state end
  return false
end, {
  ["find-replace:repeat-find"] = function(view, state)
    navigate(view, state, false)
  end,
  ["find-replace:previous-find"] = function(view, state)
    navigate(view, state, true)
  end,
})

command.add(active_find_state, {
  ["user:find-field-next"] = function(view, state)
    navigate(view, state, false)
  end,
  ["user:find-field-previous"] = function(view, state)
    navigate(view, state, true)
  end,
  ["user:find-field-add-next"] = function(view, state)
    add_match_to_selection(view, state, false)
  end,
  ["user:find-field-add-previous"] = function(view, state)
    add_match_to_selection(view, state, true)
  end,
  ["user:find-toggle-replace-field"] = function(view, state)
    toggle_field_focus(view, state)
  end,
  ["user:find-submit-or-replace"] = function(view, state)
    if state.mode == "replace" and state.focus == "replace" then
      replace_current_match(view, state)
    else
      state.input_active = false
      core.set_active_view(view)
      core.redraw = true
    end
  end,
  ["user:find-replace-all-confirm"] = function(view, state)
    if state.mode == "replace" then confirm_replace_all(view, state) end
  end,
  ["find-replace:toggle-sensitivity"] = function(view, state)
    state.case_sensitive = not state.case_sensitive
    refresh_matches(view, state, { from_origin = true, scroll = true })
    core.redraw = true
  end,
  ["find-replace:toggle-regex"] = function(view, state)
    state.regex = not state.regex
    refresh_matches(view, state, { from_origin = true, scroll = true })
    core.redraw = true
  end,
})

command.add(active_visible_find_state, {
  ["user:find-close"] = function(view, state)
    close_find(view, state, true)
  end,
})

local function prioritize_key(stroke, cmd)
  keymap.unbind(stroke, cmd)
  local list = keymap.map[stroke] or {}
  table.insert(list, 1, cmd)
  keymap.map[stroke] = list
  keymap.reverse_map[cmd] = keymap.reverse_map[cmd] or {}
  table.insert(keymap.reverse_map[cmd], stroke)
end

local function install_find_shortcut_override()
  if config.plugins.search_ui then
    config.plugins.search_ui.replace_core_find = false
  end

  keymap.add_direct {
    ["ctrl+f"] = "find-replace:find",
    ["ctrl+r"] = "find-replace:replace",
  }

  keymap.add {
    ["up"] = { "user:find-field-previous", "command:select-previous", "doc:move-to-previous-line" },
    ["down"] = { "user:find-field-next", "command:select-next", "doc:move-to-next-line" },
    ["shift+up"] = { "user:find-field-add-previous", "doc:select-to-previous-line" },
    ["shift+down"] = { "user:find-field-add-next", "doc:select-to-next-line" },
    ["tab"] = { "user:find-toggle-replace-field", "command:complete", "doc:indent" },
    ["return"] = { "user:find-submit-or-replace", "command:submit", "doc:newline", "dialog:select" },
    ["keypad enter"] = { "user:find-submit-or-replace", "command:submit", "doc:newline", "dialog:select" },
    ["ctrl+return"] = { "user:find-replace-all-confirm", "doc:newline-below" },
  }

  prioritize_key("escape", "user:find-close")
  prioritize_key("tab", "user:find-toggle-replace-field")
  prioritize_key("return", "user:find-submit-or-replace")
  prioritize_key("keypad enter", "user:find-submit-or-replace")
  prioritize_key("ctrl+return", "user:find-replace-all-confirm")
end

core.intellij_find_install_shortcut_override = install_find_shortcut_override
install_find_shortcut_override()
core.add_thread(function()
  coroutine.yield(0.1)
  install_docview_patches()
  install_find_shortcut_override()
end)
