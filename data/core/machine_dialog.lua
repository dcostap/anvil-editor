-- The Machines Dialog. "This PC" shows how other devices reach this PC's Machine server, makes pairing codes
-- and lists the paired devices. "Other Machines" lists the Machines that this PC paired with, and pairs with a new
-- one. Each change applies at once.

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local json = require "core.json"
local style = require "core.style"
local ui = require "core.ui"
local layout = require "core.ui.layout"
local Dialog = require("core.ui.dialog").Dialog
local Button = require "core.ui.button"
local List = require "core.ui.list"
local Segmented = require "core.ui.segmented"
local TextField = require "core.ui.text_field"
local StatusDot = require "core.ui.status_dot"
local MachineClient = require "core.machine_client"
local access = require "core.machine_access"

local MachineDialog = Dialog:extend()

function MachineDialog:__tostring() return "MachineDialog" end

-- The rows that each list shows before it scrolls.
local VISIBLE_ROWS = 4

-- The pages of the Dialog, one at a time. The node is as tall as its tallest page, so the card does not move when
-- the page changes.
local Pages = layout.Node:extend()

function Pages:content_width()
  local widest = 0
  for _, page in ipairs(self.children) do widest = math.max(widest, page:width()) end
  return widest
end

function Pages:content_height(w)
  local tallest = 0
  for _, page in ipairs(self.children) do tallest = math.max(tallest, page:height(w)) end
  return tallest
end

function Pages:place(x, y, w, h)
  Pages.super.place(self, x, y, w, h)
  for _, page in ipairs(self.children) do
    if page.visible then page:place(x, y, w, page:height(w)) end
  end
end
-- The port of a Machine address without one. The Machine server uses it unless it starts with `--port`.
local DEFAULT_PORT = 7690
-- How often the open Dialog asks this PC's server for its devices, in seconds.
local DEVICES_INTERVAL = 2

local LEVELS = { full = "Full control", view = "View" }

local function server_file()
  return USERDIR .. PATHSEP .. "machine" .. PATHSEP .. "server.json"
end

-- The port of this PC's Machine server, from its discovery file.
local function server_port()
  local file = io.open(server_file(), "rb")
  if not file then return nil end
  local ok, found = pcall(json.decode, file:read("*a") or "")
  file:close()
  return ok and type(found) == "table" and type(found.port) == "number" and found.port or nil
end

-- "host" or "host:port". Returns the host and the port, or nil.
local function parse_address(text)
  text = text:match("^%s*(.-)%s*$")
  local host, port = text:match("^([^%s:/]+):(%d+)$")
  if host then return host, tonumber(port) end
  if text:match("^[^%s:/]+$") then return text, DEFAULT_PORT end
end

local function machine_label(record)
  if record.port == DEFAULT_PORT then return record.host end
  return record.host .. ":" .. tostring(record.port)
end

