-- mod-version:3
-- External Agent Views: the thread of an agent outside Anvil's Terminals, such as Antigravity, and a box to message
-- it. The thread lives on the Project's Machine (`core.serve_external`), so a Project on another Machine shows the
-- same thread as the Machine itself.
local core = require "core"
local Buffer = require "core.buffer"
local command = require "core.command"
local common = require "core.common"
local Editor = require "core.editor"
local keymap = require "core.keymap"
local LineInput = require "core.line_input"
local live = require "core.markdown.live_render"
local Object = require "core.object"
local panes = require "core.panes"
local style = require "core.style"
local ui = require "core.ui"
local Badge = require "core.ui.badge"
local Button = require "core.ui.button"
local EmptyState = require "core.ui.empty_state"
local StatusDot = require "core.ui.status_dot"
local surface = require "core.ui.surface"
local syntax = require "core.syntax"
local TextView = require "core.textview"
local View = require "core.view"

local plugin = {}
local PROJECT_CHAT = "Project Chat" -- Not a valid External Agent name.
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

------------------------------------------------------------------------------------------------------------------
-- The message box: text in lines that wrap. Enter sends it; Shift+Enter starts a new line.

local MessageBox = Object:extend()

function MessageBox:new(placeholder)
  self.input = LineInput("", true)
  self.placeholder = placeholder
  self.x, self.y, self.w, self.h, self.scroll = 0, 0, 0, 0, 0
  -- Room on the right for a button.
  self.trail = 0
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
  local font, width = ui.font(), math.max(1, self.w - pad_x() - math.max(pad_x(), self.trail))
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
-- Message text: a read-only Editor with the Live Preview of Markdown. A message shows, selects and copies as a note
-- does, with its lists, tables, links and highlighted code.

local MessageText = Editor:extend()

function MessageText:__tostring() return "MessageText" end

---`on_change` marks the thread for layout when the measured rows change.
function MessageText:new(text, on_change)
  -- The text has no file, so it has no path for links to resolve against.
  local buffer = Buffer()
  buffer:set_syntax(syntax.get("message.md"), "external-agent")
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  buffer:clean()
  buffer.read_only = true
  -- The text belongs to no tab, so it skips the Editor's Buffer registry.
  TextView.new(self, buffer)
  self:become_selection_mirror_owner()
  self.scrollable = false
  self.hide_scrollbars = true
  self.show_current_line_highlight = false
  self.wrap_continuation_flush = true
  self:set_wrapping_enabled(true)
  live.attach(self)
  self.on_height_change = on_change
end

function MessageText:invalidate_height()
  if self.measured then
    self.measured = nil
    self.on_height_change()
  end
end

-- Markdown can publish the wrapped rows after the parse, or after a resize.
function MessageText:clear_composed_visual_row_cache()
  TextView.clear_composed_visual_row_cache(self)
  self:invalidate_height()
end

function MessageText:invalidate_visual_metrics(...)
  TextView.invalidate_visual_metrics(self, ...)
  self:invalidate_height()
end

-- The text is read-only, so a selection shows no Markdown syntax.
function MessageText:get_line_render_selection_state() return { selections = {}, last_selection = 1 } end
function MessageText:get_gutter_width() return 0, 0 end
function MessageText:draw_line_gutter() return self:get_line_height() end
function MessageText:draw_line_highlight() end
function MessageText:draw_scrollbar() end
function MessageText:draw_background() end
function MessageText:draw_content_left_edge() end
function MessageText:draw_soft_wrap_continuation_indicators() end
function MessageText:compute_wrap_width() return math.max(1, self.size.x) end
-- An Editor also records Navigation History. This text is not in a Pane.
function MessageText:update() TextView.update(self) end

---Wraps the text to `width` and returns its height. The height stays until the width, the font or the parse
---changes.
function MessageText:measure(width)
  local key = self.measured
  local font = self:get_font()
  if key and key.width == width and key.font == font then return key.height end
  self.size.x = width
  self:update_wrap_cache()
  local bottom = self:get_visual_row_y_offset(self:get_scrollable_line_count() + 1)
  local height = math.max(self:get_line_height(), bottom - self:get_visual_row_y_offset(1))
  self.measured = { width = width, font = font, height = height }
  return height
end

---Places the text with its first row at (`x`, `top`), wrapped to `width`. Returns its height.
function MessageText:place(x, top, width)
  local height = self:measure(width)
  -- A Text View draws its first row one padding below its top.
  self.position.x, self.position.y = x, top - style.padding.y
  self.size.y = height + 2 * style.padding.y
  self.scroll.x, self.scroll.y, self.scroll.to.x, self.scroll.to.y = 0, 0, 0, 0
  self.text_h = height
  return height
end

-- Draws only the text of the rows that show. The full frame of a Text View, with its caret, overlays and line
-- packets, costs more than a thread can spend on each message.
function MessageText:draw()
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  local x = self:get_content_offset() + self:get_gutter_width()
  local drawn = {}
  for entry in self:iter_visible_visual_rows() do
    if not drawn[entry.line] then
      drawn[entry.line] = true
      local _, y = self:get_line_screen_position(entry.line)
      self:draw_line_body_in_region(entry.line, x, y)
    end
  end
  core.pop_clip_rect()
