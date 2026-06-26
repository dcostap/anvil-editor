-- mod-version:3
-- Read-only Documents backed by Git revision contents.

local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"

local HistoricalDocView = DocView:extend()

function HistoricalDocView:get_state()
  return nil
end

local historical = {
  View = HistoricalDocView,
}

local function short_rev(rev)
  return tostring(rev or ""):sub(1, 8)
end

function historical.key(repo, rev, relpath)
  local root = type(repo) == "table" and repo.root or tostring(repo or "")
  return table.concat({ root, tostring(rev or ""), tostring(relpath or "") }, "\0")
end

local function reject_edit(doc)
  core.log_quiet("Historical Document is read-only: %s", doc.git_historical_title or doc:get_name())
  return false
end

local function set_doc_text(doc, text)
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
  doc.lines = lines
  doc:set_selection(1, 1, 1, 1)
end

local function make_read_only(doc)
  doc.git_historical_read_only = true
  doc.apply_edits = reject_edit
  doc.text_input = reject_edit
  doc.ime_text_editing = reject_edit
  doc.insert = reject_edit
  doc.remove = reject_edit
  doc.replace = reject_edit
  doc.replace_cursor = reject_edit
  doc.save = function(self)
    error("Historical Document is read-only")
  end
  doc.set_filename = function(self)
    error("Historical Document is read-only")
  end
  doc.is_dirty = function() return false end
  doc.get_name = function(self) return self.git_historical_title or "Historical Document" end
end

function historical.find(key)
  for _, doc in ipairs(core.docs or {}) do
    if doc.git_historical_key == key then return doc end
  end
end

function historical.create_document(repo, rev, relpath, text)
  local key = historical.key(repo, rev, relpath)
  local existing = historical.find(key)
  if existing then return existing, false end

  local title = string.format("%s @ %s", relpath, short_rev(rev))
  local doc = Doc(nil, nil, true)
  doc.filename = relpath
  set_doc_text(doc, text)
  doc:reset_syntax()
  doc:clear_undo_redo()
  doc:clean()
  doc.git_historical_key = key
  doc.git_historical_repo = type(repo) == "table" and repo.root or repo
  doc.git_historical_rev = rev
  doc.git_historical_path = relpath
  doc.git_historical_title = title
  make_read_only(doc)
  table.insert(core.docs, doc)
  core.log_quiet("Opened Historical Document %s", title)
  return doc, true
end

local function main_root_panel()
  return core.tool_window_main_root_panel or core.root_panel
end

local function views_referencing_doc(root_panel, doc)
  local views = {}
  local root = root_panel and root_panel.root_node
  if not root or not root.get_children then return views end
  for _, view in ipairs(root:get_children()) do
    if view.doc == doc then views[#views + 1] = view end
  end
  return views
end

local function activate_view(root_panel, view)
  local node = root_panel and root_panel.root_node
    and root_panel.root_node.get_node_for_view
    and root_panel.root_node:get_node_for_view(view)
  if node and node.set_active_view then
    node:set_active_view(view)
  else
    core.set_active_view(view)
  end
end

local function open_doc_view(doc)
  local root_panel = main_root_panel()
  for _, view in ipairs(views_referencing_doc(root_panel, doc)) do
    activate_view(root_panel, view)
    return view, doc, false
  end

  local view = HistoricalDocView(doc)
  local previous_event_window = core.event_window
  core.active_window = core.window
  core.event_window = core.window
  root_panel:get_active_node_default():add_view(view)
  core.set_active_view(view)
  core.event_window = previous_event_window
  core.active_window = core.window
  return view, doc, true
end

function historical.activate_existing(repo, rev, relpath)
  local doc = historical.find(historical.key(repo, rev, relpath))
  if not doc then return nil end
  return open_doc_view(doc)
end

function historical.open(repo, rev, relpath, text)
  local doc = historical.create_document(repo, rev, relpath, text)
  return open_doc_view(doc)
end

return historical
