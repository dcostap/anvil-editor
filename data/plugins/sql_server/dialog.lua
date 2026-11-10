-- The Project Databases Dialog: the Project's SQL Server connections. The list shows each connection and its
-- state. The fields below it change the selected one. Each change applies at once.

local core = require "core"
local common = require "core.common"
local style = require "core.style"
local ui = require "core.ui"
local layout = require "core.ui.layout"
local Dialog = require("core.ui.dialog").Dialog
local List = require "core.ui.list"
local Button = require "core.ui.button"
local TextField = require "core.ui.text_field"
local Segmented = require "core.ui.segmented"
local Select = require "core.ui.select"
local StatusDot = require "core.ui.status_dot"
local EmptyState = require "core.ui.empty_state"
local project_look = require "core.project_look"
local sql = require "plugins.sql_server"
local Databases = Dialog:extend()

function Databases:__tostring() return "Databases" end

-- The shown state of each connection state, and its tone.
local STATES = {
  Disconnected = { "Disconnected", "neutral" },
  Connecting = { "Connecting", "info" },
  Ready = { "Connected", "success" },
  Failed = { "Failed", "danger" },
}

-- One dot draws the state of each row.
local row_dot = StatusDot {}

local function draw_connection(c, x, y, w, h)
  local font, pad = ui.font(), ui.metrics().pad_x
  local state = STATES[c.state] or STATES.Disconnected
  row_dot:set(state[2], state[1])
  local dot_w = row_dot:width()
  row_dot:place(x + w - pad - dot_w, y, dot_w, h)
  row_dot:draw_node()
  local name_w = w - 2 * pad - dot_w - ui.metrics().gap
  common.draw_text(font, style.dialog_text, ui.fit_text(font, c.name, name_w), "left", x + pad, y, name_w, h)
end

function Databases:new()
  local path = core.root_project().path
  local name = project_look.name { path = path, scratch = core.is_scratch_project(path) }
  Databases.super.new(self, { title = "Project Databases — " .. name, width = 660 })
  self.fields = {}
  self.list = List {
    row_height = ui.metrics().control_h,
    max_rows = 3,
    draw_row = draw_connection,
    on_select = function() self:show_selected() end,
  }
  for _, key in ipairs({ "name", "server", "database", "user" }) do
    self.fields[key] = TextField {
      width = 320,
      on_submit = function(value)
        local c = self:selected()
        if not c then return false end
        return sql.update(c.id, key, value)
      end,
    }
  end
  self.auth = Segmented {
    options = { { value = "windows", label = "Windows" }, { value = "sql", label = "SQL Login" } },
    value = "windows",
    on_change = function(value)
      local c = self:selected()
      if not c then return false end
      sql.update(c.id, "integrated", value == "windows")
      self:show_selected()
      return true
    end,
  }
  self.password = TextField { width = 320, secret = true }
  self.trust = Select {
    width = 200,
    options = { { value = "verify", label = "Verify Certificate" }, { value = "trust", label = "Trust Certificate" },
      { value = "none", label = "No Encryption" } },
    value = "verify",
    on_change = function(value)
      local c = self:selected()
      if not c then return false end
      sql.update(c.id, "encrypt", value ~= "none")
      return sql.update(c.id, "trust_certificate", value == "trust")
    end,
  }
  self.add_button = Button { label = "Add Connection", icon = ui.icons.add, on_click = function()
    local c = sql.add_connection()
    if c then self:refresh(c.id); self:focus(self.fields.name) end
  end }
  self.remove_button = Button { label = "Remove", icon = ui.icons.remove, kind = "danger", on_click = function()
    local c = self:selected()
    if c then sql.remove(c.id); self:refresh() end
  end }
  self.connect_button = Button { label = "Connect", on_click = function()
    local c = self:selected()
    if not c then return end
    sql.connect(c.id, self.password:get_text())
    self.password:set_text("")
  end }
  self.disconnect_button = Button { label = "Disconnect", on_click = function()
    local c = self:selected()
    if c then sql.disconnect(c.id); self.password:set_text("") end
  end }
  self.query_button = Button { label = "New Query", kind = "primary", on_click = function()
    local c = self:selected()
    if c then self:close(); sql.new_query(c.id) end
  end }
  self.bind_button = Button { label = "Use for Query", on_click = function()
    local c = self:selected()
    if c and self.source and self.source.buffer then sql.bind(self.source.buffer, c.id); self:close() end
  end }
  self.status_text = layout.Text {}
  self.user_row = layout.Field { title = "User", control = self.fields.user }
  self.password_row = layout.Field { title = "Password", control = self.password }
  self.form = layout.Column {
    self.list,
    layout.Group {
      layout.Field { title = "Name", control = self.fields.name },
      layout.Field { title = "Server", control = self.fields.server },
      layout.Field { title = "Database", control = self.fields.database },
      layout.Field { title = "Authentication", control = self.auth },
      self.user_row,
      self.password_row,
      layout.Field { title = "Encryption", control = self.trust },
    },
    self.status_text,
    layout.Row { gap = 8, self.connect_button, self.disconnect_button, layout.Spacer { grow = 1 },
      self.add_button, self.remove_button },
  }
  -- Without connections, the body shows only the Add button. The status shows in both bodies.
  self.empty = layout.Column {
    EmptyState {
      icon = ui.icons.database, title = "No connections",
      description = "Add a SQL Server connection for this Project.",
      actions = { self.add_button },
    },
    self.status_text,
  }
  self.footer = layout.Row { self.bind_button, layout.Spacer { grow = 1 }, self.query_button }
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
  end
  self.selected_id = c and c.id
  self.auth.value = c and not c.integrated and "sql" or "windows"
  self.trust:set_value(c and c.encrypt == false and "none" or (c and c.trust_certificate and "trust" or "verify"))
  local login = c ~= nil and not c.integrated
  self.user_row.visible, self.password_row.visible = login, login
  self.fields.user.enabled, self.password.enabled = login, login
  if not login then self.password:set_text("") end
  self:set_body(c and self.form or self.empty)
  self.status_text.align = c and "left" or "center"
  self.width = c and 660 or 480
  self.add_button.enabled = sql.ready()
  self.add_button.kind = c and "secondary" or "primary"
  self.remove_button.enabled = c ~= nil
  self.connect_button.enabled = c ~= nil and c.state ~= "Connecting"
  self.connect_button.label = c and c.state == "Ready" and "Refresh" or "Connect"
  self.disconnect_button.enabled = c ~= nil and c.state ~= "Disconnected"
  self.disconnect_button.visible = c ~= nil and (c.state == "Ready" or c.state == "Connecting")
  self.query_button.enabled = c ~= nil
  self.query_button.visible = c ~= nil
  self.bind_button.enabled = c ~= nil and self.source ~= nil and self.source.buffer ~= nil
  self.bind_button.visible = self.bind_button.enabled
  self.footer.visible = c ~= nil
  if self.is_open and (not self.focused or not self.focused:can_focus()) then self:focus(c and self.list or self.add_button) end
end

function Databases:on_update()
  if self.generation ~= sql.generation then self:refresh() end
  -- The state of a connection changes without a new generation.
  local c = self:selected()
  local error = sql.load_error or sql.save_error or (c and c.error)
  self.status_text:set_text(error or (not sql.ready() and "Loading…") or "")
  self.status_text.color = error and style.dialog_danger or nil
  self.status_text.visible = self.status_text.text ~= ""
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
