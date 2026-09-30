-- mod-version:3
-- View-local in-file find/replace overlay.
--
-- This intentionally does not use the core.global_prompt_bar instance: find is
-- editor-local UI.  It does share the prompt bar renderer so local find looks
-- like Anvil's other prompt bars instead of carrying custom chrome.
-- Each TextView owns its own find state, so two splits of the same Buffer can keep
-- independent queries, current match, highlights, and visible input bars.

local core = require "core"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local prompt_bar_renderer = require "core.prompt_bar_renderer"
local common = require "core.common"
local file_context = require "core.file_context"
local panes = require "core.panes"
local navigation_history = require "core.navigation_history"
local translate = require "core.buffer.translate"
local Buffer = require "core.buffer"
local Highlighter = require "core.buffer.highlighter"
local TextView = require "core.textview"
local GlobalPromptBar = require "core.global_prompt_bar"
local MessageBox = require "widget.messagebox"
local find_overview = require "plugins.intellij_find.overview"
local find_scanner = require "core.local_find_scan"
local worker_pool = require "core.worker_pool"
local line_search = require "line_search"

local find_state_by_view = setmetatable({}, { __mode = "k" })
local last_global_query = ""
local update_after_input
local FIND_NAV_VISIBLE_MARGIN_LINES = 4
local SCAN_SLICE_SECONDS = .002
local SCAN_SLICE_MAX_STEPS = 8192

local SingleLineHighlighter = Highlighter:extend()
function SingleLineHighlighter:get_line(idx)
  return { text = self.buffer.lines[1], tokens = { "normal", self.buffer.lines[1] } }
end
function SingleLineHighlighter:start() end

local SingleLineBuffer = Buffer:extend()
function SingleLineBuffer:reset()
  SingleLineBuffer.super.reset(self)
  self.highlighter = SingleLineHighlighter(self)
  self:reset_syntax()
end
function SingleLineBuffer:normalize_edit_text(text, edit, opts)
  return tostring(text or ""):gsub("[\r\n]", "")
end

function SingleLineBuffer:insert(line, col, text)
  SingleLineBuffer.super.insert(self, line, col, self:normalize_edit_text(text))
end

local LocalFindInputView = TextView:extend()
function LocalFindInputView:__tostring() return "LocalFindInputView" end

function LocalFindInputView:new(state, field_name)
  LocalFindInputView.super.new(self, SingleLineBuffer())
  self.local_find_input = true
  self.local_find_state = state
  self.local_find_field = field_name
  self.scrollable = false
  self.hide_scrollbars = true
  self.font = "font"
  self.label = ""
  self.gutter_width = 0
  self.gutter_text_brightness = 0
  self.size.y = 0

  local input = self
  function self.buffer:on_text_change(...)
    input:on_buffer_text_change()
  end
end

function LocalFindInputView:on_buffer_text_change()
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
  return self.buffer:get_text(1, 1, 1, math.huge)
end

function LocalFindInputView:set_text(text, select)
  self.buffer:remove(1, 1, math.huge, math.huge)
  self.buffer:text_input(text or "")
  if select then
    self.buffer:set_selection(math.huge, math.huge, 1, 1)
  else
    self.buffer:set_selection(1, math.huge, 1, math.huge)
  end
end

function LocalFindInputView:select_all()
  self.buffer:set_selection(math.huge, math.huge, 1, 1)
end

function LocalFindInputView:move_to_end()
  self.buffer:set_selection(1, math.huge, 1, math.huge)
end

function LocalFindInputView:get_gutter_width()
  return self.gutter_width or 0, 0
end

function LocalFindInputView:get_line_height()
  return prompt_bar_renderer.line_height(self:get_font())
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
  local x = LocalFindInputView.super.get_line_screen_position(self, 1, col)
  local _, y = self:get_content_offset()
  return x, prompt_bar_renderer.line_y(y, self.size.y, self:get_font())
end

function LocalFindInputView:draw_line_gutter(idx, x, y)
  local pos = self.position
  prompt_bar_renderer.draw_label(
    self:get_font(),
    self.label,
    pos.x,
    pos.y,
    self:get_gutter_width(),
    self.size.y,
    self.gutter_text_brightness
  )
  return self:get_line_height()
end

function LocalFindInputView:draw_overlay()
  if core.active_view == self then
    LocalFindInputView.super.draw_overlay(self)
  end
end

function LocalFindInputView:draw()
  LocalFindInputView.super.draw(self)
end

local function field_text(field)
  return field and field:get_text() or ""
end

local function is_searchable_textview(view)
  return view and view.extends and view:extends(TextView)
    and not view:is(GlobalPromptBar)
    and not view.local_find_input
    and view.buffer
end

local function active_textview()
  local view = core.active_view
  if view and view.local_find_input then
    local owner = view.local_find_state and view.local_find_state.owner_view
    if is_searchable_textview(owner) then return true, owner end
  end
  if is_searchable_textview(view) then return true, view end
  return false
end

local function copy_selection(view)
  return view:with_selection_state(function()
    return { view.buffer:get_selection() }
  end)
end

