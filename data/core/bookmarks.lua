local core = require "core"
local common = require "core.common"
local locations = require "core.bookmark_locations"
local range_marker = require "core.range_marker"
local storage = require "core.storage"
local worker_pool = require "core.worker_pool"

local bookmarks = {}
local projects = {}
local generation = 0
local gutter_cache = setmetatable({}, { __mode = "k" })
local snapshot_cache = setmetatable({}, { __mode = "k" })

local function buffer_snapshot(buffer)
  local cached = snapshot_cache[buffer]
  if not cached or cached.revision ~= buffer.text_revision then
    cached = { revision = buffer.text_revision, value = locations.snapshot(buffer.lines) }
    snapshot_cache[buffer] = cached
  end
  return cached.value
end

local function positive_integer(value)
  return type(value) == "number" and value >= 1 and value <= 9007199254740990 and value == math.floor(value)
end

local function saved_context(value, version)
  if value == nil then return {} end
  if version == 1 and type(value) == "string" then return { value } end
  if type(value) ~= "table" or #value > 3 then return nil end
  local context, count = {}, 0
  for index, line in pairs(value) do
    if not positive_integer(index) or index > #value or type(line) ~= "string" then return nil end
    context[index] = line
    count = count + 1
  end
  if count ~= #value then return nil end
  return context
end

local function load_records(key)
  local ok, saved = pcall(storage.load, "bookmarks", key)
  if not ok then core.log_quiet("Bookmarks: storage load failed for %s: %s", key, tostring(saved)) end
  if not ok or saved == nil then return {}, 1 end
  if type(saved) ~= "table" or (saved.version ~= 1 and saved.version ~= 2 and saved.version ~= 3) or type(saved.marks) ~= "table" then
    core.log_quiet("Bookmarks: ignored invalid storage for %s", key)
    return {}, 1
  end
  local snapshots = {}
  if saved.version == 3 and type(saved.snapshots) == "table" then
    for index, value in ipairs(saved.snapshots) do
      if type(value) == "string" and #value > 0 and #value <= locations.recovery_limit then
        local lines = encoding.split_lines(value)
        if table.concat(lines) == value then snapshots[index] = { lines = lines } end
      end
    end
  end
  local marks, ids, next_id = {}, {}, 1
  for _, record in ipairs(saved.marks) do
    local before = type(record) == "table" and saved_context(record.before, saved.version)
    local after = type(record) == "table" and saved_context(record.after, saved.version)
    if type(record) == "table" and positive_integer(record.id) and not ids[record.id]
        and positive_integer(record.line) and type(record.path) == "string" and common.is_absolute_path(record.path)
        and type(record.text) == "string" and (record.name == nil or type(record.name) == "string")
        and (record.location_version == nil or positive_integer(record.location_version))
        and (record.location_deleted == nil or type(record.location_deleted) == "boolean")
        and (record.status == "ready" or record.status == "location_missing" or record.status == "checking" or record.status == "file_missing")
        and before and after then
      local fingerprint = record.fingerprint
      if type(fingerprint) ~= "string" or not fingerprint:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x:%d+:%d+$") then fingerprint = nil end
      local snapshot = positive_integer(record.snapshot) and snapshots[record.snapshot]
      local unavailable = record.recovery_unavailable == true or record.snapshot ~= nil and not snapshot
      if snapshot and (not snapshot.lines[record.line]
          or snapshot.lines[record.line]:gsub("[\r\n]+$", "") ~= record.text) then
        snapshot, unavailable = nil, true
      end
      if unavailable then core.log_quiet("Bookmarks: retained record with unavailable text version id=%d path=%s", record.id, record.path) end
      marks[#marks + 1] = {
        id = record.id, path = record.path, line = record.line, text = record.text, name = record.name or "",
        before = before, after = after, fingerprint = fingerprint,
        snapshot = snapshot, recovery_unavailable = unavailable or nil,
        location_version = record.location_version or 1, location_deleted = record.location_deleted,
        location_status = record.location_deleted and "location_missing" or record.status,
        needs_recovery = true, status = "checking",
      }
      ids[record.id] = true
      next_id = math.max(next_id, record.id + 1)
    else
      core.log_quiet("Bookmarks: ignored invalid record for %s", key)
    end
  end
  if positive_integer(saved.next_id) then next_id = math.max(next_id, saved.next_id) end
  return marks, next_id
