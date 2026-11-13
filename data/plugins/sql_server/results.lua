local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local Preview = require "plugins.tabular_data_preview"

local Results = Preview:extend()
local empty = { headers = {}, rows = {}, column_count = 0, distinct_values = {} }
function Results:__tostring() return "SQLResults" end

-- A normal Untitled Editor, so the text can be edited, searched and saved.
local function open_text(text, mode)
  local buffer = core.open_buffer()
  require("plugins.untitled_tabs").tag_buffer(buffer)
  if mode then buffer:set_language_mode(mode, { reason = "SQL Result text" }) end
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  buffer:set_selection(1, 1)
  local editor = require("core.editor")(buffer)
  require("core.panes").place(function() return editor end, { placement = "new", focus = true })
  return editor
end
local function show_messages(view)
  local text = view:messages_text()
  return require("core.panes").place(function()
    return require("core.textview").from_text(text, { name = "SQL Messages" })
  end, { placement = "current", focus = true })
end

function Results:new(connection_name)
  self.connection_name = connection_name
  self.message = "Running SQL…"
  self.title = "SQL Results · " .. connection_name
  Preview.new(self, nil, nil, empty)
end

function Results:get_name() return self.title end
function Results:get_state() return nil end

function Results:begin_run(cancel, explain, text)
  self.cancel_query = cancel
  self.data = nil
  self.run_text = text
  self.kind = explain and "Explain Plan" or "SQL Results"
  self.message = explain and "Reading plan…" or "Running SQL…"
  self.title = self.kind .. " · " .. self.connection_name
  self:publish_model(empty, 0)
end