end

function MessageText:contains(x, y)
  local top = self.position.y + style.padding.y
  return x >= self.position.x and x < self.position.x + self.size.x and y >= top and y < top + (self.text_h or 0)
end

function MessageText:get_text()
  return self.buffer:get_text(1, 1, math.huge, math.huge)
end

---The selected text, or nil when nothing is selected.
function MessageText:get_selected_text()
  local line1, col1, line2, col2 = self.buffer:get_selection(true)
  if line1 == line2 and col1 == col2 then return nil end
  return self.buffer:get_text(line1, col1, line2, col2)
end

function MessageText:clear_selection()
  local line, col = self.buffer:get_selection()
  self.buffer:set_selection(line, col)
end

function MessageText:on_close()
  live.detach(self)
  TextView.on_close(self)
  self.buffer:on_close()
end

local function close_text(message)
  if message.text_view then message.text_view:on_close() end
  message.text_view = nil
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
  -- The thread in cards, from `layout`. Each card holds a message and the messages that answer it.
  self.cards = {}
  -- "connecting", "listening", "idle", "unknown" (the agent never waited) or "offline".
  self.status = "connecting"
  self.unread = 0
  self.stick = true
  self.content_h, self.last_max = 0, 0
  self.project_chat = agent == PROJECT_CHAT
  self.field = MessageBox(self.project_chat and "Message" or "Message " .. agent)
  if self.project_chat then
    self.recipient_button = Button { label = "To: Choose agent", icon = ui.icons.chevron_down, kind = "ghost",
      size = "small", on_click = function() self:choose_recipient() end }
  end
  self.status_dot = StatusDot {}
  self.badge = Badge { tone = "warning" }
  self.empty = EmptyState { icon = ui.icons.inbox, title = "No messages yet" }
  core.add_thread(function() self:read_thread() end)
end

function ExternalAgentView:get_name() return self.agent end
function ExternalAgentView:supports_text_input() return true end
-- A thread stays in its Pane, as a busy Terminal does. Another View, such as a Terminal from the Sidebar, opens in a
-- new Pane.
function ExternalAgentView:can_open_view() return false end
function ExternalAgentView:on_close()
  self.closed = true
  for _, message in ipairs(self.messages) do close_text(message) end
end

-- An unsent message stays with the Workspace.
function ExternalAgentView:get_state()
  local draft = self.field:get_text()
  return { agent = self.agent, draft = draft ~= "" and draft or nil, target = self.target, recipient = self.recipient }
end

function ExternalAgentView.from_state(state)
  if type(state) ~= "table" or state.agent ~= PROJECT_CHAT and not valid_name(state.agent) then return end
  local view = ExternalAgentView(state.agent)
  if view.project_chat then
    view.target, view.recipient = state.target, state.recipient
    view:update_recipient_label()
  end
  if type(state.draft) == "string" then view.field:set_text(state.draft) end
  return view
end

function ExternalAgentView:update_recipient_label()
  local recipient = self.target or self.recipient
  self.recipient_button.label = self.read_only and "External Agents"
    or "To: " .. (recipient and (recipient.name or "Reply") or "Choose agent")
end

function ExternalAgentView:set_recipient(recipient)
  self.recipient, self.target = recipient, nil
  self:update_recipient_label()
  self.field:set_error(nil)
  self:focus_text(nil)
end

function ExternalAgentView:choose_recipient()
  local button = self.recipient_button
  local read_only = self.read_only
  button.enabled = false
  plugin.request(read_only and "external.list" or "chat.recipients", {}, function(err, result)
    button.enabled = true
    core.redraw = true
    if self.closed or core.active_view ~= self then return end
    if err then return self.field:set_error(err.message or err.code) end
    local function select(agent)
      if read_only then plugin.open(agent.name) else self:set_recipient(agent) end
    end
    local agents = result.agents or EMPTY
    if #agents == 0 then
      return core.warn("No agents are available. Start Pi or run anvil:mcp_server to set up an External Agent.")
    end
    if #agents == 1 then return select(agents[1]) end
    local options = {}
    for _, agent in ipairs(agents) do
      options[#options + 1] = {text = agent.name, recipient = agent,
        info = agent.terminal and "Pi · " .. agent.terminal:sub(1, 8) or "External Agent"}
    end
    core.global_prompt_bar:enter(read_only and "External Agent" or "To", {
      text = "",
      suggest = function(text) return common.fuzzy_match(options, text) end,
      validate = function(_, option) return option ~= nil end,
      submit = function(_, option) if not self.closed then select(option.recipient) end end,
    })
  end)
end

