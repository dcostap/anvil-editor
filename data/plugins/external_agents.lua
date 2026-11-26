-- mod-version:3
-- External Agent Views: the thread of an agent outside Anvil's Terminals, such as Antigravity, and a box to message
-- it. The thread lives on the Project's Machine (`core.serve_external`), so a Project on another Machine shows the
-- same thread as the Machine itself.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local LineInput = require "core.line_input"
local Object = require "core.object"
local panes = require "core.panes"
local style = require "core.style"
local ui = require "core.ui"
local surface = require "core.ui.surface"
local View = require "core.view"

local plugin = {}
-- The thread keeps at most this many messages. A full page asks for the next page at once.
local MAX_SHOWN, PAGE = 500, 100
-- The message box grows up to this many lines, then scrolls.
local MAX_BOX_LINES = 8
-- Messages of one author within this many seconds share one header.
local GROUP_SECONDS = 300
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

------------------------------------------------------------------------------------------------------------------
-- Line breaks

local function continuation(text, pos)
  local byte = text:byte(pos + 1)
  return byte ~= nil and byte >= 0x80 and byte < 0xC0
end

-- The end of the line that starts at `first` and must end by `stop`: after the last space that fits, or inside a
-- word that is wider than the line. A line has at least one character, and a cut never splits a UTF-8 sequence.
local function fit(font, text, first, stop, width)
  if font:get_width(text:sub(first + 1, stop)) <= width then return stop end
  local low, high = first + 1, stop
  while continuation(text, low) and low < stop do low = low + 1 end
  while low < high do
    local mid = math.floor((low + high + 1) / 2)
    while mid > low and continuation(text, mid) do mid = mid - 1 end
    if mid > low and font:get_width(text:sub(first + 1, mid)) <= width then low = mid else high = mid - 1 end
    if mid == low then break end
  end
  -- Spaces after the last word that fits stay on its line.
  if text:byte(low + 1) == 32 then
    while low < stop and text:byte(low + 1) == 32 do low = low + 1 end
    return low
  end
  for pos = low, first + 1, -1 do
    if text:byte(pos) == 32 then return pos end
  end
  return low
end

