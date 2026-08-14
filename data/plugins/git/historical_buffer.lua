-- mod-version:3
-- Read-only Buffers backed by Git revision contents.

local core = require "core"
local Buffer = require "core.buffer"
local TextView = require "core.textview"

local HistoricalTextView = TextView:extend()

function HistoricalTextView:get_state()
  return nil
end

local historical = {
  View = HistoricalTextView,
}

local function short_rev(rev)
  return tostring(rev or ""):sub(1, 8)
end

function historical.key(repo, rev, relpath)
  local root = type(repo) == "table" and repo.root or tostring(repo or "")
  return table.concat({ root, tostring(rev or ""), tostring(relpath or "") }, "\0")
end

local function reject_edit(buffer)
  core.log_quiet("Historical Buffer is read-only: %s", buffer.git_historical_title or buffer:get_name())
  return false
end

local function set_buffer_text(buffer, text)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines, start = {}, 1
  while start <= #text do
    local nl = text:find("\n", start, true)
    if nl then
      lines[#lines + 1] = text:sub(start, nl)
      start = nl + 1
    else
      lines[#lines + 1] = text:sub(start) .. "\n"
      break
    end
  end
  if #lines == 0 then lines[1] = "\n" end
  buffer.lines = lines
  buffer:set_selection(1, 1, 1, 1)
end

local function make_read_only(buffer)
  buffer.git_historical_read_only = true
  buffer.apply_edits = reject_edit
  buffer.text_input = reject_edit
  buffer.ime_text_editing = reject_edit
  buffer.insert = reject_edit
  buffer.remove = reject_edit
  buffer.replace = reject_edit
  buffer.replace_cursor = reject_edit
  buffer.save = function(self)
    error("Historical Buffer is read-only")
  end
  buffer.set_filename = function(self)
    error("Historical Buffer is read-only")
  end
  buffer.is_dirty = function() return false end
  buffer.get_name = function(self) return self.git_historical_title or "Historical Buffer" end
end

function historical.find(key)
  for _, buffer in ipairs(core.buffers or {}) do
    if buffer.git_historical_key == key then return buffer end
  end
end

function historical.create_buffer(repo, rev, relpath, text)
  local key = historical.key(repo, rev, relpath)
  local existing = historical.find(key)
  if existing then return existing, false end

  local title = string.format("%s @ %s", relpath, short_rev(rev))
  local buffer = Buffer(nil, nil, true)
  buffer.filename = relpath
  set_buffer_text(buffer, text)
  buffer:reset_syntax()
  buffer:clear_undo_redo()
  buffer:clean()
  buffer.git_historical_key = key
  buffer.git_historical_repo = type(repo) == "table" and repo.root or repo
  buffer.git_historical_rev = rev
  buffer.git_historical_path = relpath
  buffer.git_historical_title = title
  make_read_only(buffer)
  table.insert(core.buffers, buffer)
  core.log_quiet("Opened Historical Buffer %s", title)
  return buffer, true
end

local function main_root_panel()
  return core.root_panel
end

local function views_referencing_buffer(root_panel, buffer)
  local views = {}
  local panes = require "core.panes"
  for _, pane in ipairs(panes.ordered()) do
    for _, view in ipairs(panes.history_views(pane)) do
      if view.buffer == buffer then views[#views + 1] = view end
    end
  end
  return views
end

local function activate_view(root_panel, view)
  local panes = require "core.panes"
  local pane = panes.pane_for_view(view)
  if pane then panes.present(view, { pane = pane, focus = true }) end
end

local function open_buffer_view(buffer)
  local root_panel = main_root_panel()
  for _, view in ipairs(views_referencing_buffer(root_panel, buffer)) do
    activate_view(root_panel, view)
    return view, buffer, false
  end

  local view = HistoricalTextView(buffer)
  require("core.panes").place(function() return view end, {
    placement = "current",
    focus = true,
    reason = "git-historical-buffer",
  })
  return view, buffer, true
end

function historical.activate_existing(repo, rev, relpath)
  local buffer = historical.find(historical.key(repo, rev, relpath))
  if not buffer then return nil end
  return open_buffer_view(buffer)
end

function historical.open(repo, rev, relpath, text)
  local buffer = historical.create_buffer(repo, rev, relpath, text)
  return open_buffer_view(buffer)
end

return historical
