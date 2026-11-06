local core = require "core"
local common = require "core.common"
local style = require "core.style"
local ui = require "core.ui"
local Dialog = require("core.ui.dialog").Dialog
local List = require "core.ui.list"
local Button = require "core.ui.button"
local TextField = require "core.ui.text_field"
local Segmented = require "core.ui.segmented"
local sql = require "plugins.sql_server"
local Databases = Dialog:extend()

function Databases:new()
  Databases.super.new(self, { title = "Databases", width = 660 })
  self.fields, self.labels = {}, {}
  self.list = self:add(List {
    row_height = ui.metrics().control_h,
    draw_row = function(c, x, y, w, h)
      common.draw_text(ui.font(), style.text, ui.fit_text(ui.font(), c.name, w * 0.6), "left", x + ui.metrics().pad_x, y, w * 0.6, h)
      common.draw_text(ui.font(), style.card_text, c.state, "right", x, y, w - ui.metrics().pad_x, h)
    end,
    on_select = function() self:show_selected() end,
  })
  for _, spec in ipairs({ { "name", "Name" }, { "server", "Server" }, { "database", "Database" }, { "user", "User" } }) do
    local key = spec[1]
    self.labels[key] = spec[2]
    self.fields[key] = self:add(TextField {
      on_submit = function(value)
        local c = self:selected()
        if not c then return false end
        return sql.update(c.id, key, value)
      end,
    })
  end
  self.auth = self:add(Segmented { on_change = function(value)
    local c = self:selected()
    if c then sql.update(c.id, "integrated", value == "windows"); self:show_selected(); return true end
    return false
  end })
  self.auth:set_options({ { value = "windows", label = "Windows" }, { value = "sql", label = "SQL Login" } }, "windows")
  self.password = self:add(TextField { secret = true })
  self.trust = self:add(Segmented { on_change = function(value)
    local c = self:selected()
    if not c then return false end
    sql.update(c.id, "encrypt", value ~= "none")
    return sql.update(c.id, "trust_certificate", value == "trust")
  end })
  self.trust:set_options({ { value = "verify", label = "Verify" }, { value = "trust", label = "Trust Certificate" },
    { value = "none", label = "No Encryption" } }, "verify")
  self.add_button = self:add(Button { label = "Add", on_click = function()
    local c = sql.add_connection()
    if c then self:refresh(c.id); self:focus(self.fields.name) end
  end })
  self.remove_button = self:add(Button { label = "Remove", kind = "danger", on_click = function()
    local c = self:selected()
    if c then sql.remove(c.id); self:refresh() end
  end })
  self.connect_button = self:add(Button { label = "Connect", on_click = function()
    local c = self:selected()
    if not c then return end
    sql.connect(c.id, self.password:get_text())
    self.password:set_text("")
  end })
  self.disconnect_button = self:add(Button { label = "Disconnect", on_click = function()
    local c = self:selected()
    if c then sql.disconnect(c.id); self.password:set_text("") end
  end })
  self.query_button = self:add(Button { label = "New Query", kind = "primary", on_click = function()
    local c = self:selected()
    if c then self:close(); sql.new_query(c.id) end
  end })
  self.bind_button = self:add(Button { label = "Use for Query", on_click = function()
    local c = self:selected()
    if c and self.source and self.source.buffer then sql.bind(self.source.buffer, c.id); self:close() end
  end })
  self:refresh()
end
function Databases:selected() return self.list:selected_row() end
function Databases:refresh(id)
  local previous = self:selected()
  id = id or (previous and previous.id)
  local index = 1
  for i, c in ipairs(sql.connections) do if c.id == id then index = i end end
  self.list:set_rows(sql.connections, index)
  self.generation = sql.generation
  self:show_selected()
end
function Databases:show_selected()
  local c = self:selected()
  if self.selected_id ~= (c and c.id) then self.password:set_text("") end
  for key, field in pairs(self.fields) do
    if self.selected_id ~= (c and c.id) or field:get_text() == field.accepted then field:set_text(c and c[key] or "") end
    field.enabled = c ~= nil and (key ~= "user" or not c.integrated)
  end
  self.selected_id = c and c.id
  self.auth.value = c and not c.integrated and "sql" or "windows"
  self.trust.value = c and c.encrypt == false and "none" or (c and c.trust_certificate and "trust" or "verify")
  self.auth.enabled, self.trust.enabled = c ~= nil, c ~= nil
  self.password.enabled = c ~= nil and not c.integrated
  self.add_button.enabled = sql.ready()
  self.remove_button.enabled = c ~= nil
  self.connect_button.enabled = c ~= nil and c.state ~= "Connecting"
  self.disconnect_button.enabled = c ~= nil and c.state ~= "Disconnected"
  self.query_button.enabled = c ~= nil
  self.bind_button.enabled = c ~= nil and self.source ~= nil and self.source.buffer ~= nil
end
function Databases:on_update()
  if self.generation ~= sql.generation then self:refresh() end
end
function Databases:layout_content(x, y, w, max_h)
  local m = ui.metrics()
  local gap, h = m.gap, m.control_h
  local list_h = h * math.max(1, math.min(#sql.connections, 3))
  list_h = math.max(h, math.min(list_h, max_h - 11 * (h + gap)))
  self.list:set_rect(x, y, w, list_h)
  local cy = y + list_h + gap
  self.captions = self.captions or {}
  local label_w = ui.font():get_width("Authentication") + m.pad_x * 2
  local function row(label, control)
    self.captions[label] = cy
    control:set_rect(x + label_w, cy, w - label_w, h)
    cy = cy + h + gap
  end
  row("Name", self.fields.name); row("Server", self.fields.server); row("Database", self.fields.database)
  row("Authentication", self.auth); row("User", self.fields.user); row("Password", self.password); row("TLS", self.trust)
  self.status_y = cy
  cy = cy + h + gap
  local bx = x
  for _, button in ipairs({ self.add_button, self.remove_button, self.connect_button, self.disconnect_button }) do
    local width = button:measure()
    button:set_rect(bx, cy, width, h); bx = bx + width + gap
  end
  cy = cy + h + gap
  local width = self.query_button:measure()
  self.query_button:set_rect(x + w - width, cy, width, h)
  self.bind_button:set_rect(x, cy, self.bind_button:measure(), h)
  self.content_x, self.content_w = x, w
  return cy + h - y
end
function Databases:draw_content()
  local font, h = ui.font(), ui.metrics().control_h
  for label, y in pairs(self.captions) do
    common.draw_text(font, style.card_text, label, "left", self.content_x, y, self.content_w, h)
  end
  local c = self:selected()
  local error = sql.load_error or sql.save_error or (c and c.error)
  local message = error or (sql.is_saving() and "Saving") or (not sql.ready() and "Loading") or ""
  common.draw_text(font, error and style.error or style.card_text, ui.fit_text(font, message, self.content_w),
    "left", self.content_x, self.status_y, self.content_w, h)
  Databases.super.draw_content(self)
end
function Databases:on_close()
  self.password:set_text("")
end
local M = { Dialog = Databases }
function M.open()
  sql.load()
  local open = require("core.ui.dialog").current()
  if open and open:is(Databases) then return open end
  local instance = Databases()
  instance.source = core.active_view and core.active_view:extends(require "core.editor") and core.active_view or nil
  instance:refresh(instance.source and instance.source.buffer.sql_connection_id)
  instance:open(instance.list)
  return instance
end
return M
