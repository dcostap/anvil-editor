-- One Tab's content: its Pane number, View Icon or Terminal status dot, name, and note. The Title Bar and the
-- Project Sidebar draw Tabs with this module, so both show the same thing.
-- A Tab item is plain data. The Project describes its Panes, and the Pane report sends the items to the Sidebar.
local style = require "core.style"
local view_icons = require "core.view_icons"
local agent_icons = require "core.agent_icons"

local tab = {}

local DAY = 24 * 60 * 60
local WEEK, MONTH = 7 * DAY, 30 * DAY
-- Programs such as Pi lead their title with a braille spinner frame while they work. The title arrives at most a
-- few times a second, so the Tab turns a leading spinner itself.
local SPINNER = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
local SPINNER_FRAME = 0.08
local ELLIPSIS = "\u{2026}"

-- A short age such as "5m", "3h", "2d", "3w" or "4mo".
function tab.age_text(activity, now)
  if not activity or activity <= 0 then return nil end
  local age = math.max(0, now - activity)
  if age < 60 then return "now" end
  if age < 60 * 60 then return math.floor(age / 60) .. "m" end
  if age < DAY then return math.floor(age / (60 * 60)) .. "h" end
  if age < WEEK then return math.floor(age / DAY) .. "d" end
  if age < MONTH then return math.floor(age / WEEK) .. "w" end
  if age < 365 * DAY then return math.floor(age / MONTH) .. "mo" end
  return math.floor(age / (365 * DAY)) .. "y"
end

-- Whether the title leads with a braille character (U+2800 to U+28FF).
local function has_spinner(title)
  local first, second = title:byte(1, 2)
  return first == 0xE2 and second and second >= 0xA0 and second <= 0xA3
end

