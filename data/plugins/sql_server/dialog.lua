local core = require "core"
local common = require "core.common"
local style = require "core.style"
local ui = require "core.ui"
local Dialog = require("core.ui.dialog").Dialog
local List = require "core.ui.list"
local Button = require "core.ui.button"
local TextField = require "core.ui.text_field"
local Segmented = require "core.ui.segmented"
local project_look = require "core.project_look"
local sql = require "plugins.sql_server"
local Databases = Dialog:extend()

function Databases:new()
  local path = core.root_project().path
  local name = project_look.name { path = path, scratch = core.is_scratch_project(path) }
  Databases.super.new(self, { title = "Project Databases — " .. name, width = 660 })
  self.fields = {}
  self.list = self:add(List {
    row_height = ui.metrics().control_h,
    draw_row = function(c, x, y, w, h)
      common.draw_text(ui.font(), style.text, ui.fit_text(ui.font(), c.name, w * 0.6), "left", x + ui.metrics().pad_x, y, w * 0.6, h)
      common.draw_text(ui.font(), style.card_text, c.state, "right", x, y, w - ui.metrics().pad_x, h)
    end,
    on_select = function() self:show_selected() end,
  })
  for _, key in ipairs({ "name", "server", "database" }) do
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
  self.fields.user = self:add(TextField { on_submit = function(value)
    local c = self:selected()
    return c and sql.update(c.id, "user", value) or false
  end })
  self.password = self:add(TextField { secret = true })
  self.trust = self:add(Segmented { on_change = function(value)
    local c = self:selected()
    if not c then return false end
    sql.update(c.id, "encrypt", value ~= "none")
    return sql.update(c.id, "trust_certificate", value == "trust")
  end })
  self.trust:set_options({ { value = "verify", label = "Verify" }, { value = "trust", label = "Trust Certificate" },
    { value = "none", label = "No Encryption" } }, "verify")
  self.add_button = self:add(Button { label = "Add Connection", on_click = function()
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
  self.form_rows = {
    { "Name", self.fields.name }, { "Server", self.fields.server }, { "Database", self.fields.database },
    { "Authentication", self.auth }, { "User", self.fields.user }, { "Password", self.password }, { "TLS", self.trust },
  }
  self.actions = { self.add_button, self.remove_button, self.connect_button, self.disconnect_button }
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
    field.visible = field.enabled
  end
  self.selected_id = c and c.id
  self.auth.value = c and not c.integrated and "sql" or "windows"
  self.trust.value = c and c.encrypt == false and "none" or (c and c.trust_certificate and "trust" or "verify")
  self.auth.enabled, self.trust.enabled = c ~= nil, c ~= nil
  self.auth.visible, self.trust.visible = c ~= nil, c ~= nil
  self.password.enabled = c ~= nil and not c.integrated
  self.password.visible = self.password.enabled
  if not self.password.visible then self.password:set_text("") end
  self.list.visible = c ~= nil
  local title_width = ui.bold_font():get_width(self.title) + 2 * self:metrics().pad + ui.metrics().control_h
  self.width = c and 660 or math.min(660, math.max(360, title_width / SCALE))
  self.add_button.enabled = sql.ready()
  self.add_button.kind = c and "secondary" or "primary"
  self.remove_button.enabled = c ~= nil
  self.remove_button.visible = c ~= nil
  self.connect_button.enabled = c ~= nil and c.state ~= "Connecting"
  self.connect_button.visible = c ~= nil
  self.connect_button.label = c and c.state == "Ready" and "Refresh" or "Connect"
  self.disconnect_button.enabled = c ~= nil and c.state ~= "Disconnected"
  self.disconnect_button.visible = c ~= nil and (c.state == "Ready" or c.state == "Connecting")
  self.query_button.enabled = c ~= nil
  self.query_button.visible = c ~= nil
  self.bind_button.enabled = c ~= nil and self.source ~= nil and self.source.buffer ~= nil
  self.bind_button.visible = self.bind_button.enabled
  if self.is_open and (not self.focused or not self.focused:can_focus()) then self:focus(c and self.list or self.add_button) end
end
function Databases:on_update()
  if self.generation ~= sql.generation then self:refresh() end
end
function Databases:layout_content(x, y, w, max_h)
  local m = ui.metrics()
  local gap, h = m.gap, m.control_h
  local c = self:selected()
  self.content_x, self.content_w = x, w
  self.status_error = sql.load_error or sql.save_error or (c and c.error)
  self.status_text = self.status_error or (not sql.ready() and "Loading…") or nil
  local cy = y
  if not c then
    if self.status_text then self.status_y = cy; cy = cy + h + gap end
    self.add_button:set_rect(x, cy, w, h)
    return cy + h - y
  end
  local rows = 2
  for _, row in ipairs(self.form_rows) do if row[2].visible then rows = rows + 1 end end
  if self.status_text then rows = rows + 1 end
  local list_h = math.max(h, math.min(h * math.min(#sql.connections, 3), max_h - rows * (h + gap)))
  self.list:set_rect(x, cy, w, list_h)
  cy = cy + list_h + gap
  local label_w = ui.font():get_width("Authentication") + m.pad_x * 2
  for _, row in ipairs(self.form_rows) do
    local control = row[2]
    if control.visible then
      control:set_rect(x + label_w, cy, w - label_w, h)
      cy = cy + h + gap
    end
  end
  if self.status_text then self.status_y = cy; cy = cy + h + gap end
  local bx = x
  for _, button in ipairs(self.actions) do
    if button.visible then
      local width = button:measure()
      button:set_rect(bx, cy, width, h); bx = bx + width + gap
    end
  end
  cy = cy + h + gap
  local width = self.query_button:measure()
  self.query_button:set_rect(x + w - width, cy, width, h)
  self.bind_button:set_rect(x, cy, self.bind_button:measure(), h)
  return cy + h - y
end
function Databases:draw_content()
  local font, h = ui.font(), ui.metrics().control_h
  for _, row in ipairs(self.form_rows) do
    if row[2].visible then
      common.draw_text(font, style.card_text, row[1], "left", self.content_x, row[2].y, self.content_w, h)
    end
  end
  if self.status_text then
    common.draw_text(font, self.status_error and style.error or style.card_text, ui.fit_text(font, self.status_text, self.content_w),
      "left", self.content_x, self.status_y, self.content_w, h)
  end
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
  instance:open(instance:selected() and instance.list or instance.add_button)
  return instance
end
return M
