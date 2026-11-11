local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local Preview = require "plugins.tabular_data_preview"

local Results = Preview:extend()
local empty = { headers = {}, rows = {}, column_count = 0, distinct_values = {} }
function Results:__tostring() return "SQLResults" end

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
  self.parse_warning = self.data.error or (self.data.limited and "Result limit reached. Later statements may not have run.") or model.warning
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

function Results:draw_status()
  if self.model.column_count > 0 then return Preview.draw_status(self) end
  common.draw_text(style.font, style.dim, self.message, "center", self.position.x, self.position.y,
    self.size.x, self.size.y)
end

function Results:on_mouse_pressed(button, x, y, clicks)
  if button ~= "right" then return Preview.on_mouse_pressed(self, button, x, y, clicks) end
  local row, column = self:cell_at(x, y)
  if row and not self:cell_is_selected(row, column) then self:select_cell(row, column, false) end
  return require("core.context_menu").open(x, y, {
    { label = "Copy", command = "tabular_data:copy_selection" },
    { label = "Previous Result", command = "sql_server:previous_result" },
    { label = "Next Result", command = "sql_server:next_result" },
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
  ["sql_server:messages"] = function(view)
    local text = view:messages_text()
    require("core.panes").place(function()
      return require("core.textview").from_text(text, { name = "SQL Messages" })
    end, { placement = "current", focus = true })
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
