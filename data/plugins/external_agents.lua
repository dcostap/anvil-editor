-- mod-version:3
-- External Agent Views: the thread of an agent outside Anvil's Terminals, such as Antigravity, and a field to message
-- it. The thread lives on the Project's Machine (`core.serve_external`), so a Project on another Machine shows the
-- same thread as the Machine itself.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local panes = require "core.panes"
local style = require "core.style"
local ui = require "core.ui"
local TextField = require "core.ui.text_field"
local View = require "core.view"

local plugin = {}
-- The thread keeps at most this many messages. A full page asks for the next page at once.
local MAX_SHOWN, PAGE = 500, 100
local EMPTY = {}
local own_client

local function valid_name(name)
  return require("core.serve_external").valid_name(name)
end

-- The Machine of this Project process: the Project's Machine, or this PC's own server for a local Project.
function plugin.client()
  local fs = require "core.fs"
  if fs.machine then return fs.machine end
  local projects = require "core.machine_project"
  local own = projects.own_id()
  if not own then return nil, "Anvil's Machine server is not running" end
  if not own_client or own_client.state == "closed" then
    own_client = require("core.machine_client").new(projects.machine_file(own))
  end
  return own_client
end

-- Sends a request about this Project's External Agents. `on_reply(err, result)` runs once.
function plugin.request(method, params, on_reply)
  local client, err = plugin.client()
  if not client then return on_reply({code = "offline", message = err}) end
  params.project = core.root_project().path
  client:request(method, params, nil, on_reply)
end

local ExternalAgentView = View:extend()
plugin.View = ExternalAgentView

function ExternalAgentView:__tostring() return "ExternalAgentView" end

function ExternalAgentView:new(agent)
  ExternalAgentView.super.new(self)
  self.agent = agent
  self.scrollable = true
  self.messages, self.read_cursor = {}, 0
  -- "connecting", "listening", "idle", "unknown" (the agent never waited) or "offline".
  self.status = "connecting"
  self.stick = true
  self.content_h = 0
  self.field = TextField { placeholder = "Message " .. agent }
  core.add_thread(function() self:read_thread() end)
end

function ExternalAgentView:get_name() return self.agent end
function ExternalAgentView:get_state() return { agent = self.agent } end
function ExternalAgentView:supports_text_input() return true end
function ExternalAgentView:on_close() self.closed = true end

function ExternalAgentView.from_state(state)
  if type(state) == "table" and valid_name(state.agent) then return ExternalAgentView(state.agent) end
end

-- Reads the thread, then waits for each change. The Machine answers a wait when a message arrives or the agent's
-- listening state changes, and at the latest after 25 seconds.
function ExternalAgentView:read_thread()
  local loaded = false
  while not self.closed do
    local done, err, result
    plugin.request("external.read", { agent = self.agent, after = self.read_cursor, wait = loaded },
      function(e, r) done, err, result = true, e, r end)
    while not done and not self.closed do coroutine.yield(0.05) end
    if self.closed then return end
    if err then
      self.status = err.code == "not_found" and "unknown" or "offline"
      self.error = err.message or err.code
      loaded = false
      core.redraw = true
      coroutine.yield(err.code == "not_found" and 5 or 2)
    else
      self:receive(result)
      loaded = #(result.messages or EMPTY) < PAGE
    end
  end
end

