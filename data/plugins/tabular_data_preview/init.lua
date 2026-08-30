-- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local Editor = require "core.editor"
local keymap = require "core.keymap"
local panes = require "core.panes"
local style = require "core.style"
local View = require "core.view"
local view_icons = require "core.view_icons"
local parser = require "plugins.tabular_data_preview.parser"

local Preview = View:extend()
Preview.context = "workspace"
Preview.view_icon = view_icons.register("tabular_data", view_icons.file("preview.csv"))

local DEFAULT_COLUMN_WIDTH = 180
local MIN_COLUMN_WIDTH = 72
local SOURCE_COLUMN_MIN_WIDTH = 64
local CELL_PADDING = 8
local DIVIDER_HIT_WIDTH = 5
local FILTER_BUTTON_WIDTH = 24
local FILTER_SUGGESTION_LIMIT = 200
local PARSE_DEBOUNCE = 0.2

local function scaled(value)
  return common.round(value * SCALE)
end

local function path_for_buffer(buffer)
  return buffer and (buffer.abs_filename or buffer.filename) or nil
end

local function value_label(value)
  if value == false then return "<missing>" end
  if value == "" then return "<empty>" end
  return tostring(value)
end

local function compare_values(a, b)
  if a == false then return b ~= false and 1 or 0 end
  if b == false then return -1 end
  local al = tostring(a):gsub("\r\n", " "):gsub("[\r\n]", " "):lower()
  local bl = tostring(b):gsub("\r\n", " "):gsub("[\r\n]", " "):lower()
  if al == bl then return 0 end
  return al < bl and -1 or 1
end

local function copy_array(values)
  local result = {}
  for index, value in ipairs(values or {}) do result[index] = value end
  return result
end

local function draw_text_clipped(font, color, text, x, y, width, height, align)
  if width <= 0 or height <= 0 then return end
  core.push_clip_rect(x, y, width, height)
  common.draw_text(font, color, tostring(text or ""), align or "left", x, y, width, height)
  core.pop_clip_rect()
end

local function display_text(value)
  if value == false then return "" end
  return tostring(value or ""):gsub("\r\n", " ↵ "):gsub("[\r\n]", " ↵ ")
end

function Preview:__tostring()
  return "TabularDataPreview"
end

function Preview:new(buffer, saved_state)
  assert(buffer, "Tabular Data Preview requires a Buffer")
  Preview.super.new(self)
  self.scrollable = true
  self.buffer = buffer
  self.model = nil
  self.display_rows = {}
  self.filters = {}
  self.sort = nil
  self.column_widths = {}
  self.column_offsets = { 0 }
  self.total_data_width = 0
  self.parse_generation = 0
  self.parse_status = "loading"
  self.published_revision = nil
  self.parse_warning = nil
  self.parse_error = nil
  self.closed = false
  self.column_drag = nil
  self.selection_anchor = nil
  self.selection_focus = nil
  self.selection_drag = false
  self.hover_target = nil
  self.parse_thread_key = {}
  self.saved_state = saved_state
  self.listener_id = "tabular-data-preview:" .. tostring(self):gsub("%s+", "-")

  if saved_state and saved_state.scroll then
    local sx = tonumber(saved_state.scroll.x) or 0
    local sy = tonumber(saved_state.scroll.y) or 0
    self.scroll.x, self.scroll.to.x = sx, sx
    self.scroll.y, self.scroll.to.y = sy, sy
  end

  if core.buffer_registry then core.buffer_registry:retain(buffer, self) end
  self:install_buffer_listeners()
  self:schedule_parse(0, "open")
  core.log_quiet("Tabular Data Preview: opened %s", tostring(path_for_buffer(buffer)))
end

function Preview:install_buffer_listeners()
  self.buffer:add_text_change_listener(self.listener_id, {
    after_change = function()
      if not self.closed then self:schedule_parse(PARSE_DEBOUNCE, "text-change") end
    end,
  })
  self.buffer:add_metadata_listener(self.listener_id, function(_, event)
    if self.closed then return end
    if event.kind == "close" then
      self.parse_generation = self.parse_generation + 1
      self.parse_error = "The source Buffer is closed"
      self.parse_status = "error"
      core.redraw = true
    elseif event.filename_changed then
      self:schedule_parse(0, "filename-change")
    end
  end)
end

function Preview:snapshot_lines()
  local lines = {}
  for index in ipairs(self.buffer.lines or {}) do
    lines[index] = self.buffer:get_utf8_line(index)
  end
  return lines
end

