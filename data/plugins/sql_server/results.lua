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
  buffer:set_language_mode(mode, { reason = "SQL Result text" })
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

function Results:begin_run(cancel, explain)
  self.cancel_query = cancel
  self.data = nil
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
  if data.limited then lines[#lines + 1] = "A result limit stopped the run. Later statements may not have run." end
  if data.transaction_count and data.transaction_count > 0 then
    lines[#lines + 1] = string.format("Open transactions: %d. Commit or roll back.", data.transaction_count)
  end
  return #lines > 0 and table.concat(lines, "\n") or self.message
end

function Results:show_result(index)
  local model = self.data and self.data.results and self.data.results[index]
  if not model then return false end
  self.result_index = index
  self.filters, self.sort = {}, nil
  self.scroll.x, self.scroll.y, self.scroll.to.x, self.scroll.to.y = 0, 0, 0, 0
  self:publish_model(model, index)
  self.result_warning = self.data.error or (self.data.limited and "Result limit reached. Later statements may not have run.") or model.warning
  self.title = string.format("%s %d/%d · %s", self.kind or "SQL Results", index, #self.data.results, self.connection_name)
  core.redraw = true
  return true
end

function Results:complete(data)
  self.cancel_query = nil
  self.data = data
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
  if self.cancel_query then labels[#labels + 1] = "cancel" end
  if self.source_buffer then labels[#labels + 1] = "limit" end
  if self.model.column_count > 0 then labels[#labels + 1] = "csv"; labels[#labels + 1] = "json" end
  if self.data then labels[#labels + 1] = "messages" end
  local names = { cancel = "Cancel", csv = "CSV", json = "JSON", messages = "Messages" }
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

function Results:footer_summary()
  if self.cancel_query then return self.message, style.dim end
  if self.result_warning then return self.result_warning, style.warn end
  if self.model.column_count == 0 then return nil end
  local rows = self:row_count()
  local text = string.format("%d %s", rows, rows == 1 and "row" or "rows")
  if self.data and #self.data.results > 1 then
    text = string.format("Result %d of %d · %s", self.result_index, #self.data.results, text)
  end
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
  if button ~= "right" then return Preview.on_mouse_pressed(self, button, x, y, clicks) end
  local row, column = self:cell_at(x, y)
  if row and not self:cell_is_selected(row, column) then self:select_cell(row, column, false) end
  return require("core.context_menu").open(x, y, {
    { label = "Copy", command = "tabular_data:copy_selection" },
    { label = "Previous Result", command = "sql_server:previous_result" },
    { label = "Next Result", command = "sql_server:next_result" },
    { label = "View as CSV", command = "sql_server:view_as_csv" },
    { label = "View as JSON", command = "sql_server:view_as_json" },
    { label = "Messages", command = "sql_server:messages" },
    { label = "Go to Error", command = "sql_server:results_go_to_error" },
    { label = "Cancel SQL", command = "sql_server:cancel" },
  }, { button = button })
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

command.add(Results, {
  ["sql_server:next_result"] = function(view) view:show_result((view.result_index or 0) + 1) end,
  ["sql_server:previous_result"] = function(view) view:show_result((view.result_index or 2) - 1) end,
  ["sql_server:messages"] = show_messages,
})
command.add(function()
  local view = core.active_view
  return view and view:is(Results) and view.model.column_count > 0, view
end, {
  ["sql_server:view_as_csv"] = function(view)
    return open_text(require("plugins.sql_server.export").csv(view), "csv")
  end,
  ["sql_server:view_as_json"] = function(view)
    return open_text(require("plugins.sql_server.export").json(view), "json")
  end,
})
command.add(function()
  local view = core.active_view
  local buffer = view and view:is(Results) and view.source_buffer
  return buffer and buffer.sql_error_line ~= nil, view, buffer
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
