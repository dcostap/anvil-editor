-- The Machines Dialog. "This PC" shows how other devices reach this PC's Machine server, makes pairing codes
-- and lists the paired devices. "Other Machines" lists the Machines that this PC paired with, and pairs with a new
-- one. Each change applies at once.

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local json = require "core.json"
local style = require "core.style"
local ui = require "core.ui"
local Dialog = require("core.ui.dialog").Dialog
local Button = require "core.ui.button"
local List = require "core.ui.list"
local Segmented = require "core.ui.segmented"
local TextField = require "core.ui.text_field"
local MachineClient = require "core.machine_client"
local access = require "core.machine_access"

local MachineDialog = Dialog:extend()

function MachineDialog:__tostring() return "MachineDialog" end

-- The rows that each list shows before it scrolls.
local VISIBLE_ROWS = 4
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
  self.page_control = self:add(Segmented({
    options = { { value = "this", label = "This PC" }, { value = "others", label = "Other Machines" } },
    value = "this",
    on_change = function(page)
      self:show_page(page)
      return true
    end,
  }))
  local row_h = ui.font():get_height() + math.floor(14 * SCALE)

  -- This PC
  self.access_button = self:add(Button({ label = "Share on Tailnet", on_click = function() self:toggle_access() end }))
  self.level_control = self:add(Segmented({
    options = { { value = "full", label = LEVELS.full }, { value = "view", label = LEVELS.view } },
    value = "full",
  }))
  self.code_button = self:add(Button({ label = "Make Code", on_click = function() self:make_code() end }))
  self.device_list = self:add(List({
    row_height = row_h,
    draw_row = function(...) self:draw_device(...) end,
    on_select = function() self:update_buttons() end,
  }))
  self.revoke_button = self:add(Button({
    label = "Revoke", icon = ui.icons.remove, kind = "danger",
    on_click = function() self:revoke() end,
  }))

  -- Other Machines
  self.machine_list = self:add(List({
    row_height = row_h,
    draw_row = function(...) self:draw_machine(...) end,
    on_select = function() self:update_buttons() end,
    on_activate = function() self:open_project() end,
  }))
  self.open_button = self:add(Button({
    label = "Open Project", icon = ui.icons.open_in_new,
    on_click = function() self:open_project() end,
  }))
  self.forget_button = self:add(Button({
    label = "Forget", icon = ui.icons.remove, kind = "danger",
    on_click = function() self:forget() end,
  }))
  self.address_field = self:add(TextField({
    on_change = function() self:update_buttons() end }))
  self.code_field = self:add(TextField({ on_change = function() self:update_buttons() end }))
  self.pair_button = self:add(Button({ label = "Pair", on_click = function() self:pair() end }))

  self.done_button = self:add(Button({ label = "Done", kind = "primary", on_click = function() self:close() end }))

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
  for _, control in ipairs({ self.access_button, self.level_control, self.code_button, self.device_list,
    self.revoke_button }) do
    control.visible = this
  end
  for _, control in ipairs({ self.machine_list, self.open_button, self.forget_button, self.address_field,
    self.code_field, self.pair_button }) do
    control.visible = not this
  end
  if this then self:refresh_devices() end
  self:update_buttons()
end

function MachineDialog:update_buttons()
  local ready = self.owner and self.owner.state == "ready"
  self.code_button.enabled = ready
  self.level_control.enabled = ready
  self.revoke_button.enabled = ready and self.device_list:selected_row() ~= nil
  local state = self.access and self.access.state
  self.access_button.visible = self.page == "this" and (state == "off" or state == "on" or state == "error")
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
-- Layout

local CAPTIONS = { "Access", "Pairing", "Devices", "Machines", "Address", "Code" }

local function sizes()
  local um = ui.metrics()
  local font = ui.font()
  local label_w = 0
  for _, text in ipairs(CAPTIONS) do label_w = math.max(label_w, font:get_width(text)) end
  return {
    control_h = um.control_h, gap = um.gap,
    section_gap = math.floor(16 * SCALE + 0.5), row_gap = math.floor(10 * SCALE + 0.5),
    label_w = math.floor(label_w + 20 * SCALE), line_h = font:get_height(),
    footer_gap = math.floor(20 * SCALE + 0.5),
  }
end

-- Places a row of buttons from `x` and returns the x after them.
local function place_buttons(buttons, x, y, s)
  for _, button in ipairs(buttons) do
    local bw = button:measure()
    button:set_rect(x, y, bw, s.control_h)
    x = x + bw + s.gap
  end
  return x
end

