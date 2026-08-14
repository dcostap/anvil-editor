-- mod-version:3 priority:99
-- Env-gated automated edit/cursor perf scenario.
-- Does nothing unless ANVIL_EDIT_PERF_TEST is truthy.
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local Editor = require "core.editor"
local perf = require "core.perf"

local function truthy(name)
  local value = os.getenv(name)
  if not value or value == "" then return false end
  value = value:lower():match("^%s*(.-)%s*$")
  return value ~= "0" and value ~= "false" and value ~= "no" and value ~= "off"
end

if not truthy("ANVIL_EDIT_PERF_TEST") then return {} end

local function env_number(name, default)
  local value = tonumber(os.getenv(name) or "")
  return value or default
end

local stress = {
  duration = env_number("ANVIL_EDIT_PERF_SECONDS", 15),
  warmup = env_number("ANVIL_EDIT_PERF_WARMUP", 1),
  operations_per_second = env_number("ANVIL_EDIT_PERF_OPS", 30),
  start_line = env_number("ANVIL_EDIT_PERF_START_LINE", 1),
  quit = truthy("ANVIL_EDIT_PERF_QUIT"),
  result_file = os.getenv("ANVIL_EDIT_PERF_RESULT_FILE") or "",
  file = os.getenv("ANVIL_EDIT_PERF_FILE") or "",
}

local snippets = {
  "x", "y", "z", "_", "1", "2", "3", " ",
  "test", " edit", " sample", "\n", " cursor", " perf",
}

local function active_textview()
  local view = core.active_view
  if view and view:extends(Editor) and view.buffer and #view.buffer.lines > 0 then
    if stress.file == "" or common.path_equals(view.buffer.abs_filename, stress.file) then
      return view
    end
  end
end

local function activate_view(view)
  if not view then return nil end
  local panes = require "core.panes"
  local pane = panes.pane_for_view(view)
  if pane then panes.present(view, { pane = pane, focus = true }) else core.set_active_view(view) end
  return view
end

local function open_target_file()
  if stress.file == "" then return nil end
  local buffer = core.open_buffer(stress.file)
  if not buffer then return nil end
  local Editor = require "core.editor"
  return activate_view(require("core.panes").place(function() return Editor(buffer) end, {
    placement = "current", focus = true,
  }))
end

local function clamp_line(buffer, line)
  return math.max(1, math.min(#buffer.lines, line))
end

local function line_len(buffer, line)
  return #(buffer.lines[line] or "") + 1
end

local function set_cursor(buffer, line, col)
  line = clamp_line(buffer, line)
  col = math.max(1, math.min(line_len(buffer, line), col))
  buffer:set_selections(1, line, col)
  return line, col
end

local function write_result(path)
  if stress.result_file ~= "" then
    local fp = io.open(stress.result_file, "wb")
    if fp then
      fp:write(path or "")
      fp:close()
    end
  end
end

local function run_operation(dv, step)
  activate_view(dv)
  local buffer = dv.buffer
  local nlines = math.max(1, #buffer.lines)
  local line = ((stress.start_line + step * 7 - 2) % nlines) + 1
  local col = ((step * 11) % math.max(1, line_len(buffer, line))) + 1
  line, col = set_cursor(buffer, line, col)

  local mode = step % 12
  if mode == 0 then
    buffer:text_input(snippets[(step % #snippets) + 1])
  elseif mode == 1 then
    buffer:move_to(1)
  elseif mode == 2 then
    buffer:move_to(-1)
  elseif mode == 3 then
    buffer:select_to(6)
  elseif mode == 4 then
    buffer:delete_to(-1)
  elseif mode == 5 then
    local line2 = clamp_line(buffer, line + 1)
    buffer:set_selections(1, line, 1, line2, math.min(8, line_len(buffer, line2)))
  elseif mode == 6 then
    buffer:text_input("a")
  elseif mode == 7 then
    buffer:move_to(0, 1)
  elseif mode == 8 then
    buffer:move_to(0, -1)
  elseif mode == 9 then
    dv:scroll_to_line(line, true)
  elseif mode == 10 then
    buffer:text_input("bc")
  else
    buffer:set_selections(1, line, math.max(1, col - 3), line, math.min(line_len(buffer, line), col + 3))
  end
  core.redraw = true
end

core.add_thread(function()
  coroutine.yield()
  local dv = open_target_file()

  repeat
    dv = active_textview() or open_target_file()
    coroutine.yield(0.05)
  until dv

  activate_view(dv)

  core.log("Edit perf stress: warmup %.1fs, recording %.1fs, %.1f ops/s", stress.warmup, stress.duration, stress.operations_per_second)
  dv:scroll_to_line(stress.start_line, true)
  core.redraw = true

  local warmup_end = system.get_time() + stress.warmup
  while system.get_time() < warmup_end do coroutine.yield(0.05) end

  perf.start_recording()
  local start = system.get_time()
  local next_op = start
  local step = 0
  local op_interval = 1 / math.max(1, stress.operations_per_second)
  while system.get_time() - start < stress.duration do
    local now = system.get_time()
    if now >= next_op then
      step = step + 1
      core.try(run_operation, dv, step)
      next_op = next_op + op_interval
    end
    coroutine.yield(1 / (config.fps or 60))
  end

  local summary = perf.stop_recording()
  write_result(summary)
  core.log("Edit perf stress finished: %s", summary or "")
  if stress.quit then os.exit() end
end)

return stress