-- Breaks `text` into lines that fit `width`. Each line is {first, last}: byte offsets, without the line break.
local function break_lines(font, text, width)
  local lines, pos = {}, 0
  while true do
    local stop = (text:find("\n", pos + 1, true) or #text + 1) - 1
    local first = pos
    repeat
      local last = fit(font, text, first, stop, width)
      lines[#lines + 1] = {first, last}
      first = last
    until first >= stop
    if stop >= #text then return lines end
    pos = stop + 1
  end
end

local function line_texts(font, text, width)
  local lines = break_lines(font, text, width)
  for i, line in ipairs(lines) do lines[i] = text:sub(line[1] + 1, line[2]) end
  return lines
end

------------------------------------------------------------------------------------------------------------------
-- The message box: text in lines that wrap. Enter sends it; Shift+Enter starts a new line.

local MessageBox = Object:extend()

function MessageBox:new(placeholder)
  self.input = LineInput("", true)
  self.placeholder = placeholder
  self.x, self.y, self.w, self.h, self.scroll = 0, 0, 0, 0, 0
end

function MessageBox:get_text() return self.input.text end

function MessageBox:set_text(text)
  self.input:set_text(text or "")
  self.error, self.goal_x = nil, nil
  core.redraw = true
end

function MessageBox:set_error(message)
  self.error = message
  core.redraw = true
end

function MessageBox:changed()
  self.error, self.goal_x = nil, nil
  core.redraw = true
end

function MessageBox:on_text(text)
  self.input:insert(text)
  self:changed()
  return true
end

local function pad_x() return ui.metrics().pad_x end
local function pad_y() return math.floor((ui.metrics().field_h - ui.font():get_height()) / 2) end

-- The box's lines for its width. The text, the width and the font size key the cache.
function MessageBox:lines()
  local font, width = ui.font(), math.max(1, self.w - 2 * pad_x())
  local cache = self.cache
  if not cache or cache.text ~= self.input.text or cache.width ~= width or cache.size ~= font:get_size() then
    cache = {text = self.input.text, width = width, size = font:get_size(),
      lines = break_lines(font, self.input.text, width)}
    self.cache = cache
  end
  return cache.lines
end

-- The height for `width`: one line up to MAX_BOX_LINES lines.
function MessageBox:height_for(width)
  self.w = width
  local count = math.max(1, math.min(MAX_BOX_LINES, #self:lines()))
  return count * ui.font():get_height() + 2 * pad_y()
end

function MessageBox:set_rect(x, y, w, h)
  self.x, self.y, self.w, self.h = x, y, w, h
end

function MessageBox:contains(x, y)
  return x >= self.x and x < self.x + self.w and y >= self.y and y < self.y + self.h
end

-- The line of the offset `pos`. At a wrap, the offset belongs to the next line.
function MessageBox:line_of(pos)
  local lines = self:lines()
  for i = #lines, 1, -1 do
    if lines[i][1] <= pos then return i, lines[i] end
  end
  return 1, lines[1]
end

function MessageBox:offset_at(x, y)
  local lines, font = self:lines(), ui.font()
  local row = math.floor((y - self.y - pad_y() + self.scroll) / font:get_height()) + 1
  local line = lines[math.max(1, math.min(#lines, row))]
  return self.input:offset_at(font, x - self.x - pad_x(), line[1], line[2])
end

-- Moves the caret one line up or down at the same x, as an Editor does.
function MessageBox:move_line(delta, select)
  local font, text = ui.font(), self.input.text
  local i, line = self:line_of(self.input.caret)
  local goal = self.goal_x or font:get_width(text:sub(line[1] + 1, self.input.caret))
  local lines = self:lines()
  local target = lines[i + delta]
  local pos = not target and (delta < 0 and 0 or #text) or self.input:offset_at(font, goal, target[1], target[2])
  self.input:set_caret(pos, select)
  self.goal_x = goal
  core.redraw = true
end

---Performs an editor line command, without its "core:" prefix. Returns false for a command that the box does
---not have.
function MessageBox:perform(name)
  local kind, direction = name:match("^(%a+)_to_(%a+)_line$")
  if (kind == "move" or kind == "select") and (direction == "previous" or direction == "next") then
    self:move_line(direction == "previous" and -1 or 1, kind == "select")
    return true
  end
  local before = self.input.text
  if not self.input:perform(name) then return false end
  if self.input.text ~= before then self:changed() else self.goal_x = nil end
  core.redraw = true
  return true
end

function MessageBox:on_mouse_pressed(x, y, clicks)
  local pos = self:offset_at(x, y)
  self.goal_x = nil
  if clicks >= 3 then
    self.input:perform("select_all")
  elseif clicks == 2 then
    self.input:set_caret(pos)
    self.input:perform("move_to_next_word_end")
    local last = self.input.caret
    self.input:perform("move_to_previous_word_start")
    self.input.anchor, self.input.caret = self.input.caret, last
  else
    self.input:set_caret(pos, keymap.modkeys.shift)
    self.selecting = true
  end
  core.redraw = true
  return true
end

function MessageBox:on_mouse_moved(x, y)
  if not self.selecting then return false end
  self.input:set_caret(self:offset_at(x, y), true)
  core.redraw = true
  return true
end

function MessageBox:on_mouse_released() self.selecting = false end

-- Scrolls the box's text by `lines`. Returns false when the text fits.
function MessageBox:scroll_lines(lines)
  local font_h = ui.font():get_height()
  local max = math.max(0, #self:lines() * font_h - (self.h - 2 * pad_y()))
  if max == 0 then return false end
  self.scroll = math.max(0, math.min(max, self.scroll - lines * font_h))
  self.scrolled = true
  core.redraw = true
  return true
end

function MessageBox:draw(focused)
  local m, font = ui.metrics(), ui.font()
  local x, y, w, h = self.x, self.y, self.w, self.h
  local font_h = font:get_height()
  surface.draw("well", x, y, w, h, m.control_radius, self.error and style.dialog_danger or focused and style.dialog_focus_ring or nil)
  local input, lines, text = self.input, self:lines(), self.input.text
  local caret_line = self:line_of(input.caret)
  local view_h = h - 2 * pad_y()
  -- The text scrolls as little as it can to keep the caret in view, unless the wheel moved it.
  local max = math.max(0, #lines * font_h - view_h)
  if focused and not self.selecting and not self.scrolled then
    local caret_y = (caret_line - 1) * font_h
    self.scroll = math.max(caret_y + font_h - view_h, math.min(self.scroll, caret_y))
  end
  self.scroll = math.max(0, math.min(max, self.scroll))
  local tx, ty = x + pad_x(), y + pad_y() - self.scroll
  core.push_clip_rect(x + m.border, y + pad_y(), w - 2 * m.border, view_h)
  if text == "" and self.placeholder then
    renderer.draw_text(font, self.placeholder, tx, ty, style.dialog_placeholder)
  end
  local first, last = input:selection()
  for i, line in ipairs(lines) do
    local ly = ty + (i - 1) * font_h
    if ly + font_h > y and ly < y + h then
      if focused and first ~= last and first <= line[2] and last >= line[1] then
        local from, to = math.max(first, line[1]), math.min(last, line[2])
        local left = font:get_width(text:sub(line[1] + 1, from))
        local width = font:get_width(text:sub(from + 1, to))
        -- A selected line break shows as a space at the line's end.
        if last > line[2] and text:byte(line[2] + 1) == 10 then width = width + font:get_width(" ") end
        renderer.draw_rect(tx + left, ly, width, font_h, style.selection)
      end
      renderer.draw_text(font, text:sub(line[1] + 1, line[2]), tx, ly, style.dialog_text)
    end
  end
  if focused then
    local line = lines[caret_line]
    local caret_x = font:get_width(text:sub(line[1] + 1, input.caret))
    renderer.draw_rect(tx + caret_x, ty + (caret_line - 1) * font_h, math.max(1, math.floor(1.5 * SCALE)), font_h,
      style.dialog_text_strong)
  end
  core.pop_clip_rect()
end

------------------------------------------------------------------------------------------------------------------
-- The View

local ExternalAgentView = View:extend()
plugin.View = ExternalAgentView

function ExternalAgentView:__tostring() return "ExternalAgentView" end

function ExternalAgentView:new(agent)
  ExternalAgentView.super.new(self)
  self.agent = agent
  self.scrollable = true
  self.messages, self.requests, self.read_cursor = {}, {}, 0
  -- "connecting", "listening", "idle", "unknown" (the agent never waited) or "offline".
  self.status = "connecting"
  self.unread = 0
  self.stick = true
  self.content_h, self.last_max = 0, 0
  self.field = MessageBox("Message " .. agent)
  core.add_thread(function() self:read_thread() end)
end

function ExternalAgentView:get_name() return self.agent end
function ExternalAgentView:supports_text_input() return true end
-- A thread stays in its Pane, as a busy Terminal does. Another View, such as a Terminal from the Sidebar, opens in a
-- new Pane.
function ExternalAgentView:can_open_view() return false end
function ExternalAgentView:on_close() self.closed = true end

-- An unsent message stays with the Workspace.
function ExternalAgentView:get_state()
  local draft = self.field:get_text()
  return { agent = self.agent, draft = draft ~= "" and draft or nil }
end

function ExternalAgentView.from_state(state)
  if type(state) ~= "table" or not valid_name(state.agent) then return end
  local view = ExternalAgentView(state.agent)
  if type(state.draft) == "string" then view.field:set_text(state.draft) end
  return view
end

-- Reads the thread, then waits for each change. The Machine answers a wait when a message arrives, or the agent's
-- listening or read state changes, and at the latest after 25 seconds.
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
      self:status_changed()
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
    self.messages, self.requests, self.read_cursor = {}, {}, 0
  end
  for _, message in ipairs(result.messages or EMPTY) do
    if message.seq > self.read_cursor then
      self.messages[#self.messages + 1] = message
      if message.request then self.requests[message.request] = message end
    end
  end
  while #self.messages > MAX_SHOWN do
    local removed = table.remove(self.messages, 1)
    if removed.request then self.requests[removed.request] = nil end
  end
  if type(result.cursor) == "number" then self.read_cursor = math.max(self.read_cursor, result.cursor) end
  -- A Machine without read states sends no `read`. Its thread then shows no unread messages.
  self.read = type(result.read) == "number" and result.read or nil
  self.unread = 0
  for _, message in ipairs(self.messages) do
    if self:is_unread(message) then self.unread = self.unread + 1 end
  end
  self.status, self.error = result.listening and "listening" or "idle", nil
  self.laid_out = nil
  self:status_changed()
end

function ExternalAgentView:is_unread(message)
  return self.read ~= nil and message.seq > self.read and (message.from or EMPTY).kind ~= "self"
end

local STATUS = {
  connecting = { "Connecting", "dim" },
  listening = { "Listening", "good" },
  idle = { "Not listening", "warn" },
  unknown = { "Not connected yet", "warn" },
  offline = { "Offline", "error" },
}

function ExternalAgentView:status_changed()
  local state = STATUS[self.status] or STATUS.offline
  local text = state[1]
  if self.status == "offline" and self.error then text = text .. ": " .. self.error end
  if self.unread > 0 and (self.status == "listening" or self.status == "idle") then
    text = string.format("%s · %d unread", text, self.unread)
  end
  self.status_text, self.status_color = text, state[2]
  core.redraw = true
end

---Posts the box's text to the thread. A failed post puts the text back.
function ExternalAgentView:send()
  local text = self.field:get_text():gsub("^%s*\n", ""):gsub("%s+$", "")
  if not text:find("%S") then return false end
  local draft = self.field:get_text()
  self.field:set_text("")
  plugin.request("external.post", { agent = self.agent, text = text, from = { kind = "user" } }, function(err)
    if not err then return end
    if self.field:get_text() == "" then self.field:set_text(draft) end
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
local function code_pad() return ui.metrics().gap end

function ExternalAgentView:author(message)
  local from = message.from or EMPTY
  if from.kind == "self" then
    -- An answer to a Pi names the Pi.
    local asked = message.reply_to and self.requests[message.reply_to]
    local to = asked and (asked.from or EMPTY).kind == "agent" and asked.from.name
    return to and self.agent .. " → " .. to or self.agent
  end
  local name = from.kind == "user" and "You" or from.name or "Agent"
  return from.machine and name .. " @ " .. from.machine or name
end

local function time_text(time)
  if type(time) ~= "number" then return "" end
  return os.date(os.date("%Y%m%d", time) == os.date("%Y%m%d") and "%H:%M" or "%d %b %H:%M", time)
end

-- The parts of a message's text: prose, and code between ``` fence lines.
local function split_parts(text)
  local parts, lines, code = {}, {}, false
  local function flush()
    if #lines > 0 then parts[#parts + 1] = { code = code, text = table.concat(lines, "\n") } end
    lines = {}
  end
  for line in (text:gsub("%s+$", "") .. "\n"):gmatch("(.-)\r?\n") do
    if line:match("^%s*```") then
      flush()
      code = not code
    else
      lines[#lines + 1] = line
    end
  end
  flush()
  return parts
end

-- The parts of a message, with their lines for `width`. The width and the font size key the cache.
function ExternalAgentView:parts(message, width)
  local font = ui.font()
  local cache = message.layout
  if not cache or cache.width ~= width or cache.size ~= font:get_size() then
    local parts, height = split_parts(message.text or ""), 0
    for i, part in ipairs(parts) do
      local part_font = part.code and style.code_font or font
      local inner = part.code and width - 2 * code_pad() or width
      part.lines = line_texts(part_font, part.text, math.max(1, inner))
      part.h = #part.lines * part_font:get_height() + (part.code and 2 * code_pad() or 0)
      height = height + part.h + (i > 1 and ui.metrics().text_gap or 0)
    end
    cache = { width = width, size = font:get_size(), parts = parts, h = height }
    message.layout = cache
  end
  return cache
end

-- Places each message: `y` from the thread's top, its height, and whether it continues the message before it.
function ExternalAgentView:layout(width)
  local m = ui.metrics()
  local font_size = ui.font():get_size()
  local last = self.messages[#self.messages]
  local key = self.laid_out
  if key and key.width == width and key.size == font_size and key.count == #self.messages and key.last == last then
    return
  end
  local y, previous = 0, nil
  for _, message in ipairs(self.messages) do
    local from = message.from or EMPTY
    message.author = message.author or table.concat({ from.kind or "", from.name or "", from.machine or "" }, "\0")
    message.continued = previous ~= nil and previous.author == message.author and type(message.time) == "number"
      and type(previous.time) == "number" and message.time - previous.time < GROUP_SECONDS
    if previous then y = y + (message.continued and m.gap or m.section_gap) end
    message.label = message.label or self:author(message)
    message.when = message.when or time_text(message.time)
    message.y = y
    message.h = (message.continued and 0 or ui.bold_font():get_height() + m.text_gap) + self:parts(message, width).h
    y = y + message.h
    previous = message
  end
  self.content_h = y
  self.laid_out = { width = width, size = font_size, count = #self.messages, last = last }
end

function ExternalAgentView:footer_h()
  return self.field.h + 2 * pad()
end

function ExternalAgentView:get_scrollable_size()
  return header_h() + 2 * pad() + self.content_h + self:footer_h()
end

function ExternalAgentView:max_scroll()
  return math.max(0, self:get_scrollable_size() - self.size.y)
end

function ExternalAgentView:update()
  -- The thread follows new messages while it shows its end.
  self.stick = self.stick or self.scroll.to.y >= self.last_max - 1
  local width = self.size.x - 2 * pad()
  local box_h = self.field:height_for(width)
  self.field:set_rect(self.position.x + pad(), self.position.y + self.size.y - pad() - box_h, width, box_h)
  self:layout(width)
  self.last_max = self:max_scroll()
  if self.stick then self.scroll.to.y = self.last_max end
  self.stick = false
  ExternalAgentView.super.update(self)
end

------------------------------------------------------------------------------------------------------------------
-- Input

function ExternalAgentView:message_at(x, y)
  local top, bottom = self.position.y + header_h(), self.position.y + self.size.y - self:footer_h()
  if y < top or y >= bottom or x < self.position.x or x >= self.position.x + self.size.x then return end
  local offset = y - (top + pad() - self.scroll.y)
  local gap = ui.metrics().gap
  for _, message in ipairs(self.messages) do
    if offset >= message.y - gap / 2 and offset < message.y + message.h + gap / 2 then return message end
  end
end

function ExternalAgentView:on_mouse_wheel(y)
  local mx, my = core.root_panel.mouse.x, core.root_panel.mouse.y
  if self.field:contains(mx, my) and self.field:scroll_lines(y) then return true end
end

function ExternalAgentView:on_mouse_pressed(button, x, y, clicks)
  if ExternalAgentView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if button ~= "left" then return true end
  if self.field:contains(x, y) then
    self.field.scrolled = false
    return self.field:on_mouse_pressed(x, y, clicks or 1)
  end
  -- A click selects a message, so Copy takes its text.
  local message = self:message_at(x, y)
  self.selected = message ~= self.selected and message or nil
  core.redraw = true
  return true
end

function ExternalAgentView:on_mouse_moved(x, y, dx, dy)
  if ExternalAgentView.super.on_mouse_moved(self, x, y, dx, dy) then return true end
  if self.field:on_mouse_moved(x, y) then return true end
  self.cursor = self.field:contains(x, y) and "ibeam" or "arrow"
end

function ExternalAgentView:on_mouse_released(button, x, y)
  ExternalAgentView.super.on_mouse_released(self, button, x, y)
  self.field:on_mouse_released()
end

function ExternalAgentView:on_text_input(text)
  self.field.scrolled = false
  self.field:on_text(text)
end

---Performs an editor line command, without its "core:" prefix. Copy takes the selected message when the box has
---no selection.
function ExternalAgentView:perform(name)
  local first, last = self.field.input:selection()
  if name == "copy" and first == last and self.selected then
    system.set_clipboard(self.selected.text or "")
    return true
  end
  self.field.scrolled = false
  return self.field:perform(name)
end

function ExternalAgentView:context_menu(x, y)
  if x and y then
    self.selected = self:message_at(x, y)
    core.redraw = true
  end
  if not self.selected then return end
  local icons = require("core.context_menu").icons
  return { { label = "Copy Message", icon = icons.copy, command = "external_agents:copy_message" } }
end

function ExternalAgentView:context_menu_point()
  local message = self.selected
  if not message then return end
  return self.position.x + pad(), self.position.y + header_h() + pad() - self.scroll.y + message.y
end

-- The keymap's commands for the editor do not run in this View, so its keys come here.
function ExternalAgentView:on_key_pressed(key, event)
  if keymap.is_modifier_key(key) then return false end
  if key == "return" or key == "keypad enter" then
    if keymap.modkeys.shift then
      self.field.scrolled = false
      return self.field:on_text("\n")
    end
    if keymap.modkeys.alt then return false end
    return self:send() or true
  end
  if key == "escape" and self.selected then
    self.selected = nil
    core.redraw = true
    return true
  end
  if key == "pageup" or key == "pagedown" then
    local page = math.max(1, self.size.y - header_h() - self:footer_h()) * 0.9
    self.scroll.to.y = self.scroll.to.y + (key == "pageup" and -page or page)
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

function ExternalAgentView:draw_message(message, x, y, width)
  local m = ui.metrics()
  local font, bold, meta = ui.font(), ui.bold_font(), ui.role_font("meta")
  if message == self.selected then
    renderer.draw_rect(self.position.x, y - m.gap / 2, self.size.x, message.h + m.gap, style.line_highlight)
  end
  if self:is_unread(message) then
    -- A dot in the margin marks a message that the agent has not received yet.
    local dot = math.max(2, math.floor(font:get_height() / 4))
    local line_y = message.continued and y or y + bold:get_height() + m.text_gap
    renderer.draw_rect(x - math.floor((pad() + dot) / 2), line_y + math.floor((font:get_height() - dot) / 2), dot, dot,
      style.accent)
  end
  if not message.continued then
    local from = message.from or EMPTY
    renderer.draw_text(bold, message.label, x, y, from.kind == "self" and style.accent or style.text)
    renderer.draw_text(meta, message.when, x + bold:get_width(message.label) + m.gap,
      y + bold:get_height() - meta:get_height(), style.dim)
    y = y + bold:get_height() + m.text_gap
  end
  for i, part in ipairs(self:parts(message, width).parts) do
    if i > 1 then y = y + m.text_gap end
    if part.code then
      renderer.draw_rounded_rect(x, y, width, part.h, m.small_radius, style.markdown_live_code_background,
        style.markdown_live_code_background)
      local code_font = style.code_font
      local ly = y + code_pad()
      for _, line in ipairs(part.lines) do
        renderer.draw_text(code_font, line, x + code_pad(), ly, style.text)
        ly = ly + code_font:get_height()
      end
    else
      local ly = y
      for _, line in ipairs(part.lines) do
        renderer.draw_text(font, line, x, ly, style.text)
        ly = ly + font:get_height()
      end
    end
    y = y + part.h
  end
end

function ExternalAgentView:draw()
  self:draw_background(style.background)
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local m = ui.metrics()
  local font = ui.font()
  local p, top_h, bottom_h = pad(), header_h(), self:footer_h()
  local width = w - 2 * p

  -- The clip keeps the thread out of the header and the footer, which stay in place while it scrolls.
  core.push_clip_rect(x, y + top_h, w, h - top_h - bottom_h)
  local top = y + top_h + p - self.scroll.y
  for _, message in ipairs(self.messages) do
    local my = top + message.y
    if my + message.h > y + top_h - m.gap and my < y + h - bottom_h + m.gap then
      self:draw_message(message, x + p, my, width)
    end
  end
  core.pop_clip_rect()

  if not self.status_text then self:status_changed() end
  local dot = math.floor(font:get_height() / 3)
  local cy = y + math.floor(top_h / 2)
  renderer.draw_rect(x + p, cy - math.floor(dot / 2), dot, dot, style[self.status_color] or style.dim)
  renderer.draw_text(font, ui.fit_text(font, self.status_text, width - dot - m.gap), x + p + dot + m.gap,
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

command.add(function()
  local view = core.active_view
  return view and view:is(ExternalAgentView) and view.selected ~= nil, view
end, {
  ["external_agents:copy_message"] = function(view)
    system.set_clipboard(view.selected.text or "")
  end,
})

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

plugin.break_lines = break_lines

return plugin
