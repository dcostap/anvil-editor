local core = require "core"
local config = require "core.config"
local panes = require "core.panes"
local style = require "core.style"

local M = {}

local candidates = setmetatable({}, { __mode = "k" })
local next_samples = setmetatable({}, { __mode = "k" })
local feedback_started_at

local function options()
  local configured = config.plugins.navigation_history
  if configured == false then return { enabled = false } end
  return configured or { enabled = false }
end

local function position(selection_state)
  local selections = selection_state and selection_state.selections
  if type(selections) ~= "table" or #selections < 2 then return nil end
  local selected = math.max(1, math.floor(tonumber(selection_state.last_selection) or 1))
  local offset = (selected - 1) * 4 + 1
  return {
    line = tonumber(selections[offset]) or tonumber(selections[1]) or 1,
    col = tonumber(selections[offset + 1]) or tonumber(selections[2]) or 1,
  }
end

local function navigation_state(view, selection_state)
  return {
    selection_state = selection_state or view:get_selection_state(),
    scroll = { x = view.scroll.x, y = view.scroll.y },
  }
end

local function is_far(a, b, opts)
  return math.abs(a.line - b.line) >= opts.far_lines
    or a.line == b.line and math.abs(a.col - b.col) >= opts.far_columns
end

local function is_near(a, b, opts)
  return math.abs(a.line - b.line) <= opts.near_lines
    and (a.line ~= b.line or math.abs(a.col - b.col) <= opts.near_columns)
end

local function current_recorded_position(pane)
  local entry = pane and pane.history and pane.history.entries[pane.history.index]
  return entry and position(entry.state and entry.state.selection_state)
end

local function record(view, state, opts)
  local pane = panes.pane_for_view(view)
  if not pane or pane.current_view ~= view then return false end
  local inserted = panes.record_location(pane, {
    view = view,
    state = state,
    nearby_lines = opts.near_lines,
    nearby_columns = opts.near_columns,
  })
  if inserted then M.navigation_place_inserted() end
  return inserted
end

function M.perform_jump(view, action, ...)
  local opts = options()
  local origin = navigation_state(view)
  local result = table.pack(action(view, ...))
  if not opts.enabled then return table.unpack(result, 1, result.n) end
  local destination = navigation_state(view)
  local old_position = position(origin.selection_state)
  local new_position = position(destination.selection_state)
  if not old_position or not new_position or not is_far(old_position, new_position, opts) then
    return table.unpack(result, 1, result.n)
  end

  candidates[view] = nil
  record(view, origin, opts)
  local inserted = record(view, destination, opts)
  core.log_quiet(
    "Navigation History: large Editor jump from %d:%d to %d:%d inserted=%s",
    old_position.line, old_position.col, new_position.line, new_position.col,
    tostring(inserted)
  )
  return table.unpack(result, 1, result.n)
end

function M.sample(view, now)
  local opts = options()
  if not opts.enabled then candidates[view] = nil; return false end
  local pane = panes.pane_for_view(view)
  if not pane or pane.current_view ~= view then candidates[view] = nil; return false end

  now = now or system.get_time()
  local state = navigation_state(view)
  local caret = position(state.selection_state)
  local recorded = current_recorded_position(pane)
  if not caret or not recorded or not is_far(caret, recorded, opts) then
    candidates[view] = nil
    return false
  end

  local candidate = candidates[view]
  if not candidate or not is_near(caret, candidate.anchor, opts) then
    candidates[view] = { anchor = caret, started_at = now }
    return false
  end
  if now - candidate.started_at < opts.dwell_time then return false end

  candidates[view] = nil
  local inserted = record(view, state, opts)
  core.log_quiet(
    "Navigation History: Editor dwell at %d:%d seconds=%.1f inserted=%s",
    caret.line, caret.col, now - candidate.started_at, tostring(inserted)
  )
  return inserted
end

function M.update(view, now, force)
  local opts = options()
  now = now or system.get_time()
  if not opts.enabled then candidates[view], next_samples[view] = nil, nil; return false end
  if not force then
    local pane = panes.pane_for_view(view)
    local focused_pane = panes.pane_for_view(core.active_view)
    if pane ~= panes.active() or focused_pane ~= pane then
      candidates[view] = nil
      return false
    end
  end
  if now < (next_samples[view] or 0) then return false end
  next_samples[view] = now + math.max(0.1, tonumber(opts.sample_interval))
  return M.sample(view, now)
end

function M.navigation_place_inserted()
  local opts = options()
  if not opts.feedback then return end
  feedback_started_at = system.get_time()
  core.redraw = true
end

function M.draw_feedback(panel, now)
  if not feedback_started_at then return false end
  local opts = options()
  local duration = math.max(0.01, tonumber(opts.feedback_duration))
  local elapsed = (now or system.get_time()) - feedback_started_at
  if elapsed >= duration then feedback_started_at = nil; return false end
  local source = style.navigation_history_feedback
  if type(source) ~= "table" then return false end
  local color = { table.unpack(source) }
  color[4] = math.floor((color[4] or 255) * (1 - elapsed / duration))
  renderer.draw_rect(panel.position.x, panel.position.y, panel.size.x, panel.size.y, color)
  core.redraw = true
  return true
end

function M.reset()
  candidates = setmetatable({}, { __mode = "k" })
  next_samples = setmetatable({}, { __mode = "k" })
  feedback_started_at = nil
end

core.navigation_history = M
return M