function ExternalAgentView:receive(result)
  -- A Machine that lost the thread starts again at 1, and sends the whole new thread.
  if type(result.seq) == "number" and result.seq < self.read_cursor then
    self.messages, self.read_cursor = {}, 0
  end
  for _, message in ipairs(result.messages or EMPTY) do
    if message.seq > self.read_cursor then self.messages[#self.messages + 1] = message end
  end
  while #self.messages > MAX_SHOWN do table.remove(self.messages, 1) end
  if type(result.cursor) == "number" then self.read_cursor = math.max(self.read_cursor, result.cursor) end
  self.status, self.error = result.listening and "listening" or "idle", nil
  core.redraw = true
end

---Posts the field's text to the thread. A failed post puts the text back.
function ExternalAgentView:send()
  local text = self.field:get_text()
  if not text:find("%S") then return false end
  self.field:set_text("")
  plugin.request("external.post", { agent = self.agent, text = text, from = { kind = "user" } }, function(err)
    if not err then return end
    if self.field:get_text() == "" then self.field:set_text(text) end
    self.field:set_error(err.message or err.code)
    core.log_quiet("External Agent %s: message not sent: %s", self.agent, tostring(err.message or err.code))
  end)
  self.stick = true
  return true
end

------------------------------------------------------------------------------------------------------------------
-- Layout

local function pad() return ui.metrics().row_pad_x end
local function header_h() return ui.font():get_height() + 2 * ui.metrics().gap end
local function footer_h() return ui.metrics().field_h + 2 * pad() end

-- Cuts a word that is wider than the line into lines. Returns its last part. A cut never splits a UTF-8
-- sequence, and keeps invalid bytes.
local function cut_word(font, word, width, lines)
  local part, i = "", 1
  while i <= #word do
    local j = i + 1
    while j <= #word and j - i < 4 and word:byte(j) >= 0x80 and word:byte(j) < 0xC0 do j = j + 1 end
    local char = word:sub(i, j - 1)
    if part ~= "" and font:get_width(part .. char) > width then
      lines[#lines + 1] = part
      part = char
    else
      part = part .. char
    end
    i = j
  end
  return part
end

-- Breaks `text` into lines that fit `width`, at spaces.
local function wrap(font, text, width)
  local lines = {}
  for paragraph in (text .. "\n"):gmatch("(.-)\r?\n") do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      local candidate = line == "" and word or line .. " " .. word
      if font:get_width(candidate) <= width then
        line = candidate
      else
        if line ~= "" then lines[#lines + 1] = line end
        line = font:get_width(word) > width and cut_word(font, word, width, lines) or word
      end
    end
    lines[#lines + 1] = line
  end
  return lines
end

function ExternalAgentView:author(message)
  local from = message.from or EMPTY
  if from.kind == "self" then return self.agent end
  local name = from.kind == "user" and "You" or from.name or "Agent"
  return from.machine and name .. " @ " .. from.machine or name
end

local function time_text(time)
  if type(time) ~= "number" then return "" end
  return os.date(os.date("%Y%m%d", time) == os.date("%Y%m%d") and "%H:%M" or "%d %b %H:%M", time)
end

-- The wrapped lines of a message for `width`. The width and the font size key the cache.
function ExternalAgentView:lines(message, width)
  local font = ui.font()
  local cache = message.layout
  if not cache or cache.width ~= width or cache.size ~= font:get_size() then
    cache = { width = width, size = font:get_size(), lines = wrap(font, message.text or "", width) }
    message.layout = cache
  end
  return cache.lines
end

function ExternalAgentView:message_h(message, width)
  local m = ui.metrics()
  return ui.bold_font():get_height() + m.text_gap + #self:lines(message, width) * ui.font():get_height()
    + m.section_gap
end

function ExternalAgentView:get_scrollable_size()
  return header_h() + pad() + self.content_h + footer_h()
end

function ExternalAgentView:max_scroll()
  return math.max(0, self:get_scrollable_size() - self.size.y)
end

function ExternalAgentView:update()
  local width = self.size.x - 2 * pad()
  local height = 0
  for _, message in ipairs(self.messages) do height = height + self:message_h(message, width) end
  self.content_h = height
  if self.stick then self.scroll.to.y = self:max_scroll() end
  local m = ui.metrics()
  self.field:set_rect(self.position.x + pad(), self.position.y + self.size.y - pad() - m.field_h,
    self.size.x - 2 * pad(), m.field_h)
  ExternalAgentView.super.update(self)
end

------------------------------------------------------------------------------------------------------------------
-- Input

function ExternalAgentView:on_mouse_wheel(...)
  local used = ExternalAgentView.super.on_mouse_wheel(self, ...)
  self.stick = self.scroll.to.y >= self:max_scroll() - 1
  return used
end

function ExternalAgentView:message_at(x, y)
  local top, bottom = self.position.y + header_h(), self.position.y + self.size.y - footer_h()
  if y < top or y >= bottom or x < self.position.x or x >= self.position.x + self.size.x then return end
  local width = self.size.x - 2 * pad()
  local my = self.position.y + header_h() + pad() - self.scroll.y
  for _, message in ipairs(self.messages) do
    local h = self:message_h(message, width)
    if y >= my and y < my + h then return message end
    my = my + h
  end
end

function ExternalAgentView:on_mouse_pressed(button, x, y, clicks)
  if ExternalAgentView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if button ~= "left" then return true end
  if self.field:contains(x, y) then
    self.field.pressed = true
    return self.field:on_mouse_pressed(x, y, clicks)
  end
  -- A click selects a message, so Copy takes its text.
  local message = self:message_at(x, y)
  self.selected = message ~= self.selected and message or nil
  core.redraw = true
  return true
end

function ExternalAgentView:on_mouse_moved(x, y, dx, dy)
  if ExternalAgentView.super.on_mouse_moved(self, x, y, dx, dy) then return true end
  if self.field.pressed then return self.field:on_mouse_moved(x, y) end
  core.request_cursor(self.field:contains(x, y) and "ibeam" or "arrow")
end

function ExternalAgentView:on_mouse_released(button, x, y)
  ExternalAgentView.super.on_mouse_released(self, button, x, y)
  if self.field.pressed then
    self.field.pressed = false
    self.field:on_mouse_released(x, y)
  end
end

function ExternalAgentView:on_text_input(text)
  self.field:on_text(text)
end

---Performs an editor line command, without its "core:" prefix. Copy takes the selected message when the field
---has no selection.
function ExternalAgentView:perform(name)
  local first, last = self.field.input:selection()
  if name == "copy" and first == last and self.selected then
    system.set_clipboard(self.selected.text or "")
    return true
  end
  return self.field:perform(name)
end

-- The keymap's commands for the editor do not run in this View, so its keys come here.
function ExternalAgentView:on_key_pressed(key, event)
  if keymap.is_modifier_key(key) then return false end
  if key == "return" or key == "keypad enter" then return self:send() or true end
  if key == "escape" then
    if self.selected then self.selected = nil
    else self.field:set_text("") end
    core.redraw = true
    return true
  end
  local stroke = keymap.stroke_for_event(key, event)
  for _, name in ipairs(keymap.map[stroke] or EMPTY) do
    local line_command = type(name) == "string" and name:match("^core:(.+)$")
    if line_command and self:perform(line_command) then return true end
  end
  return false
end

------------------------------------------------------------------------------------------------------------------
-- Drawing

local STATUS = {
  connecting = { "Connecting", "dim" },
  listening = { "Listening", "good" },
  idle = { "Not listening", "warn" },
  unknown = { "Not connected yet", "warn" },
  offline = { "Offline", "error" },
}

function ExternalAgentView:draw()
  self:draw_background(style.background)
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local m = ui.metrics()
  local font, meta = ui.font(), ui.role_font("meta")
  local p, top_h, bottom_h = pad(), header_h(), footer_h()
  local width = w - 2 * p

  core.push_clip_rect(x, y + top_h, w, h - top_h - bottom_h)
  local my = y + top_h + p - self.scroll.y
  local bottom = y + h - bottom_h
  for _, message in ipairs(self.messages) do
    local mh = self:message_h(message, width)
    if my + mh > y + top_h and my < bottom then
      if message == self.selected then
        renderer.draw_rect(x, my - m.gap / 2, w, mh - m.section_gap + m.gap, style.line_highlight)
      end
      local from = message.from or EMPTY
      local name_color = from.kind == "self" and style.accent or style.text
      -- The labels of a message do not change, so a frame makes no new strings.
      message.label = message.label or self:author(message)
      message.when = message.when or time_text(message.time)
      local label = message.label
      renderer.draw_text(ui.bold_font(), label, x + p, my, name_color)
      renderer.draw_text(meta, message.when, x + p + ui.bold_font():get_width(label) + m.gap,
        my + ui.bold_font():get_height() - meta:get_height(), style.dim)
      local ly = my + ui.bold_font():get_height() + m.text_gap
      for _, line in ipairs(self:lines(message, width)) do
        renderer.draw_text(font, line, x + p, ly, style.text)
        ly = ly + font:get_height()
      end
    end
    my = my + mh
  end
  core.pop_clip_rect()

  -- The clip keeps the thread out of the header and the footer, which stay in place while it scrolls.
  local state = STATUS[self.status] or STATUS.offline
  local text = self.status == "offline" and self.error and state[1] .. ": " .. self.error or state[1]
  local dot = math.floor(font:get_height() / 3)
  local cy = y + math.floor(top_h / 2)
  renderer.draw_rect(x + p, cy - math.floor(dot / 2), dot, dot, style[state[2]] or style.dim)
  renderer.draw_text(font, ui.fit_text(font, text, width - dot - m.gap), x + p + dot + m.gap,
    cy - math.floor(font:get_height() / 2), style.dim)
  self.field:draw(core.active_view == self)
  self:draw_scrollbar()
end

------------------------------------------------------------------------------------------------------------------

---Opens the View of `agent` in a new Pane, or shows its open View. Returns the View.
function plugin.open(agent)
  for _, pane in ipairs(panes.ordered()) do
    for _, view in ipairs(panes.views(pane)) do
      if view:is(ExternalAgentView) and view.agent == agent then
        panes.present(view, { pane = pane, reuse = true, focus = true })
        return view
      end
    end
  end
  return (panes.place(function() return ExternalAgentView(agent) end,
    { placement = "new", focus = true, reason = "open-external-agent" }))
end

command.add(nil, {
  ["external_agents:open"] = command.palette(function()
    plugin.request("external.list", {}, function(err, result)
      if err then return core.warn("External Agents: %s", err.message or err.code) end
      local names = {}
      for _, agent in ipairs(result.agents or EMPTY) do names[#names + 1] = agent.name end
      if #names == 0 then
        return core.warn("No External Agent has connected to this Project. Run anvil:mcp_server and copy the agent setup.")
      end
      if #names == 1 then return plugin.open(names[1]) end
      core.global_prompt_bar:enter("External Agent", {
        text = "",
        suggest = function(text)
          local items = {}
          for _, name in ipairs(names) do
            if name:lower():find(text:lower(), 1, true) then items[#items + 1] = { text = name } end
          end
          return items
        end,
        submit = function(text, option)
          local name = option and option.text or text
          if valid_name(name) then plugin.open(name) end
        end,
      })
    end)
  end, { keywords = { "antigravity", "agy", "agent", "chat", "message" }, opens_view = true }),
})

return plugin
