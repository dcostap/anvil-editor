-- Opt-in, private Markdown Live Preview history. Never write Buffer text to session logs.
local core = require "core"
local common = require "core.common"
local json = require "core.json"

local capture = {}
local active = setmetatable({}, { __mode = "k" })
local last_path
local serial = 0
local MAX_SNAPSHOT_BYTES = 512 * 1024
local MAX_HISTORY_BYTES = 8 * 1024 * 1024
local MAX_EVENTS = 256

local function snapshot(view)
  local buffer = view.buffer
  local text = table.concat(buffer.lines)
  if #text > MAX_SNAPSHOT_BYTES then return nil end
  local selection = view:get_selection_state()
  local model = require("core.markdown.model").peek(buffer)
  local owner = view.__markdown_live_owner
  local pending = {}
  for line in pairs(owner and owner.pending_lines or {}) do pending[#pending + 1] = line end
  table.sort(pending)
  return {
    text = text,
    revision = buffer.text_revision,
    selections = selection.selections,
    last_selection = selection.last_selection,
    scroll = { x = view.scroll.x, y = view.scroll.y,
      target_x = view.scroll.to.x, target_y = view.scroll.to.y },
    size = { x = view.size.x, y = view.size.y },
    position = { x = view.position.x, y = view.position.y },
    live = require("core.markdown.live_render").is_live_mode(view),
    wrapping = view.wrapped_settings and true or false,
    model = model and { status = model.status,
      published_revision = model.published_revision, generation = model.generation },
    pending_lines = pending,
    pending_from = owner and owner.semantic_pending_line,
  }
end

local function add(view, event)
  local state = active[view]
  if not state then return end
  event.time = system.get_time() - state.started
  local bytes = #json.encode(event)
  state.events[#state.events + 1] = event
  state.bytes = state.bytes + bytes
  while #state.events > MAX_EVENTS or state.bytes > MAX_HISTORY_BYTES do
    local removed = table.remove(state.events, 1)
    state.bytes = state.bytes - #json.encode(removed)
    state.truncated = true
  end
end

function capture.start(view)
  local before = snapshot(view)
  if not before then return nil, "Buffer exceeds the 512 KiB capture limit" end
  if not capture.installed then
    require("core.buffer").register_text_transaction_handler("markdown-diagnostic-capture", capture.edit)
    capture.installed = true
  end
  active[view] = { started = system.get_time(), events = {}, bytes = 0,
    name = view.buffer:get_name(), path = view.buffer.abs_filename, truncated = false }
  add(view, { kind = "start", before = before })
  return true
end

function capture.stop(view)
  active[view] = nil
end

function capture.is_active(view)
  return active[view] ~= nil
end

function capture.input(view, kind, ...)
  if not active[view] then return end
  local before = snapshot(view)
  if not before then capture.stop(view); core.warn("Markdown diagnostic stopped: Buffer is too large"); return end
  local a, b, c, d = ...
  local event = { kind = "input", type = kind, before = before }
  if kind == "textinput" then event.text = a
  elseif kind == "keypressed" or kind == "keyreleased" then
    event.key = a
    event.modifiers = b and { ctrl = b.ctrl, shift = b.shift, alt = b.alt, gui = b.gui, altgr = b.altgr }
  elseif kind == "mousewheel" or kind == "mousemoved" then
    event.x, event.y, event.dx, event.dy = a, b, c, d
  else event.button, event.x, event.y, event.clicks = a, b, c, d end
  add(view, event)
end

function capture.command(view, name)
  if not active[view] then return end
  local before = snapshot(view)
  if before then add(view, { kind = "command", name = name, before = before }) end
end

function capture.edit(buffer, transaction)
  for view in pairs(active) do
    if view.buffer == buffer then
      local after = snapshot(view)
      if not after then capture.stop(view); core.warn("Markdown diagnostic stopped: Buffer is too large"); return end
      local edits = {}
      for _, edit in ipairs(transaction.edits or {}) do
        edits[#edits + 1] = { line1 = edit.line1, col1 = edit.col1,
          line2 = edit.line2, col2 = edit.col2, text = edit.text }
      end
      add(view, { kind = "edit", type = transaction.type, edits = edits, after = after })
    end
  end
end

function capture.phase(buffer, kind, fields)
  for view in pairs(active) do
    if view.buffer == buffer then
      add(view, { kind = kind, revision = buffer.text_revision, fields = fields })
    end
  end
end

local function visible_rows(view)
  local rows = {}
  local first, last = view:get_visible_line_range()
  for line = math.max(1, first or 1), math.min(#view.buffer.lines, last or 0) do
    local ok, row = pcall(function()
      local _, y = view:get_line_screen_position(line, 1)
      local render = view:get_line_render(line)
      local fragments = {}
      for _, fragment in ipairs(render and render.fragments or {}) do
        fragments[#fragments + 1] = { text = fragment.text, hidden = fragment.hidden,
          col1 = fragment.col1, col2 = fragment.col2 }
      end
      return { line = line, y = y, height = view:get_position_visual_row_height(line, 1),
        fragments = fragments }
    end)
    rows[#rows + 1] = ok and row or { line = line, error = tostring(row) }
  end
  return rows
end

function capture.save(view)
  local state = active[view]
  if not state then return nil, "capture is not on for this Editor" end
  local current = snapshot(view)
  if not current then return nil, "Buffer exceeds the 512 KiB capture limit" end
  -- An event with a snapshot is the first point from which retained history can replay.
  local first = 1
  while first <= #state.events and not (state.events[first].before or state.events[first].after) do
    first = first + 1
  end
  local events = {}
  for i = first, #state.events do events[#events + 1] = state.events[i] end
  local rows_ok, rows = pcall(visible_rows, view)
  local encoded_ok, body = pcall(json.encode, { version = 1, name = state.name,
    path = state.path, truncated = state.truncated, events = events,
    current = current, visible_rows = rows_ok and rows or nil,
    visible_rows_error = not rows_ok and tostring(rows) or nil }, true)
  if not encoded_ok then return nil, tostring(body) end
  local root = USERDIR .. PATHSEP .. "markdown-diagnostics"
  local made, err = common.mkdirp(root)
  if not made then return nil, err end
  serial = serial + 1
  local path = string.format("%s%smarkdown-%s-p%s-%d.json", root, PATHSEP,
    os.date("%Y%m%d-%H%M%S"), tostring(system.get_process_id()), serial)
  local file, open_err = io.open(path, "wb")
  if not file then return nil, open_err end
  local ok, write_err = file:write(body)
  local closed = file:close()
  if not ok or not closed then os.remove(path); return nil, write_err or "cannot close capture" end
  last_path = path
  return path
end

function capture.last_saved_path()
  return last_path
end

return capture