function Preview:build_distinct_values(result, generation)
  local distinct = {}
  for column = 1, result.column_count do
    distinct[column] = { values = {}, counts = {} }
  end
  for row_index, row in ipairs(result.rows) do
    for column = 1, result.column_count do
      local value = row.cells[column]
      local values = distinct[column]
      if values.counts[value] == nil then
        values.counts[value] = 0
        values.values[#values.values + 1] = value
      end
      values.counts[value] = values.counts[value] + 1
    end
    if row_index % 4096 == 0 then
      coroutine.yield()
      if self.closed or generation ~= self.parse_generation then return nil end
    end
  end
  return distinct
end

function Preview:schedule_parse(delay, reason)
  self.parse_generation = self.parse_generation + 1
  local generation = self.parse_generation
  self.parse_status = self.model and "updating" or "loading"
  self.parse_error = nil
  core.redraw = true
  core.log_quiet(
    "Tabular Data Preview: parse scheduled reason=%s generation=%d",
    tostring(reason), generation
  )

  core.add_thread(function()
    if delay and delay > 0 then coroutine.yield(delay) end
    if self.closed or generation ~= self.parse_generation then return end

    local path = path_for_buffer(self.buffer)
    local delimiter = parser.delimiter_for_path(path)
    if not delimiter then
      self.parse_status = "error"
      self.parse_error = "Unsupported tabular data extension"
      core.redraw = true
      return
    end

    local revision = self.buffer.text_revision or 0
    local lines = self:snapshot_lines()
    local started = system.get_time()
    local result, err = parser.parse(lines, delimiter, {
      should_cancel = function()
        return self.closed
          or generation ~= self.parse_generation
          or revision ~= (self.buffer.text_revision or 0)
      end,
      yield_fn = function() coroutine.yield() end,
    })
    if not result then
      if err ~= "cancelled" then
        self.parse_status = "error"
        self.parse_error = tostring(err)
        core.redraw = true
      else
        core.log_quiet(
          "Tabular Data Preview: stale parse dropped generation=%d", generation
        )
      end
      return
    end

    local distinct = self:build_distinct_values(result, generation)
    if not distinct or self.closed or generation ~= self.parse_generation
        or revision ~= (self.buffer.text_revision or 0) then
      core.log_quiet(
        "Tabular Data Preview: stale parse dropped generation=%d", generation
      )
      return
    end

    result.distinct_values = distinct
    self:publish_model(result, revision)
    core.log_quiet(
      "Tabular Data Preview: parse complete bytes=%d rows=%d columns=%d time_ms=%.2f",
      tonumber(result.bytes) or 0, #result.rows, result.column_count,
      (system.get_time() - started) * 1000
    )
    if result.warning then
      core.log_quiet("Tabular Data Preview: %s", result.warning)
    end
  end, self.parse_thread_key)
end

function Preview:default_column_width()
  return scaled(DEFAULT_COLUMN_WIDTH)
end

function Preview:min_column_width()
  return scaled(MIN_COLUMN_WIDTH)
end

function Preview:rebuild_column_offsets()
  local offsets = { 0 }
  local total = 0
  local count = self.model and self.model.column_count or 0
  for column = 1, count do
    local width = tonumber(self.column_widths[column]) or self:default_column_width()
    width = math.max(self:min_column_width(), width)
    self.column_widths[column] = width
    total = total + width
    offsets[column + 1] = total
  end
  self.column_offsets = offsets
  self.total_data_width = total
end

function Preview:deserialize_filters(saved)
  local filters = {}
  for _, entry in ipairs(saved or {}) do
    local column = tonumber(entry.column)
    if column and column >= 1 then
      local selected = {}
      for _, item in ipairs(entry.values or {}) do
        local value
        if item.missing then value = false else value = tostring(item.value or "") end
        selected[value] = true
      end
      if next(selected) ~= nil then filters[column] = selected end
    end
  end
  return filters
end

function Preview:serialize_filters()
  local saved = {}
  for column, selected in pairs(self.filters) do
    local values = {}
    for value in pairs(selected) do
      values[#values + 1] = value == false and { missing = true } or { value = value }
    end
    table.sort(values, function(a, b)
      local av = a.missing and "<missing>" or value_label(a.value)
      local bv = b.missing and "<missing>" or value_label(b.value)
      return av < bv
    end)
    saved[#saved + 1] = { column = column, values = values }
  end
  table.sort(saved, function(a, b) return a.column < b.column end)
  return saved
end

function Preview:prune_filters()
  local distinct = self.model and self.model.distinct_values or {}
  for column, selected in pairs(self.filters) do
    local counts = distinct[column] and distinct[column].counts or {}
    for value in pairs(selected) do
      if counts[value] == nil then selected[value] = nil end
    end
    if next(selected) == nil then self.filters[column] = nil end
  end
end

function Preview:apply_saved_state()
  local saved = self.saved_state
  self.saved_state = nil
  if not saved then return end
  if type(saved.column_widths) == "table" then
    self.column_widths = copy_array(saved.column_widths)
  end
  if type(saved.sort) == "table" then
    local column = tonumber(saved.sort.column)
    local direction = saved.sort.direction
    if column and column >= 1 and column <= self.model.column_count
        and (direction == "ascending" or direction == "descending") then
      self.sort = { column = column, direction = direction }
    end
  end
  self.filters = self:deserialize_filters(saved.filters)
end

function Preview:publish_model(result, revision)
  self.model = result
  self.parse_warning = result.warning
  self:apply_saved_state()
  if self.sort and self.sort.column > result.column_count then self.sort = nil end
  for column = 1, result.column_count do
    self.column_widths[column] = self.column_widths[column] or self:default_column_width()
  end
  for column = result.column_count + 1, #self.column_widths do
    self.column_widths[column] = nil
  end
  self:rebuild_column_offsets()
  self:prune_filters()
  self:rebuild_display_rows("parse")
  self.published_revision = revision
  self.parse_status = "ready"
  self.parse_error = nil
  self:clamp_scroll_position()
  self.scroll.x = self.scroll.to.x
  self.scroll.y = self.scroll.to.y
  core.redraw = true
end

function Preview:row_passes_filters(row)
  for column, selected in pairs(self.filters) do
    if not selected[row.cells[column]] then return false end
  end
  return true
end

function Preview:rebuild_display_rows(reason)
  local started = system.get_time()
  local display_rows = {}
  for source_index, row in ipairs(self.model and self.model.rows or {}) do
    if self:row_passes_filters(row) then display_rows[#display_rows + 1] = source_index end
  end

  if self.sort then
    local column = self.sort.column
    local descending = self.sort.direction == "descending"
    local rows = self.model.rows
    table.sort(display_rows, function(a_index, b_index)
      local a_value = rows[a_index].cells[column]
      local b_value = rows[b_index].cells[column]
      if a_value == false and b_value ~= false then return false end
      if b_value == false and a_value ~= false then return true end
      local comparison = compare_values(a_value, b_value)
      if comparison == 0 then return a_index < b_index end
      if descending then return comparison > 0 end
      return comparison < 0
    end)
  end

  self.display_rows = display_rows
  self:clear_selection()
  self:clamp_scroll_position()
  core.redraw = true
  core.log_quiet(
    "Tabular Data Preview: display rebuild reason=%s rows=%d time_ms=%.2f",
    tostring(reason), #display_rows, (system.get_time() - started) * 1000
  )
end

function Preview:row_count()
  return #self.display_rows
end

function Preview:source_row(display_row)
  local source_index = self.display_rows[display_row]
  return source_index and self.model and self.model.rows[source_index] or nil
end

function Preview:cell_value(display_row, column)
  local row = self:source_row(display_row)
  if not row then return nil end
  return row.cells[column]
end

function Preview:clear_selection()
  local changed = self.selection_anchor ~= nil or self.selection_focus ~= nil
  self.selection_anchor = nil
  self.selection_focus = nil
  self.selection_drag = false
  if changed then core.redraw = true end
  return changed
end

function Preview:selection_bounds()
  local anchor, focus = self.selection_anchor, self.selection_focus
  if not (anchor and focus) then return nil end
  return math.min(anchor.row, focus.row), math.min(anchor.column, focus.column),
    math.max(anchor.row, focus.row), math.max(anchor.column, focus.column)
end

function Preview:cell_is_selected(row, column)
  local row1, column1, row2, column2 = self:selection_bounds()
  return row1 ~= nil and row >= row1 and row <= row2
    and column >= column1 and column <= column2
end

function Preview:ensure_cell_visible(row, column)
  if not self.model then return end
  local row_height = self:row_height()
  local body_height = math.max(0, self.size.y - self:header_height())
  local row_top = (row - 1) * row_height
  local row_bottom = row_top + row_height
  if row_top < self.scroll.to.y then
    self.scroll.to.y = row_top
  elseif row_bottom > self.scroll.to.y + body_height then
    self.scroll.to.y = row_bottom - body_height
  end

  local data_width = math.max(0, self.size.x - self:source_column_width())
  local column_left = self.column_offsets[column]
  local column_right = self.column_offsets[column + 1]
  if column_left < self.scroll.to.x then
    self.scroll.to.x = column_left
  elseif column_right > self.scroll.to.x + data_width then
    self.scroll.to.x = column_right - data_width
  end
  self:clamp_scroll_position()
end

function Preview:select_cell(row, column, extend)
  local row_count = self:row_count()
  local column_count = self.model and self.model.column_count or 0
  if row_count == 0 or column_count == 0 then return false end
  row = common.clamp(math.floor(tonumber(row) or 1), 1, row_count)
  column = common.clamp(math.floor(tonumber(column) or 1), 1, column_count)
  if not extend or not self.selection_anchor then
    self.selection_anchor = { row = row, column = column }
  end
  self.selection_focus = { row = row, column = column }
  self:ensure_cell_visible(row, column)
  core.redraw = true
  return true
end

function Preview:move_selection(row_delta, column_delta, extend)
  if not self.model or self:row_count() == 0 or self.model.column_count == 0 then
    return false
  end
  local focus = self.selection_focus
  if not focus then return self:select_cell(1, 1, false) end
  return self:select_cell(
    focus.row + row_delta, focus.column + column_delta, extend
  )
end

function Preview:select_all_cells()
  if not self.model or self:row_count() == 0 or self.model.column_count == 0 then
    return false
  end
  self.selection_anchor = { row = 1, column = 1 }
  self.selection_focus = { row = self:row_count(), column = self.model.column_count }
  core.redraw = true
  return true
end

local function tsv_value(value)
  local text = value == false and "" or tostring(value or "")
  if text:find('[\t\r\n"]') then
    return '"' .. text:gsub('"', '""') .. '"'
  end
  return text
end

function Preview:selection_text()
  local row1, column1, row2, column2 = self:selection_bounds()
  if not row1 then return nil end
  local lines = {}
  for row = row1, row2 do
    local cells = {}
    for column = column1, column2 do
      cells[#cells + 1] = tsv_value(self:cell_value(row, column))
    end
    lines[#lines + 1] = table.concat(cells, "\t")
  end
  return table.concat(lines, "\n")
end

function Preview:copy_selection()
  local row1, column1, row2, column2 = self:selection_bounds()
  if not row1 then return false end
  local cells = (row2 - row1 + 1) * (column2 - column1 + 1)
  local text
  if cells == 1 then
    local value = self:cell_value(row1, column1)
    text = value == false and "" or tostring(value or "")
  else
    text = self:selection_text()
  end
  self:copy_text(text, cells == 1 and "cell" or string.format("%d cells", cells))
  return true
end

function Preview:cycle_sort(column)
  if not self.model or not self.model.headers[column] then return false end
  if not self.sort or self.sort.column ~= column then
    self.sort = { column = column, direction = "ascending" }
  elseif self.sort.direction == "ascending" then
    self.sort.direction = "descending"
  else
    self.sort = nil
  end
  self:rebuild_display_rows("sort")
  return true
end

function Preview:toggle_filter_value(column, value)
  if not self.model or not self.model.headers[column] then return false end
  local selected = self.filters[column] or {}
  self.filters[column] = selected
  selected[value] = not selected[value] or nil
  if next(selected) == nil then self.filters[column] = nil end
  self:rebuild_display_rows("filter")
  return true
end

function Preview:clear_filter(column)
  if not self.filters[column] then return false end
  self.filters[column] = nil
  self:rebuild_display_rows("clear-filter")
  return true
end

function Preview:open_filter_prompt(column)
  local distinct = self.model and self.model.distinct_values[column]
  if not distinct then return false end
  local pane = panes.pane_for_view(self)
  if not pane then return false end

  local function suggest(text)
    local query = tostring(text or ""):lower()
    local values = copy_array(distinct.values)
    table.sort(values, function(a, b)
      local a_selected = self.filters[column] and self.filters[column][a] or false
      local b_selected = self.filters[column] and self.filters[column][b] or false
      if a_selected ~= b_selected then return a_selected end
      return value_label(a):lower() < value_label(b):lower()
    end)
    local choices = {}
    if self.filters[column]
        and (query == "" or ("clear column filter"):find(query, 1, true)) then
      choices[#choices + 1] = {
        text = "Clear column filter",
        info = self.model.headers[column],
        clear_filter = true,
      }
    end
    for _, value in ipairs(values) do
      local label = value_label(value)
      if query == "" or label:lower():find(query, 1, true) then
        local selected = self.filters[column] and self.filters[column][value] or false
        choices[#choices + 1] = {
          text = (selected and "✓ " or "  ") .. label,
          info = string.format("%d row%s", distinct.counts[value], distinct.counts[value] == 1 and "" or "s"),
          value = value,
          has_value = true,
        }
        if #choices >= FILTER_SUGGESTION_LIMIT then break end
      end
    end
    return choices
  end

  core.global_prompt_bar:enter("Filter " .. tostring(self.model.headers[column]), {
    text = "",
    pane_scope = pane,
    pane_source_view = self,
    suggest = suggest,
    submit = function(_, item)
      if not item then return end
      if item.clear_filter then
        self:clear_filter(column)
      elseif item.has_value then
        self:toggle_filter_value(column, item.value)
      end
      self:open_filter_prompt(column)
    end,
  })
  return true
end

function Preview:get_name()
  local path = path_for_buffer(self.buffer)
  return "Preview " .. (path and common.basename(path) or "Tabular Data")
end

function Preview:get_state()
  local path = path_for_buffer(self.buffer)
  if not path then return nil end
  return {
    filename = path,
    scroll = { x = self.scroll.x, y = self.scroll.y },
    column_widths = copy_array(self.column_widths),
    sort = self.sort and { column = self.sort.column, direction = self.sort.direction } or nil,
    filters = self:serialize_filters(),
  }
end

function Preview.from_state(state)
  if type(state) ~= "table" or not parser.is_supported(state.filename) then return nil end
  local info = system.get_file_info(state.filename)
  if not info or info.type ~= "file" then return nil end
  local ok, buffer = pcall(core.open_buffer, state.filename)
  if not ok or not buffer then return nil end
  return Preview(buffer, state)
end

function Preview:get_navigation_state()
  return { scroll = { x = self.scroll.x, y = self.scroll.y } }
end

function Preview:set_navigation_state(state)
  local scroll = state and state.scroll
  if not scroll then return end
  self.scroll.x, self.scroll.to.x = tonumber(scroll.x) or 0, tonumber(scroll.x) or 0
  self.scroll.y, self.scroll.to.y = tonumber(scroll.y) or 0, tonumber(scroll.y) or 0
end

function Preview:duplicate()
  return Preview(self.buffer, self:get_state())
end

function Preview:on_close()
  if self.closed then return end
  self.closed = true
  self.parse_generation = self.parse_generation + 1
  core.threads[self.parse_thread_key] = nil
  if self.buffer then
    if self.buffer.remove_text_change_listener then
      self.buffer:remove_text_change_listener(self.listener_id)
    end
    if self.buffer.remove_metadata_listener then
      self.buffer:remove_metadata_listener(self.listener_id)
    end
    if core.buffer_registry then core.buffer_registry:release(self.buffer, self) end
  end
  self.model = nil
  self.display_rows = {}
  self.filters = {}
  core.log_quiet("Tabular Data Preview: closed %s", tostring(path_for_buffer(self.buffer)))
end

function Preview:row_height()
  return math.max(1, common.round(style.code_font:get_height() * config.line_height + scaled(4)))
end

function Preview:header_height()
  return self:row_height() + scaled(4)
end

function Preview:source_column_width()
  local max_line = math.max(1, #(self.buffer and self.buffer.lines or {}))
  local range = tostring(max_line) .. "–" .. tostring(max_line)
  return math.max(scaled(SOURCE_COLUMN_MIN_WIDTH), style.code_font:get_width(range) + scaled(CELL_PADDING * 2))
end

function Preview:get_scrollable_size()
  local content = self:header_height() + self:row_count() * self:row_height()
  return math.max(self.size.y, content)
end

function Preview:get_h_scrollable_size()
  local content = self:source_column_width() + self.total_data_width
  return math.max(self.size.x, content)
end

function Preview:on_scale_change(new_scale, previous_scale)
  local ratio = previous_scale > 0 and new_scale / previous_scale or 1
  for column, width in ipairs(self.column_widths) do
    self.column_widths[column] = common.round(width * ratio)
  end
  self:rebuild_column_offsets()
end

function Preview:column_at_offset(offset)
  local count = self.model and self.model.column_count or 0
  local low, high = 1, count
  while low <= high do
    local middle = math.floor((low + high) / 2)
    if offset < self.column_offsets[middle] then
      high = middle - 1
    elseif offset >= self.column_offsets[middle + 1] then
      low = middle + 1
    else
      return middle
    end
  end
end

function Preview:visible_column_range()
  local count = self.model and self.model.column_count or 0
  if count == 0 then return 1, 0 end
  local width = math.max(0, self.size.x - self:source_column_width())
  local first = self:column_at_offset(self.scroll.x) or count
  local last = self:column_at_offset(self.scroll.x + width) or count
  return math.max(1, first), math.min(count, last + 1)
end

function Preview:visible_row_range()
  local count = self:row_count()
  if count == 0 then return 1, 0 end
  local row_height = self:row_height()
  local body_height = math.max(0, self.size.y - self:header_height())
  local first = math.max(1, math.floor(self.scroll.y / row_height))
  local last = math.min(count, math.ceil((self.scroll.y + body_height) / row_height) + 1)
  return first, last
end

function Preview:column_screen_rect(column)
  local source_width = self:source_column_width()
  local x = self.position.x + source_width + self.column_offsets[column] - self.scroll.x
  return x, self.position.y, self.column_widths[column], self:header_height()
end

function Preview:column_divider_screen_position(column)
  local x = self.position.x + self:source_column_width()
    + self.column_offsets[column + 1] - self.scroll.x
  return x, self.position.y + self:header_height() / 2
end

function Preview:cell_screen_rect(display_row, column)
  local x = self.position.x + self:source_column_width()
    + self.column_offsets[column] - self.scroll.x
  local y = self.position.y + self:header_height()
    + (display_row - 1) * self:row_height() - self.scroll.y
  return x, y, self.column_widths[column], self:row_height()
end

function Preview:hit_test(x, y)
  if x < self.position.x or x >= self.position.x + self.size.x
      or y < self.position.y or y >= self.position.y + self.size.y then
    return { kind = "none" }
  end
  local source_width = self:source_column_width()
  local header_height = self:header_height()
  local in_header = y < self.position.y + header_height
  if x < self.position.x + source_width then
    if in_header then return { kind = "source_header" } end
    local display_row = math.floor((y - self.position.y - header_height + self.scroll.y)
      / self:row_height()) + 1
    if display_row >= 1 and display_row <= self:row_count() then
      return { kind = "source_row", display_row = display_row }
    end
    return { kind = "none" }
  end

  local offset = x - self.position.x - source_width + self.scroll.x
  local column = self:column_at_offset(offset)
  if not column then
    local count = self.model and self.model.column_count or 0
    if in_header and count > 0
        and math.abs(offset - self.total_data_width) <= scaled(DIVIDER_HIT_WIDTH) then
      return { kind = "column_divider", column = count }
    end
    return { kind = "none" }
  end
  local left_divider_x = self.position.x + source_width
    + self.column_offsets[column] - self.scroll.x
  if in_header and column > 1
      and math.abs(x - left_divider_x) <= scaled(DIVIDER_HIT_WIDTH) then
    return { kind = "column_divider", column = column - 1 }
  end
  local divider_x = self.position.x + source_width
    + self.column_offsets[column + 1] - self.scroll.x
  if in_header and math.abs(x - divider_x) <= scaled(DIVIDER_HIT_WIDTH) then
    return { kind = "column_divider", column = column }
  end
  if in_header then
    if x >= divider_x - scaled(FILTER_BUTTON_WIDTH) then
      return { kind = "header_filter", column = column }
    end
    return { kind = "header", column = column }
  end

  local display_row = math.floor((y - self.position.y - header_height + self.scroll.y)
    / self:row_height()) + 1
  if display_row < 1 or display_row > self:row_count() then return { kind = "none" } end
  return { kind = "cell", column = column, display_row = display_row }
end

function Preview:copy_text(text, label)
  system.set_clipboard(tostring(text or ""))
  core.cursor_clipboard = {}
  core.cursor_clipboard_whole_line = {}
  if core.status_bar then
    core.status_bar:show_message("i", style.text, "Copied " .. label)
  end
  core.log_quiet("Tabular Data Preview: copied %s", label)
end

function Preview:source_line_label(display_row)
  local row = self:source_row(display_row)
  if not row then return "" end
  if row.source_line1 == row.source_line2 then return tostring(row.source_line1) end
  return tostring(row.source_line1) .. "–" .. tostring(row.source_line2)
end

function Preview:on_mouse_pressed(button, x, y, clicks)
  if Preview.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if self:scrollbar_overlaps_point(x, y) then return false end
  local target = self:hit_test(x, y)
  if button == "right" then
    if target.kind == "cell" then
      if not self:cell_is_selected(target.display_row, target.column) then
        self:select_cell(target.display_row, target.column, false)
      end
      self:copy_selection()
      return true
    elseif target.kind == "header" or target.kind == "header_filter" then
      self:copy_text(self.model.headers[target.column], "header")
      return true
    elseif target.kind == "source_row" then
      self:copy_text(self:source_line_label(target.display_row), "source row")
      return true
    end
    return false
  end
  if button ~= "left" then return false end
  if target.kind == "column_divider" then
    if (clicks or 1) >= 2 then
      self.column_widths[target.column] = self:default_column_width()
      self:rebuild_column_offsets()
    else
      self.column_drag = {
        column = target.column,
        start_x = x,
        start_width = self.column_widths[target.column],
      }
    end
    self.cursor = "sizeh"
    core.redraw = true
    return true
  elseif target.kind == "header_filter" then
    return self:open_filter_prompt(target.column)
  elseif target.kind == "header" then
    return self:cycle_sort(target.column)
  elseif target.kind == "cell" then
    self:select_cell(
      target.display_row, target.column,
      keymap.modkeys["shift"] and self.selection_anchor ~= nil
    )
    self.selection_drag = true
    return true
  end
  return false
end

function Preview:on_mouse_moved(x, y, dx, dy)
  if self.column_drag then
    local drag = self.column_drag
    self.column_widths[drag.column] = math.max(
      self:min_column_width(), common.round(drag.start_width + x - drag.start_x)
    )
    self:rebuild_column_offsets()
    self:clamp_scroll_position()
    self.cursor = "sizeh"
    core.redraw = true
    return true
  end
  if self.selection_drag then
    local target = self:hit_test(x, y)
    if target.kind == "cell" then
      self:select_cell(target.display_row, target.column, true)
    end
    return true
  end
  if Preview.super.on_mouse_moved(self, x, y, dx, dy) then return true end
  local target = self:hit_test(x, y)
  local previous = self.hover_target
  self.hover_target = target
  if target.kind == "column_divider" then
    self.cursor = "sizeh"
  elseif target.kind == "header" or target.kind == "header_filter" then
    self.cursor = "hand"
  else
    self.cursor = "arrow"
  end
  if not previous or previous.kind ~= target.kind
      or previous.column ~= target.column or previous.display_row ~= target.display_row then
    core.redraw = true
  end
  return target.kind ~= "none"
end

function Preview:on_mouse_released(button, x, y)
  Preview.super.on_mouse_released(self, button, x, y)
  if button == "left" and self.column_drag then
    self.column_drag = nil
    core.redraw = true
    return true
  end
  if button == "left" and self.selection_drag then
    self.selection_drag = false
    return true
  end
end

function Preview:on_mouse_left()
  Preview.super.on_mouse_left(self)
  if not self.column_drag then
    self.hover_target = nil
    self.cursor = "arrow"
    core.redraw = true
  end
end

function Preview:on_mouse_wheel(y, x)
  if keymap.modkeys["shift"] then x, y = y, 0 end
  if y and y ~= 0 then
    self.scroll.to.y = self.scroll.to.y - y * config.mouse_wheel_scroll
  end
  if x and x ~= 0 then
    self.scroll.to.x = self.scroll.to.x - x * config.mouse_wheel_scroll
  end
  self:clamp_scroll_position()
  return (y and y ~= 0) or (x and x ~= 0) or false
end

function Preview:draw_body()
  if not self.model then return end
  local font = style.code_font
  local row_height = self:row_height()
  local header_height = self:header_height()
  local source_width = self:source_column_width()
  local body_x = self.position.x + source_width
  local body_y = self.position.y + header_height
  local body_width = math.max(0, self.size.x - source_width)
  local body_height = math.max(0, self.size.y - header_height)
  local first_row, last_row = self:visible_row_range()
  local first_column, last_column = self:visible_column_range()

  for display_row = first_row, last_row do
    local y = body_y + (display_row - 1) * row_height - self.scroll.y
    if display_row % 2 == 0 then
      renderer.draw_rect(self.position.x, y, self.size.x, row_height, style.background2)
    end
  end

  core.push_clip_rect(body_x, body_y, body_width, body_height)
  for display_row = first_row, last_row do
    local y = body_y + (display_row - 1) * row_height - self.scroll.y
    for column = first_column, last_column do
      local x = body_x + self.column_offsets[column] - self.scroll.x
      local width = self.column_widths[column]
      local selected = self:cell_is_selected(display_row, column)
      local hovered = self.hover_target and self.hover_target.kind == "cell"
        and self.hover_target.display_row == display_row
        and self.hover_target.column == column
      if selected then
        renderer.draw_rect(x, y, width, row_height, style.selection)
      elseif hovered then
        renderer.draw_rect(x, y, width, row_height, style.line_highlight)
      end
      draw_text_clipped(
        font, style.text, display_text(self:cell_value(display_row, column)),
        x + scaled(CELL_PADDING), y,
        math.max(0, width - scaled(CELL_PADDING * 2)), row_height
      )
      renderer.draw_rect(x + width - 1, y, 1, row_height, style.divider)
      if self.selection_focus and self.selection_focus.row == display_row
          and self.selection_focus.column == column then
        local thickness = math.max(1, scaled(2))
        renderer.draw_rect(x, y, width, thickness, style.accent)
        renderer.draw_rect(x, y + row_height - thickness, width, thickness, style.accent)
        renderer.draw_rect(x, y, thickness, row_height, style.accent)
        renderer.draw_rect(x + width - thickness, y, thickness, row_height, style.accent)
      end
    end
    renderer.draw_rect(body_x, y + row_height - 1, body_width, 1, style.divider)
  end
  core.pop_clip_rect()

  core.push_clip_rect(self.position.x, body_y, source_width, body_height)
  for display_row = first_row, last_row do
    local y = body_y + (display_row - 1) * row_height - self.scroll.y
    local background = display_row % 2 == 0 and style.background2 or style.background
    renderer.draw_rect(self.position.x, y, source_width, row_height, background)
    draw_text_clipped(
      font, style.dim, self:source_line_label(display_row),
      self.position.x + scaled(CELL_PADDING), y,
      source_width - scaled(CELL_PADDING * 2), row_height, "right"
    )
    renderer.draw_rect(self.position.x + source_width - 1, y, 1, row_height, style.divider)
    renderer.draw_rect(self.position.x, y + row_height - 1, source_width, 1, style.divider)
  end
  core.pop_clip_rect()
end

function Preview:draw_header()
  if not self.model then return end
  local font = style.code_font
  local height = self:header_height()
  local source_width = self:source_column_width()
  local first_column, last_column = self:visible_column_range()
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, height, style.background2)

  core.push_clip_rect(
    self.position.x + source_width, self.position.y,
    math.max(0, self.size.x - source_width), height
  )
  for column = first_column, last_column do
    local x, y, width = self:column_screen_rect(column)
    local filter_width = scaled(FILTER_BUTTON_WIDTH)
    local hovered = self.hover_target
      and (self.hover_target.kind == "header" or self.hover_target.kind == "header_filter")
      and self.hover_target.column == column
    if hovered then renderer.draw_rect(x, y, width, height, style.line_highlight) end
    local arrow = ""
    if self.sort and self.sort.column == column then
      arrow = self.sort.direction == "ascending" and " ▲" or " ▼"
    end
    draw_text_clipped(
      font, style.text, tostring(self.model.headers[column] or "") .. arrow,
      x + scaled(CELL_PADDING), y,
      math.max(0, width - filter_width - scaled(CELL_PADDING)), height
    )
    local filter_color = self.filters[column] and style.accent or style.dim
    draw_text_clipped(
      font, filter_color, "▾", x + width - filter_width, y, filter_width, height, "center"
    )
    renderer.draw_rect(x + width - 1, y, 1, height, style.divider)
  end
  core.pop_clip_rect()

  renderer.draw_rect(self.position.x, self.position.y, source_width, height, style.background2)
  draw_text_clipped(
    font, style.dim, "Row", self.position.x + scaled(CELL_PADDING), self.position.y,
    source_width - scaled(CELL_PADDING * 2), height, "right"
  )
  renderer.draw_rect(self.position.x + source_width - 1, self.position.y, 1, height, style.divider)
  renderer.draw_rect(self.position.x, self.position.y + height - 1, self.size.x, 1, style.divider)

  if self.parse_status == "updating" then
    local width = font:get_width("Updating…") + scaled(CELL_PADDING * 2)
    renderer.draw_rect(
      self.position.x + self.size.x - width, self.position.y, width, height, style.background2
    )
    draw_text_clipped(
      font, style.dim, "Updating…", self.position.x + self.size.x - width,
      self.position.y, width - scaled(CELL_PADDING), height, "right"
    )
  end
end

function Preview:draw_status()
  local font = style.code_font
  local text
  local color = style.dim
  if self.parse_status == "loading" then
    text = "Loading…"
  elseif self.parse_status == "error" then
    text = self.parse_error or "Could not load tabular data"
    color = style.error or style.text
  elseif self.model and self.model.column_count == 0 then
    text = "No data to display"
  elseif self.model and self:row_count() == 0 then
    text = next(self.filters) and "No rows match the active filters" or "No data rows to display"
  end
  if text then
    common.draw_text(
      font, color, text, "center",
      self.position.x, self.position.y, self.size.x, self.size.y
    )
  end
  if self.parse_warning and self.parse_status == "ready" then
    local height = self:row_height()
    renderer.draw_rect(
      self.position.x, self.position.y + self.size.y - height,
      self.size.x, height, style.background2
    )
    draw_text_clipped(
      font, style.warn or style.text, self.parse_warning,
      self.position.x + scaled(CELL_PADDING), self.position.y + self.size.y - height,
      self.size.x - scaled(CELL_PADDING * 2), height
    )
  end
end

function Preview:draw()
  self:draw_background(style.background)
  self:draw_body()
  self:draw_header()
  self:draw_status()
  self:draw_scrollbar()
end

local function command_source_editor()
  local context = command.get_invocation_context() or {}
  local view = context.source_view or core.active_view
  if not (view and view.extends and view:extends(Editor)) then
    local pane = panes.find(context.source_pane)
    view = pane and pane.current_view or nil
  end
  local path = view and view.buffer and path_for_buffer(view.buffer)
  if view and path and parser.is_supported(path) then return true, view end
  return false
end

local function matching_preview(pane, buffer)
  for _, view in ipairs(panes.views(pane)) do
    if view.extends and view:extends(Preview) and not view.closed and view.buffer == buffer then
      return view
    end
  end
end

local function open_current(editor)
  local pane = panes.pane_for_view(editor) or panes.active()
  if not pane then return nil end
  local existing = matching_preview(pane, editor.buffer)
  if existing then
    panes.present(existing, { pane = pane, focus = true })
    core.log_quiet("Tabular Data Preview: reused current-Pane Preview")
    return existing
  end
  return panes.place(function() return Preview(editor.buffer) end, {
    pane = pane,
    placement = "current",
    focus = true,
    reason = "tabular-data-preview",
  })
end

local function open_to_side(editor)
  local source_pane = panes.pane_for_view(editor) or panes.active()
  if not source_pane then return nil end
  for _, pane in ipairs(panes.ordered()) do
    if pane ~= source_pane and pane.group == source_pane.group then
      local existing = matching_preview(pane, editor.buffer)
      if existing then
        panes.present(existing, { pane = pane, focus = true })
        core.log_quiet("Tabular Data Preview: reused side Preview")
        return existing
      end
    end
  end
  return panes.place(function() return Preview(editor.buffer) end, {
    pane = source_pane,
    placement = "split",
    direction = "right",
    focus = true,
    reason = "tabular-data-preview-side",
  })
end

command.add(command_source_editor, {
  ["tabular_data:open_preview"] = command.palette(open_current, {
    keywords = { "csv", "tsv", "psv", "ssv", "table", "data" },
    opens_view = true,
  }),
  ["tabular_data:open_preview_to_the_side"] = command.palette(open_to_side, {
    keywords = { "csv", "tsv", "psv", "ssv", "table", "split", "side" },
    opens_view = true,
  }),
})

command.add(Preview, {
  ["tabular_data:move_left"] = function(view) return view:move_selection(0, -1, false) end,
  ["tabular_data:move_right"] = function(view) return view:move_selection(0, 1, false) end,
  ["tabular_data:move_up"] = function(view) return view:move_selection(-1, 0, false) end,
  ["tabular_data:move_down"] = function(view) return view:move_selection(1, 0, false) end,
  ["tabular_data:extend_left"] = function(view) return view:move_selection(0, -1, true) end,
  ["tabular_data:extend_right"] = function(view) return view:move_selection(0, 1, true) end,
  ["tabular_data:extend_up"] = function(view) return view:move_selection(-1, 0, true) end,
  ["tabular_data:extend_down"] = function(view) return view:move_selection(1, 0, true) end,
  ["tabular_data:copy_selection"] = function(view) return view:copy_selection() end,
  ["tabular_data:select_all"] = function(view) return view:select_all_cells() end,
  ["tabular_data:clear_selection"] = function(view) return view:clear_selection() end,
})

keymap.add {
  ["left"] = "tabular_data:move_left",
  ["right"] = "tabular_data:move_right",
  ["up"] = "tabular_data:move_up",
  ["down"] = "tabular_data:move_down",
  ["shift+left"] = "tabular_data:extend_left",
  ["shift+right"] = "tabular_data:extend_right",
  ["shift+up"] = "tabular_data:extend_up",
  ["shift+down"] = "tabular_data:extend_down",
  ["ctrl+c"] = "tabular_data:copy_selection",
  ["ctrl+a"] = "tabular_data:select_all",
  ["escape"] = "tabular_data:clear_selection",
}

return Preview