end

local function project_key(root)
  return common.path_compare_key(root or core.root_project().path)
end

local function store_for(root)
  local key = project_key(root)
  if not projects[key] then
    local marks, next_id = load_records(key)
    projects[key] = { key = key, marks = marks, next_id = next_id, revision = 0 }
    core.log_quiet("Bookmarks: loaded %d records for %s", #projects[key].marks, key)
    generation = generation + 1
  end
  return projects[key]
end

local function owner(mark)
  for _, store in pairs(projects) do
    for _, item in ipairs(store.marks) do
      if item == mark then return store end
    end
  end
end

local function line_text(buffer, line)
  return (buffer.lines[line] or ""):gsub("[\r\n]+$", "")
end

local function save(store)
  local records, snapshots, snapshot_ids = {}, {}, {}
  for _, mark in ipairs(store.marks) do
    if mark.buffer and mark.location_status == "ready" and not mark.needs_recovery then
      mark.snapshot = buffer_snapshot(mark.buffer)
    end
    local snapshot_id
    if mark.snapshot then
      snapshot_id = snapshot_ids[mark.snapshot]
      if not snapshot_id then
        snapshot_id = #snapshots + 1
        snapshot_ids[mark.snapshot] = snapshot_id
        snapshots[snapshot_id] = table.concat(mark.snapshot.lines)
      end
    end
    records[#records + 1] = {
      id = mark.id, path = mark.path, line = mark.line, name = mark.name,
      text = mark.text, before = mark.before, after = mark.after, status = mark.location_status or mark.status,
      location_version = mark.location_version,
      location_deleted = mark.location_deleted,
      fingerprint = mark.fingerprint,
      snapshot = snapshot_id, recovery_unavailable = mark.recovery_unavailable,
    }
  end
  local ok = storage.save("bookmarks", store.key, { version = 3, next_id = store.next_id, marks = records, snapshots = snapshots })
  store.dirty = not ok
  return ok
end

local function changed(store)
  generation = generation + 1
  store.revision = store.revision + 1
  core.redraw = true
  store.dirty = true
  if store.save_pending then return end
  store.save_pending = true
  core.add_thread(function()
    coroutine.yield(0.25)
    while projects[store.key] == store and store.dirty do
      if save(store) then break end
      core.log_quiet("Bookmarks: save failed for %s; retry pending", store.key)
      coroutine.yield(5)
    end
    store.save_pending = false
  end)
end

local function detach(mark)
  if mark.marker then range_marker.remove(mark.marker); mark.marker = nil end
  mark.buffer = nil
end

local function capture(mark, buffer, line)
  mark.line = line
  mark.text = line_text(buffer, line)
  mark.before, mark.after = locations.capture(buffer.lines, line)
  -- Live edit transactions supply exact positions. Retain file text only at save,
  -- close, or reload boundaries, not on each keystroke.
  mark.snapshot, mark.fingerprint, mark.recovery_unavailable = nil, nil, nil
  mark.location_status = "ready"
  mark.buffer_revision = buffer.text_revision
  mark.status = mark.disk_missing and "file_missing" or "ready"
end

local function bind(mark, buffer, line)
  detach(mark)
  mark.buffer = buffer
  mark.needs_recovery = nil
  mark.location_deleted = nil
  capture(mark, buffer, line)
  mark.marker = range_marker.new(buffer, {
    line1 = line, col1 = 1, line2 = line, col2 = #buffer.lines[line],
    greedy_left = true, greedy_right = true, sticky_right_on_newline = true,
    kind = "bookmark",
  })
end

function bookmarks.attach(buffer)
  if not buffer.abs_filename or buffer.git_historical_key then return end
  local store = store_for()
  local attached = false
  for _, mark in ipairs(store.marks) do
    if not mark.buffer and common.path_equals(mark.path, buffer.abs_filename) then
      attached = true
      mark.buffer, mark.needs_recovery, mark.status = buffer, true, "checking"
    end
  end
  if attached then changed(store); bookmarks.refresh(store.key) end
  if buffer.__bookmarks_attached then return end
  buffer.__bookmarks_attached = true
  buffer:add_text_change_listener("bookmarks", {
    before_change = function(_, event)
      local transaction = event.transaction
      if not transaction then return end
      if transaction.full_snapshot and transaction.content_changed then
        for _, project_store in pairs(projects) do
          for _, mark in ipairs(project_store.marks) do
            if mark.buffer == buffer and mark.location_status == "ready" and not mark.needs_recovery then
              mark.snapshot = buffer_snapshot(buffer)
            end
          end
        end
      end
      if not transaction.observer_state then return end
      local states = {}
      for key, store in pairs(projects) do
        local positions = {}
        for _, mark in ipairs(store.marks) do
          if mark.buffer == buffer then
            local range = mark.buffer_revision ~= buffer.text_revision and mark.marker and mark.marker:range()
            if range then capture(mark, buffer, range.line1) end
            if mark.location_status == "ready" and not mark.needs_recovery then
              for _, edit in ipairs(transaction.edits or {}) do
                if edit.line1 <= mark.line and edit.line2 >= mark.line and edit.line1 < edit.line2 then
                  mark.snapshot = buffer_snapshot(buffer)
                  break
                end
              end
            end
            positions[mark.id] = {
              line = mark.line, status = mark.location_status or mark.status, text = mark.text,
              before = mark.before, after = mark.after, location_version = mark.location_version,
              fingerprint = mark.fingerprint,
              snapshot = mark.snapshot, recovery_unavailable = mark.recovery_unavailable,
              location_deleted = mark.location_deleted,
              needs_recovery = mark.needs_recovery,
            }
          end
        end
        states[key] = positions
      end
      transaction.observer_state.bookmarks = states
    end,
    after_change = function(_, event)
      local transaction = event.transaction or {}
      local restored = transaction.restore_observer_state and transaction.restore_observer_state.bookmarks
      for key, store in pairs(projects) do
        local touched, pending_recovery = false, false
        for _, mark in ipairs(store.marks) do
          if mark.buffer == buffer then
            touched = true
            local state = restored and restored[key] and restored[key][mark.id]
            if state and state.location_version == mark.location_version then
              if state.status == "ready" and not state.needs_recovery then
                bind(mark, buffer, state.line)
              else
                if mark.marker then range_marker.remove(mark.marker); mark.marker = nil end
                mark.line, mark.status = state.line, state.status
                mark.location_status = state.status
                mark.location_deleted = state.location_deleted
                mark.needs_recovery = state.needs_recovery
                mark.status = mark.disk_missing and "file_missing" or mark.needs_recovery and "checking" or state.status
                mark.text, mark.before, mark.after = state.text, state.before, state.after
                mark.fingerprint = state.fingerprint
                mark.snapshot, mark.recovery_unavailable = state.snapshot, state.recovery_unavailable
              end
            elseif mark.needs_recovery or transaction.full_snapshot and transaction.content_changed then
              -- Saved coordinates cannot track edits until recovery finds the target.
              if mark.marker then range_marker.remove(mark.marker); mark.marker = nil end
              mark.needs_recovery, mark.status = true, "checking"
            else
              local previous = transaction.observer_state and transaction.observer_state.bookmarks
              previous = previous and previous[key] and previous[key][mark.id]
              local mapped = previous and transaction.line_mapping and transaction.line_mapping[previous.line]
              local deleted, edited_line = false, nil
              if previous and previous.status == "ready" then
                for index, edit in ipairs(transaction.edits or {}) do
                  if edit.text == "" and edit.line1 < edit.line2
                      and previous.line >= edit.line1 and previous.line < edit.line2
                      and (previous.line > edit.line1 or edit.col1 == 1) then
                    deleted = true
                  elseif edit.line1 == edit.line2 and previous.line == edit.line1
                      and not edit.text:find("\n", 1, true) then
                    -- Batch ranges already include all earlier edits, even on this line.
                    -- Raw edits contain one change and use its original line.
                    local changed_range = transaction.changed_ranges and transaction.changed_ranges[index]
                    edited_line = changed_range and changed_range.new_line1 or edit.line1
                  end
                end
              end
              local range = mark.marker and mark.marker:range()
              if mapped and previous.status == "ready" then bind(mark, buffer, mapped)
              elseif deleted then
                if mark.marker then range_marker.remove(mark.marker); mark.marker = nil end
                mark.location_deleted = true
                mark.snapshot = nil
                mark.location_status = "location_missing"
                mark.status = mark.disk_missing and "file_missing" or "location_missing"
                core.log_quiet("Bookmarks: location deleted id=%d path=%s line=%d", mark.id, mark.path, mark.line)
              elseif range then capture(mark, buffer, range.line1)
              elseif edited_line then bind(mark, buffer, edited_line)
              else
                mark.location_status = "location_missing"
                mark.status = mark.disk_missing and "file_missing" or "location_missing"
              end
            end
            pending_recovery = pending_recovery or mark.needs_recovery
          end
        end
        if touched then
          changed(store)
          if pending_recovery then bookmarks.refresh(key) end
        end
      end
    end,
  })
  buffer:add_metadata_listener("bookmarks", function(_, event)
    for _, project_store in pairs(projects) do
      local touched = false
      for _, mark in ipairs(project_store.marks) do
        if mark.buffer == buffer then
          if event.kind == "close" then
            local range = mark.marker and mark.marker:range()
            if range then
              capture(mark, buffer, range.line1)
              mark.snapshot = buffer_snapshot(buffer)
            end
            detach(mark)
            mark.needs_recovery, mark.status = true, "checking"
            touched = true
          elseif event.filename_changed then
            mark.path = buffer.abs_filename
            mark.disk_missing = nil
            touched = true
          end
        end
      end
      if touched then changed(project_store) end
    end
  end)
end

function bookmarks.generation() return generation end

local function pending_file_location(store, path, except)
  for _, mark in ipairs(store.marks) do
    if mark ~= except and mark.needs_recovery and not mark.location_deleted and not mark.recovery_unavailable
        and common.path_equals(mark.path, path) then return true end
  end
end

function bookmarks.add(buffer, line, name)
  if not buffer.abs_filename then return nil, "Save the Buffer before adding a Bookmark" end
  bookmarks.attach(buffer)
  local store = store_for()
  if pending_file_location(store, buffer.abs_filename) then return nil, "Wait for Bookmark locations to finish checking" end
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
  local key = project_key()
  local cache = gutter_cache[buffer]
  if not cache or cache.key ~= key or cache.generation ~= generation then
    cache = { key = key, generation = generation, lines = {} }
    for _, mark in ipairs(bookmarks.list()) do
      if common.path_equals(mark.path, buffer.abs_filename) and mark.location_status == "ready" and not mark.needs_recovery then
        cache.lines[mark.line] = mark
      end
    end
    cache.generation = generation
    gutter_cache[buffer] = cache
  end
  return cache.lines[line]
end

function bookmarks.list(root)
  local store = store_for(root)
  for _, mark in ipairs(store.marks) do
    if mark.marker then
      local range = mark.buffer_revision ~= mark.buffer.text_revision and mark.marker:range()
      if range then
        capture(mark, mark.buffer, range.line1)
      elseif not mark.marker:is_valid() and not mark.needs_recovery then
        mark.location_status = "location_missing"
        mark.status = mark.disk_missing and "file_missing" or "location_missing"
      end
    end
  end
  return store.marks
end

function bookmarks.is_refreshing(root)
  return store_for(root).job ~= nil
end

function bookmarks.navigation_target(mark)
  local store = store_for()
  if owner(mark) ~= store then return nil, "Bookmark is no longer in the Selected Project" end
  bookmarks.list()
  local info = system.get_file_info(mark.path)
  if not info or info.type ~= "file" then
    mark.disk_missing, mark.status = true, "file_missing"
    changed(store)
    return nil, "Bookmark file missing — right-click to rename, remove, or attach"
  end
  if mark.disk_missing then
    mark.disk_missing = nil
    mark.status = mark.needs_recovery and "checking" or mark.location_status or "location_missing"
    changed(store)
  end
  -- Disk recovery supplies search results, not permission to use stale coordinates.
  -- Navigation must use the same Buffer that recovery checked.
  if not mark.buffer then return nil, "Checking Bookmark location…" end
  if mark.status ~= "ready" then
    return nil, mark.status == "checking" and "Checking Bookmark location…" or "Bookmark location missing — right-click for actions"
  end
  return { path = mark.path, line = mark.line, buffer = mark.buffer }
end

---Resolve against opened text before changing a Pane. Return a cancellation function.
function bookmarks.open_target(mark, done)
  local store = store_for()
  local target, reason = bookmarks.navigation_target(mark)
  local cancel = function() end
  if target or owner(mark) ~= store or mark.status == "file_missing" or mark.location_deleted then
    done(target, reason)
    return cancel
  end
  local buffer = mark.buffer
  if not buffer then
    local ok, opened = pcall(core.open_buffer, mark.path)
    if not ok or not opened or not common.path_equals(opened.abs_filename, mark.path) then
      core.log_quiet("Bookmarks: cannot open target %s: %s", mark.path, tostring(opened))
      done(nil, "Cannot open Bookmark file")
      return cancel
    end
    buffer = opened
  end
  local request, active = {}, true
  if core.buffer_registry:identity(buffer) then core.buffer_registry:retain(buffer, request) end
  cancel = function()
    if not active then return end
    active = false
    core.buffer_registry:release(buffer, request)
  end
  bookmarks.attach(buffer)
  if mark.needs_recovery then bookmarks.refresh(store.key) end
  core.add_thread(function()
    while active do
      local resolved, error_message = bookmarks.navigation_target(mark)
      if resolved or store ~= store_for() or owner(mark) ~= store or not store.job then
        local ok, err = pcall(done, resolved, error_message)
        cancel()
        if not ok then core.log_quiet("Bookmarks: navigation callback failed: %s", tostring(err)) end
        return
      end
      coroutine.yield(0.01)
    end
  end)
  return cancel
end

function bookmarks.refresh(root)
  local store = store_for(root)
  if store.job then return end
  bookmarks.list(root)
  local files, by_path, buffers = {}, {}, {}
  for _, mark in ipairs(store.marks) do
    local key = common.path_compare_key(mark.path)
    local file = by_path[key]
    if not file then
      file = { path = mark.path, records = {}, snapshots = {}, snapshot_ids = {} }
      by_path[key], files[#files + 1] = file, file
    end
    local snapshot_id
    if mark.snapshot then
      snapshot_id = file.snapshot_ids[mark.snapshot]
      if not snapshot_id then
        snapshot_id = #file.snapshots + 1
        file.snapshot_ids[mark.snapshot] = snapshot_id
        file.snapshots[snapshot_id] = mark.snapshot
      end
    end
    file.records[#file.records + 1] = {
      id = mark.id, line = mark.line, status = mark.location_status,
      text = mark.text, before = mark.before, after = mark.after, fingerprint = mark.fingerprint,
      location_deleted = mark.location_deleted,
      snapshot = snapshot_id, recovery_unavailable = mark.recovery_unavailable,
    }
    if mark.buffer then
      file.live = true
      buffers[key] = { buffer = mark.buffer, revision = mark.buffer.text_revision }
      if mark.needs_recovery and not file.lines then
        file.lines = {}
        for index, line in ipairs(mark.buffer.lines) do file.lines[index] = line end
      end
    end
  end
  for _, file in ipairs(files) do file.snapshot_ids = nil end
  if #files == 0 then return end
  local revision = store.revision
  local results = {}
  store.job = worker_pool.system():submit {
    kind = "bookmarks", priority = "background", payload = { files = files },
    on_result = function(message)
      if message.type == "result" then results[#results + 1] = message.payload end
    end,
    on_complete = function()
      store.job = nil
      if projects[store.key] ~= store then return end
      if store.revision ~= revision then
        core.log_quiet("Bookmarks: discarded stale recovery for %s", store.key)
        bookmarks.refresh(store.key)
        return
      end
      local touched = false
      for _, result in ipairs(results) do
        local key = common.path_compare_key(result.path)
        local bound = buffers[key]
        if not bound or bound.buffer.text_revision == bound.revision then
          local recovered = {}
          for _, record in ipairs(result.records or {}) do recovered[record.id] = record end
          for _, mark in ipairs(store.marks) do
            if common.path_equals(mark.path, result.path) then
              local old_status, old_location, old_line, old_fingerprint = mark.status, mark.location_status, mark.line, mark.fingerprint
              local was_recovering = mark.needs_recovery
              mark.disk_missing = result.missing
              local record = recovered[mark.id]
              if record then
                mark.needs_recovery = nil
                if record.line and mark.buffer then bind(mark, mark.buffer, record.line)
                elseif record.line then
                  mark.line, mark.location_status = record.line, "ready"
                  mark.text, mark.before, mark.after, mark.fingerprint = record.text, record.before, record.after, record.fingerprint
                else mark.location_status = "location_missing" end
                if record.line then
                  mark.snapshot = result.snapshot
                  if mark.buffer then
                    snapshot_cache[mark.buffer] = { revision = mark.buffer.text_revision, value = result.snapshot }
                  end
                end
              end
              mark.status = result.missing and "file_missing" or mark.needs_recovery and "checking"
                or mark.location_status or "location_missing"
              if mark.status ~= old_status then
                core.log_quiet("Bookmarks: checked id=%d path=%s line=%d status=%s", mark.id, mark.path, mark.line, mark.status)
              end
              touched = touched or mark.status ~= old_status or mark.location_status ~= old_location or mark.line ~= old_line
                or mark.fingerprint ~= old_fingerprint or was_recovering and not mark.needs_recovery
            end
          end
          if result.error then core.log_quiet("Bookmarks: %s: %s", result.path, result.error) end
        else
          core.log_quiet("Bookmarks: discarded stale Buffer recovery for %s", result.path)
        end
      end
      if touched then changed(store) end
    end,
    on_error = function(err)
      store.job = nil
      core.log_quiet("Bookmarks: recovery failed: %s", tostring(err))
    end,
  }
end

function bookmarks.rename(mark, name)
  local store = owner(mark)
  if not store then return false end
  mark.name = name or ""
  changed(store)
  core.log_quiet("Bookmarks: renamed id=%d path=%s", mark.id, mark.path)
  return true
end

function bookmarks.retarget(mark, buffer, line)
  local store = owner(mark)
  if not store then return nil, "Bookmark no longer exists" end
  if not buffer.abs_filename then return nil, "Save the Buffer before attaching a Bookmark" end
  if buffer.git_historical_key then return nil, "Cannot attach a Bookmark to historical text" end
  if store ~= store_for() then return nil, "Bookmark is no longer in the Selected Project" end
  bookmarks.attach(buffer)
  if pending_file_location(store, buffer.abs_filename, mark) then return nil, "Wait for Bookmark locations to finish checking" end
  local existing = bookmarks.at(buffer, line)
  if existing and existing ~= mark then return nil, "The caret line already has a Bookmark" end
  mark.path = buffer.abs_filename
  mark.location_version = (mark.location_version or 1) + 1
  mark.disk_missing = nil
  bind(mark, buffer, line)
  bookmarks.attach(buffer)
  changed(store)
  core.log_quiet("Bookmarks: attached id=%d path=%s line=%d", mark.id, mark.path, line)
  return true
end

function bookmarks.move_path(old_path, new_path, entry_type)
  store_for()
  for _, store in pairs(projects) do
    local touched = false
    for _, mark in ipairs(store.marks) do
      local moved = false
      if common.path_equals(mark.path, old_path) then
        mark.path, moved = new_path, true
      elseif entry_type == "dir" and common.path_belongs_to(mark.path, old_path) then
        mark.path, moved = new_path .. mark.path:sub(#old_path + 1), true
      end
      if moved then
        mark.disk_missing = nil
        mark.status = mark.location_status or "checking"
        touched = true
      end
    end
    if touched then changed(store) end
  end
end

function bookmarks.flush()
  for _, store in pairs(projects) do
    if store.dirty then save(store) end
  end
end

function bookmarks.remove(mark)
  local store = owner(mark)
  if not store then return false end
  for index, item in ipairs(store.marks) do
    if item == mark then
      detach(mark)
      table.remove(store.marks, index)
      changed(store)
      core.log_quiet("Bookmarks: removed id=%d path=%s", mark.id, mark.path)
      return true
    end
  end
  return false
end

function bookmarks.close_project(root)
  local key = project_key(root)
  local store = projects[key]
  if not store then return end
  if store.job then worker_pool.system():cancel(store.job); store.job = nil end
  bookmarks.list(root)
  if not save(store) then
    changed(store)
    core.log_quiet("Bookmarks: retained unsaved records for %s", key)
    return false
  end
  for _, mark in ipairs(store.marks) do detach(mark) end
  projects[key] = nil
  generation = generation + 1
  return true
end

return bookmarks