function MachineDialog:new()
  MachineDialog.super.new(self, { title = "Machines", width = 600 })
  self.page = "this"
  self.page_control = Segmented({
    options = { { value = "this", label = "This PC" }, { value = "others", label = "Other Machines" } },
    value = "this",
    on_change = function(page)
      self:show_page(page)
      return true
    end,
  })
  local row_h = ui.metrics().control_h

  -- This PC
  self.access_button = Button({ label = "Share on Tailnet", size = "small",
    on_click = function() self:toggle_access() end })
  self.level_control = Segmented({
    options = { { value = "full", label = LEVELS.full }, { value = "view", label = LEVELS.view } },
    value = "full",
  })
  self.code_button = Button({ label = "Make Code", on_click = function() self:make_code() end })
  self.device_list = List({
    row_height = row_h,
    max_rows = VISIBLE_ROWS,
    empty = "No paired devices",
    draw_row = function(...) self:draw_device(...) end,
    on_select = function() self:update_buttons() end,
  })
  self.revoke_button = Button({
    label = "Revoke", icon = ui.icons.remove, kind = "danger", size = "small",
    on_click = function() self:revoke() end,
  })

  -- Other Machines
  self.machine_list = List({
    row_height = row_h,
    max_rows = VISIBLE_ROWS,
    empty = "No paired Machines",
    draw_row = function(...) self:draw_machine(...) end,
    on_select = function() self:update_buttons() end,
    on_activate = function() self:open_project() end,
  })
  self.open_button = Button({
    label = "Open Project", icon = ui.icons.open_in_new, size = "small",
    on_click = function() self:open_project() end,
  })
  self.forget_button = Button({
    label = "Forget", icon = ui.icons.remove, kind = "danger", size = "small",
    on_click = function() self:forget() end,
  })
  self.address_field = TextField({ width = 280, placeholder = "host or host:port",
    on_change = function() self:update_buttons() end })
  self.code_field = TextField({ width = 140, on_change = function() self:update_buttons() end })
  self.pair_button = Button({ label = "Pair", on_click = function() self:pair() end })

  self.done_button = Button({ label = "Done", kind = "primary", min_width = 88, on_click = function() self:close() end })

  self.access_row = layout.Field { title = "Access", description = "", control = self.access_button }
  self.code_text = layout.Text { role = "title", wrap = false }
  self.code_timer = layout.Text { role = "meta", wrap = false }
  self.code_row = layout.Row { self.code_text, layout.Spacer { grow = 1 }, self.code_timer }
  self.pair_status = layout.Text {}
  self.this_page = layout.Column {
    layout.Group {
      self.access_row,
      layout.Field { title = "Pairing", control = layout.Row { gap = 8, self.level_control, self.code_button } },
      self.code_row,
    },
    layout.Group {
      title = "Devices",
      self.device_list,
      layout.Row { justify = "end", self.revoke_button },
    },
  }
  self.others_page = layout.Column {
    layout.Group {
      title = "Paired Machines",
      self.machine_list,
      layout.Row { gap = 8, justify = "end", self.open_button, self.forget_button },
    },
    layout.Group {
      title = "Pair a Machine",
      layout.Field { title = "Address", control = self.address_field },
      layout.Field { title = "Code", control = layout.Row { gap = 8, self.code_field, self.pair_button } },
      self.pair_status,
    },
  }
  self.body = layout.Column {
    layout.Row { self.page_control },
    Pages { self.this_page, self.others_page },
  }
  self.footer = layout.Row { justify = "end", self.done_button }

  self.owner = MachineClient.new(server_file(), function()
    self:update_buttons()
    self:refresh_devices()
  end)
  self.clients = {}
  self:refresh_machines()
  self:check_access()
  self:show_page("this")
  -- Clients report no changes, so the open Dialog looks again each second. It also asks for the devices, so a
  -- device that pairs with the code shows at once.
  core.add_thread(function()
    local next_devices = 0
    while self.owner do
      if self.owner.state == "ready" and self.page == "this" and system.get_time() >= next_devices then
        next_devices = system.get_time() + DEVICES_INTERVAL
        self:refresh_devices()
      end
      self:update_buttons()
      core.redraw = true
      coroutine.yield(1)
    end
  end)
end

function MachineDialog:show_page(page)
  self.page = page
  self.page_control:set_value(page)
  local this = page == "this"
  self.this_page.visible, self.others_page.visible = this, not this
  if this then self:refresh_devices() end
  self:update_buttons()
end

function MachineDialog:update_buttons()
  local ready = self.owner and self.owner.state == "ready"
  self.code_button.enabled = ready
  self.level_control.enabled = ready
  self.revoke_button.enabled = ready and self.device_list:selected_row() ~= nil
  local state = self.access and self.access.state
  self.access_button.visible = state == "off" or state == "on" or state == "error"
  self.access_button.enabled = not self.changing_access
  self.access_button.label = state == "on" and "Stop Sharing" or "Share on Tailnet"
  local machine = self.machine_list:selected_row()
  self.open_button.enabled = machine ~= nil
  self.forget_button.enabled = machine ~= nil
  self.pair_button.enabled = not self.pairing and parse_address(self.address_field:get_text()) ~= nil
    and self:entered_code() ~= ""
  core.redraw = true
end

------------------------------------------------------------------------------------------------------------------
-- This PC

function MachineDialog:check_access()
  local port = server_port()
  if not port then
    self.access = nil
    return
  end
  access.status(port, function(status)
    self.access = status
    self:update_buttons()
  end)
end

function MachineDialog:toggle_access()
  local port = server_port()
  if not port or self.changing_access then return false end
  self.changing_access = true
  access.set(port, not (self.access and self.access.state == "on"), function(status)
    self.changing_access = false
    self.access = status
    self:update_buttons()
  end)
  self:update_buttons()
  return true
end

