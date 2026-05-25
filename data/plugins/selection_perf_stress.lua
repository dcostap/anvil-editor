-- mod-version:3 priority:98
-- Env-gated automated stress scenario for selection rendering performance.
-- Does nothing unless ANVIL_SELECTION_STRESS_TEST is truthy.
local core = require "core"
local config = require "core.config"
local DocView = require "core.docview"

local function truthy(name)
  local value = os.getenv(name)
  if not value or value == "" then return false end
  value = value:lower():match("^%s*(.-)%s*$")
  return value ~= "0" and value ~= "false" and value ~= "no" and value ~= "off"
end

if not truthy("ANVIL_SELECTION_STRESS_TEST") then return {} end

local function env_number(name, default)
  local value = tonumber(os.getenv(name) or "")
  return value or default
end

local stress = {
  cursor_count = env_number("ANVIL_SELECTION_STRESS_CURSORS", 1000),
  drag_lines = env_number("ANVIL_SELECTION_STRESS_DRAG_LINES", 8),
  duration = env_number("ANVIL_SELECTION_STRESS_SECONDS", 10),
  huge_lines = env_number("ANVIL_SELECTION_STRESS_HUGE_LINES", 8000),
  huge_seconds = env_number("ANVIL_SELECTION_STRESS_HUGE_SECONDS", 2),
  scroll_lines_per_frame = env_number("ANVIL_SELECTION_STRESS_SCROLL_LINES", 1),
  start_line = env_number("ANVIL_SELECTION_STRESS_START_LINE", 1),
}

local function active_docview()
  local view = core.active_view
  if view and view:is(DocView) and view.doc and #view.doc.lines > 1 then
    return view
  end
end

local function set_huge_selection(dv)
  local doc = dv.doc
  local last = math.min(#doc.lines, stress.start_line + stress.huge_lines)
  doc.selections = { stress.start_line, 1, last, math.huge }
  doc.last_selection = 1
end

local function set_multiline_cursors(dv, base_line, phase)
  local doc = dv.doc
  local nlines = #doc.lines
  local max_count = math.max(1, math.min(stress.cursor_count, nlines - stress.drag_lines - 1))
  local selections = {}
  local drag = math.max(1, math.floor((phase % 1) * stress.drag_lines) + 1)
  local col1 = 1
  local col2 = math.huge

  for i = 0, max_count - 1 do
    local line1 = ((base_line + i - 1) % (nlines - drag - 1)) + 1
    local line2 = math.min(nlines, line1 + drag)
    local p = i * 4 + 1
    selections[p] = line1
    selections[p + 1] = col1
    selections[p + 2] = line2
    selections[p + 3] = col2
  end
  doc.selections = selections
  doc.last_selection = 1
end

core.add_thread(function()
  local dv
  repeat
    dv = active_docview()
    coroutine.yield(0.05)
  until dv

  core.log("Selection stress test: huge selection %d lines for %.1fs; %d multiline selections for %.1fs",
    stress.huge_lines, stress.huge_seconds, stress.cursor_count, stress.duration)

  dv:scroll_to_line(stress.start_line, true)
  set_huge_selection(dv)
  core.redraw = true
  local huge_end = system.get_time() + stress.huge_seconds
  while system.get_time() < huge_end do
    core.redraw = true
    coroutine.yield(1 / (config.fps or 60))
  end

  local start = system.get_time()
  local base_line = stress.start_line
  while system.get_time() - start < stress.duration do
    local elapsed = system.get_time() - start
    set_multiline_cursors(dv, base_line, elapsed * 4)
    dv:scroll_to_line(base_line, true)
    base_line = base_line + stress.scroll_lines_per_frame
    if base_line > math.max(1, #dv.doc.lines - stress.cursor_count - stress.drag_lines - 1) then
      base_line = 1
    end
    core.redraw = true
    coroutine.yield(1 / (config.fps or 60))
  end

  core.log("Selection stress test finished")
end)

return stress
