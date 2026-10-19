-- mod-version:3
-- Quick Commands: key slots that enter one shell command into one Terminal Session.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local panes = require "core.panes"
local poi = require "core.poi"
local storage = require "core.storage"
local text_capture = require "core.text_capture"
local text_poi_locations = require "core.text_poi_locations"
local terminal = require "plugins.terminal"

local M = {}

local SLOTS = {
  { key = "a", label = "A" },
  { key = "s", label = "S" },
  { key = "d", label = "D" },
  { key = "f", label = "F" },
}
local STORAGE_MODULE = "quick-commands"
local READY_TIMEOUT = 5

local function project_key()
  local project = core.root_project and core.root_project()
  return project and project.path or system.getcwd()
end

local function trim(text)
  return tostring(text or ""):gsub("[\r\n]+", " "):match("^%s*(.-)%s*$")
end

function M.get(index)
  local slots = storage.load(STORAGE_MODULE, project_key())
  local slot = type(slots) == "table" and slots[index]
  if type(slot) ~= "table" or type(slot.session_id) ~= "string" or trim(slot.command) == "" then return nil end
  return slot
end

local function save(index, slot)
  local key = project_key()
  local slots = storage.load(STORAGE_MODULE, key)
  if type(slots) ~= "table" then slots = {} end
  slots[index] = slot or false
  storage.save(STORAGE_MODULE, key, slots)
end

-- The output of a Terminal's latest Quick Command, as a remote Point of Interest source.
-- It rereads the terminal text when navigation asks for its points, so it follows output that is still arriving.
local Output = text_capture.View:extend()

function Output:__tostring() return "QuickCommandOutput" end

function Output:new(view)
  Output.super.new(self, {
    text = "", title = "Quick Command Output", display_name = "Quick Command Output",
    remote_poi_source = true, points = {}, wrapping = false,
  })
  self.terminal = view
end

-- Line 1 holds the latest line that shows the command. Its output follows.
local function latest_run_text(text, command_text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
  for i = #lines, 1, -1 do
    if lines[i]:find(command_text, 1, true) then return table.concat(lines, "\n", i) end
  end
  return command_text .. "\n" .. text
end

function Output:refresh()
  local session = self.terminal.session
  local capture = session and session:text_capture()
  if not capture or type(capture.text) ~= "string" then return end
  local text = latest_run_text(capture.text, self.command_text)
  if text == self.captured_text then return end
  self.captured_text = text
  local buffer = self.buffer
  buffer:remove(1, 1, #buffer.lines, #buffer.lines[#buffer.lines])
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  buffer:clean()
  buffer:set_selection(1, 1)
  local points = {}
  for _, point in ipairs(text_poi_locations.extract(text, { root = self.terminal:get_cwd(), kind = "terminal-location" })) do
    if point.line > 1 then points[#points + 1] = point end
  end
  self.text_capture_data.points = points
  core.log_quiet("Quick Command output refreshed: lines=%d locations=%d", #buffer.lines, #points)
end

function Output:get_points_of_interest()
  self:refresh()
  return self.text_capture_data.points
end

local outputs = setmetatable({}, { __mode = "k" })

local function select_output(view, command_text)
  local output = outputs[view]
  if not output then
    output = Output(view)
    outputs[view] = output
  end
  output.command_text = command_text
  output.captured_text = nil
  -- Show Remote POI Source then presents the terminal.
  panes.register_focus_target(view, output)
  poi.set_remote_source(output)
end

local function open_view(session_id)
  for _, view in ipairs(terminal.open_views()) do
    if view.session_id == session_id then return view end
  end
end

local function enter_command(view, def, slot)
  if view.busy ~= false then
    core.warn("Quick Command %s did not run: its terminal is busy", def.label)
    core.log_quiet("Quick Command %s skipped: state=%s busy=%s", def.label, tostring(view.state), tostring(view.busy))
    return false
  end
  view.session:scroll("bottom")
  if not view.session:write(slot.command .. "\r") then
    core.warn("Quick Command %s did not run: its terminal rejected the input", def.label)
    return false
  end
  select_output(view, slot.command)
  core.log_quiet("Quick Command %s entered: session=%s length=%d", def.label, slot.session_id, #slot.command)
  return true
end

local function ready(view)
  return view.session ~= nil and view.state == "running" and view.busy ~= nil
end

function M.run(index)
  local def = SLOTS[index]
  local slot = M.get(index)
  if not slot then
    core.warn("Quick Command %s is not set. Set it from a terminal.", def.label)
    return false
  end
  local view = open_view(slot.session_id)
  if view then
    terminal.focus_session(slot.session_id)
  elseif terminal.session_available(slot.session_id) then
    view = terminal.open { session_id = slot.session_id, focus = true, placement = "current", reason = "quick-command" }
  end
  if not view then
    core.warn("Quick Command %s did not run: its terminal was closed. Set it again from a terminal.", def.label)
    core.log_quiet("Quick Command %s session is gone: %s", def.label, slot.session_id)
    return false
  end
  if ready(view) then return enter_command(view, def, slot) end
  core.log_quiet("Quick Command %s waits for its terminal: state=%s", def.label, tostring(view.state))
  core.add_thread(function()
    local deadline = system.get_time() + READY_TIMEOUT
    while not ready(view) and view.state ~= "failed" and view.state ~= "closed" and system.get_time() < deadline do
      coroutine.yield(0.05)
    end
    if ready(view) then return enter_command(view, def, slot) end
    core.warn("Quick Command %s did not run: its terminal is not ready", def.label)
  end)
  return true
end

function M.prompt(index, view)
  local def = SLOTS[index]
  if not view.session_id then
    core.warn("This terminal is still starting. Set Quick Command %s again in a moment.", def.label)
    return false
  end
  local slot = M.get(index)
  core.global_prompt_bar:enter("Quick Command " .. def.label, {
    text = slot and slot.command or "",
    select_text = slot ~= nil,
    show_suggestions = false,
    submit = function(text)
      text = trim(text)
      if text == "" then
        save(index, nil)
        core.log_quiet("Quick Command %s cleared", def.label)
        return
      end
      save(index, { session_id = view.session_id, command = text })
      core.log_quiet("Quick Command %s set: session=%s length=%d", def.label, view.session_id, #text)
    end,
  })
  return true
end

local run_commands, set_commands, bindings = {}, {}, {}
for index, def in ipairs(SLOTS) do
  run_commands["quick_command:run_" .. def.key] = command.palette(function() return M.run(index) end, {
    keywords = { "terminal", "run", "shell" },
    opens_view = true,
  })
  set_commands["quick_command:set_" .. def.key] = command.palette(function(view) return M.prompt(index, view) end, {
    keywords = { "terminal", "shell" },
  })
  bindings["alt+" .. def.key] = "quick_command:run_" .. def.key
end

command.add(nil, run_commands)
command.add(function()
  local view = core.active_view
  return view and view.terminal_view == true, view
end, set_commands)
keymap.add_direct(bindings)

return M