-- All server messages in order, as SSMS's Messages tab shows them.
function Results:messages_text()
  local data, lines = self.data or {}, {}
  for _, message in ipairs(data.messages or {}) do lines[#lines + 1] = message.text end
  if data.cancelled then lines[#lines + 1] = "SQL cancelled. Committed changes remain." end
  if data.error and not (data.messages and #data.messages > 0) then lines[#lines + 1] = data.error end
  if data.limited then lines[#lines + 1] = "A result limit cut the shown results. Later statements still ran." end
  if data.transaction_count and data.transaction_count > 0 then
    lines[#lines + 1] = string.format("Open transactions: %d. Commit or roll back.", data.transaction_count)
  end
  return #lines > 0 and table.concat(lines, "\n") or self.message
end

-- The filter, sort, widths and scroll of the shown result, so it shows the
-- same when the user comes back to it.
function Results:save_result_state()
  if not self.result_index then return end
  self.result_states[self.result_index] = { filters = self.filters, sort = self.sort,
    column_widths = self.column_widths, x = self.scroll.to.x, y = self.scroll.to.y }
end

function Results:show_result(index)
  local model = self.data and self.data.results and self.data.results[index]
  if not model then return false end
  self:save_result_state()
  self.result_index = index
  local saved = self.result_states[index] or { filters = {}, column_widths = {}, x = 0, y = 0 }
  self.filters, self.sort, self.column_widths = saved.filters, saved.sort, saved.column_widths
  self.scroll.x, self.scroll.y, self.scroll.to.x, self.scroll.to.y = saved.x, saved.y, saved.x, saved.y
  self:publish_model(model, index)
  self.result_warning = self.data.error or (self.data.limited and "Result limit reached. Some results are cut.") or model.warning
  self.title = string.format("%s%s %d/%d · %s", self.kept and "Kept " or "", self.kind or "SQL Results", index,
    #self.data.results, self.connection_name)
  core.redraw = true
  return true
end

function Results:complete(data)
  self.cancel_query = nil
  self.data = data
  self.result_index, self.result_states = nil, {}
  self.edits, self.deletes, self.edit_info, self.edit_error = {}, {}, nil, nil
  local last = data.messages and data.messages[#data.messages]
  if data.cancelled then
    self.message = "SQL cancelled. Committed changes remain."
  elseif data.error then
    self.message = data.error
  elseif last then
    self.message = last.text
  else
    self.message = "SQL finished."
  end
  if not data.cancelled and data.transaction_count and data.transaction_count > 0 then
    self.message = self.message .. "  ·  Transaction open"
  end
  if not self:show_result(1) then self:publish_model(empty, 0) end
  core.redraw = true
end

-- Pending edits show in their cells until the user scripts or discards them.
function Results:cell_value(display_row, column)
  local row = self:source_row(display_row)
  local edits = row and self.edits and self.edits[row]
  if edits and edits[column] ~= nil then return edits[column] end
  return Preview.cell_value(self, display_row, column)
end

local tints = setmetatable({}, { __mode = "k" })
local function tint(color)
  local t = tints[color]
  if not t then t = { color[1], color[2], color[3], 48 }; tints[color] = t end
  return t
end
function Results:cell_style(display_row, column)
  local row = self:source_row(display_row)
  if not row or not self.edits then return end
  if self.deletes[row] then return tint(style.error), style.dim end
  local edits = self.edits[row]
  if edits and edits[column] ~= nil then return tint(style.accent), nil end
end

function Results:draw_header()
  if self.model.column_count > 0 then Preview.draw_header(self) end
end

-- The footer shows the result and its row count, and the buttons that act on
-- it: Cancel while the SQL runs, Row Limit for the Query, CSV, JSON and Messages.
function Results:footer_height()
  return self:row_height() + common.round(6 * SCALE)
end

function Results:get_scrollable_size()
  local content = self:header_height() + self:row_count() * self:row_height() + self:footer_height()
  return math.max(self.size.y, content)
end

local function limit_label(buffer)
  local limit = require("plugins.sql_server").row_limit(buffer)
  if buffer.sql_row_limit == false then return "No Row Limit" end
  return "Limit " .. tostring(limit):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

function Results:footer_buttons()
  local buttons, labels = {}, {}
  local changes = self.edits and require("plugins.sql_server.edit").change_count(self) or 0
  if self.cancel_query then labels[#labels + 1] = "cancel" end
  if changes > 0 then labels[#labels + 1] = "script"; labels[#labels + 1] = "discard" end
  if self.source_buffer then labels[#labels + 1] = "limit" end
  if self.model.column_count > 0 then labels[#labels + 1] = "csv"; labels[#labels + 1] = "json" end
  if self.data then labels[#labels + 1] = "messages" end
  if self.kept then labels[#labels + 1] = "sql" end
  local names = { cancel = "Cancel", csv = "CSV", json = "JSON", messages = "Messages", discard = "Discard", sql = "SQL",
    script = changes == 1 and "Script 1 Change" or string.format("Script %d Changes", changes) }
  local pad, height = common.round(10 * SCALE), self:footer_height()
  local x = self.position.x + self.size.x - common.round(4 * SCALE) - style.scrollbar_size
  local y = self.position.y + self.size.y - height
  for i = #labels, 1, -1 do
    local id = labels[i]
    local label = names[id] or limit_label(self.source_buffer)
    local w = style.font:get_width(label) + pad * 2
    x = x - w
    table.insert(buttons, 1, { id = id, label = label, x = x, y = y, w = w, h = height })
  end
  return buttons
end

-- Two or more selected cells show their aggregates. A drag shows only the
-- count, and the aggregates come when it ends.
function Results:selection_summary()
  local row1, column1, row2, column2 = self:selection_bounds()
  if not row1 then return nil end
  local count = (row2 - row1 + 1) * (column2 - column1 + 1)
  if count < 2 then return nil end
  if self.selection_drag then return string.format("%d cells", count) end
  local key = string.format("%d:%d:%d:%d:%d", row1, column1, row2, column2, self.edit_revision or 0)
  local cache = self.aggregate_cache
  if cache and cache.key == key and cache.rows == self.display_rows then return cache.text end
  local cells = {}
  for display_row = row1, row2 do
    for column = column1, column2 do
      local value = self:cell_value(display_row, column)
      cells[#cells + 1] = value == nil and false or value
    end
  end
  local text = require("plugins.sql_server.aggregate").summary(cells)
  self.aggregate_cache = { key = key, rows = self.display_rows, text = text }
  return text
end

function Results:footer_summary()
  if self.cancel_query then return self.message, style.dim end
  if self.result_warning then return self.result_warning, style.warn end
  if self.model.column_count == 0 then return nil end
  local selection = self:selection_summary()
  if selection then return selection, style.text end
  -- Like DbVisualizer's rows and columns item, a filter shows the total too.
  -- The text stays until the rows or the result change, so a frame makes none.
  local rows, cache = self:row_count(), self.summary_cache
  if cache and cache.model == self.model and cache.data == self.data and cache.rows == rows then
    return cache.text, style.dim
  end
  local total, columns = #self.model.rows, self.model.column_count
  local text = string.format("%s%d %s · %d %s", rows ~= total and string.format("%d of ", rows) or "", total,
    total == 1 and "row" or "rows", columns, columns == 1 and "column" or "columns")
  local seconds = self.data and self.data.seconds
  if seconds then
    text = text .. " · " .. (seconds < 1 and string.format("%d ms", math.floor(seconds * 1000 + 0.5))
      or seconds < 60 and string.format("%.1f s", seconds)
      or string.format("%d min %d s", math.floor(seconds / 60), math.floor(seconds % 60)))
  end
  if self.data and #self.data.results > 1 then
    text = string.format("Result %d of %d · %s", self.result_index, #self.data.results, text)
  end
  self.summary_cache = { model = self.model, data = self.data, rows = rows, text = text }
  return text, style.dim
end

function Results:draw_status()
  local height = self:footer_height()
  if self.model.column_count > 0 then
    Preview.draw_status(self)
  else
    common.draw_text(style.font, style.dim, self.message, "center", self.position.x, self.position.y,
      self.size.x, self.size.y - height)
  end
  local y = self.position.y + self.size.y - height
  renderer.draw_rect(self.position.x, y, self.size.x, height, style.background2)
  renderer.draw_rect(self.position.x, y, self.size.x, style.divider_size, style.divider)
  local buttons = self:footer_buttons()
  local left = buttons[1] and buttons[1].x or self.position.x + self.size.x
  local text, color = self:footer_summary()
  if text then
    local pad = common.round(10 * SCALE)
    core.push_clip_rect(self.position.x + pad, y, math.max(0, left - self.position.x - pad * 2), height)
    common.draw_text(style.font, color, text:gsub("\n.*", ""), "left", self.position.x + pad, y, 0, height)
    core.pop_clip_rect()
  end
  for i, b in ipairs(buttons) do
    if self.footer_hover == i then
      renderer.draw_rect(b.x, b.y + style.divider_size, b.w, b.h - style.divider_size, style.line_highlight)
    end
    local warn = b.id == "limit" and self.data and (self.data.limited or self.result_warning == self.model.warning
      and self.model.truncated)
    common.draw_text(style.font, warn and style.warn or style.text, b.label, "center", b.x, b.y, b.w, b.h)
  end
end

function Results:footer_button_at(x, y)
  for i, b in ipairs(self:footer_buttons()) do
    if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then return i, b end
  end
end

function Results:in_footer(y)
  return y >= self.position.y + self.size.y - self:footer_height()
end

function Results:on_mouse_moved(x, y, ...)
  local hover = self:in_footer(y) and self:footer_button_at(x, y) or nil
  if hover ~= self.footer_hover then self.footer_hover = hover; core.redraw = true end
  return Preview.on_mouse_moved(self, x, y, ...)
end

function Results:on_mouse_left()
  self.footer_hover = nil
  return Preview.on_mouse_left(self)
end

local LIMITS = { 100, 1000, 10000 }
function Results:press_footer_button(b)
  if b.id == "cancel" then
    if self.cancel_query then self.cancel_query() end
  elseif b.id == "csv" then
    open_text(require("plugins.sql_server.export").csv(self), "csv")
  elseif b.id == "json" then
    open_text(require("plugins.sql_server.export").json(self), "json")
  elseif b.id == "messages" then
    show_messages(self)
  elseif b.id == "sql" then
    return self:open_script(self.run_text)
  elseif b.id == "script" then
    self:script_changes()
  elseif b.id == "discard" then
    self:discard_changes()
  elseif b.id == "limit" then
    local items = {}
    for _, limit in ipairs(LIMITS) do
      items[#items + 1] = { label = limit_label({ sql_row_limit = limit }),
        command = "sql_server:set_row_limit", args = { self.source_buffer, limit } }
    end
    items[#items + 1] = { label = "No Row Limit", command = "sql_server:set_row_limit", args = { self.source_buffer, false } }
    return require("core.context_menu").open(b.x, b.y, items, {})
  end
  return true
end

function Results:on_mouse_pressed(button, x, y, clicks)
  if self:in_footer(y) then
    local _, b = self:footer_button_at(x, y)
    if b and button == "left" then return self:press_footer_button(b) end
    return true
  end
  if button == "left" and (clicks or 1) >= 2 then
    local target = self:hit_test(x, y)
    if target.kind == "cell" then
      self:select_cell(target.display_row, target.column, false)
      return self:edit_cell()
    end
  end
  return Preview.on_mouse_pressed(self, button, x, y, clicks)
end

function Results:cell_menu_items()
  local items = Preview.cell_menu_items(self)
  for _, item in ipairs {
    "-",
    { label = "View Cell", command = "sql_server:view_cell" },
    { label = "Edit Cell", command = "sql_server:edit_cell" },
    { label = "Set to NULL", command = "sql_server:set_cell_null" },
    { label = "Delete Rows", command = "sql_server:delete_rows" },
    { label = "Script Rows as INSERT", command = "sql_server:script_rows_as_insert" },
    { label = "Script Rows as SELECT", command = "sql_server:script_rows_as_select" },
    { label = "Related Rows", command = "sql_server:related_rows" },
    { label = "Script Changes", command = "sql_server:script_changes" },
    { label = "Discard Changes", command = "sql_server:discard_changes" },
    "-",
    { label = "Previous Result", command = "sql_server:previous_result" },
    { label = "Next Result", command = "sql_server:next_result" },
    { label = "View as CSV", command = "sql_server:view_as_csv" },
    { label = "View as JSON", command = "sql_server:view_as_json" },
    { label = "Messages", command = "sql_server:messages" },
    { label = "Keep Result", command = "sql_server:keep_result" },
    { label = "Go to Error", command = "sql_server:results_go_to_error" },
    { label = "Cancel SQL", command = "sql_server:cancel" },
  } do items[#items + 1] = item end
  return items
end

-- The cell at the selection focus, with its source row.
function Results:focus_cell()
  local focus = self.selection_focus
  local row = focus and self:source_row(focus.row)
  if row then return row, focus.column, focus.row end
end

-- Runs action(info) once SQL Server has described the result, or warns.
function Results:with_edit_info(action)
  local sql = require "plugins.sql_server"
  return require("plugins.sql_server.edit").prepare(sql, self, function(info)
    if not self.closed then action(info) end
  end)
end

function Results:set_value(row, column, value)
  local original = row.cells[column]
  local edits = self.edits[row] or {}
  if value == original then edits[column] = nil else edits[column] = value end
  self.edits[row] = next(edits) and edits or nil
  self.edit_revision = (self.edit_revision or 0) + 1
  core.redraw = true
end

-- True when Anvil keeps only the start of the cell's value (`row.cut`) and no
-- edit replaced it. Edits and scripts must not use such a value.
function Results:is_cut(row, column)
  local edits = self.edits and self.edits[row]
  return row.cut ~= nil and row.cut[column] == true and not (edits and edits[column] ~= nil)
end

function Results:cut_message(column)
  return string.format("Anvil has only the first 32,768 characters of a value in %s.", self.model.headers[column])
end

function Results:edit_cell()
  local row, column, display_row = self:focus_cell()
  if not row then return false end
  return self:with_edit_info(function(info)
    if not info.columns[column].editable then
      core.warn("Column %s is not a column of %s that can change.", self.model.headers[column], info.table); return
    end
    if self:is_cut(row, column) then core.warn("%s Change it with SQL.", self:cut_message(column)); return end
    local value = self:cell_value(display_row, column)
    if value and value:find("[\r\n]") then core.warn("Edit values with line breaks in a script."); return end
    core.global_prompt_bar:enter(self.model.headers[column], {
      text = value or "",
      submit = function(text) if self.edits then self:set_value(row, column, text) end end,
    })
  end)
end

-- Opens the focused cell's value in a new text Pane, as JSON or XML when it
-- looks like either, like DbVisualizer's cell viewers.
function Results:view_cell()
  local row, column, display_row = self:focus_cell()
  if not row then return false end
  local value = self:cell_value(display_row, column)
  if value == false then core.warn("The value is NULL."); return false end
  local cut = self:is_cut(row, column)
  local first = value:match("^%s*(.)")
  open_text(value, (first == "{" or first == "[") and "json" or first == "<" and "xml" or nil)
  if cut then
    core.warn("SQL Server sent more of this value. Anvil keeps its first 32,768 characters.")
  end
  return true
end

function Results:set_cells_null()
  local row1, column1, row2, column2 = self:selection_bounds()
  if not row1 then return false end
  return self:with_edit_info(function(info)
    for display_row = row1, row2 do
      local row = self:source_row(display_row)
      for column = column1, column2 do
        if info.columns[column].editable then self:set_value(row, column, false) end
      end
    end
  end)
end

function Results:delete_rows()
  local row1, _, row2 = self:selection_bounds()
  if not row1 then return false end
  return self:with_edit_info(function()
    for display_row = row1, row2 do
      local row = self:source_row(display_row)
      self.deletes[row] = not self.deletes[row] or nil
    end
    core.redraw = true
  end)
end

-- A script opens in a new SQL Query on the result's connection and runs nothing.
function Results:open_script(text)
  local sql = require "plugins.sql_server"
  local c = self.source_buffer and sql.connection_for(self.source_buffer)
  local editor = sql.new_query(self.connection_id or c and c.id)
  if not editor then return false end
  editor.buffer:text_input(text)
  editor.buffer:set_selection(1, 1)
  return true
end

function Results:script_changes()
  local edit = require "plugins.sql_server.edit"
  if not self.edit_info or edit.change_count(self) == 0 then return false end
  core.log_quiet("SQL Server: scripted %d result change(s)", edit.change_count(self))
  return self:open_script(edit.script(self))
end

-- Script Rows as INSERT or as SELECT, for the selected rows of the result's table.
function Results:script_rows(kind)
  local row1, column1, row2, column2 = self:selection_bounds()
  if not row1 then return false end
  return self:with_edit_info(function()
    local edit = require "plugins.sql_server.edit"
    local text, reason, note
    if kind == "insert" then text, reason = edit.insert_script(self, row1, row2)
    else text, reason, note = edit.select_script(self, row1, column1, row2, column2) end
    if not text then core.warn("%s", reason); return end
    core.log_quiet("SQL Server: scripted %d result row(s) as %s", row2 - row1 + 1, kind)
    self:open_script(text)
    if note then core.warn("%s", note) end
  end)
end

-- Lists the rows that foreign keys link to the selected rows. A choice opens
-- its SELECT in a new SQL Query, which runs at once like other generated SELECTs.
function Results:related_rows()
  local row1, column1, row2 = self:selection_bounds()
  if not row1 then return false end
  local sql = require "plugins.sql_server"
  local c = self.source_buffer and sql.connection_for(self.source_buffer)
  if not c or not c.catalog then core.warn("Connect to read the foreign keys."); return false end
  if sql.other_database(self.source_buffer) then
    core.warn("Foreign keys are known only for the connection's database."); return false
  end
  return self:with_edit_info(function()
    local items, reason = require("plugins.sql_server.edit").related(self, c.catalog, row1, row2)
    if not items then core.warn("%s", reason); return end
    local menu = {}
    for i, item in ipairs(items) do
      menu[i] = { label = item.label, command = "sql_server:open_related_rows", args = { self, item.text } }
    end
    local x, y, _, h = self:cell_screen_rect(row1, column1)
    require("core.context_menu").open(x, y + h, menu, {})
  end)
end

function Results:open_related_rows(text)
  local sql = require "plugins.sql_server"
  if not self:open_script(text) then return false end
  core.log_quiet("SQL Server: opened related rows")
  if require("core.config").plugins.sql_server.run_generated_select then sql.run(core.active_view, { whole_buffer = true }) end
  return true
end

-- Opens an export of the shown rows, and warns when it holds cut values.
function Results:export(text, mode)
  local opened = open_text(text, mode)
  for display_row = 1, self:row_count() do
    if self:source_row(display_row).cut then
      core.warn("Anvil has only the first 32,768 characters of some values.")
      break
    end
  end
  return opened
end

function Results:discard_changes()
  self.edits, self.deletes = {}, {}
  self.edit_revision = (self.edit_revision or 0) + 1
  core.redraw = true
  return true
end

local function copy_filters(filters)
  local copy = {}
  for column, selected in pairs(filters) do
    copy[column] = {}
    for value in pairs(selected) do copy[column][value] = true end
  end
  return copy
end

-- A Kept Result is a copy of the run in its own Pane. It keeps the SQL and the
-- connection of the run, and its rows do not change: no new run reaches it, and
-- it takes no edits.
function Results:keep()
  if not self.data then return false end
  local sql = require "plugins.sql_server"
  local c = self.source_buffer and sql.connection_for(self.source_buffer)
  self:save_result_state()
  local copy = Results(self.connection_name)
  copy.kept, copy.kind, copy.run_text = true, self.kind, self.run_text
  copy.connection_id = self.connection_id or c and c.id
  copy:complete(self.data)
  copy.message, copy.edits, copy.deletes = self.message, nil, nil
  for index, state in pairs(self.result_states) do
    local widths = {}
    for i, width in ipairs(state.column_widths) do widths[i] = width end
    copy.result_states[index] = { filters = copy_filters(state.filters), column_widths = widths,
      sort = state.sort and { column = state.sort.column, direction = state.sort.direction }, x = state.x, y = state.y }
  end
  copy.result_index = nil
  copy:show_result(self.result_index or 1)
  local panes = require "core.panes"
  if not panes.place(function() return copy end,
      { pane = panes.pane_for_view(self), placement = "split", direction = "right", focus = false }) then
    return false
  end
  core.log_quiet("SQL Server: kept a result of %d table(s)", #self.data.results)
  return true
end

function Results:duplicate()
  local copy = Results(self.connection_name)
  if self.data then copy:complete(self.data); copy:show_result(self.result_index or 1) end
  return copy
end

function Results:on_close()
  if self.cancel_query then self.cancel_query() end
  Preview.on_close(self)
end

command.add(function()
  local view = core.active_view
  return view and view:is(Results) and view.data ~= nil and not view.cancel_query, view
end, {
  ["sql_server:keep_result"] = function(view) return view:keep() end,
})
command.add(Results, {
  ["sql_server:next_result"] = function(view) view:show_result((view.result_index or 0) + 1) end,
  ["sql_server:previous_result"] = function(view) view:show_result((view.result_index or 2) - 1) end,
  ["sql_server:messages"] = show_messages,
})
command.add(function()
  local view = core.active_view
  return view and view:is(Results) and view.selection_focus ~= nil and view:focus_cell() ~= nil, view
end, {
  ["sql_server:view_cell"] = function(view) return view:view_cell() end,
})
command.add(function()
  local view = core.active_view
  return view and view:is(Results) and view.edits ~= nil and view.selection_focus ~= nil, view
end, {
  ["sql_server:edit_cell"] = function(view) return view:edit_cell() end,
  ["sql_server:set_cell_null"] = function(view) return view:set_cells_null() end,
  ["sql_server:delete_rows"] = function(view) return view:delete_rows() end,
  ["sql_server:script_rows_as_insert"] = function(view) return view:script_rows("insert") end,
  ["sql_server:script_rows_as_select"] = function(view) return view:script_rows("select") end,
  ["sql_server:related_rows"] = function(view) return view:related_rows() end,
})
command.add(function(view, text)
  return view ~= nil and type(text) == "string" and not view.closed, view, text
end, {
  ["sql_server:open_related_rows"] = function(view, text) return view:open_related_rows(text) end,
})
command.add(function()
  local view = core.active_view
  return view and view:is(Results) and view.edits ~= nil
    and require("plugins.sql_server.edit").change_count(view) > 0, view
end, {
  ["sql_server:script_changes"] = function(view) return view:script_changes() end,
  ["sql_server:discard_changes"] = function(view) return view:discard_changes() end,
})
command.add(function()
  local view = core.active_view
  return view and view:is(Results) and view.model.column_count > 0, view
end, {
  ["sql_server:view_as_csv"] = function(view)
    return view:export(require("plugins.sql_server.export").csv(view), "csv")
  end,
  ["sql_server:view_as_json"] = function(view)
    return view:export(require("plugins.sql_server.export").json(view), "json")
  end,
})
command.add(function()
  local view = core.active_view
  local buffer = view and view:is(Results) and view.source_buffer
  return buffer and require("plugins.sql_server").error_line(buffer) ~= nil, view, buffer
end, {
  ["sql_server:results_go_to_error"] = function(_, buffer)
    for _, editor in ipairs(core.get_views_referencing_buffer(buffer)) do
      local pane = require("core.panes").pane_for_view(editor)
      if pane then
        require("core.panes").present(editor, { focus = true })
        return command.perform("sql_server:go_to_error")
      end
    end
    return false
  end,
})

return Results
