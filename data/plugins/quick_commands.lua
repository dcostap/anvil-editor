-- mod-version:3
-- Quick Commands: key slots that enter one shell command into one Terminal Session.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local panes = require "core.panes"
local poi = require "core.poi"
local storage = require "core.storage"
local text_capture = require "core.text_capture"
local worker_pool = require "core.worker_pool"
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
-- Navigation captures current output, then a worker parses and resolves it.
local Output = text_capture.View:extend()

function Output:__tostring() return "QuickCommandOutput" end

function Output:new(view)
  Output.super.new(self, {
    text = "", title = "Quick Command Output", display_name = "Quick Command Output",
    remote_poi_source = true, points = {}, wrapping = false,
  })
  self.terminal = view
end

-- The Terminal draws this source. Keep its text position for navigation,
-- but do not lay out a hidden capture just to scroll it horizontally.
function Output:scroll_to_make_visible() end

function Output:cancel_scan()
  local request = self.request
  self.request = nil
  if request and request.handle then request.pool:cancel(request.handle) end
end

function Output:prepare_points_of_interest(on_ready)
  local session = self.terminal.session
  local capture = session and session:text_capture()
  if not capture or type(capture.text) ~= "string" then on_ready(false) return end
  local root = self.terminal:get_cwd()
  if capture.text == self.captured_text and root == self.captured_root then
    on_ready(true)
    return
  end
  local request = self.request
  if request and request.text == capture.text and request.root == root then
    request.on_ready = on_ready
    return
  end
  self:cancel_scan()
  request = { text = capture.text, root = root, on_ready = on_ready, pool = worker_pool.system() }
  self.request = request
  local function current()
    return self.request == request and self.terminal.session == session and not self.textview_closed
  end
  local function failed(reason)
    if self.request ~= request then return end
    self.request = nil
    core.warn("Could not read Quick Command output: %s", tostring(reason))
    request.on_ready(false)
  end
  local handle, err = request.pool:submit {
    kind = "core.workers.command_output",
    priority = "interactive",
    payload = { text = capture.text, command = self.command_text, root = root },
    is_stale = function() return not current() end,
    on_result = function(message) request.result = message.payload end,
    on_complete = function()
      local result = request.result
      if not result then failed("worker returned no output") return end
      self.request = nil
      local buffer = self.buffer
      local last, col = #buffer.lines, #buffer.lines[#buffer.lines]
      if buffer:get_text(1, 1, last, col) ~= result.text then
        buffer:remove(1, 1, last, col)
        buffer:insert(1, 1, result.text)
        buffer:clear_undo_redo()
        buffer:clean()
        buffer:set_selection(1, 1)
      end
      self.text_capture_data.points = result.points
      self.captured_text, self.captured_root = request.text, root
      core.log_quiet("Quick Command output ready: lines=%d locations=%d", #buffer.lines, #result.points)
      request.on_ready(true)
    end,
    on_error = function(message) failed(message.error) end,
    on_stale = function() if self.request == request then self.request = nil end end,
    on_cancelled = function() if self.request == request then self.request = nil end end,
  }
  request.handle = handle
  if not handle then failed(err) end
end

function Output:on_close()
  self:cancel_scan()
  Output.super.on_close(self)
end

local outputs = setmetatable({}, { __mode = "k" })

local function select_output(view, command_text)
  local output = outputs[view]
  if not output then
    output = Output(view)
    outputs[view] = output
  end
  output:cancel_scan()
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
  if not view:write_input(slot.command .. "\r") then
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

local function save_modified_buffers(def)
  for _, buffer in ipairs(core.buffers) do
    if buffer.filename and buffer:is_dirty() then
      -- Use normal save hooks, including the disk conflict guard. A synchronous
      -- save also cancels an older background save and writes the current text.
      local ok, err = pcall(buffer.save, buffer)
      if not ok or buffer:is_dirty() then
        core.warn("Quick Command %s cancelled: could not save %s", def.label, buffer.filename)
        core.log_quiet("Quick Command %s save failed: file=%s error=%s",
          def.label, buffer.filename, tostring(err or "Buffer still has unsaved edits"))
        return false
      end
    end
  end
  return true
end

function M.run(index, opts)
  local focus = not opts or opts.focus ~= false
  local def = SLOTS[index]
  local slot = M.get(index)
  if not slot then
    core.warn("Quick Command %s is not set. Set it from a terminal.", def.label)
    return false
  end
  local view = open_view(slot.session_id)
  if not view and terminal.session_available(slot.session_id) then
    if not save_modified_buffers(def) then return false end
    -- Keep the current View until the session is ready and all saves succeed.
    view = terminal.open {
      session_id = slot.session_id, focus = false,
      placement = "new", preserve_focus = true,
      reason = "quick-command",
    }
  end
  if not view then
    core.warn("Quick Command %s did not run: its terminal was closed. Set it again from a terminal.", def.label)
    core.log_quiet("Quick Command %s session is gone: %s", def.label, slot.session_id)
    return false
  end
  core.log_quiet("Quick Command %s target: session=%s focus=%s", def.label, slot.session_id, tostring(focus))
  local function run_ready()
    -- Edits can arrive while the terminal reconnects. Save again before input.
    if not save_modified_buffers(def) then return false end
    if focus then terminal.focus_session(slot.session_id) end
    return enter_command(view, def, slot)
  end
  if ready(view) then return run_ready() end
  core.log_quiet("Quick Command %s waits for its terminal: state=%s", def.label, tostring(view.state))
  core.add_thread(function()
    local deadline = system.get_time() + READY_TIMEOUT
    while not ready(view) and view.state ~= "failed" and view.state ~= "closed" and system.get_time() < deadline do
      coroutine.yield(0.05)
    end
    if ready(view) then return run_ready() end
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
  run_commands["quick_command:run_" .. def.key .. "_without_moving_focus"] = command.palette(function()
    return M.run(index, { focus = false })
  end, {
    keywords = { "terminal", "run", "shell" },
  })
  set_commands["quick_command:set_" .. def.key] = command.palette(function(view) return M.prompt(index, view) end, {
    keywords = { "terminal", "shell" },
  })
  bindings["alt+" .. def.key] = "quick_command:run_" .. def.key
  bindings["alt+shift+" .. def.key] = "quick_command:run_" .. def.key .. "_without_moving_focus"
end

command.add(nil, run_commands)
command.add(function()
  local view = core.active_view
  return view and view.terminal_view == true, view
end, set_commands)
keymap.add_direct(bindings)

return M
