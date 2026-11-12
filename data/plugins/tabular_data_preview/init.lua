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

local function value_label(value, missing_label)
  if value == false then return missing_label or "<missing>" end
  if value == "" then return "<empty>" end
  return tostring(value)
end

-- A plain decimal's sign, integer digits and fraction digits, without the
-- zeros that do not change its value. Nil for other text.
local function decimal_parts(text)
  local sign, whole, fraction = text:match("^%s*([+-]?)(%d*)%.?(%d*)%s*$")
  if not sign or whole == "" and fraction == "" then return nil end
  whole, fraction = whole:gsub("^0+", ""), fraction:gsub("0+$", "")
  if whole == "" and fraction == "" then sign = "" end
  return sign == "-" and -1 or 1, whole, fraction
end

-- Compares number text exactly, also past double precision, such as
-- decimal(38) and bigint values. Other number text, such as 1E+3, compares
-- as a double. Text that is not a number goes after numbers.
local function compare_numbers(a, b)
  local a_sign, a_whole, a_fraction = decimal_parts(a)
  local b_sign, b_whole, b_fraction = decimal_parts(b)
  if a_sign and b_sign then
    if a_sign ~= b_sign then return a_sign < b_sign and -1 or 1 end
    local order = 0
    if #a_whole ~= #b_whole then order = #a_whole < #b_whole and -1 or 1
    elseif a_whole ~= b_whole then order = a_whole < b_whole and -1 or 1
    elseif a_fraction ~= b_fraction then order = a_fraction < b_fraction and -1 or 1 end
    return order * a_sign
  end
  local x, y = tonumber(a), tonumber(b)
  if x and y then return x == y and 0 or (x < y and -1 or 1) end
  if x or y then return x and -1 or 1 end
  return nil
end

local function compare_values(a, b, kind)
  if a == false then return b ~= false and 1 or 0 end
  if b == false then return -1 end
  if kind == "number" then
    local order = compare_numbers(a, b)
    if order then return order end
  end
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

local function display_text(value, missing_label)
  if value == false then return missing_label or "" end
  return tostring(value or ""):gsub("\r\n", " ↵ "):gsub("[\r\n]", " ↵ ")
end

function Preview:__tostring()
  return "TabularDataPreview"
end

