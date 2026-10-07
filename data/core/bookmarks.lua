local core = require "core"
local common = require "core.common"
local range_marker = require "core.range_marker"
local storage = require "core.storage"

local bookmarks = {}
local projects = {}
local generation = 0

local function project_key(root)
  return common.path_compare_key(root or core.root_project().path)
end

local function store_for(root)
  local key = project_key(root)
  if not projects[key] then
    local saved = storage.load("bookmarks", key) or {}
    projects[key] = { key = key, marks = saved.marks or {}, next_id = saved.next_id or 1 }
    core.log_quiet("Bookmarks: loaded %d records for %s", #projects[key].marks, key)
  end
  return projects[key]
end

local function line_text(buffer, line)
  return (buffer.lines[line] or ""):gsub("[\r\n]+$", "")
end

local function save(store)
  local records = {}
  for _, mark in ipairs(store.marks) do
    records[#records + 1] = {
      id = mark.id, path = mark.path, line = mark.line, name = mark.name,
      text = mark.text, before = mark.before, after = mark.after, status = mark.status,
      location_version = mark.location_version,
    }
  end
  storage.save("bookmarks", store.key, { version = 1, next_id = store.next_id, marks = records })
  store.dirty = false
end

local function changed(store)
  generation = generation + 1
  core.redraw = true
  store.dirty = true
  if store.save_pending then return end
  store.save_pending = true
  core.add_thread(function()
    coroutine.yield(0.25)
    store.save_pending = false
    if projects[store.key] == store and store.dirty then save(store) end
  end)
end

local function detach(mark)
  if mark.marker then range_marker.remove(mark.marker); mark.marker = nil end
  mark.buffer = nil
end

local function capture(mark, buffer, line)
  mark.line = line
  mark.text = line_text(buffer, line)
  mark.before = line > 1 and line_text(buffer, line - 1) or nil
  mark.after = line < #buffer.lines and line_text(buffer, line + 1) or nil
  mark.status = "ready"
end

local function bind(mark, buffer, line)
  detach(mark)
  mark.buffer = buffer
  capture(mark, buffer, line)
  mark.marker = range_marker.new(buffer, {
    line1 = line, col1 = 1, line2 = line, col2 = #buffer.lines[line],
    greedy_left = true, greedy_right = true, sticky_right_on_newline = true,
    kind = "bookmark",
  })
end

function bookmarks.generation() return generation end

function bookmarks.add(buffer, line, name)
  if not buffer.abs_filename then return nil, "Save the Buffer before adding a Bookmark" end
  local store = store_for()
  local existing = bookmarks.at(buffer, line)
  if existing then return existing end
  local mark = {
    id = store.next_id, path = buffer.abs_filename, name = name or "",
    location_version = 1,
  }
  store.next_id = store.next_id + 1
  store.marks[#store.marks + 1] = mark
  bind(mark, buffer, line)
  changed(store)
  core.log_quiet("Bookmarks: added id=%d path=%s line=%d", mark.id, mark.path, line)
  return mark
end

function bookmarks.at(buffer, line)
  for _, mark in ipairs(bookmarks.list()) do
    if common.path_equals(mark.path, buffer.abs_filename) and mark.status == "ready" and mark.line == line then
      return mark
    end
  end
end

function bookmarks.list(root)
  local store = store_for(root)
  for _, mark in ipairs(store.marks) do
    if mark.marker then
      local range = mark.marker:range()
      if range then
        capture(mark, mark.buffer, range.line1)
      else
        mark.status = "location_missing"
      end
    end
  end
  return store.marks
end

function bookmarks.rename(mark, name)
  mark.name = name or ""
  changed(store_for())
end

function bookmarks.remove(mark)
  local store = store_for()
  for index, item in ipairs(store.marks) do
    if item == mark then
      detach(mark)
      table.remove(store.marks, index)
      changed(store)
      return true
    end
  end
  return false
end

function bookmarks.close_project(root)
  local key = project_key(root)
  local store = projects[key]
  if not store then return end
  bookmarks.list(root)
  save(store)
  for _, mark in ipairs(store.marks) do detach(mark) end
  projects[key] = nil
end

return bookmarks