function MachineDialog:make_code()
  local level = self.level_control.value
  self.owner:request("pairing.start", { level = level }, nil, function(err, result)
    if err then
      self.code = { error = err.message or err.code }
    else
      self.code = { code = result.code, level = level, expires = system.get_time() + result.expires_in,
        made = os.time() }
      core.log_quiet("Machines Dialog: made a pairing code for %s access", level)
    end
    core.redraw = true
  end)
end

-- The pairing code while it works, or nil.
function MachineDialog:active_code()
  local code = self.code
  if code and code.code and system.get_time() >= code.expires then self.code, code = nil, nil end
  return code
end

function MachineDialog:refresh_devices()
  if not (self.owner and self.owner.state == "ready") or self.loading_devices then return end
  self.loading_devices = true
  self.owner:request("devices.list", {}, nil, function(err, result)
    self.loading_devices = false
    if err or type(result) ~= "table" or type(result.devices) ~= "table" then return end
    local devices = result.devices
    table.sort(devices, function(a, b) return (a.paired or 0) > (b.paired or 0) end)
    local code = self:active_code()
    -- A code works one time. A device that paired after it was made used it.
    if code and code.code and devices[1] and (devices[1].paired or 0) >= code.made then self.code = nil end
    local selected = self.device_list:selected_row()
    local index
    for i, device in ipairs(devices) do
      if selected and device.id == selected.id then index = i end
    end
    self.device_list:set_rows(devices, index)
    self:update_buttons()
  end)
end

function MachineDialog:revoke()
  local device = self.device_list:selected_row()
  if not device then return false end
  self.owner:request("devices.revoke", { device = device.id }, nil, function(err)
    if err then core.error("Cannot revoke %s: %s", tostring(device.name), err.message or err.code) end
    self:refresh_devices()
  end)
  return true
end

------------------------------------------------------------------------------------------------------------------
-- Other Machines

-- Read the paired Machines again, and connect to each while the Dialog is open. `select` is a Machine ID.
function MachineDialog:refresh_machines(select)
  local records = MachineClient.records()
  local clients = {}
  for _, record in ipairs(records) do
    clients[record.machine] = self.clients[record.machine] or MachineClient.new(record.path)
  end
  for machine, client in pairs(self.clients) do
    if not clients[machine] then client:close() end
  end
  self.clients = clients
  local selected = self.machine_list:selected_row()
  local wanted = select or (selected and selected.machine)
  local index
  for i, record in ipairs(records) do
    if record.machine == wanted then index = i end
  end
  self.machine_list:set_rows(records, index)
  self:update_buttons()
end

function MachineDialog:open_project()
  local record = self.machine_list:selected_row()
  if not record then return false end
  self:close()
  return command.perform("machine:open_project", record.machine)
end

-- Forgets the selected Machine. With Full control, this PC also removes itself from the Machine's devices.
function MachineDialog:forget()
  local record = self.machine_list:selected_row()
  if not record then return false end
  local client = self.clients[record.machine]
  local function done()
    MachineClient.forget(record.machine)
    self:refresh_machines()
  end
  if client and client.state == "ready" and client.level == "full" then
    client:request("devices.revoke", { device = record.device }, nil, done)
  else
    done()
  end
  return true
end

function MachineDialog:entered_code()
  return (self.code_field:get_text():gsub("%s", ""))
end

function MachineDialog:pair()
  local host, port = parse_address(self.address_field:get_text())
  local code = self:entered_code()
  if not host or code == "" or self.pairing then return false end
  self.pairing, self.pair_error = true, nil
  local name = os.getenv("COMPUTERNAME") or os.getenv("HOSTNAME") or "Anvil"
  core.log_quiet("Machines Dialog: pair with %s:%d", host, port)
  MachineClient.pair(host, port, code, name, function(err, path)
    self.pairing = false
    if err then
      self.pair_error = err.message or err.code
    else
      self.address_field:set_text("")
      self.code_field:set_text("")
      self:refresh_machines(common.basename(path):match("^(%x+)%.json$"))
      self:focus(self.machine_list)
    end
    self:update_buttons()
  end)
  self:update_buttons()
  return true
end

-- Enter in the address field moves to the code. Enter in the code field pairs. A focus change only keeps the text.
function MachineDialog:confirm()
  if self.focused == self.address_field then
    self.address_field:submit()
    return self:focus(self.code_field)
  end
  if self.focused == self.code_field then
    self.code_field:submit()
    return self:pair()
  end
  return MachineDialog.super.confirm(self)
end