function MachineDialog:layout_content(x, y, w, max_h)
  local s = sizes()
  local fx, fw = x + s.label_w, w - s.label_w
  self.rows = self.rows or {}
  local rows = self.rows
  self.page_control:set_rect(x, y, self.page_control:measure(), s.control_h)
  local top = y + s.control_h + s.section_gap
  local fixed_h = top - y + s.control_h * 4 + s.row_gap * 3 + s.section_gap * 2 + s.footer_gap + s.line_h
  local list_h = math.max(self.device_list.row_height,
    math.min(VISIBLE_ROWS * self.device_list.row_height, max_h - fixed_h))

  -- This PC
  local cy = top
  rows.access = cy
  local access_w = self.access_button:measure()
  self.access_button:set_rect(x + w - access_w, cy, access_w, s.control_h)
  cy = cy + s.control_h + s.row_gap
  rows.pairing = cy
  local level_w = self.level_control:measure()
  self.level_control:set_rect(fx, cy, level_w, s.control_h)
  rows.code_x = place_buttons({ self.code_button }, fx + level_w + s.gap, cy, s)
  cy = cy + s.control_h + s.section_gap
  rows.this_divider = cy
  cy = cy + s.section_gap
  rows.devices = cy
  self.device_list:set_rect(fx, cy, fw, list_h)
  cy = cy + list_h + s.row_gap
  place_buttons({ self.revoke_button }, fx, cy, s)
  local this_bottom = cy + s.control_h

  -- Other Machines
  cy = top
  rows.machines = cy
  self.machine_list:set_rect(fx, cy, fw, list_h)
  cy = cy + list_h + s.row_gap
  place_buttons({ self.open_button, self.forget_button }, fx, cy, s)
  cy = cy + s.control_h + s.section_gap
  rows.others_divider = cy
  cy = cy + s.section_gap
  rows.address = cy
  self.address_field:set_rect(fx, cy, fw, s.control_h)
  cy = cy + s.control_h + s.row_gap
  rows.code = cy
  local code_w = math.floor(140 * SCALE)
  self.code_field:set_rect(fx, cy, code_w, s.control_h)
  place_buttons({ self.pair_button }, fx + code_w + s.gap, cy, s)
  cy = cy + s.control_h + s.row_gap
  rows.pair_status = cy
  local others_bottom = cy + s.line_h

  -- Both pages have the same height, so the card does not move when the page changes.
  cy = math.max(this_bottom, others_bottom) + s.footer_gap
  local done_w = math.max(self.done_button:measure(), math.floor(88 * SCALE))
  self.done_button:set_rect(x + w - done_w, cy, done_w, s.control_h)
  self.content_x, self.content_w = x, w
  return cy + s.control_h - y
end

------------------------------------------------------------------------------------------------------------------
-- Drawing

local function draw_row_text(left, right, right_color, x, y, w, h)
  local font = ui.font()
  local pad = ui.metrics().pad_x
  local right_w = right and font:get_width(right) or 0
  local left_w = w - 2 * pad - (right and right_w + ui.metrics().gap or 0)
  common.draw_text(font, style.text, ui.fit_text(font, left, left_w), "left", x + pad, y, left_w, h)
  if right then common.draw_text(font, right_color, right, "right", x + w - pad - right_w, y, right_w, h) end
end

function MachineDialog:draw_device(device, x, y, w, h)
  draw_row_text(tostring(device.name or device.id), device.level == "full" and "Full" or "View", style.card_text,
    x, y, w, h)
end

function MachineDialog:draw_machine(record, x, y, w, h)
  local client = self.clients[record.machine]
  local state, color = "Connecting", style.card_text
  if client and client.state == "ready" then
    state, color = "Online", style.good
  elseif client and client.error then
    state = "Offline"
  end
  draw_row_text(machine_label(record), state, color, x, y, w, h)
end

-- The text of the Access row and its color.
function MachineDialog:access_text()
  local owner = self.owner
  if not (owner and owner.state == "ready") then
    if owner and owner.error then return owner.error, style.error end
    return "Connecting to the Machine server", style.card_text
  end
  if self.changing_access then return "Changing Tailscale", style.card_text end
  local status = self.access
  if not status then return "Checking Tailscale", style.card_text end
  if status.state == "on" then return status.address or "Shared on the tailnet", style.text end
  if status.state == "off" then return "Only this PC", style.text end
  if status.state == "missing" then return "Only this PC. Install Tailscale to reach it from other devices.", style.card_text end
  if status.state == "disconnected" then return "Only this PC. Tailscale is not connected.", style.card_text end
  return status.message or "Tailscale failed", style.error
end

function MachineDialog:draw_content()
  local s = sizes()
  local font = ui.font()
  local x, w = self.content_x, self.content_w
  local fx, fw = x + s.label_w, w - s.label_w
  local rows = self.rows
  local function caption(text, row_y)
    common.draw_text(font, style.card_text, text, "left", x, row_y, s.label_w, s.control_h)
  end
  local function empty(list, text)
    if #list.rows == 0 then
      common.draw_text(font, style.card_text, text, "center", list.x, list.y, list.w, list.h)
    end
  end
  if self.page == "this" then
    caption("Access", rows.access)
    local text, color = self:access_text()
    local text_w = (self.access_button.visible and self.access_button.x - s.gap or x + w) - fx
    common.draw_text(font, color, ui.fit_text(font, text, text_w), "left", fx, rows.access, text_w, s.control_h)
    caption("Pairing", rows.pairing)
    local code = self:active_code()
    if code and code.error then
      common.draw_text(font, style.error, ui.fit_text(font, code.error, x + w - rows.code_x), "left", rows.code_x,
        rows.pairing, x + w - rows.code_x, s.control_h)
    elseif code then
      local left = math.max(0, math.ceil(code.expires - system.get_time()))
      local bold = ui.bold_font()
      local digits = code.code:sub(1, 3) .. " " .. code.code:sub(4)
      common.draw_text(bold, style.text, digits, "left", rows.code_x, rows.pairing, bold:get_width(digits), s.control_h)
      local timer = string.format("%d:%02d", math.floor(left / 60), left % 60)
      common.draw_text(font, style.card_text, timer, "right", x, rows.pairing, w, s.control_h)
    end
    renderer.draw_rect(x, rows.this_divider, w, ui.metrics().border, style.card_border)
    caption("Devices", rows.devices)
    empty(self.device_list, "No paired devices")
  else
    caption("Machines", rows.machines)
    empty(self.machine_list, "No paired Machines")
    renderer.draw_rect(x, rows.others_divider, w, ui.metrics().border, style.card_border)
    caption("Address", rows.address)
    caption("Code", rows.code)
    local status = self.pairing and "Pairing" or self.pair_error
    if status then
      renderer.draw_text(font, ui.fit_text(font, status, fw), fx, rows.pair_status,
        self.pair_error and not self.pairing and style.error or style.card_text)
    end
  end
  MachineDialog.super.draw_content(self)
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