-- The title with its leading braille character swapped for the spinner frame at `clock`, or nil.
function tab.spinner_title(title, clock)
  if not has_spinner(title) then return nil end
  return SPINNER[math.floor(clock / SPINNER_FRAME) % #SPINNER + 1] .. title:sub(4)
end

-- Seconds until a drawn spinner shows its next frame.
function tab.spinner_delay(clock)
  return SPINNER_FRAME - clock % SPINNER_FRAME
end

-- Describes one Pane as a Tab item. `number` is the Pane's one-based Tab number.
function tab.describe(pane, number)
  local view = pane.current_view
  local item = {id = pane.id, number = number, name = view.get_name and view:get_name() or "View"}
  if view.terminal_view then
    -- Each spinner frame would otherwise change the item. The Tab turns the spinner itself.
    if has_spinner(item.name) then item.name = SPINNER[1] .. item.name:sub(4) end
    item.terminal = {session = view.session_id, state = view.state, busy = view.busy,
      activity = view.get_activity and view:get_activity() or nil,
      app = view.state == "running" and view.agent_app or nil}
    return item
  end
  local icon = view_icons.for_view(view)
  if icon then item.icon = icon.kind == "file" and {kind = "file", path = icon.path} or {kind = "ui", glyph = icon.glyph} end
  local path_tree = require "plugins.path_tree"
  local path = require("core.file_context").view_file_path(view)
  local git = path and path_tree.git_info_for_file(path)
  local color = path_tree.git_text_color(git and git.kind)
  if color then item.color = {color[1], color[2], color[3], color[4]} end
  if view.buffer and view.buffer.file_missing then item.missing = true end
  return item
end

-- Describes a Terminal Session that no Pane shows, from its Project Sidebar record.
function tab.describe_session(terminal)
  local name = terminal.title ~= "" and terminal.title or "Terminal"
  if terminal.state ~= "running" then name = name .. " (" .. terminal.state .. ")" end
  local busy
  if terminal.busy == 1 then busy = true elseif terminal.busy == 0 then busy = false end
  return {name = name, terminal = {session = terminal.id, state = terminal.state, busy = busy,
    bell = (terminal.bell or 0) > 0, activity = terminal.activity,
    app = terminal.state == "running" and terminal.agent_app or nil},
    agent = terminal.state == "running" and tab.agent(terminal) or nil}
end

local function tint(color, alpha)
  return {color[1], color[2], color[3], alpha}
end

-- A short duration such as "8s", "3m 05s" or "1h 20m".
function tab.duration_text(seconds)
  seconds = math.max(0, math.floor(seconds))
  if seconds < 60 then return seconds .. "s" end
  if seconds < 60 * 60 then return string.format("%dm %02ds", math.floor(seconds / 60), seconds % 60) end
  return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
end

-- The agent status of a Terminal Session record, or nil when no agent reports one. An agent such as Pi reports
-- its state (idle, working, blocked, done or error) with a message, and Anvil's Pi extension reports its step,
-- such as "Thinking" or "bash: npm test". Without an agent, show the shell command's status.
function tab.agent(record)
  local state, step = record.agent_state, record.agent_step
  if (type(state) ~= "string" or state == "") and (type(step) ~= "string" or step == "") then
    if not record.command_started or record.command_started <= 0 then return nil end
    local finished = record.command_finished and record.command_finished > 0 and record.command_finished or nil
    return { state = finished and (record.command_exit == 0 and "done" or "error") or "working",
      message = "", command = true, since = record.command_started, finished = finished }
  end
  return {state = state ~= "" and state or "working", kind = record.agent_kind, app = record.agent_app,
    message = record.agent_message or "",
    since = record.agent_since, step = step ~= "" and step or nil, step_since = record.agent_step_since}
end

-- The Terminal status dot's colour: dim when it does not run, warn after a bell or while an agent needs an answer,
-- error after an agent failed, accent while a command or an agent works.
function tab.status_color(item)
  local terminal, agent = item.terminal, item.agent
  if terminal.state ~= "running" and terminal.state ~= "reconnecting" then return tint(style.dim, 120) end
  if terminal.bell then return style.warn end
  if agent then
    if agent.state == "blocked" then return style.warn end
    if agent.state == "error" then return style.error end
    if agent.state == "working" or agent.step then return style.accent end
    return style.good
  end
  if terminal.busy == true then return style.accent end
  if terminal.busy == false then return style.good end
  return style.dim
end

-- The right-aligned note: a Terminal's age since its last activity. An agent's own line shows its times instead.
function tab.note(item, now)
  return item.terminal and not item.agent and tab.age_text(item.terminal.activity, now) or nil
end

-- The agent's line: its text, its time, and its tone: "warn", "error" or "result" for a result not seen yet.
-- A time under an hour counts seconds, so `ticking` tells the caller to draw again each second.
function tab.agent_line(agent, now, seen)
  if agent.command then
    local elapsed = math.max(0, (agent.finished or now) - agent.since)
    local text = agent.finished and (agent.state == "error" and "Failed" or "Done") or "Running"
    local tone = agent.state == "error" and "error" or (agent.finished and not seen and "result" or nil)
    return text, tab.duration_text(elapsed), tone, not agent.finished and elapsed < 60 * 60
  end
  local text, since, tone = nil, agent.since, nil
  if agent.step and agent.state ~= "blocked" then
    text, since = agent.step, agent.step_since
  elseif agent.state == "blocked" then
    text, tone = agent.message ~= "" and "Needs you: " .. agent.message or "Needs you", "warn"
  elseif agent.state == "error" then
    text, tone = agent.message ~= "" and "Error: " .. agent.message or "Error", "error"
  elseif agent.state == "done" then
    text, tone = "Done", not seen and "result" or nil
  elseif agent.state == "idle" then
    text = "Idle"
  else
    text = "Working"
  end
  if not since or since <= 0 then return text, nil, tone, false end
  if agent.state == "done" or agent.state == "error" or agent.state == "idle" then
    local age = tab.age_text(since, now)
    return text, age ~= "now" and age .. " ago" or age, tone, false
  end
  local elapsed = now - since
  return text, tab.duration_text(elapsed), tone, elapsed < 60 * 60
end

-- Shortens text with an ellipsis until it fits in `width`.
function tab.fit(font, text, width)
  if font:get_width(text) <= width + 0.5 then return text end
  if width <= 0 or font:get_width(ELLIPSIS) > width + 0.5 then return "" end
  local ends = {}
  for stop in text:gmatch("[%z\1-\127\194-\244][\128-\191]*()") do ends[#ends + 1] = stop - 1 end
  local low, high = 0, #ends
  while low < high do
    local middle = math.ceil((low + high) / 2)
    if font:get_width(text:sub(1, ends[middle]) .. ELLIPSIS) <= width + 0.5 then low = middle else high = middle - 1 end
  end
  return text:sub(1, ends[low] or 0) .. ELLIPSIS
end

local function gap() return math.max(4 * SCALE, style.padding.x / 2) end
local function number_gap() return math.max(3 * SCALE, style.padding.x / 3) end
local function dot_radius() return 3 * SCALE end

local function program_app(item)
  if not item.terminal or item.terminal.state ~= "running" then return nil end
  return item.agent and item.agent.app or item.terminal.app
end

-- Remove executable-path noise only for Terminal Tabs. Keep the original name for hover and persistence.
function tab.display_name(item)
  local title = item.name
  if not item.terminal then return title end
  local source = title:gsub("^&%s+", "")
  local executable, arguments
  local quote = source:sub(1, 1)
  if quote == '"' or quote == "'" then
    local ending = source:find(quote, 2, true)
    if not ending then return title end
    executable, arguments = source:sub(2, ending - 1), source:sub(ending + 1)
  elseif source:match("^%a:[/\\]") or source:match("^\\\\") then
    -- Windows can use an unquoted executable path, including spaces, as the entire window title.
    executable, arguments = source:match("^(.-%.[%a]+)(%s.*)$")
    if not executable then executable, arguments = source, "" end
  else
    executable, arguments = source:match("^(%S+)(.*)$")
  end
  if not executable then return title end
  local name = executable:match("([^/\\]+)$")
  if not name then return title end
  local stem, extension = name:match("^(.+)%.([^.]+)$")
  extension = extension and extension:lower()
  local is_executable = extension == "exe" or extension == "cmd" or extension == "bat"
  if is_executable then name = stem end
  local lower = name:lower()
  if lower == "pwsh" or lower == "powershell" then name = "PowerShell"
  elseif not is_executable and lower ~= "gradlew" then return title end
  return name .. arguments
end

-- The width the Tab's content needs at its full display name.
---@param opts {number_font: renderer.font?, name_font: renderer.font?, now: number?}?
function tab.width(item, row_height, opts)
  opts = opts or {}
  local width = 0
  if item.number then width = (opts.number_font or style.font):get_width(tostring(item.number)) + number_gap() end
  if item.terminal then
    width = width + dot_radius() * 2 + gap()
    local size = agent_icons.size(program_app(item), row_height)
    if size > 0 then width = width + size + gap() end
  elseif item.icon then
    width = width + view_icons.width(item.icon, row_height) + gap()
  end
  width = width + (opts.name_font or style.font):get_width(tab.display_name(item))
  local note = tab.note(item, opts.now or os.time())
  if note then width = width + gap() * 2 + style.font:get_width(note) end
  return width
end

-- Draws the Tab's content in the rectangle. `name_color` colours a name without a Git or missing-file colour.
-- Returns true when it drew a spinner frame, so the caller can draw the next one, and the name's left edge.
---@param opts {name_color: renderer.color, number_font: renderer.font?, name_font: renderer.font?, now: number?, clock: number?}
function tab.draw(item, x, y, w, h, opts)
  local number_font, name_font = opts.number_font or style.font, opts.name_font or style.font
  local right = x + w
  local function middle(font) return y + math.floor((h - font:get_height()) / 2) end
  if item.number then
    local text = tostring(item.number)
    renderer.draw_text(number_font, text, x, middle(number_font), style.titlebar_pane_number)
    x = x + number_font:get_width(text) + number_gap()
  end
  local color = opts.name_color
  if item.terminal then
    local radius = dot_radius()
    renderer.draw_rounded_rect(x, y + h / 2 - radius, radius * 2, radius * 2, radius, tab.status_color(item))
    x = x + radius * 2 + gap()
    local app = program_app(item)
    local size = agent_icons.size(app, h)
    if size > 0 then
      agent_icons.draw(app, x, y, h)
      x = x + size + gap()
    end
    if item.terminal.state ~= "running" and item.terminal.state ~= "reconnecting" then color = style.dim end
  elseif item.icon then
    view_icons.draw(item.icon, x, y, h, color)
    x = x + view_icons.width(item.icon, h) + gap()
  end
  color = item.missing and style.tab_file_missing or item.color or color
  local note = tab.note(item, opts.now or os.time())
  local note_w = note and style.font:get_width(note) + gap() * 2 or 0
  if note_w > (right - x) / 2 then note, note_w = nil, 0 end
  local name, spinning = tab.display_name(item), false
  local spun = item.terminal and item.terminal.state == "running" and tab.spinner_title(name, opts.clock or 0)
  if spun then name, spinning = spun, true end
  name = tab.fit(name_font, name, math.max(0, right - x - note_w))
  local name_y = middle(name_font)
  renderer.draw_text(name_font, name, x, name_y, color)
  if item.missing and name ~= "" then
    renderer.draw_rect(x, name_y + math.floor(name_font:get_height() / 2), name_font:get_width(name),
      math.max(1, SCALE), color)
  end
  if note then renderer.draw_text(style.font, note, right - style.font:get_width(note), middle(style.font), style.dim) end
  return spinning, x
end

-- Draws the agent's line at the left edge of the Tab's name. Returns true when the time counts seconds.
---@param opts {now: number, seen: boolean?}
function tab.draw_agent(agent, x, y, w, h, opts)
  local text, time, tone, ticking = tab.agent_line(agent, opts.now, opts.seen)
  local font, right = style.font, x + w
  local ty = y + math.floor((h - font:get_height()) / 2)
  local time_w = time and font:get_width(time) + gap() * 2 or 0
  if time_w > w / 2 then time, time_w = nil, 0 end
  local color = tone == "warn" and style.warn or tone == "error" and style.error or tone == "result" and style.accent
    or style.dim
  renderer.draw_text(font, tab.fit(font, text, math.max(0, w - time_w)), x, ty, color)
  if time then renderer.draw_text(font, time, right - font:get_width(time), ty, style.dim) end
  return ticking and time ~= nil
end

return tab
