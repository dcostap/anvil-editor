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

function Results:begin_run(cancel)
  self.cancel_query = cancel
  self.data = nil
  self.message = "Running SQL…"
  self.title = "SQL Results · " .. self.connection_name
  self:publish_model(empty, 0)
end

function Results:show_result(index)
  local model = self.data and self.data.results and self.data.results[index]
  if not model then return false end
  self.result_index = index
  self.filters, self.sort = {}, nil
  self.scroll.x, self.scroll.y, self.scroll.to.x, self.scroll.to.y = 0, 0, 0, 0
  self:publish_model(model, index)
  self.parse_warning = self.data.error or (self.data.limited and "Result limit reached. Later statements may not have run.") or model.warning
  self.title = string.format("SQL Results %d/%d · %s", index, #self.data.results, self.connection_name)
  core.redraw = true
  return true
end

function Results:complete(data)
  self.cancel_query = nil
  self.data = data
  if data.cancelled then
    self.message = "SQL cancelled. Committed changes remain."
  elseif data.error then
    self.message = data.error
  elseif data.affected_rows and #data.affected_rows > 0 then
    self.message = table.concat(data.affected_rows, ", ") .. " rows affected"
  else
    self.message = "SQL finished."
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
    require("core.panes").place(function()
      return require("core.textview").from_text(view.message, { name = "SQL Messages" })
    end, { placement = "current", focus = true })
  end,
})

return Results