function Preview:new(buffer, saved_state, snapshot)
  assert(buffer or snapshot, "A table View requires a Buffer or a snapshot")
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

  if buffer then
    if core.buffer_registry then core.buffer_registry:retain(buffer, self) end
    self:install_buffer_listeners()
    self:schedule_parse(0, "open")
  else
    self:publish_model(snapshot, 0)
  end
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
  return parser.distinct_values(result, function()
    return self.closed or generation ~= self.parse_generation
  end, coroutine.yield)
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
    local kind = self.model.column_kinds and self.model.column_kinds[column]
    table.sort(display_rows, function(a_index, b_index)
      local a_value = rows[a_index].cells[column]
      local b_value = rows[b_index].cells[column]
      if a_value == false and b_value ~= false then return false end
      if b_value == false and a_value ~= false then return true end
      local comparison = compare_values(a_value, b_value, kind)
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

---A cell's background and text color, or nil for the defaults. Subclasses
---mark cells, such as pending edits.
function Preview:cell_style(display_row, column) end

function Preview:clear_selection()
  local changed = self.selection_anchor ~= nil or self.selection_focus ~= nil
  self.selection_anchor = nil
  self.selection_focus = nil
  self.selection_span = nil
  self.selection_drag = nil
  if changed then core.redraw = true end
  return changed
end

-- The selected rectangle. A selection of whole rows or whole columns
-- (`selection_span`) covers every column or every row.
function Preview:selection_bounds()
  local anchor, focus = self.selection_anchor, self.selection_focus
  if not (anchor and focus) then return nil end
  local row1, column1 = math.min(anchor.row, focus.row), math.min(anchor.column, focus.column)
  local row2, column2 = math.max(anchor.row, focus.row), math.max(anchor.column, focus.column)
  if self.selection_span == "rows" then column1, column2 = 1, self.model.column_count
  elseif self.selection_span == "columns" then row1, row2 = 1, self:row_count() end
  return row1, column1, row2, column2
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
    self.selection_span = nil
  end
  self.selection_focus = { row = row, column = column }
  self:ensure_cell_visible(row, column)
  core.redraw = true
  return true
end

-- Selects whole rows or whole columns (`span`), from the anchor to `index`.
-- The active cell keeps its other coordinate.
function Preview:select_span(span, index, extend)
  local focus = self.selection_focus
  local row = span == "rows" and index or focus and focus.row or 1
  local column = span == "columns" and index or focus and focus.column or 1
  if not self:select_cell(row, column, extend) then return false end
  self.selection_span = span
  return true
end

function Preview:select_row() return self.selection_focus and self:select_span("rows", self.selection_focus.row) end
function Preview:select_column() return self.selection_focus and self:select_span("columns", self.selection_focus.column) end

-- The number of rows that one page moves.
function Preview:page_rows()
  return math.max(1, math.floor((self.size.y - self:header_height()) / self:row_height()) - 1)
end

-- Moves the active cell to a place that `target(focus)` gives, such as an edge.
function Preview:move_to(target, extend)
  if not self.model or self:row_count() == 0 or self.model.column_count == 0 then return false end
  local focus = self.selection_focus or { row = 1, column = 1 }
  local row, column = target(self, focus)
  return self:select_cell(row, column, extend)
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
  self.selection_span = nil
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

-- The selection as TSV, with a line of column names first when `headers`.
function Preview:selection_text(headers)
  local row1, column1, row2, column2 = self:selection_bounds()
  if not row1 then return nil end
  local lines = {}
  if headers then
    local names = {}
    for column = column1, column2 do names[#names + 1] = tsv_value(self.model.headers[column]) end
    lines[1] = table.concat(names, "\t")
  end
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

function Preview:copy_with_headers()
  if not self:selection_bounds() then return false end
  self:copy_text(self:selection_text(true), "cells with column names")
  return true
end

local function markdown_value(value)
  local text = value == false and "" or tostring(value or "")
  return (text:gsub("|", "\\|"):gsub("\r?\n", "<br>"):gsub("\r", "<br>"))
end

-- The selection as a Markdown table, with the column names as its header.
function Preview:copy_as_markdown()
  local row1, column1, row2, column2 = self:selection_bounds()
  if not row1 then return false end
  local function line(value_at)
    local cells = {}
    for column = column1, column2 do cells[#cells + 1] = " " .. markdown_value(value_at(column)) .. " " end
    return "|" .. table.concat(cells, "|") .. "|"
  end
  local lines = { line(function(column) return self.model.headers[column] end) }
  lines[2] = string.rep("|---", column2 - column1 + 1) .. "|"
  for row = row1, row2 do
    lines[#lines + 1] = line(function(column) return self:cell_value(row, column) end)
  end
  self:copy_text(table.concat(lines, "\n"), "cells as Markdown")
  return true
end

-- Each selected column's values on one line, separated by commas. Missing
-- and empty values stay out.
function Preview:copy_as_comma_list()
  local row1, column1, row2, column2 = self:selection_bounds()
  if not row1 then return false end
  local lines = {}
  for column = column1, column2 do
    local values = {}
    for row = row1, row2 do
      local value = self:cell_value(row, column)
      if value and value ~= "" then values[#values + 1] = tostring(value) end
    end
    lines[#lines + 1] = table.concat(values, ", ")
  end
  self:copy_text(table.concat(lines, "\n"), "cells as a comma list")
  return true
end

function Preview:copy_column_name(column)
  column = column or self.selection_focus and self.selection_focus.column
  local name = column and self.model and self.model.headers[column]
  if not name then return false end
  self:copy_text(name, "column name")
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

-- Sorts by `column` in `direction`, or removes the sort without a direction.
function Preview:set_sort(column, direction)
  if not self.model or not self.model.headers[column] then return false end
  self.sort = direction and { column = column, direction = direction } or nil
  self:rebuild_display_rows("sort")
  return true
end

-- Removes the sort and all filters.
function Preview:reset_view()
  if not self.model then return false end
  self.sort, self.filters = nil, {}
  self:rebuild_display_rows("reset")
  return true
end

function Preview:focus_column()
  return self.selection_focus and self.selection_focus.column
end

function Preview:header_menu_items(column)
  return {
    { label = "Sort Ascending", command = "tabular_data:sort_ascending", args = { column } },
    { label = "Sort Descending", command = "tabular_data:sort_descending", args = { column } },
    { label = "Reset Sorting", command = "tabular_data:reset_sorting" },
    "-",
    { label = "Filter…", command = "tabular_data:filter_column", args = { column } },
    { label = "Select Column", command = "tabular_data:select_column", args = { column } },
    "-",
    { label = "Copy Column Name", command = "tabular_data:copy_column_name", args = { column } },
  }
end

-- The cell menu. Subclasses add their own items.
function Preview:cell_menu_items()
  return {
    { label = "Copy", command = "tabular_data:copy_selection" },
    { label = "Copy with Column Names", command = "tabular_data:copy_with_headers" },
    { label = "Copy As", items = {
      { label = "Markdown Table", command = "tabular_data:copy_as_markdown" },
      { label = "Comma List", command = "tabular_data:copy_as_comma_list" },
    } },
    "-",
    { label = "Select Row", command = "tabular_data:select_row" },
    { label = "Select Column", command = "tabular_data:select_column" },
    { label = "Select All", command = "tabular_data:select_all" },
    "-",
    { label = "Reset Sorting and Filters", command = "tabular_data:reset_view" },
  }
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
      return value_label(a, self.model.missing_label):lower() < value_label(b, self.model.missing_label):lower()
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
      local label = value_label(value, self.model.missing_label)
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
    local items
    if target.kind == "cell" then
      if not self:cell_is_selected(target.display_row, target.column) then
        self:select_cell(target.display_row, target.column, false)
      end
      items = self:cell_menu_items()
    elseif target.kind == "source_row" then
      if not self:cell_is_selected(target.display_row, 1) then
        self:select_span("rows", target.display_row)
      end
      items = self:cell_menu_items()
    elseif target.kind == "header" or target.kind == "header_filter" then
      items = self:header_menu_items(target.column)
    end
    if not items then return false end
    return require("core.context_menu").open(x, y, items, { button = button })
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
    self.selection_drag = "cells"
    return true
  elseif target.kind == "source_row" then
    self:select_span("rows", target.display_row, keymap.modkeys["shift"])
    self.selection_drag = "rows"
    return true
  elseif target.kind == "source_header" then
    return self:select_all_cells()
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
    if self.selection_drag == "rows" and target.display_row then
      self:select_span("rows", target.display_row, true)
    elseif target.kind == "cell" then
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
    self.selection_drag = nil
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
      local background, color = self:cell_style(display_row, column)
      if selected then
        renderer.draw_rect(x, y, width, row_height, style.selection)
      elseif hovered then
        renderer.draw_rect(x, y, width, row_height, style.line_highlight)
      end
      if background then renderer.draw_rect(x, y, width, row_height, background) end
      draw_text_clipped(
        font, color or style.text, display_text(self:cell_value(display_row, column), self.model.missing_label),
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
  ["tabular_data:copy_with_headers"] = function(view) return view:copy_with_headers() end,
  ["tabular_data:copy_as_markdown"] = function(view) return view:copy_as_markdown() end,
  ["tabular_data:copy_as_comma_list"] = function(view) return view:copy_as_comma_list() end,
  ["tabular_data:copy_column_name"] = function(view, column) return view:copy_column_name(column) end,
  ["tabular_data:select_all"] = function(view) return view:select_all_cells() end,
  ["tabular_data:clear_selection"] = function(view) return view:clear_selection() end,
  ["tabular_data:select_row"] = function(view) return view:select_row() end,
  ["tabular_data:select_column"] = function(view, column)
    if column then return view:select_span("columns", column) end
    return view:select_column()
  end,
  ["tabular_data:sort_ascending"] = function(view, column)
    return view:set_sort(column or view:focus_column(), "ascending")
  end,
  ["tabular_data:sort_descending"] = function(view, column)
    return view:set_sort(column or view:focus_column(), "descending")
  end,
  ["tabular_data:reset_sorting"] = function(view)
    return view.sort ~= nil and view:set_sort(view.sort.column, nil)
  end,
  ["tabular_data:reset_view"] = function(view) return view:reset_view() end,
  ["tabular_data:filter_column"] = function(view, column)
    column = column or view:focus_column()
    return column ~= nil and view:open_filter_prompt(column)
  end,
})

-- Moves to an edge of the table or one page away. Each move has a `select_to`
-- form that extends the selection.
do
  local targets = {
    row_start = function(_, focus) return focus.row, 1 end,
    row_end = function(view, focus) return focus.row, view.model.column_count end,
    first_row = function(_, focus) return 1, focus.column end,
    last_row = function(view, focus) return view:row_count(), focus.column end,
    start = function() return 1, 1 end,
    ["end"] = function(view) return view:row_count(), view.model.column_count end,
  }
  local pages = {
    page_up = function(view, focus) return focus.row - view:page_rows(), focus.column end,
    page_down = function(view, focus) return focus.row + view:page_rows(), focus.column end,
  }
  local commands = {}
  for name, target in pairs(targets) do
    commands["tabular_data:move_to_" .. name] = function(view) return view:move_to(target, false) end
    commands["tabular_data:select_to_" .. name] = function(view) return view:move_to(target, true) end
  end
  for name, target in pairs(pages) do
    commands["tabular_data:" .. name] = function(view) return view:move_to(target, false) end
    commands["tabular_data:select_" .. name] = function(view) return view:move_to(target, true) end
  end
  command.add(Preview, commands)
end

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
  ["ctrl+shift+c"] = "tabular_data:copy_with_headers",
  ["ctrl+a"] = "tabular_data:select_all",
  ["escape"] = "tabular_data:clear_selection",
  ["shift+space"] = "tabular_data:select_row",
  ["ctrl+space"] = "tabular_data:select_column",
  ["tab"] = "tabular_data:move_right",
  ["shift+tab"] = "tabular_data:move_left",
  ["home"] = "tabular_data:move_to_row_start",
  ["end"] = "tabular_data:move_to_row_end",
  ["shift+home"] = "tabular_data:select_to_row_start",
  ["shift+end"] = "tabular_data:select_to_row_end",
  ["ctrl+left"] = "tabular_data:move_to_row_start",
  ["ctrl+right"] = "tabular_data:move_to_row_end",
  ["ctrl+shift+left"] = "tabular_data:select_to_row_start",
  ["ctrl+shift+right"] = "tabular_data:select_to_row_end",
  ["ctrl+up"] = "tabular_data:move_to_first_row",
  ["ctrl+down"] = "tabular_data:move_to_last_row",
  ["ctrl+shift+up"] = "tabular_data:select_to_first_row",
  ["ctrl+shift+down"] = "tabular_data:select_to_last_row",
  ["ctrl+home"] = "tabular_data:move_to_start",
  ["ctrl+end"] = "tabular_data:move_to_end",
  ["ctrl+shift+home"] = "tabular_data:select_to_start",
  ["ctrl+shift+end"] = "tabular_data:select_to_end",
  ["pageup"] = "tabular_data:page_up",
  ["pagedown"] = "tabular_data:page_down",
  ["shift+pageup"] = "tabular_data:select_page_up",
  ["shift+pagedown"] = "tabular_data:select_page_down",
}

return Preview