local function set_selection(view, sel)
  if not view or not view.buffer or not sel then return end
  return view:with_selection_state(function()
    view.buffer:set_selection(table.unpack(sel))
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
    file_context.exclude_content_view(state.find)
    file_context.exclude_content_view(state.replace)
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
  if panes.pane_for_view(view) then panes.register_focus_target(view, field) end
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
  local ok, view = active_textview()
  if not ok then return false end
  local state = find_state_by_view[view]
  if state and state.visible and state.input_active then return true, view, state end
  return false
end

local function active_visible_find_state()
  local ok, view = active_textview()
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

local function find_all_matches(buffer, state, ranges, checkpoint, external_line, reveal)
  local query = field_text(state.find)
  if not buffer or query == "" then return {}, nil end

  local matches, by_line = {}, {}
  local search, err = find_scanner.compile(query, state.regex, state.case_sensitive)
  if not search then return {}, err end

  if not ranges then
    local index = line_search.begin(buffer.lines)
    local pending = state.pending
    local caret_line, caret_col = pending.start_line, pending.start_col
    local nearest_reported = false
    for _, range in ipairs { { caret_line, #buffer.lines }, { 1, caret_line - 1 } } do
      local next_line = range[1]
      while next_line <= range[2] do
        local long_line, nearest
        next_line, long_line, nearest = index:advance(buffer.lines, search.query, search.compiled,
          state.case_sensitive, next_line, .006, 65536, range[2], caret_line, caret_col,
          reveal and #buffer.lines >= 8192 and not nearest_reported)
        if nearest and reveal then nearest_reported = true; reveal(nearest) end
        if long_line then
          local line = next_line
          external_line(buffer.lines[line], nil, function(batch)
            index:add_ranges(line, batch)
            if reveal then
              for i = 1, #batch, 2 do
                if line ~= caret_line or batch[i] >= caret_col then
                  nearest_reported = true
                  reveal { line = line, col1 = batch[i], col2 = batch[i + 1] }
                  break
                end
              end
            end
          end)
          next_line = next_line + 1
        end
        if next_line <= range[2] and checkpoint then checkpoint(true) end
      end
    end
    index:finish()
    return index
  end

  local current_line
  local function emit(first, last)
    matches[#matches + 1] = { line = current_line, col1 = first, col2 = last }
    local indexes = by_line[current_line] or {}
    by_line[current_line] = indexes
    indexes[#indexes + 1] = #matches
  end
  local function scan_line(line_nr)
    current_line = line_nr
    local line_text = buffer.lines[line_nr]
    if external_line and #line_text > 65536 then
      external_line(line_text, emit)
    else
      find_scanner.line(line_text, search, emit, checkpoint)
    end
  end

  if ranges then
    for _, range in ipairs(ranges) do
      for line = range.new_line1, math.min(#buffer.lines, range.new_line2) do scan_line(line) end
    end
  else
    for line = 1, #buffer.lines do scan_line(line) end
  end

  return matches, nil, by_line
end

local function same_query(state)
  return state.match_query == field_text(state.find)
    and state.match_regex == state.regex
    and state.match_case_sensitive == state.case_sensitive
end

local function matches_are_current(buffer, state)
  return state.match_buffer == buffer and state.match_revision == buffer.text_revision and same_query(state)
end

local function remember_matches(buffer, state, indexes)
  state.match_buffer = buffer
  state.match_revision = buffer.text_revision
  state.match_query = field_text(state.find)
  state.match_regex = state.regex
  state.match_case_sensitive = state.case_sensitive
  if type(state.matches) == "userdata" then
    state.match_index = state.matches
    -- Small searches keep their inspectable result table. Large searches stay
    -- packed in C; rendering and navigation materialize only requested ranges.
    if #state.match_index <= 65536 then
      local matches = {}
      for i = 1, #state.match_index do matches[i] = state.match_index[i] end
      state.matches = matches
    end
    state.match_indexes_by_line = setmetatable({}, { __index = function(_, line)
      local first, last = state.match_index:line_range(line)
      if not first or last < first then return end
      local result = {}
      for i = first, last do result[#result + 1] = i end
      return result
    end })
  else
    state.match_index = nil
    state.match_indexes_by_line = indexes or build_match_indexes_by_line(state.matches)
  end
  state.match_set_revision = (state.match_set_revision or 0) + 1
end

Buffer.register_text_transaction_handler("local-find", function(buffer, transaction)
  if not transaction or not transaction.changed then return end
  for view, state in pairs(find_state_by_view) do
    if state.visible and view.buffer == buffer then
      -- A transaction uses old and new line coordinates. Merge touching ranges
      -- so several edits on one line cause only one search of that line.
      local ranges = {}
      for _, change in ipairs(transaction.changed_ranges or {}) do
        local last = ranges[#ranges]
        if last and change.old_line1 <= last.old_line2 + 1 then
          last.old_line2 = math.max(last.old_line2, change.old_line2)
          last.new_line2 = math.max(last.new_line2, change.new_line2)
        else
          ranges[#ranges + 1] = {
            old_line1 = change.old_line1, old_line2 = change.old_line2,
            new_line1 = change.new_line1, new_line2 = change.new_line2,
          }
        end
      end
      if #ranges > 0 and state.match_buffer == buffer and same_query(state)
          and state.match_revision == buffer.text_revision - 1 then
        local long_line = false
        for _, range in ipairs(ranges) do
          for line = range.new_line1, range.new_line2 do
            if #buffer.lines[line] > 65536 then long_line = true; break end
          end
          if long_line then break end
        end
        if state.match_index and long_line then
          state.match_revision = nil
          core.log_quiet("Local find: deferred long-line edit scan in %s", buffer:get_name())
        elseif state.match_index then
          local search, err = find_scanner.compile(field_text(state.find), state.regex, state.case_sensitive)
          if search then
            local shift = 0
            for _, range in ipairs(ranges) do
              state.match_index:replace(buffer.lines, search.query, search.compiled, state.case_sensitive,
                range.old_line1 + shift, range.old_line2 + shift, range.new_line1, range.new_line2)
              shift = range.new_line2 - range.old_line2
            end
            state.matches, state.match_error = state.match_index, nil
            remember_matches(buffer, state)
          else
            state.match_revision, state.match_error = nil, err
          end
        else
        local added, err = find_all_matches(buffer, state, ranges)
        local matches, old, index, added_index, shift = {}, state.matches, 1, 1, 0
        local function retain(match)
          matches[#matches + 1] = shift == 0 and match or {
            line = match.line + shift, col1 = match.col1, col2 = match.col2,
          }
        end
        for _, range in ipairs(ranges) do
          while old[index] and old[index].line < range.old_line1 do
            retain(old[index])
            index = index + 1
          end
          while old[index] and old[index].line <= range.old_line2 do index = index + 1 end
          while added[added_index] and added[added_index].line <= range.new_line2 do
            matches[#matches + 1] = added[added_index]
            added_index = added_index + 1
          end
          shift = range.new_line2 - range.old_line2
        end
        while old[index] do
          retain(old[index])
          index = index + 1
        end
        state.matches, state.match_error = matches, err
        remember_matches(buffer, state)
        end
      else
        state.match_revision = nil
        core.log_quiet("Local find: invalidated matches for %s after %s",
          buffer:get_name(), transaction.type or "change")
      end
      -- Refresh the current match and status even when undo history did not change.
      state.change_id = -1
    end
  end
end)

local function selection_match_index(view, matches)
  local l1, c1, l2, c2 = table.unpack(view:with_selection_state(function()
    return { view.buffer:get_selection(true) }
  end))
  local lo, hi = 1, #matches + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    local match = matches[mid]
    if match.line < l1 or (match.line == l1 and match.col1 < c1) then
      lo = mid + 1
    else hi = mid end
  end
  local match = matches[lo]
  if match then
    if match.line == l1 and match.line == l2 and match.col1 == c1 and match.col2 == c2 then
      return lo
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
  local lo, hi = 1, #matches + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    local match = matches[mid]
    if compare_pos(match.line, match.col1, line, col) < 0 then lo = mid + 1
    else hi = mid end
  end
  return lo <= #matches and lo or 1
end

local function choose_match(view, state, reverse, from_origin)
  local matches = state.matches or {}
  if #matches == 0 then return 0 end

  if from_origin then
    local line, col = selection_search_start(state.origin or copy_selection(view))
    return choose_match_from_position(matches, line, col)
  end

  local l1, c1, l2, c2 = table.unpack(view:with_selection_state(function()
    return { view.buffer:get_selection(true) }
  end))
  local line, col = reverse and l1 or l2, reverse and c1 or c2

  local lo, hi = 1, #matches + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    local match = matches[mid]
    local cmp = compare_pos(match.line, reverse and match.col1 or match.col2, line, col)
    if reverse and cmp < 0 or not reverse and cmp <= 0 then lo = mid + 1
    else hi = mid end
  end
  if reverse then return lo > 1 and lo - 1 or #matches end
  return lo <= #matches and lo or 1
end

local function set_status(state)
  if state.pending then
    state.info = "Searching…"
    state.error = false
  elseif field_text(state.find) == "" then
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

local function select_match_without_history(view, state, index, scroll)
  local match = state.matches and state.matches[index]
  state.current = match and index or 0
  if not match then return false end
  view:with_selection_state(function()
    if view.expand_folds_covering_range then
      view:expand_folds_covering_range(match.line, match.col1, match.line, match.col2, "local-find")
    end
    view.buffer:set_selection(match.line, match.col2, match.line, match.col1)
  end)
  if scroll ~= false then
    -- Match navigation should behave like the built-in find command: only move
    -- the vertical camera if the match is outside the padded visible range.  The
    -- bottom padding keeps matches clear of the find bar overlay, and horizontal
    -- range reveal is handled separately so long-line matches stay visible.
    view:scroll_to_line(match.line, true, false, { visible_margin_lines = FIND_NAV_VISIBLE_MARGIN_LINES })
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

local function select_match(view, state, index, scroll, explicit)
  return navigation_history.perform_jump_with_options(view, {
    record_nearby = explicit == true,
    departure = { no_merge = true }, destination = { no_merge = true },
  }, function()
    return select_match_without_history(view, state, index, scroll)
  end)
end

local refresh_matches
local function cancel_scan(state)
  local scan = state.pending
  local pool = worker_pool.current_system()
  if scan and scan.job and pool then pool:cancel(scan.job) end
  state.pending = nil
end

local function advance_scan(view, state)
  local scan = state.pending
  if not scan then return end
  local selection = copy_selection(view)
  for i = 1, 4 do
    if selection[i] ~= scan.selection[i] then
      -- A later caret move takes priority over a pending search reveal.
      scan.opts.select, scan.opts.after_scan = false, nil
      scan.actions = {}
      break
    end
  end
  if scan.buffer ~= view.buffer or scan.revision ~= view.buffer.text_revision
      or scan.query ~= field_text(state.find) or scan.regex ~= state.regex
      or scan.case_sensitive ~= state.case_sensitive then
    cancel_scan(state)
    state.current = scan.current
    refresh_matches(view, state, scan.opts)
    if state.pending then
      state.pending.actions = scan.actions
    else
      for _, action in ipairs(scan.actions) do action() end
    end
    return
  end
  scan.deadline = system.get_time() + SCAN_SLICE_SECONDS
  local ok, matches, err, indexes = coroutine.resume(scan.thread)
  if not ok then
    cancel_scan(state)
    state.matches, state.match_error = {}, tostring(matches)
    remember_matches(view.buffer, state, {})
    refresh_matches(view, state, scan.opts)
    core.log_quiet("Local find: scan failed in %s: %s", view.buffer:get_name(), tostring(matches))
    return
  end
  if coroutine.status(scan.thread) ~= "dead" then
    set_status(state)
    core.redraw = true
    return
  end
  state.pending = nil
  state.current = scan.current
  state.matches, state.match_error = matches, err
  remember_matches(view.buffer, state, indexes)
  refresh_matches(view, state, scan.opts)
  if scan.opts.after_scan then scan.opts.after_scan() end
  for _, action in ipairs(scan.actions) do action() end
  core.log_quiet("Local find: searched %d lines in %s", #view.buffer.lines, view.buffer:get_name())
  core.redraw = true
end

refresh_matches = function(view, state, opts)
  opts = opts or {}
  if not matches_are_current(view.buffer, state) then
    local pending = state.pending
    if pending and pending.buffer == view.buffer
        and pending.revision == view.buffer.text_revision
        and pending.query == field_text(state.find) and pending.regex == state.regex
        and pending.case_sensitive == state.case_sensitive then return end
    cancel_scan(state)
    local scan = { buffer = view.buffer, revision = view.buffer.text_revision,
      query = field_text(state.find), regex = state.regex,
      case_sensitive = state.case_sensitive, opts = opts, actions = {}, current = state.current,
      selection = copy_selection(view) }
    scan.start_line, scan.start_col = selection_search_start(opts.early_origin or state.origin or scan.selection)
    state.pending = scan
    state.match_revision = nil
    state.matches, state.match_indexes_by_line = {}, {}
    state.current, state.found, state.error = 0, false, false
    scan.thread = coroutine.create(function()
      if #scan.buffer.lines >= 8192 or #scan.buffer.lines[1] > 65536 then
        coroutine.yield()
      end
      local work = 0
      return find_all_matches(scan.buffer, state, nil, function(force)
        work = work + 1
        if force or work % 32 == 0 and (work >= SCAN_SLICE_MAX_STEPS or system.get_time() >= scan.deadline) then
          work = 0
          coroutine.yield()
        end
      end, function(text, emit, emit_batch)
        -- A native find or lowercase call cannot yield inside a long line.
        -- Copy that immutable line to a worker and receive bounded batches.
        local done, failure
        scan.job = assert(worker_pool.system():submit {
          kind = "local_find_line", priority = "interactive",
          payload = { text = text, query = scan.query, regex = scan.regex,
            case_sensitive = scan.case_sensitive },
          is_stale = function()
            return state.pending ~= scan or view.buffer ~= scan.buffer
              or scan.buffer.text_revision ~= scan.revision
              or field_text(state.find) ~= scan.query or state.regex ~= scan.regex
              or state.case_sensitive ~= scan.case_sensitive
          end,
          on_result = function(message)
            local batch = message.payload
            if emit_batch then emit_batch(batch)
            else for i = 1, #batch, 2 do emit(batch[i], batch[i + 1]) end end
          end,
          on_complete = function() done = true end,
          on_error = function(message) failure, done = message.error, true end,
          on_cancelled = function() failure, done = "Find scan cancelled", true end,
        })
        repeat coroutine.yield() until done
        scan.job = nil
        if failure then error(failure) end
      end, function(match)
        if scan.revealed or #scan.buffer.lines < 8192
            or opts.select == false and not opts.after_scan then return end
        scan.revealed = true
        state.matches = { match }
        state.match_indexes_by_line = { [match.line] = { 1 } }
        select_match(view, state, 1, opts.scroll)
        scan.selection = copy_selection(view)
      end)
    end)
    advance_scan(view, state)
    return
  end
  state.error = state.match_error
  state.change_id = view.buffer:get_change_id()

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

  local function after_scan()
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
  end
  local current = matches_are_current(view.buffer, state)
  refresh_matches(view, state, { select = false, scroll = true, after_scan = after_scan, early_origin = origin })
  if current then after_scan() end

  last_global_query = field_text(state.find)
  core.redraw = true
end

local function single_line_selection_text(view)
  local text = view:with_selection_state(function()
    local l1, c1, l2, c2 = view.buffer:get_selection(true)
    if l1 ~= l2 or c1 == c2 then return "" end
    return view.buffer:get_text(l1, c1, l2, c2)
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
  core.log_quiet("Local find: opened %s overlay for %s", state.mode, view.buffer.filename or "<untitled>")
  core.redraw = true
end

local function close_find(view, state, hide)
  state = state or find_state_by_view[view]
  if not state then return end
  state.input_active = false
  if hide then
    cancel_scan(state)
    state.visible = false
    state.matches = {}
    state.match_indexes_by_line = {}
    state.current = 0
    state.match_revision = nil
  end
  if core.active_view and core.active_view.local_find_input and view then
    core.set_active_view(view)
  end
  core.log_quiet("Local find: %s overlay for %s", hide and "closed" or "deactivated", view and view.buffer and (view.buffer.filename or "<untitled>") or "<no buffer>")
  core.redraw = true
end

local core_set_active_view_for_find = core.intellij_find_base_set_active_view or core.set_active_view
core.intellij_find_base_set_active_view = core_set_active_view_for_find
function core.set_active_view(view, focus_context)
  focus_context = focus_context or core.focus_change_context(2)
  local previous = core.active_view
  local previous_state = previous and previous.local_find_input and previous.local_find_state
  local result = core_set_active_view_for_find(view, focus_context)
  local next = core.active_view
  local next_state = next and next.local_find_input and next.local_find_state
  if next_state and next_state.visible then
    next_state.input_active = true
    next_state.focus = next.local_find_field
  end
  if previous_state and previous_state.visible and next ~= previous then
    if next_state ~= previous_state then
      previous_state.input_active = false
      -- Focus can leave the input without closing search or clearing matches.
      core.log_quiet("Local find: input lost focus; search remains open")
      core.redraw = true
    end
  end
  return result
end

local function navigate(view, state, reverse)
  if not state or field_text(state.find) == "" then return end
  if state.change_id ~= view.buffer:get_change_id() or not matches_are_current(view.buffer, state) then
    refresh_matches(view, state, { scroll = false })
  end
  if state.pending then
    table.insert(state.pending.actions, function() navigate(view, state, reverse) end)
    return
  end
  if #(state.matches or {}) == 0 then
    state.current = 0
    set_status(state)
    core.error("Couldn't find %q", field_text(state.find))
    return
  end
  local index = choose_match(view, state, reverse, false)
  select_match(view, state, index, true, true)
  core.redraw = true
end

local function add_match_to_selection(view, state, reverse)
  if not state or field_text(state.find) == "" then return end
  if state.change_id ~= view.buffer:get_change_id() or not matches_are_current(view.buffer, state) then
    refresh_matches(view, state, { scroll = false })
  end
  if state.pending then
    table.insert(state.pending.actions, function() add_match_to_selection(view, state, reverse) end)
    return
  end
  local index = choose_match(view, state, reverse, false)
  local match = state.matches and state.matches[index]
  if not match then return end
  view:with_selection_state(function()
    local existing
    for idx, l1, c1, l2, c2 in view.buffer:get_selections(true, true) do
      if l1 == match.line and l2 == match.line and c1 == match.col1 and c2 == match.col2 then
        existing = idx
        break
      end
    end
    if existing then
      view.buffer.last_selection = existing
    else
      view.buffer:add_selection(match.line, match.col2, match.line, match.col1)
    end
  end)
  state.current = index
  set_status(state)
  view:scroll_to_line(match.line, true, false, { visible_margin_lines = FIND_NAV_VISIBLE_MARGIN_LINES })
  core.redraw = true
end

local function replace_current_match(view, state)
  if not state or field_text(state.find) == "" then return end
  if state.change_id ~= view.buffer:get_change_id() or not matches_are_current(view.buffer, state) then
    refresh_matches(view, state, { scroll = false })
  end

  if state.pending then
    table.insert(state.pending.actions, function() replace_current_match(view, state) end)
    return
  end
  local replaced = false
  view:with_selection_state(function()
    local d = view.buffer
    local l1, c1, l2, c2 = d:get_selection(true)
    local match = state.matches and state.matches[state.current]
    if not (match and match.line == l1 and match.line == l2 and match.col1 == c1 and match.col2 == c2) then
      match = nil
      for i = 1, #state.matches do
        local candidate = state.matches[i]
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
    local d = view.buffer
    local edits = {}
    for i = 1, #matches do
      local match = matches[i]
      edits[#edits + 1] = {
        line1 = match.line,
        col1 = match.col1,
        line2 = match.line,
        col2 = match.col2,
        text = replacement or "",
      }
    end
    d:apply_edits(edits, {
      type = "replace",
      last_selection = d.last_selection,
      merge_cursors = false,
    })
  end)
  state.origin = copy_selection(view)
  refresh_matches(view, state, { from_origin = true, scroll = true })
end

local function confirm_replace_all(view, state)
  if not state or field_text(state.find) == "" then return end
  refresh_matches(view, state, { scroll = false })
  if state.pending then
    table.insert(state.pending.actions, function() confirm_replace_all(view, state) end)
    return
  end
  local matches = {}
  for i = 1, #state.matches do
    local match = state.matches[i]
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
  local h = prompt_bar_renderer.height(font)
  return {
    x = view.position.x,
    y = view.position.y + view.size.y - h,
    w = view.size.x,
    h = h,
    pad = style.padding.x,
    sep = math.max(style.padding.x, style.divider_size or SCALE),
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

local function make_field_row(layout, label, x, w)
  local label_w = prompt_bar_renderer.label_width(label, layout.font)
  w = math.max(label_w + 1, w)
  return {
    label = label,
    label_w = label_w,
    x = x,
    y = layout.y,
    w = w,
    h = layout.h,
    input_x = x + label_w,
    input_w = math.max(1, w - label_w),
    input_h = layout.h,
    font = layout.font,
  }
end

local function find_bar_rows(layout, state, info_text)
  local font, pad, sep = layout.font, layout.pad, layout.sep
  local right = layout.x + layout.w
  -- Reserve the complete results slot independently of its current text.
  -- The text can change from empty, to an error, to a match count without
  -- changing the geometry of either input field.
  -- Keep this compact so the reserved area does not leave a large gap before
  -- the result count. Longer status text is clipped within the same stable
  -- slot rather than moving the input fields.
  local info_slot_w = 130 * SCALE
  info_slot_w = math.min(info_slot_w, math.max(0, layout.w - pad))
  local info_slot_x = right - pad - info_slot_w
  local info_x = info_slot_x + sep + pad
  local info_w = math.max(0, right - pad - info_x)
  local info = {
    text = info_text,
    x = info_x,
    w = info_w,
    separator_x = info_slot_x,
  }
  local field_right = math.max(layout.x, info_slot_x - pad)
  local find_label = "Find: "
  local replace_label = "Replace: "

  if state.mode == "replace" then
    local available = math.max(0, field_right - layout.x)
    local find_label_w = prompt_bar_renderer.label_width(find_label, font)
    local replace_label_w = prompt_bar_renderer.label_width(replace_label, font)
    local gap = available >= find_label_w + replace_label_w + sep and sep or 0
    local usable = math.max(0, available - gap - find_label_w - replace_label_w)
    local find_input_w = math.floor(usable * 0.48)
    local replace_input_w = usable - find_input_w
    local find_w = find_label_w + find_input_w
    local replace_w = replace_label_w + replace_input_w
    local find_row = make_field_row(layout, find_label, layout.x, find_w)
    local replace_row = make_field_row(layout, replace_label, layout.x + find_w + gap, replace_w)
    replace_row.separator_x = gap > 0 and replace_row.x - gap or nil
    return find_row, replace_row, info
  end

  local find_row = make_field_row(layout, find_label, layout.x, math.max(0, field_right - layout.x))
  return find_row, nil, info
end

local function apply_field_row(field, row)
  field.label = row.label
  field.gutter_width = row.label_w
  field.position.x = row.x
  field.position.y = row.y
  field.size.x = math.max(1, row.w)
  field.size.y = math.max(1, row.h)
end

local function layout_find_fields(view, state)
  local layout = find_bar_layout(view, state)
  local find_row, replace_row, info = find_bar_rows(layout, state, find_info_text(state))
  apply_field_row(state.find, find_row)
  if replace_row then apply_field_row(state.replace, replace_row) end
  return layout, find_row, replace_row, info
end

local function update_find_input_fields(view, state)
  local _, _, replace_row = layout_find_fields(view, state)
  state.find:update()
  if replace_row then state.replace:update() end
end

local function draw_input_field(field)
  core.push_clip_rect(field.position.x, field.position.y, field.size.x, field.size.y)
  field:draw()
  core.pop_clip_rect()
end

local function draw_local_find(view)
  local state = visible_find_state(view)
  if not state then return end
  local layout, find_row, replace_row, info = layout_find_fields(view, state)
  prompt_bar_renderer.draw_background(layout.x, layout.y, layout.w, layout.h)

  draw_input_field(state.find)

  if replace_row then
    draw_input_field(state.replace)
    if replace_row.separator_x then
      prompt_bar_renderer.draw_vertical_divider(
        replace_row.separator_x,
        layout.y,
        layout.h
      )
    end
  end

  if info and info.text ~= "" and info.w > 0 then
    local color = state.error and style.error or style.dim
    prompt_bar_renderer.draw_info(
      layout.font,
      info.text,
      info.x,
      layout.y,
      info.w,
      layout.h,
      color
    )
    prompt_bar_renderer.draw_vertical_divider(info.separator_x, layout.y, layout.h)
  end

  prompt_bar_renderer.draw_top_divider(layout.x, layout.y, layout.w)
end

local function point_in_rect(x, y, r)
  return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

local function point_in_field(x, y, row)
  return row and x >= row.x and x <= row.x + row.w and y >= row.y and y <= row.y + row.h
end

local function handle_find_mouse_pressed(view, state, x, y, clicks)
  local layout, find_row, replace_row = layout_find_fields(view, state)
  if not point_in_rect(x, y, layout) then return false end
  local target_field, target_name = state.find, "find"
  if replace_row and point_in_field(x, y, replace_row) then
    target_field, target_name = state.replace, "replace"
  end
  focus_field(view, state, target_name)

  local line, col = target_field:resolve_screen_position(x, y)
  if keymap.modkeys["shift"] then
    local l1, c1 = target_field.buffer:get_selection()
    target_field.buffer:set_selection(l1, c1, line, col)
  else
    target_field.buffer:set_selection(line, col, line, col)
  end
  if clicks == 2 then
    local line1, col1 = translate.start_of_word(target_field.buffer, line, col)
    local line2, col2 = translate.end_of_word(target_field.buffer, line1, col1)
    target_field.buffer:set_selection(line2, col2, line1, col1)
  elseif clicks == 3 then
    target_field:select_all()
  end
  core.blink_reset()
  core.redraw = true
  return true
end

-- Draw per-view find highlights. These are intentionally keyed by TextView, not
-- Buffer, so the same Buffer open in two splits can show independent search state.
--
-- Some plugins replace TextView draw/update methods after this module is first
-- required from anvil_defaults.  Install these as re-wrappable shims and run
-- the installer again after startup so local find is still outermost and
-- split-local even when later plugins patch TextView.  Each
-- shim captures its base function in an upvalue; do not read the base through a
-- mutable TextView field from inside the shim, because later wrappers may have
-- captured an older shim and would recurse when we re-wrap them.
local textview_draw_line_body_wrapper
local textview_draw_wrapper
local textview_draw_scrollbar_wrapper
local textview_update_wrapper
local textview_on_mouse_pressed_wrapper

local function draw_find_overview(view)
  local state = visible_find_state(view)
  if not state then return end
  find_overview.draw(view, state)
end

local sync_scrollbar_geometry = TextView.sync_scrollbar_geometry
function TextView:sync_scrollbar_geometry()
  sync_scrollbar_geometry(self)
  local state = visible_find_state(self)
  if state then find_overview.update(self, state) end
end

local textview_surface_focus_targets = TextView.get_surface_focus_targets
function TextView:get_surface_focus_targets()
  local targets = textview_surface_focus_targets(self)
  local state = visible_find_state(self)
  if not state then return targets end
  local result = {}
  for _, target in ipairs(targets or { self }) do result[#result + 1] = target end
  if #result == 0 then result[1] = self end
  result[#result + 1] = state.find
  if state.mode == "replace" then result[#result + 1] = state.replace end
  return result
end

local function make_local_find_draw_scrollbar(base)
  return function(self, ...)
    if (TextView.__local_find_draw_scrollbar_depth or 0) > 0 then
      return base(self, ...)
    end
    local old_depth = TextView.__local_find_draw_scrollbar_depth or 0
    TextView.__local_find_draw_scrollbar_depth = old_depth + 1
    local result = base(self, ...)
    draw_find_overview(self)
    TextView.__local_find_draw_scrollbar_depth = old_depth
    return result
  end
end

local function make_local_find_draw_line_body(base)
  return function(self, line, x, y)
    if (TextView.__local_find_draw_line_body_depth or 0) > 0 then
      return base(self, line, x, y)
    end

    local old_depth = TextView.__local_find_draw_line_body_depth or 0
    TextView.__local_find_draw_line_body_depth = old_depth + 1

    local state = visible_find_state(self)
    local line_matches = state and state.match_indexes_by_line and state.match_indexes_by_line[line]
    local rectangles = line_matches and {}
    if line_matches and #line_matches > 0 then
      for position, idx in ipairs(line_matches) do
        local match = state.matches[idx]
        rectangles[position] = {}
        self:draw_search_match_background(match.line, match.col1, match.col2, idx == state.current, rectangles[position])
      end
    end

    local old_local_find_active = self.local_find_active
    local old_show_current_line_highlight = self.show_current_line_highlight
    self.local_find_active = state ~= nil
    if state then self.show_current_line_highlight = false end
    local lh = base(self, line, x, y)
    self.local_find_active = old_local_find_active
    self.show_current_line_highlight = old_show_current_line_highlight

    if line_matches and #line_matches > 0 then
      for position, idx in ipairs(line_matches) do
        local match = state.matches[idx]
        self:draw_search_match_outline(match.line, match.col1, match.col2, idx == state.current, rectangles[position])
      end
    end

    TextView.__local_find_draw_line_body_depth = old_depth
    return lh
  end
end

local function make_local_find_draw(base)
  return function(self, ...)
    if (TextView.__local_find_draw_depth or 0) > 0 then
      return base(self, ...)
    end

    local old_depth = TextView.__local_find_draw_depth or 0
    TextView.__local_find_draw_depth = old_depth + 1
    local state = visible_find_state(self)
    local old_local_find_active = self.local_find_active
    local old_show_current_line_highlight = self.show_current_line_highlight
    self.local_find_active = state ~= nil
    if state then self.show_current_line_highlight = false end
    local result = base(self, ...)
    self.local_find_active = old_local_find_active
    self.show_current_line_highlight = old_show_current_line_highlight
    if result ~= false then
      core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
      draw_local_find(self)
      core.pop_clip_rect()
    end
    TextView.__local_find_draw_depth = old_depth
    return result
  end
end

local function make_local_find_update(base)
  return function(self, ...)
    if (TextView.__local_find_update_depth or 0) > 0 then
      return base(self, ...)
    end

    local old_depth = TextView.__local_find_update_depth or 0
    TextView.__local_find_update_depth = old_depth + 1
    local state = visible_find_state(self)
    if state then
      update_find_input_fields(self, state)
      if state.pending then
        advance_scan(self, state)
      elseif state.change_id ~= self.buffer:get_change_id() or not matches_are_current(self.buffer, state) then
        refresh_matches(self, state, {
          scroll = false,
          restore_origin = false,
          select = state.input_active and core.active_view == self,
        })
      end
    end
    local result = base(self, ...)
    if state then find_overview.update(self, state) end
    TextView.__local_find_update_depth = old_depth
    return result
  end
end

local function make_local_find_on_mouse_pressed(base)
  return function(self, button, x, y, clicks)
    if (TextView.__local_find_on_mouse_pressed_depth or 0) > 0 then
      return base(self, button, x, y, clicks)
    end

    local state = find_state_by_view[self]
    if button == "left" and state and state.visible then
      if handle_find_mouse_pressed(self, state, x, y, clicks) then return true end
      state.input_active = false
    end

    local old_depth = TextView.__local_find_on_mouse_pressed_depth or 0
    TextView.__local_find_on_mouse_pressed_depth = old_depth + 1
    local result = base(self, button, x, y, clicks)
    TextView.__local_find_on_mouse_pressed_depth = old_depth
    return result
  end
end

local function patch_textview_method(name, wrapper_field, base_field, current_wrapper, make_wrapper)
  if TextView[name] == current_wrapper then return current_wrapper end

  local base = TextView[name]
  if TextView[wrapper_field] and base == TextView[wrapper_field] then
    base = TextView[base_field]
  end

  local wrapper = make_wrapper(base)
  TextView[base_field] = base
  TextView[wrapper_field] = wrapper
  TextView[name] = wrapper
  core.log_quiet("Local find: patched TextView.%s", name)
  return wrapper
end

local function install_textview_patches()
  textview_draw_scrollbar_wrapper = patch_textview_method(
    "draw_scrollbar",
    "__local_find_draw_scrollbar_wrapper",
    "__local_find_draw_scrollbar_base",
    textview_draw_scrollbar_wrapper,
    make_local_find_draw_scrollbar
  )
  textview_draw_line_body_wrapper = patch_textview_method(
    "draw_line_body",
    "__local_find_draw_line_body_wrapper",
    "__local_find_draw_line_body_base",
    textview_draw_line_body_wrapper,
    make_local_find_draw_line_body
  )
  textview_draw_wrapper = patch_textview_method(
    "draw",
    "__local_find_draw_wrapper",
    "__local_find_draw_base",
    textview_draw_wrapper,
    make_local_find_draw
  )
  textview_update_wrapper = patch_textview_method(
    "update",
    "__local_find_update_wrapper",
    "__local_find_update_base",
    textview_update_wrapper,
    make_local_find_update
  )
  textview_on_mouse_pressed_wrapper = patch_textview_method(
    "on_mouse_pressed",
    "__local_find_on_mouse_pressed_wrapper",
    "__local_find_on_mouse_pressed_base",
    textview_on_mouse_pressed_wrapper,
    make_local_find_on_mouse_pressed
  )
end

install_textview_patches()

command.add(function()
  return active_textview()
end, {
  ["editor:find"] = function(view)
    open_find(view, false)
  end,
  ["editor:replace"] = function(view)
    open_find(view, true)
  end,
  ["editor:find"] = function(view)
    open_find(view, false)
  end,
})

command.add(function()
  local ok, view = active_textview()
  if not ok then return false end
  local state = find_state_by_view[view]
  if state and state.visible and field_text(state.find) ~= "" then return true, view, state end
  return false
end, {
  ["editor:repeat_find"] = function(view, state)
    navigate(view, state, false)
  end,
  ["editor:previous_find"] = function(view, state)
    navigate(view, state, true)
  end,
})

command.add(active_find_state, {
  ["editor:find_field_next"] = function(view, state)
    navigate(view, state, false)
  end,
  ["editor:find_field_previous"] = function(view, state)
    navigate(view, state, true)
  end,
  ["editor:find_field_add_next"] = function(view, state)
    add_match_to_selection(view, state, false)
  end,
  ["editor:find_field_add_previous"] = function(view, state)
    add_match_to_selection(view, state, true)
  end,
  ["editor:find_toggle_replace_field"] = function(view, state)
    toggle_field_focus(view, state)
  end,
  ["editor:find_submit_or_replace"] = function(view, state)
    if state.mode == "replace" and state.focus == "replace" then
      replace_current_match(view, state)
    else
      state.input_active = false
      core.set_active_view(view)
      core.redraw = true
    end
  end,
  ["editor:find_replace_all_confirm"] = function(view, state)
    if state.mode == "replace" then confirm_replace_all(view, state) end
  end,
  ["editor:toggle_sensitivity"] = function(view, state)
    state.case_sensitive = not state.case_sensitive
    refresh_matches(view, state, { from_origin = true, scroll = true })
    core.redraw = true
  end,
  ["editor:toggle_regex"] = function(view, state)
    state.regex = not state.regex
    refresh_matches(view, state, { from_origin = true, scroll = true })
    core.redraw = true
  end,
})

command.add(active_visible_find_state, {
  ["editor:find_close"] = function(view, state)
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

  keymap.add_direct {
    ["ctrl+f"] = "editor:find",
    ["ctrl+r"] = "editor:replace",
  }

  keymap.add {
    ["up"] = { "editor:find_field_previous", "core:select_previous_prompt_item", "core:move_to_previous_line" },
    ["down"] = { "editor:find_field_next", "core:select_next_prompt_item", "core:move_to_next_line" },
    ["shift+up"] = { "editor:find_field_add_previous", "core:select_to_previous_line" },
    ["shift+down"] = { "editor:find_field_add_next", "core:select_to_next_line" },
    ["tab"] = { "editor:find_toggle_replace_field", "core:complete_prompt", "core:indent" },
    ["shift+tab"] = { "editor:find_toggle_replace_field", "core:unindent" },
    ["return"] = { "editor:find_submit_or_replace", "core:submit_prompt", "core:newline", "core:select_dialog_entry" },
    ["keypad enter"] = { "editor:find_submit_or_replace", "core:submit_prompt", "core:newline", "core:select_dialog_entry" },
    ["ctrl+return"] = { "editor:find_replace_all_confirm", "core:newline_below" },
  }

  prioritize_key("escape", "editor:find_close")
  prioritize_key("tab", "editor:find_toggle_replace_field")
  prioritize_key("shift+tab", "editor:find_toggle_replace_field")
  prioritize_key("return", "editor:find_submit_or_replace")
  prioritize_key("keypad enter", "editor:find_submit_or_replace")
  prioritize_key("ctrl+return", "editor:find_replace_all_confirm")
end

core.intellij_find_install_shortcut_override = install_find_shortcut_override
install_find_shortcut_override()
core.add_thread(function()
  coroutine.yield(0.1)
  install_textview_patches()
  install_find_shortcut_override()
end)