function MachineDialog:perform(name)
  if name == "delete" then
    if self.focused == self.device_list then return self:revoke() end
    if self.focused == self.machine_list then return self:forget() end
  end
  return MachineDialog.super.perform(self, name)
end

function MachineDialog:on_close()
  if self.owner then self.owner:close() end
  self.owner = nil
  for _, client in pairs(self.clients) do client:close() end
  self.clients = {}
end

------------------------------------------------------------------------------------------------------------------
-- Drawing

-- One dot draws the state of each Machine row.
local row_dot = StatusDot {}

-- A row's name at the left, and `right_w` pixels kept free at the right.
local function draw_name(text, right_w, x, y, w, h)
  local font, m = ui.font(), ui.metrics()
  local name_w = w - 2 * m.pad_x - right_w - m.gap
  common.draw_text(font, style.dialog_text, ui.fit_text(font, text, name_w), "left", x + m.pad_x, y, name_w, h)
end

function MachineDialog:draw_device(device, x, y, w, h)
  local font, pad = ui.role_font("description"), ui.metrics().pad_x
  local level = device.level == "full" and LEVELS.full or LEVELS.view
  local level_w = font:get_width(level)
  common.draw_text(font, style.dialog_text_muted, level, "right", x + w - pad - level_w, y, level_w, h)
  draw_name(tostring(device.name or device.id), level_w, x, y, w, h)
end

function MachineDialog:draw_machine(record, x, y, w, h)
  local client = self.clients[record.machine]
  if client and client.state == "ready" then
    row_dot:set("success", "Online")
  elseif client and client.error then
    row_dot:set("neutral", "Offline")
  else
    row_dot:set("info", "Connecting")
  end
  local dot_w = row_dot:width()
  row_dot:place(x + w - ui.metrics().pad_x - dot_w, y, dot_w, h)
  row_dot:draw_node()
  draw_name(machine_label(record), dot_w, x, y, w, h)
end

-- The text of the Access row and its color.
function MachineDialog:access_text()
  local owner = self.owner
  if not (owner and owner.state == "ready") then
    if owner and owner.error then return owner.error, style.dialog_danger end
    return "Connecting to the Machine server", style.dialog_text_muted
  end
  if self.changing_access then return "Changing Tailscale", style.dialog_text_muted end
  local status = self.access
  if not status then return "Checking Tailscale", style.dialog_text_muted end
  if status.state == "on" then return status.address or "Shared on the tailnet", style.dialog_text end
  if status.state == "off" then return "Only this PC", style.dialog_text end
  if status.state == "missing" then
    return "Only this PC. Install Tailscale to reach it from other devices.", style.dialog_text_muted
  end
  if status.state == "disconnected" then return "Only this PC. Tailscale is not connected.", style.dialog_text_muted end
  return status.message or "Tailscale failed", style.dialog_danger
end

-- The texts that change without an event: the Access row, the pairing code and its time, and the pairing state.
function MachineDialog:on_update()
  local text, color = self:access_text()
  local access = self.access_row.description
  access:set_text(text)
  access.color = color
  local code = self:active_code()
  self.code_row.visible = code ~= nil
  if code and code.error then
    self.code_text.role = "body"
    self.code_text:set_text(code.error)
    self.code_text.color = style.dialog_danger
    self.code_timer:set_text("")
  elseif code then
    local left = math.max(0, math.ceil(code.expires - system.get_time()))
    self.code_text.role = "title"
    self.code_text:set_text(code.code:sub(1, 3) .. " " .. code.code:sub(4))
    self.code_text.color = nil
    self.code_timer:set_text(string.format("%s · %d:%02d", LEVELS[code.level] or "", math.floor(left / 60), left % 60))
  end
  local status = self.pairing and "Pairing" or self.pair_error
  self.pair_status.visible = status ~= nil
  self.pair_status:set_text(status or "")
  self.pair_status.color = self.pair_error and not self.pairing and style.dialog_danger or style.dialog_text_muted
end

------------------------------------------------------------------------------------------------------------------
-- Module

local M = { Dialog = MachineDialog }

---Open the Dialog. `pair` shows the pairing fields of "Other Machines".
---@param options? { pair: boolean? }
function M.open(options)
  options = options or {}
  local open = require("core.ui.dialog").current()
  local instance = (open and open:is(MachineDialog)) and open or MachineDialog()
  if options.pair then instance:show_page("others") end
  local focus = options.pair and instance.address_field or instance.page_control
  instance:open(focus)
  instance:focus(focus)
  return instance
end

return M