-- Reads the thread, then waits for each change. The Machine answers a wait when a message arrives, or the agent's
-- listening or read state changes, and at the latest after 25 seconds.
function ExternalAgentView:read_thread()
  local loaded = false
  while not self.closed do
    local done, err, result
    plugin.request(self.project_chat and "chat.read" or "external.read", { agent = self.agent, after = self.read_cursor, wait = loaded },
      function(e, r) done, err, result = true, e, r end)
    while not done and not self.closed do coroutine.yield(0.05) end
    if self.closed then return end
    if err then
      if self.project_chat then
        self.read_only = err.code == "forbidden" or self.read_only
        self:update_recipient_label()
      end
      self.status = self.read_only and "read_only" or err.code == "not_found" and "unknown" or "offline"
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
  if self.read_only then
    self.read_only = nil
    self:update_recipient_label()
  end
  -- A Machine that lost the thread starts again at 1, and sends the whole new thread.
  if type(result.seq) == "number" and result.seq < self.read_cursor then
    for _, message in ipairs(self.messages) do close_text(message) end
    self.messages, self.requests, self.read_cursor = {}, {}, 0
    self:focus_text(nil)
  end
  for _, message in ipairs(result.messages or EMPTY) do
    if message.seq > self.read_cursor then
      if self.project_chat then
        local from = message.from or EMPTY
        if type(message.external) == "string" then
          message.profile = {name = message.external, external = message.external}
        elseif message.pi and from.terminal and from.instance then
          message.profile = {name = from.name, terminal = from.terminal, instance = from.instance}
        end
      end
      self.messages[#self.messages + 1] = message
      if message.request then self.requests[message.request] = message end
    end
  end
  while #self.messages > MAX_SHOWN do
    local removed = table.remove(self.messages, 1)
    if removed.request then self.requests[removed.request] = nil end
    if self.text_focus == removed.text_view then self:focus_text(nil) end
    close_text(removed)
  end
  if type(result.cursor) == "number" then self.read_cursor = math.max(self.read_cursor, result.cursor) end
  -- A Machine without read states sends no `read`. Its thread then shows no unread messages.
  self.read = type(result.read) == "number" and result.read or nil
  self.unread = 0
  for _, message in ipairs(self.messages) do
    if self:is_unread(message) then self.unread = self.unread + 1 end
  end
  self.status, self.error = self.project_chat and "connected" or result.listening and "listening" or "idle", nil
  self.laid_out = nil
  self:status_changed()
end

-- A message to the agent that its waits have not given it yet.
function ExternalAgentView:is_unread(message)
  return self.read ~= nil and message.seq > self.read and (message.from or EMPTY).kind ~= "self"
end

local STATUS = {
  connected = { "Connected", "success" },
  connecting = { "Connecting", "neutral" },
  listening = { "Listening", "success" },
  idle = { "Not listening", "warning" },
  unknown = { "Not connected yet", "warning" },
  read_only = { "View access", "neutral" },
  offline = { "Offline", "danger" },
}

function ExternalAgentView:status_changed()
  local state = STATUS[self.status] or STATUS.offline
  local label = state[1]
  if self.status == "offline" and self.error then label = label .. ": " .. self.error end
  self.status_dot:set(state[2], label)
  self.badge:set_label(self.unread .. " queued")
  core.redraw = true
end

---Posts the box's text to the thread. A failed post puts the text back.
function ExternalAgentView:send()
  local text = self.field:get_text():gsub("^%s*\n", ""):gsub("%s+$", "")
  if not text:find("%S") then return false end
  if self.project_chat then
    if self.read_only or self.sending or not (self.target or self.recipient) then return false end
    local draft, target = self.field:get_text(), self.target
    local method = target and "chat.reply" or "chat.send"
    local params = target and {parent = target.id, text = text} or {recipient = self.recipient, text = text}
    self.sending = true
    plugin.request(method, params, function(err)
      self.sending = false
      if err then self.field:set_error(err.message or err.code)
      else
        if self.field:get_text() == draft then self.field:set_text("") end
        if target and self.target == target then
          self.target = nil
          self:update_recipient_label()
        end
      end
      core.redraw = true
    end)
    self.stick = true
    return true
  end
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

-- The thread and the message box are at most this wide, at scale 1, so that lines stay easy to read.
local MAX_WIDTH = 760

local function header_h() local m = ui.metrics() return m.control_h + m.gap end
local function avatar_size() return ui.font():get_height() + 2 * ui.metrics().text_gap end
-- The author's name is centred on the avatar.
local function name_top() return math.floor((avatar_size() - ui.role_font("strong"):get_height()) / 2) end
-- An answer sits this far right of its question.
local function indent() return avatar_size() + ui.metrics().gap end
-- Each message keeps room on its right for its copy button.
local function copy_size() return ui.metrics().control_xs_h end
local function send_size() return ui.metrics().control_xs_h end
local function send_inset() return math.floor((ui.metrics().field_h - send_size()) / 2) end

function ExternalAgentView:author(message)
  local from = message.from or EMPTY
  if from.kind == "self" then return self.agent end
  local name = from.kind == "user" and "You" or from.name or "Agent"
  if from.machine then name = name .. " @ " .. from.machine end
  return message.to and name .. " → " .. message.to.name or name
end

local function time_text(time)
  if type(time) ~= "number" then return "" end
  return os.date(os.date("%Y%m%d", time) == os.date("%Y%m%d") and "%H:%M" or "%d %b %H:%M", time)
end

-- The text of a message, made when the thread first shows it.
function ExternalAgentView:text_of(message)
  if not message.text_view then
    message.text_view = MessageText(message.text or "", function()
      self.laid_out = nil
      core.redraw = true
    end)
  end
  return message.text_view
end

-- The width of a message's text in a card with `inner` width.
local function text_width(message, inner)
  return math.max(1, inner - message.x - copy_size() - ui.metrics().text_gap)
end

-- The column of the thread and the message box: its left edge and its width.
function ExternalAgentView:column()
  local w = math.max(1, math.min(self.size.x - 2 * ui.metrics().row_pad_x, math.floor(MAX_WIDTH * SCALE)))
  return self.position.x + math.floor((self.size.x - w) / 2), w
end

-- The first line of a question, for the quote above its late answer.
local function first_line(text)
  return ((text or ""):match("^%s*```[^\n]*\n?(.*)$") or text or ""):match("^%s*([^\n]*)") or ""
end

-- Puts the messages in cards, in time order. A card starts with a message, and holds the answers to it and the
-- messages that its authors add within GROUP_SECONDS. An answer to a question in an earlier card starts a card
-- that quotes the question. Each message gets `y` from the thread's top, its height, its `depth` (1 for an answer)
-- and whether it shows its author.
function ExternalAgentView:layout(width)
  local m = ui.metrics()
  local font_size = ui.font():get_size()
  local last = self.messages[#self.messages]
  local key = self.laid_out
  if key and key.width == width and key.size == font_size and key.count == #self.messages and key.last == last then
    return
  end
  local inner = width - 2 * m.pad_x
  local avatar, step = avatar_size(), indent()
  local name_h = name_top() + ui.role_font("strong"):get_height()
  local cards, card, previous, y = {}, nil, nil, 0
  for _, message in ipairs(self.messages) do
    local from = message.from or EMPTY
    local to = message.to or EMPTY
    message.author = message.author or table.concat({ from.kind or "", from.name or "", from.machine or "",
      from.terminal or "", from.instance or "", to.external or "", to.terminal or "", to.instance or "" }, "\0")
    message.label = message.label or self:author(message)
    message.when = message.when or time_text(message.time)
    local asked = message.reply_to and self.requests[message.reply_to]
    local answers = card ~= nil and asked ~= nil and asked.card == card
    local continues = card ~= nil and previous.author == message.author and (not asked or answers)
      and type(message.time) == "number" and type(previous.time) == "number"
      and message.time - previous.time < GROUP_SECONDS
    if answers or continues then
      y = y + (continues and m.gap or m.pad_x)
    else
      if card then
        card.h = y + m.pad_x - card.y
        y = y + m.pad_x + m.section_gap
      end
      card = { y = y, messages = {}, root = message.author }
      cards[#cards + 1] = card
      y = y + m.pad_x
      if asked then
        card.quote = asked.label .. ": " .. first_line(asked.text)
        card.quote_y = y
        y = y + ui.role_font("meta"):get_height() + m.gap
      end
    end
    message.card = card
    message.depth = message.author == card.root and 0 or 1
    message.header = not continues
    message.x = message.depth * step + step
    message.y = y
    local body = self:text_of(message):measure(text_width(message, inner))
    message.h = message.header and math.max(avatar, name_h + m.text_gap + body) or body
    -- The thread line runs from the question's avatar to each answer's avatar.
    if message.header and message.depth == 1 then
      card.rail_from = card.rail_from or card.messages[1].y + avatar + m.text_gap
      card.rail_to = y + math.floor(avatar / 2)
    end
    card.messages[#card.messages + 1] = message
    y = y + message.h
    previous = message
  end
  if card then
    card.h = y + m.pad_x - card.y
    y = y + m.pad_x
  end
  self.cards = cards
  self.content_h = y
  self.laid_out = { width = width, size = font_size, count = #self.messages, last = last }
end

function ExternalAgentView:footer_h()
  local m = ui.metrics()
  return self.field.h + m.gap + m.row_pad_x + (self.recipient_button and m.control_sm_h + m.gap or 0)
end

function ExternalAgentView:get_scrollable_size()
  return header_h() + 2 * ui.metrics().row_pad_x + self.content_h + self:footer_h()
end

function ExternalAgentView:max_scroll()
  return math.max(0, self:get_scrollable_size() - self.size.y)
end

function ExternalAgentView:send_rect()
  local field, size, inset = self.field, send_size(), send_inset()
  return field.x + field.w - inset - size, field.y + field.h - inset - size, size
end

function ExternalAgentView:update()
  -- The thread follows new messages while it shows its end.
  self.stick = self.stick or self.scroll.to.y >= self.last_max - 1
  local x, width = self:column()
  self.field.trail = send_size() + send_inset() + ui.metrics().text_gap
  local box_h = self.field:height_for(width)
  self.field:set_rect(x, self.position.y + self.size.y - ui.metrics().row_pad_x - box_h, width, box_h)
  self:layout(width)
  local top, bottom = self:thread_top(), self.position.y + self.size.y
  for _, message in ipairs(self.messages) do
    local y = top + message.y
    if message.text_view and y + message.h > self.position.y and y < bottom then message.text_view:update() end
  end
  self.last_max = self:max_scroll()
  if self.stick then self.scroll.to.y = self.last_max end
  self.stick = false
  ExternalAgentView.super.update(self)
end

------------------------------------------------------------------------------------------------------------------
-- Input

-- The top of the thread on the screen.
function ExternalAgentView:thread_top()
  return self.position.y + header_h() + ui.metrics().row_pad_x - self.scroll.y
end

function ExternalAgentView:message_at(x, y)
  local top, bottom = self.position.y + header_h(), self.position.y + self.size.y - self:footer_h()
  local left, width = self:column()
  if y < top or y >= bottom or x < left or x >= left + width then return end
  local offset = y - self:thread_top()
  local gap = ui.metrics().gap
  for _, message in ipairs(self.messages) do
    if message.y and offset >= message.y - gap / 2 and offset < message.y + message.h + gap / 2 then return message end
  end
end

-- The text under (x, y), and the message under it.
function ExternalAgentView:text_at(x, y)
  local message = self:message_at(x, y)
  local text = message and message.text_view
  return text and text:contains(x, y) and text or nil, message
end

function ExternalAgentView:over_send(x, y)
  local sx, sy, size = self:send_rect()
  return x >= sx and x < sx + size and y >= sy and y < sy + size
end

-- The copy button of a message, at its top right.
function ExternalAgentView:copy_rect(message)
  local x, width = self:column()
  local size = copy_size()
  return x + width - ui.metrics().pad_x - size, self:thread_top() + message.y, size
end

-- The message whose copy button is under (x, y). The button shows on the message under the pointer.
function ExternalAgentView:over_copy(x, y)
  local message = self.hovered
  if not message then return nil end
  local cx, cy, size = self:copy_rect(message)
  return x >= cx and x < cx + size and y >= cy and y < cy + size and message or nil
end

---Copies the whole text of `message`.
function ExternalAgentView:copy_message(message)
  system.set_clipboard(message.text or "")
  self.copied, self.copied_time = message, system.get_time()
  core.redraw = true
end

function ExternalAgentView:reply_to(message)
  self.target = {id = message.request, name = message.from.name, label = "Reply: " .. first_line(message.text)}
  self:update_recipient_label()
  self.field:set_error(nil)
  self:focus_text(nil)
end

-- A profile is the avatar and name in a message header.
function ExternalAgentView:over_profile(message, x, y)
  if not (message and message.header and message.profile) then return false end
  local top = self:thread_top() + message.y
  if y < top or y >= top + avatar_size() then return false end
  local left = self:column() + ui.metrics().pad_x
  return x >= left + message.depth * indent() and x < left + message.x + ui.role_font("strong"):get_width(message.label)
end

---Gives the keyboard's Copy and Select All to a message's text, or to the message box when `text` is nil. The
---text that loses them also loses its selection.
function ExternalAgentView:focus_text(text)
  if self.text_focus and self.text_focus ~= text then self.text_focus:clear_selection() end
  self.text_focus = text
  self.recipient_focused = false
  core.redraw = true
end

function ExternalAgentView:on_mouse_wheel(y)
  local mx, my = core.root_panel.mouse.x, core.root_panel.mouse.y
  if self.field:contains(mx, my) and self.field:scroll_lines(y) then return true end
end

function ExternalAgentView:on_mouse_pressed(button, x, y, clicks)
  if ExternalAgentView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if button ~= "left" then return true end
  local agents = self.recipient_button
  if agents and agents:contains(x, y) then
    agents.pressed = agents.enabled
    core.redraw = true
    return true
  end
  local hit = self:message_at(x, y)
  if self.project_chat and hit and (hit.pi or hit.external) then
    local cx, cy, size = self:copy_rect(hit)
    if x < cx and x >= cx - ui.font():get_width("Reply") - ui.metrics().gap and y >= cy and y < cy + size then
      self:reply_to(hit)
      return true
    end
  end
  if self:over_profile(hit, x, y) then
    self:set_recipient(hit.profile)
    return true
  end
  local copy = self:over_copy(x, y)
  if copy then
    self:copy_message(copy)
    return true
  end
  if self:over_send(x, y) then return self:send() or true end
  if self.field:contains(x, y) then
    self:focus_text(nil)
    self.field.scrolled = false
    return self.field:on_mouse_pressed(x, y, clicks or 1)
  end
  -- A press in a message's text selects in it, as in an Editor.
  local text = self:text_at(x, y)
  self:focus_text(text)
  if text then
    self.pressed_text = text
    if not text:on_mouse_pressed(button, x, y, clicks or 1) then
      -- Normal Editors start selection through the keymap. This embedded Editor has no keymap focus.
      local line, col = text:resolve_screen_position(x, y)
      local snap = clicks == 2 and "word" or clicks == 3 and "lines" or nil
      text.buffer:set_selection(text:mouse_selection(text.buffer, snap, line, col, line, col))
      text:begin_line_render_interaction("mouse-selection")
      text.mouse_selecting = { line, col, snap }
    end
  end
  return true
end

function ExternalAgentView:on_mouse_moved(x, y, dx, dy)
  if ExternalAgentView.super.on_mouse_moved(self, x, y, dx, dy) then return true end
  local agents = self.recipient_button
  local over_agents = agents and agents:contains(x, y)
  if agents and agents.hovered ~= over_agents then
    agents.hovered = over_agents
    core.redraw = true
  end
  if self.pressed_text then
    self.pressed_text:on_mouse_moved(x, y, dx, dy)
    self.cursor = "ibeam"
    return true
  end
  if self.field:on_mouse_moved(x, y) then return true end
  local in_field = self.field:contains(x, y)
  local text, message
  if not in_field then text, message = self:text_at(x, y) end
  if text ~= self.hovered_text then
    if self.hovered_text then self.hovered_text:on_mouse_left() end
    self.hovered_text = text
  end
  -- The text shows its own pointer looks, such as a link's hand.
  if text then text:on_mouse_moved(x, y, dx, dy) end
  local over_send = self:over_send(x, y)
  if over_send ~= self.send_hovered or message ~= self.hovered then core.redraw = true end
  self.send_hovered, self.hovered = over_send, message
  local over_copy = self:over_copy(x, y) ~= nil
  if over_copy ~= self.copy_hovered then core.redraw = true end
  self.copy_hovered = over_copy
  self.cursor = (over_agents and agents.enabled or over_send or over_copy or self:over_profile(message, x, y)) and "hand"
    or in_field and "ibeam" or text and text.cursor or "arrow"
end

function ExternalAgentView:on_mouse_left()
  ExternalAgentView.super.on_mouse_left(self)
  if self.recipient_button then self.recipient_button.hovered = false end
  if self.hovered_text then self.hovered_text:on_mouse_left() end
  self.send_hovered, self.copy_hovered, self.hovered, self.hovered_text = false, false, nil, nil
  core.redraw = true
end

function ExternalAgentView:on_mouse_released(button, x, y)
  ExternalAgentView.super.on_mouse_released(self, button, x, y)
  local agents = self.recipient_button
  if button == "left" and agents and agents.pressed then
    agents:on_mouse_released(x, y)
    agents.pressed = false
    core.redraw = true
    return true
  end
  self.field:on_mouse_released()
  if self.pressed_text then
    self.pressed_text:on_mouse_released(button, x, y)
    self.pressed_text = nil
  end
end

function ExternalAgentView:on_text_input(text)
  -- Typing always goes to the message box.
  self:focus_text(nil)
  self.field.scrolled = false
  self.field:on_text(text)
end

---Performs an editor line command, without its "core:" prefix. After a click in a message, Copy takes its
---selection, or the whole message when nothing is selected, and Select All selects the message.
function ExternalAgentView:perform(name)
  local text = self.text_focus
  if text and name == "copy" then
    system.set_clipboard(text:get_selected_text() or text:get_text())
    return true
  elseif text and name == "select_all" then
    text.buffer:set_selection(1, 1, math.huge, math.huge)
    core.redraw = true
    return true
  end
  self:focus_text(nil)
  self.field.scrolled = false
  return self.field:perform(name)
end

function ExternalAgentView:context_menu(x, y)
  if x and y then self.menu_message = self:message_at(x, y) end
  local message = self.menu_message
  if not message then return end
  local icons = require("core.context_menu").icons
  local items = {}
  if self.project_chat and (message.pi or message.external) then
    items[#items + 1] = {label = "Reply", command = "external_agents:reply"}
  end
  local text = message.text_view
  if text and text == self.text_focus and text:get_selected_text() then
    items[#items + 1] = { label = "Copy", icon = icons.copy, command = "external_agents:copy" }
  end
  items[#items + 1] = { label = "Copy Message", icon = icons.copy, command = "external_agents:copy_message" }
  return items
end

function ExternalAgentView:context_menu_point()
  local message = self.menu_message
  if not message or not message.y then return end
  local x = self:column()
  return x + ui.metrics().pad_x + message.x, self:thread_top() + message.y
end

-- The keymap's commands for the editor do not run in this View, so its keys come here.
function ExternalAgentView:on_key_pressed(key, event)
  if keymap.is_modifier_key(key) then return false end
  if self.recipient_button and key == "tab" then
    local stroke = keymap.stroke_for_event(key, event)
    if stroke == "tab" or stroke == "shift+tab" then
      local focus = not self.recipient_focused
      self:focus_text(nil)
      self.recipient_focused = focus
      return true
    end
  end
  if self.recipient_focused and key == "escape" then
    self:focus_text(nil)
    return true
  end
  if key == "escape" and self.target then
    self.target = nil
    self:update_recipient_label()
    self.field:set_error(nil)
    core.redraw = true
    return true
  end
  if key == "return" or key == "keypad enter" then
    if self.recipient_focused then
      if keymap.modkeys.alt then return false end
      self.recipient_button:activate()
      return true
    end
    if keymap.modkeys.shift then
      self.field.scrolled = false
      return self.field:on_text("\n")
    end
    if keymap.modkeys.alt then return false end
    return self:send() or true
  end
  if key == "escape" and self.text_focus then
    self:focus_text(nil)
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

-- The tone of each kind of author: the agent, a Pi, or the user.
local AUTHOR_TONES = { self = "info", agent = "success" }

-- A round avatar with the first letter of `name`, in the colors of a Badge.
local function draw_avatar(name, tone, x, y)
  local size = avatar_size()
  local color = tone and ui.tone_color(tone) or style.dialog_text
  local fill = tone and ui.tint(color, 0.16) or ui.tint(style.dialog_text_strong, 0.1)
  renderer.draw_rounded_rect(x, y, size, size, size / 2, fill)
  local letter = (name:match("^[%z\1-\127\194-\244][\128-\191]*") or "?"):upper()
  common.draw_text(ui.role_font("strong"), color, letter, "center", x, y, size, size)
end

function ExternalAgentView:draw_message(message, left, top, width)
  local m = ui.metrics()
  local y = top + message.y
  if message == self.hovered then
    local hx = left + message.depth * indent() - m.text_gap * 2
    local hy, hw, hh = y - m.gap / 2, left + width + m.text_gap * 2 - hx, message.h + m.gap
    local pushed = ui.push_look(hx, hy, hw, hh, 1, 0.5)
    surface.draw("selected", hx, hy, hw, hh, m.small_radius)
    ui.pop_look(pushed)
  end
  local x = left + message.x
  if message.header then
    local from = message.from or EMPTY
    draw_avatar(message.label, AUTHOR_TONES[from.kind], left + message.depth * indent(), y)
    local strong, meta = ui.role_font("strong"), ui.role_font("meta")
    local profile, recipient = message.profile, self.recipient
    local selected = profile and recipient and profile.external == recipient.external
      and profile.terminal == recipient.terminal and profile.instance == recipient.instance
    y = y + name_top()
    renderer.draw_text(strong, message.label, x, y, selected and ui.tone_color("info") or style.dialog_text_strong)
    local mx = x + strong:get_width(message.label) + m.gap
    local my = y + strong:get_height() - meta:get_height()
    mx = renderer.draw_text(meta, message.when, mx, my, style.dialog_text_muted)
    if self:is_unread(message) then
      renderer.draw_text(meta, "Queued", mx + m.gap, my, ui.tone_color("warning"))
    end
    y = y + strong:get_height() + m.text_gap
  end
  local text = self:text_of(message)
  text:place(x, y, text_width(message, width))
  text:draw()
  if self.project_chat and (message.pi or message.external) and (message.header or message == self.hovered) then
    local cx, cy = self:copy_rect(message)
    local font = ui.font()
    renderer.draw_text(font, "Reply", cx - font:get_width("Reply") - m.gap, cy, style.dialog_text_strong)
  end
  if message == self.hovered then self:draw_copy(message) end
end

local COPY_ICON = require("core.context_menu").icons.copy
-- A copied message shows a check this long, in seconds.
local COPIED_SECONDS = 1.5

function ExternalAgentView:draw_copy(message)
  local x, y, size = self:copy_rect(message)
  local copied = self.copied == message and system.get_time() - self.copied_time < COPIED_SECONDS
  if copied then core.redraw = true end
  local amount = ui.approach(self, "copy_hover", self.copy_hovered and 1 or 0, 18)
  if amount > 0 then
    local pushed = ui.push_look(x, y, size, size, 1, amount)
    surface.draw("ghost_hover", x, y, size, size, ui.metrics().small_radius)
    ui.pop_look(pushed)
  end
  common.draw_text(ui.small_icon_font(), copied and ui.tone_color("success") or style.dialog_text_muted,
    copied and ui.icons.check or COPY_ICON, "center", x, y, size, size)
end

function ExternalAgentView:draw_card(card, x, top, width)
  local m = ui.metrics()
  local y = top + card.y
  surface.draw("group", x, y, width, card.h, m.group_radius)
  local left, inner = x + m.pad_x, width - 2 * m.pad_x
  local line = ui.tint(style.dialog_text_muted, 0.35)
  if card.quote then
    local font = ui.role_font("meta")
    local qy = top + card.quote_y
    renderer.draw_rect(left, qy, m.ring, font:get_height(), line)
    local qx = left + m.ring + m.gap
    renderer.draw_text(font, ui.fit_text(font, card.quote, left + inner - qx), qx, qy, style.dialog_text_muted)
  end
  if card.rail_from then
    local avatar = avatar_size()
    local rx = left + math.floor((avatar - m.border) / 2)
    renderer.draw_rect(rx, top + card.rail_from, m.border, card.rail_to - card.rail_from + m.border, line)
    for _, message in ipairs(card.messages) do
      if message.header and message.depth == 1 then
        local ey = top + message.y + math.floor(avatar / 2)
        renderer.draw_rect(rx, ey, left + indent() - m.text_gap - rx, m.border, line)
      end
    end
  end
  local first = self.position.y + header_h() - top
  local last = self.position.y + self.size.y - self:footer_h() - top
  for _, message in ipairs(card.messages) do
    if message.y + message.h > first and message.y < last then self:draw_message(message, left, top, inner) end
  end
end

function ExternalAgentView:draw_header()
  local m = ui.metrics()
  local y, h = self.position.y, header_h()
  local x, width = self:column()
  renderer.draw_rect(self.position.x, y + h - m.border, self.size.x, m.border, style.dialog_line)
  local right = x + width
  local avatar = avatar_size()
  local strong = ui.role_font("strong")
  local nx = x + avatar + m.gap
  if nx >= right then return end
  draw_avatar(self.agent, AUTHOR_TONES.self, x, y + math.floor((h - avatar) / 2))
  local name = ui.fit_text(strong, self.agent, right - nx)
  local dot_x = renderer.draw_text(strong, name, nx, y + math.floor((h - strong:get_height()) / 2),
    style.dialog_text_strong) + m.section_gap
  if self.unread > 0 then
    local badge_w = self.badge:width()
    right = right - badge_w - m.gap
    self.badge:place(x + width - badge_w, y, badge_w, h)
    self.badge:draw_node()
  end
  if right > dot_x then
    self.status_dot:place(dot_x, y, math.min(self.status_dot:width(), right - dot_x), h)
    self.status_dot:draw_node()
  end
end

function ExternalAgentView:draw_send()
  local x, y, size = self:send_rect()
  local ready = self.field:get_text():find("%S") ~= nil
    and (not self.project_chat or not self.read_only and not self.sending and (self.target or self.recipient))
  local amount = ui.approach(self, "send_hover", ready and self.send_hovered and 1 or 0, 18)
  local pushed = ui.push_look(x, y, size, size, 1, ready and 1 or ui.DISABLED_OPACITY)
  local base = ready and "lit" or "raised"
  surface.draw_faded(base, base .. "_hover", amount, x, y, size, size, size / 2)
  common.draw_text(ui.small_icon_font(), surface.get(base).text, ui.icons.arrow_up, "center", x, y, size, size)
  ui.pop_look(pushed)
end

function ExternalAgentView:draw_recipient(x, width)
  local button = self.recipient_button
  local m = ui.metrics()
  local w, h = button:measure()
  w = math.min(w, width)
  local y = self.field.y - m.gap - h
  button:place(x, y, w, h)
  button:draw(self.recipient_focused and core.active_view == self)
  local label = self.field.error or self.target and self.target.label
  local room = width - w - m.gap
  if label and room > 0 then
    local font = ui.role_font("description")
    renderer.draw_text(font, ui.fit_text(font, label, room), x + w + m.gap, y + math.floor((h - font:get_height()) / 2),
      self.field.error and style.dialog_danger or style.dialog_text_muted)
  end
end

function ExternalAgentView:draw()
  self:draw_background(style.background)
  local y, h = self.position.y, self.size.y
  local top_h, bottom_h = header_h(), self:footer_h()
  local x, width = self:column()
  if not self.status_dot.label then self:status_changed() end

  -- The clip keeps the thread out of the header and the footer, which stay in place while it scrolls.
  core.push_clip_rect(self.position.x, y + top_h, self.size.x, h - top_h - bottom_h)
  if #self.messages == 0 then
    local empty_h = self.empty:height(width)
    self.empty:place(x, y + top_h + math.floor((h - top_h - bottom_h - empty_h) / 2), width, empty_h)
    self.empty:draw_node()
  end
  local top = self:thread_top()
  for _, card in ipairs(self.cards) do
    local card_y = top + card.y
    if card_y + card.h > y + top_h and card_y < y + h - bottom_h then self:draw_card(card, x, top, width) end
  end
  core.pop_clip_rect()

  self:draw_header()
  if self.recipient_button then self:draw_recipient(x, width) end
  self.field:draw(core.active_view == self and not self.recipient_focused)
  self:draw_send()
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
  return view and view:is(ExternalAgentView) and view.menu_message ~= nil, view
end, {
  ["external_agents:copy_message"] = function(view) view:copy_message(view.menu_message) end,
  ["external_agents:reply"] = function(view) view:reply_to(view.menu_message) end,
})

command.add(function()
  local view = core.active_view
  local text = view and view:is(ExternalAgentView) and view.text_focus
  return text and text:get_selected_text() ~= nil, view
end, {
  ["external_agents:copy"] = function(view) system.set_clipboard(view.text_focus:get_selected_text()) end,
})

command.add(nil, {
  ["project:open_chat"] = command.palette(function() return plugin.open(PROJECT_CHAT) end,
    {keywords = {"agent", "external agents", "Pi", "antigravity", "agy", "conversation", "message", "reply"}, opens_view = true}),
})

plugin.break_lines = break_lines

return plugin
