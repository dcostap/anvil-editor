-- mod-version:3
-- Managed backing files for IntelliJ-style untitled Documents.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"

local M = {}

local cfg = config.plugins.untitled_recovery or {}
local DIR = USERDIR .. PATHSEP .. "recovery" .. PATHSEP .. "untitled"
local PROJECTS_DIR = DIR .. PATHSEP .. "projects"
local TRASH_DIR = DIR .. PATHSEP .. "trash"
local MANIFEST = "manifest.lua"
local MANIFEST_BAK = "manifest.lua.bak"

local id_counter = 0
local pending_generation = 0
local loop_running = false
local dirty_docs = setmetatable({}, { __mode = "k" })

local function log_quiet(fmt, ...)
  if core.log_quiet then core.log_quiet(fmt, ...) end
end

local function is_untitled_doc(doc)
  return doc
     and doc.intellij_untitled
     and not doc.intellij_untitled_discarded
     and doc.new_file
     and not doc.filename
     and not doc.abs_filename
end
M.is_untitled_doc = is_untitled_doc

local function normalize_project_path(path)
  path = tostring(path or "default")
  path = common.normalize_path(path)
  if PLATFORM == "Windows" then path = path:lower() end
  return path
end

local bit_ok, bit = pcall(require, "bit")
local function u32(n)
  n = tonumber(n) or 0
  if n < 0 then n = n + 4294967296 end
  return n % 4294967296
end

local function hash_text(text)
  text = tostring(text or "")
  if bit_ok and bit then
    local h1, h2 = 2166136261, 5381
    for i = 1, #text do
      local b = text:byte(i)
      h1 = bit.tobit(bit.bxor(h1, b) * 16777619)
      h2 = bit.tobit(h2 * 33 + b)
    end
    return string.format("%08x%08x", u32(h1), u32(h2))
  end
  local h1, h2 = 2166136261, 5381
  for i = 1, #text do
    local b = text:byte(i)
    h1 = (h1 * 16777619 + b) % 4294967296
    h2 = (h2 * 33 + b) % 4294967296
  end
  return string.format("%08x%08x", h1, h2)
end

function M.project_key(project_path)
  return hash_text(normalize_project_path(project_path))
end

local function current_project_path()
  local project = core.root_project and core.root_project()
  return project and project.path or system.getcwd() or "default"
end

local function project_paths(project_path)
  project_path = project_path or current_project_path()
  local key = M.project_key(project_path)
  local root = PROJECTS_DIR .. PATHSEP .. key
  return {
    key = key,
    project = project_path,
    root = root,
    docs = root .. PATHSEP .. "docs",
    manifest = root .. PATHSEP .. MANIFEST,
    manifest_bak = root .. PATHSEP .. MANIFEST_BAK,
  }
end
M.project_paths = project_paths

local function ensure_dir(path)
  local info = system.get_file_info(path)
  if info then return info.type == "dir" end
  local ok, err = common.mkdirp(path)
  if not ok then
    core.error("Cannot create untitled recovery directory %s: %s", path, err or "unknown error")
    return false
  end
  return true
end

local function sanitize_id(id)
  id = tostring(id or "")
  id = id:gsub("[^%w%._%-]", "-")
  if id == "" then return nil end
  return id
end

local function new_doc_id()
  id_counter = id_counter + 1
  local pid = system.get_process_id and system.get_process_id() or 0
  local t = math.floor(system.get_time() * 1000000)
  local r = math.random and math.random(0, 0xffff) or 0
  return string.format("%s-%d-%d-%04x", pid, t, id_counter, r)
end

local function backing_rel_for_id(id)
  return "docs" .. PATHSEP .. sanitize_id(id) .. ".txt"
end

local function safe_relative_backing_abs(project_path, rel, id)
  rel = tostring(rel or "")
  rel = rel:gsub("[/\\]", PATHSEP)
  if rel == "" or rel:find("^%a:[/\\]") or rel:sub(1, 1) == "/" or rel:sub(1, 1) == "\\" then
    rel = backing_rel_for_id(id)
  end
  local unsafe = false
  for part in rel:gmatch("[^/\\]+") do
    if part == ".." then unsafe = true; break end
  end
  if unsafe then rel = backing_rel_for_id(id) end
  local paths = project_paths(project_path)
  return paths.root .. PATHSEP .. rel, rel
end

local function backing_abs_for(project_path, id, rel)
  return safe_relative_backing_abs(project_path, rel or backing_rel_for_id(id), id)
end

local function read_file(path)
  local fp = io.open(path, "rb")
  if not fp then return nil end
  local s = fp:read("*a")
  fp:close()
  return s
end
M._read_file = read_file

local function check_io(ok, err)
  if not ok then error(err or "I/O error") end
  return ok
end

local function copy_file(src, dst)
  local input = assert(io.open(src, "rb"))
  local output, open_err = io.open(dst, "wb")
  if not output then input:close(); error(open_err or "could not open output") end
  local ok, err = pcall(function()
    while true do
      local chunk = input:read(1024 * 1024)
      if not chunk then break end
      check_io(output:write(chunk))
    end
    check_io(output:flush())
  end)
  local ci_ok, ci_err = input:close()
  local co_ok, co_err = output:close()
  if not ok then error(err) end
  check_io(ci_ok, ci_err)
  check_io(co_ok, co_err)
end
M._copy_file = copy_file

local function replace_existing_with_tmp(tmp, target, backup, opts)
  opts = opts or {}
  local had_target = system.get_file_info(target) ~= nil
  local backup_moved = false
  if backup then os.remove(backup) end
  if had_target then
    if backup then
      local moved, move_err = os.rename(target, backup)
      if not moved then error(move_err or "could not move existing target to backup") end
      backup_moved = true
    else
      local removed, remove_err = os.remove(target)
      if not removed then error(remove_err or "could not remove existing target") end
    end
  end
  if opts.fail_after_backup then error("simulated replace failure") end
  local renamed, rename_err = os.rename(tmp, target)
  if not renamed then
    if backup_moved then pcall(os.rename, backup, target) end
    error(rename_err or "could not move temp file into place")
  end
end

function M.safe_replace_bytes(target, bytes, opts)
  opts = opts or {}
  local dir = common.dirname(target)
  if dir and not ensure_dir(dir) then return false, "could not create parent directory" end
  local tmp = opts.tmp or (target .. ".tmp")
  local backup = opts.backup or (target .. ".bak")
  local fp, open_err = io.open(tmp, "wb")
  if not fp then return false, open_err end
  local ok, err = pcall(function()
    check_io(fp:write(bytes or ""))
    check_io(fp:flush())
    check_io(fp:close())
    replace_existing_with_tmp(tmp, target, backup, opts)
  end)
  if not ok then
    pcall(function() fp:close() end)
    os.remove(tmp)
    if system.get_file_info(backup) and not system.get_file_info(target) then
      pcall(os.rename, backup, target)
    end
    return false, err
  end
  return true
end
M._safe_replace_bytes = M.safe_replace_bytes

local function empty_manifest(paths)
  return { version = 1, project_key = paths.key, project = paths.project, saved_at = 0, docs = {} }
end

local function try_load_manifest_file(file, paths)
  local fn, load_err = loadfile(file)
  if not fn then return nil, load_err end
  local ok, data = pcall(fn)
  if not ok then return nil, data end
  if type(data) ~= "table" then return nil, "manifest did not return a table" end
  if type(data.docs) ~= "table" then return nil, "manifest docs field is missing or invalid" end
  if data.project and not common.path_equals(data.project, paths.project) then
    return nil, string.format("manifest project mismatch: %s", tostring(data.project))
  end
  data.version = data.version or 1
  data.project_key = data.project_key or paths.key
  data.project = data.project or paths.project
  return data
end

local function load_manifest_for(paths)
  local tmp = paths.manifest .. ".tmp"

  if system.get_file_info(paths.manifest) then
    local data, err = try_load_manifest_file(paths.manifest, paths)
    if data then return data end
    core.error("Couldn't load untitled recovery manifest %s: %s", paths.manifest, err)
  end

  if system.get_file_info(tmp) then
    local data, err = try_load_manifest_file(tmp, paths)
    if data then
      local restored, restore_err = pcall(copy_file, tmp, paths.manifest)
      if restored then
        log_quiet("Untitled recovery: restored valid temp manifest for %s", paths.project)
      else
        core.error("Couldn't restore untitled recovery temp manifest %s: %s", tmp, restore_err)
      end
      return data
    end
    core.error("Couldn't load untitled recovery temp manifest %s: %s", tmp, err)
  end

  if system.get_file_info(paths.manifest_bak) then
    local data, err = try_load_manifest_file(paths.manifest_bak, paths)
    if data then
      local restored, restore_err = pcall(copy_file, paths.manifest_bak, paths.manifest)
      if restored then
        log_quiet("Untitled recovery: restored valid backup manifest for %s", paths.project)
      else
        core.error("Couldn't restore untitled recovery backup manifest %s: %s", paths.manifest_bak, restore_err)
      end
      return data
    end
    core.error("Couldn't load untitled recovery backup manifest %s: %s", paths.manifest_bak, err)
  end

  return empty_manifest(paths)
end

function M.load_manifest(project_path)
  return load_manifest_for(project_paths(project_path))
end

local function manifest_entry(manifest, id)
  if not (manifest and type(manifest.docs) == "table" and id) then return nil end
  for _, doc in ipairs(manifest.docs) do
    if doc.id == id then return doc end
  end
end

local function write_manifest_for(paths, manifest)
  if not ensure_dir(paths.root) then return false, "could not create recovery root" end
  manifest.version = 1
  manifest.project_key = paths.key
  manifest.project = paths.project
  manifest.saved_at = os.time()
  manifest.docs = manifest.docs or {}
  table.sort(manifest.docs, function(a, b) return tostring(a.id) < tostring(b.id) end)

  local tmp = paths.manifest .. ".tmp"
  local body = "return " .. common.serialize(manifest, { pretty = true, sort = true })
  local fp, open_err = io.open(tmp, "wb")
  if not fp then return false, open_err end
  local ok, err = pcall(function()
    check_io(fp:write(body))
    check_io(fp:flush())
    check_io(fp:close())
    local fn, load_err = loadfile(tmp)
    if not fn then error(load_err) end
    local loaded_ok, loaded = pcall(fn)
    if not loaded_ok or type(loaded) ~= "table" or type(loaded.docs) ~= "table" then
      error("manifest validation failed")
    end
    replace_existing_with_tmp(tmp, paths.manifest, paths.manifest_bak)
  end)
  if not ok then
    pcall(function() fp:close() end)
    os.remove(tmp)
    if system.get_file_info(paths.manifest_bak) and not system.get_file_info(paths.manifest) then
      pcall(os.rename, paths.manifest_bak, paths.manifest)
    end
    core.error("Couldn't write untitled recovery manifest %s: %s", paths.manifest, err)
    return false, err
  end
  log_quiet("Untitled recovery: wrote manifest for %s with %d document(s)", paths.project, #manifest.docs)
  return true
end

function M.save_manifest(project_path, manifest)
  return write_manifest_for(project_paths(project_path), manifest)
end

local function doc_text_bytes(doc)
  local text = table.concat(doc.lines or { "\n" })
  if doc.crlf then text = text:gsub("\n", "\r\n") end
  return text
end
M.serialize_doc_text = doc_text_bytes

local function count_newlines(text)
  local _, count = tostring(text or ""):gsub("\n", "")
  return count
end

local function serialized_text_len(text, crlf)
  text = tostring(text or "")
  return #text + (crlf and count_newlines(text) or 0)
end

local function estimate_doc_bytes(doc)
  if not doc then return 0 end
  local cached = doc.intellij_untitled_estimated_bytes
  if cached then return cached end
  local total = 0
  for _, line in ipairs(doc.lines or { "\n" }) do
    total = total + serialized_text_len(line, doc.crlf)
  end
  doc.intellij_untitled_estimated_bytes = total
  return total
end

local function update_estimated_bytes_from_transaction(doc, transaction)
  if not doc then return end
  if type(transaction) ~= "table" or type(transaction.edits) ~= "table" then
    doc.intellij_untitled_estimated_bytes = nil
    return
  end
  local total = doc.intellij_untitled_estimated_bytes
  if not total then
    -- First edit after an uncached load/undo: pay one cheap line-length scan,
    -- but avoid concatenating the whole document on every keystroke.
    estimate_doc_bytes(doc)
    return
  end
  for _, edit in ipairs(transaction.edits) do
    total = total
      + serialized_text_len(edit.text, doc.crlf)
      - serialized_text_len(edit.old_text, doc.crlf)
  end
  doc.intellij_untitled_estimated_bytes = math.max(0, total)
end

local function text_to_lines(text)
  text = tostring(text or "")
  local crlf = text:find("\r\n", 1, true) ~= nil
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = {}
  if text == "" then
    lines[1] = "\n"
  else
    for line in (text .. "\n"):gmatch("(.-\n)") do
      lines[#lines + 1] = line
    end
    if #lines > 1 and lines[#lines] == "\n" then lines[#lines] = nil end
    if #lines == 0 then lines[1] = "\n" end
  end
  return lines, crlf
end
M._text_to_lines = text_to_lines

local function load_text_into_doc(doc, text, crlf)
  local lines, detected_crlf = text_to_lines(text)
  doc.lines = lines
  doc.crlf = crlf ~= nil and crlf or detected_crlf
  doc.intellij_untitled_estimated_bytes = nil
  estimate_doc_bytes(doc)
  doc:reset_syntax()
  doc:clear_undo_redo()
end

local function update_manifest_entry(doc, fields)
  local paths = project_paths(doc.intellij_untitled_project_path)
  local manifest = load_manifest_for(paths)
  manifest.docs = manifest.docs or {}
  local entry = manifest_entry(manifest, doc.intellij_untitled_id)
  if not entry then
    entry = { id = doc.intellij_untitled_id }
    manifest.docs[#manifest.docs + 1] = entry
  end
  for k, v in pairs(fields or {}) do entry[k] = v end
  entry.name = entry.name or doc.intellij_untitled_name or "Untitled"
  entry.backing = entry.backing or backing_rel_for_id(doc.intellij_untitled_id)
  entry.crlf = doc.crlf or false
  entry.updated_at = os.time()
  entry.created_at = entry.created_at or entry.updated_at
  entry.explicit_closed = false
  write_manifest_for(paths, manifest)
  return entry
end

function M.ensure_doc_backing(doc, opts)
  opts = opts or {}
  if not is_untitled_doc(doc) then return nil end
  doc.intellij_untitled_id = sanitize_id(opts.id or doc.intellij_untitled_id) or new_doc_id()
  doc.intellij_untitled_name = opts.name or doc.intellij_untitled_name or "Untitled"
  doc.intellij_untitled_project_path = opts.project or doc.intellij_untitled_project_path or current_project_path()
  doc.intellij_untitled_backing_rel = opts.backing or doc.intellij_untitled_backing_rel or backing_rel_for_id(doc.intellij_untitled_id)
  doc.intellij_untitled_backing_path, doc.intellij_untitled_backing_rel = backing_abs_for(doc.intellij_untitled_project_path, doc.intellij_untitled_id, doc.intellij_untitled_backing_rel)
  local paths = project_paths(doc.intellij_untitled_project_path)
  ensure_dir(paths.docs)
  if opts.update_manifest and not opts.no_manifest then
    update_manifest_entry(doc, {
      name = doc.intellij_untitled_name,
      backing = doc.intellij_untitled_backing_rel,
      crlf = doc.crlf or false,
      language = doc.syntax and doc.syntax.name or nil,
      last_snapshot_change_id = doc.intellij_untitled_last_snapshot_change_id,
    })
    log_quiet("Untitled recovery: ensured backing %s for %s", doc.intellij_untitled_backing_path, doc.intellij_untitled_name)
  end
  return doc.intellij_untitled_backing_path
end

function M.doc_backing_current(doc)
  if not is_untitled_doc(doc) then return false end
  if not doc.intellij_untitled_backing_path then return false end
  if doc.intellij_untitled_backing_dirty then return false end
  if not system.get_file_info(doc.intellij_untitled_backing_path) then return false end
  local change_id = doc.get_change_id and doc:get_change_id() or nil
  return doc.intellij_untitled_last_snapshot_change_id == change_id
end

function M.state_for_doc(doc)
  if not is_untitled_doc(doc) then return nil end
  M.ensure_doc_backing(doc, { no_manifest = true })
  return {
    intellij_untitled = true,
    intellij_untitled_name = doc.intellij_untitled_name,
    intellij_untitled_id = doc.intellij_untitled_id,
    intellij_untitled_backing = doc.intellij_untitled_backing_rel,
    intellij_untitled_backing_current = M.doc_backing_current(doc),
    intellij_untitled_change_id = doc.get_change_id and doc:get_change_id() or nil,
    intellij_untitled_backing_saved_at = doc.intellij_untitled_backing_saved_at,
    intellij_untitled_workspace_saved_at = system.get_time(),
  }
end

function M.flush_doc(doc, reason, force)
  if not is_untitled_doc(doc) then return false end
  M.ensure_doc_backing(doc)
  local change_id = doc.get_change_id and doc:get_change_id() or nil
  if not doc.intellij_untitled_backing_dirty
     and doc.intellij_untitled_last_snapshot_change_id == change_id
     and system.get_file_info(doc.intellij_untitled_backing_path) then
    log_quiet("Untitled recovery: skipped unchanged snapshot for %s", doc.intellij_untitled_name or doc.intellij_untitled_id)
    return false
  end
  local bytes = doc_text_bytes(doc)
  local ok, err = M.safe_replace_bytes(doc.intellij_untitled_backing_path, bytes)
  if not ok then
    doc.intellij_untitled_backing_dirty = true
    core.error("Untitled recovery failed for %s: %s", doc.intellij_untitled_name or "Untitled", err or "unknown error")
    return false, err
  end
  doc.intellij_untitled_backing_dirty = false
  dirty_docs[doc] = nil
  doc.intellij_untitled_backing_saved_at = os.time()
  doc.intellij_untitled_estimated_bytes = #bytes
  doc.intellij_untitled_last_snapshot_change_id = change_id
  update_manifest_entry(doc, {
    name = doc.intellij_untitled_name,
    backing = doc.intellij_untitled_backing_rel,
    crlf = doc.crlf or false,
    encoding = doc.encoding,
    language = doc.syntax and doc.syntax.name or nil,
    last_snapshot_change_id = change_id,
  })
  log_quiet("Untitled recovery: flushed %s (%s)", doc.intellij_untitled_name or doc.intellij_untitled_id, reason or "snapshot")
  return true
end

local function untitled_doc_has_recovery_content(doc)
  return doc.intellij_untitled_backing_path ~= nil
      or doc:get_text(1, 1, math.huge, math.huge) ~= ""
end

function M.flush_all(reason, force)
  local flushed = 0
  if force then
    for _, doc in ipairs(core.docs or {}) do
      if is_untitled_doc(doc) and untitled_doc_has_recovery_content(doc) then
        local ok = M.flush_doc(doc, reason, force)
        if ok then flushed = flushed + 1 end
      end
    end
  else
    for doc in pairs(dirty_docs) do
      if is_untitled_doc(doc) then
        local ok = M.flush_doc(doc, reason, false)
        if ok then flushed = flushed + 1 end
      else
        dirty_docs[doc] = nil
      end
    end
  end
  if flushed > 0 then log_quiet("Untitled recovery: flushed %d document(s) (%s)", flushed, reason or "all") end
  return flushed
end

local function pending_flush_delay(doc)
  local max_size = doc and estimate_doc_bytes(doc) or 0
  for pending_doc in pairs(dirty_docs) do
    if is_untitled_doc(pending_doc) then
      max_size = math.max(max_size, estimate_doc_bytes(pending_doc))
    end
  end
  return max_size >= cfg.large_doc_threshold and cfg.large_delay or cfg.delay
end

local function schedule_flush(doc)
  pending_generation = pending_generation + 1
  if loop_running then return end
  loop_running = true
  core.add_thread(function()
    local seen
    repeat
      seen = pending_generation
      coroutine.yield(pending_flush_delay(doc))
    until seen == pending_generation
    M.flush_all("idle")
    loop_running = false
    if seen ~= pending_generation then schedule_flush() end
  end)
end

function M.mark_dirty(doc, transaction)
  if not is_untitled_doc(doc) then return end
  M.ensure_doc_backing(doc)
  update_estimated_bytes_from_transaction(doc, transaction)
  doc.intellij_untitled_force_dirty = true
  doc.intellij_untitled_backing_dirty = true
  dirty_docs[doc] = true
  doc.intellij_untitled_pending_change_id = doc.get_change_id and doc:get_change_id() or nil
  log_quiet("Untitled recovery: queued snapshot for %s", doc.intellij_untitled_name or doc.intellij_untitled_id)
  schedule_flush(doc)
end

local function reconcile_backing(entry, paths)
  local id = sanitize_id(entry and entry.id)
  if not id then return nil end
  local primary = safe_relative_backing_abs(paths.project, entry.backing, id)
  local tmp = primary .. ".tmp"
  local bak = primary .. ".bak"
  if system.get_file_info(primary) then
    if system.get_file_info(tmp) then log_quiet("Untitled recovery: keeping primary over stale temp %s", tmp) end
    return primary
  end
  if system.get_file_info(tmp) then
    local restored, err = os.rename(tmp, primary)
    if restored then
      log_quiet("Untitled recovery: restored missing primary backing from temp %s", tmp)
      return primary
    end
    core.error("Couldn't restore untitled backing temp %s: %s", tmp, err)
    return tmp
  end
  if system.get_file_info(bak) then
    local restored, err = os.rename(bak, primary)
    if restored then
      log_quiet("Untitled recovery: restored missing primary backing from %s", bak)
      return primary
    end
    core.error("Couldn't restore untitled backing backup %s: %s", bak, err)
    return bak
  end
  return nil
end
M.reconcile_backing = reconcile_backing

local function persist_inline_recovery_doc(doc, text, reason)
  local ok, storage = pcall(require, "core.storage")
  if not ok then return false end
  local project_path = doc.intellij_untitled_project_path or current_project_path()
  local data = storage.load("untitled_recovery", project_path)
  if type(data) ~= "table" then data = {} end
  data.project = project_path
  data.saved_at = os.time()
  data.documents = type(data.documents) == "table" and data.documents or {}
  local item
  for _, candidate in ipairs(data.documents) do
    if candidate.id == doc.intellij_untitled_id then item = candidate; break end
  end
  if not item then
    item = {}
    data.documents[#data.documents + 1] = item
  end
  item.id = doc.intellij_untitled_id
  item.name = doc.intellij_untitled_name
  item.text = text or doc:get_text(1, 1, math.huge, math.huge)
  item.crlf = doc.crlf or false
  storage.save("untitled_recovery", project_path, data)
  log_quiet("Untitled recovery: wrote emergency inline recovery for %s (%s)", item.name or item.id, reason or "migration failure")
  return true
end

function M.attach_from_workspace_state(doc, state)
  if not (doc and state and state.intellij_untitled) then return end
  doc.intellij_untitled = true
  doc.intellij_untitled_name = state.intellij_untitled_name or doc.intellij_untitled_name or "Untitled"
  doc.intellij_untitled_id = sanitize_id(state.intellij_untitled_id or doc.intellij_untitled_id) or new_doc_id()
  doc.intellij_untitled_project_path = current_project_path()
  local paths = project_paths(doc.intellij_untitled_project_path)
  local manifest = load_manifest_for(paths)
  local manifest_doc = manifest_entry(manifest, doc.intellij_untitled_id)
  doc.intellij_untitled_backing_rel = (manifest_doc and manifest_doc.backing) or state.intellij_untitled_backing or backing_rel_for_id(doc.intellij_untitled_id)
  doc.intellij_untitled_backing_path, doc.intellij_untitled_backing_rel = backing_abs_for(doc.intellij_untitled_project_path, doc.intellij_untitled_id, doc.intellij_untitled_backing_rel)
  M.ensure_doc_backing(doc, { no_manifest = true })

  local entry = manifest_doc or { id = doc.intellij_untitled_id, backing = doc.intellij_untitled_backing_rel }
  local backing = reconcile_backing(entry, paths)

  if type(state.text) == "string" and state.intellij_untitled_backing_current ~= true then
    local inline_known_newer = false
    if type(state.intellij_untitled_change_id) == "number" and type(entry.last_snapshot_change_id) == "number" then
      inline_known_newer = state.intellij_untitled_change_id > entry.last_snapshot_change_id
    elseif type(state.intellij_untitled_workspace_saved_at) == "number" and type(entry.updated_at) == "number" then
      inline_known_newer = state.intellij_untitled_workspace_saved_at > entry.updated_at
    end

    if backing and manifest_doc and system.get_file_info(backing) and not inline_known_newer then
      local text = read_file(backing)
      if text then
        load_text_into_doc(doc, text, entry.crlf)
        doc.intellij_untitled_force_dirty = true
        doc.intellij_untitled_backing_dirty = false
        doc.intellij_untitled_backing_saved_at = entry.updated_at or os.time()
        doc.intellij_untitled_last_snapshot_change_id = doc:get_change_id()
        log_quiet(
          "Untitled recovery: preferred manifest backing over stale/ambiguous inline workspace text for %s",
          doc.intellij_untitled_name or doc.intellij_untitled_id
        )
        return true
      end
    end

    doc.intellij_untitled_force_dirty = true
    doc.intellij_untitled_backing_dirty = true
    local flushed = M.flush_doc(doc, "inline workspace fallback migration", true)
    if flushed then
      log_quiet("Untitled recovery: migrated inline workspace fallback for %s", doc.intellij_untitled_name or doc.intellij_untitled_id)
    else
      persist_inline_recovery_doc(doc, state.text, "inline workspace fallback migration failure")
      log_quiet("Untitled recovery: kept inline workspace text after failed stale-backing migration for %s", doc.intellij_untitled_name or doc.intellij_untitled_id)
    end
    return false
  end

  if backing and system.get_file_info(backing) then
    local text = read_file(backing)
    if text then
      load_text_into_doc(doc, text, entry.crlf)
      doc.intellij_untitled_force_dirty = true
      doc.intellij_untitled_backing_dirty = false
      doc.intellij_untitled_backing_saved_at = entry.updated_at or os.time()
      doc.intellij_untitled_last_snapshot_change_id = doc:get_change_id()
      update_manifest_entry(doc, {
        name = doc.intellij_untitled_name,
        backing = doc.intellij_untitled_backing_rel,
        crlf = doc.crlf or false,
        encoding = doc.encoding,
        language = doc.syntax and doc.syntax.name or nil,
        last_snapshot_change_id = doc.intellij_untitled_last_snapshot_change_id,
      })
      log_quiet("Untitled recovery: attached workspace doc %s from backing", doc.intellij_untitled_name or doc.intellij_untitled_id)
      return true
    end
  end

  if type(state.text) == "string" then
    doc.intellij_untitled_force_dirty = true
    doc.intellij_untitled_backing_dirty = true
    local flushed = M.flush_doc(doc, "inline workspace migration", true)
    if flushed then
      log_quiet("Untitled recovery: migrated inline workspace text for %s", doc.intellij_untitled_name or doc.intellij_untitled_id)
    else
      persist_inline_recovery_doc(doc, state.text, "inline workspace migration failure")
      log_quiet("Untitled recovery: failed to migrate inline workspace text for %s", doc.intellij_untitled_name or doc.intellij_untitled_id)
    end
    return flushed
  end
end

local function open_recovered_doc(entry, paths, backing, reason)
  local text = read_file(backing)
  if not text then return false end
  local doc = core.open_doc()
  doc.intellij_untitled = true
  doc.intellij_untitled_name = entry.name or ("Untitled-" .. tostring(entry.id):sub(1, 8))
  doc.intellij_untitled_id = sanitize_id(entry.id) or new_doc_id()
  doc.intellij_untitled_project_path = paths.project
  doc.intellij_untitled_backing_rel = entry.backing or backing_rel_for_id(doc.intellij_untitled_id)
  doc.intellij_untitled_backing_path, doc.intellij_untitled_backing_rel = backing_abs_for(paths.project, doc.intellij_untitled_id, doc.intellij_untitled_backing_rel)
  load_text_into_doc(doc, text, entry.crlf)
  doc.intellij_untitled_force_dirty = true
  doc.intellij_untitled_backing_dirty = false
  doc.intellij_untitled_backing_saved_at = entry.updated_at or os.time()
  doc.intellij_untitled_last_snapshot_change_id = doc:get_change_id()
  if backing ~= doc.intellij_untitled_backing_path then
    doc.intellij_untitled_backing_dirty = true
    M.flush_doc(doc, reason or "reconcile", true)
  end
  if core.root_panel and core.root_panel.open_doc then core.root_panel:open_doc(doc) end
  log_quiet("Untitled recovery: restored %s from %s (%s)", doc.intellij_untitled_name, backing, reason or "manifest")
  return true
end

local function open_doc_exists(id)
  for _, doc in ipairs(core.docs or {}) do
    if is_untitled_doc(doc) and doc.intellij_untitled_id == id then return true end
  end
  return false
end

local function recover_manifest_docs(project_path)
  local paths = project_paths(project_path)
  local manifest = load_manifest_for(paths)
  local restored = 0
  for _, entry in ipairs(manifest.docs or {}) do
    if entry and entry.id and not entry.explicit_closed and not open_doc_exists(entry.id) then
      local backing = reconcile_backing(entry, paths)
      if backing and open_recovered_doc(entry, paths, backing, "manifest") then restored = restored + 1 end
    end
  end
  return restored, manifest, paths
end

local function scan_orphans(manifest, paths)
  local known = {}
  local known_paths = {}
  for _, entry in ipairs(manifest.docs or {}) do
    known[entry.id] = true
    if entry.backing then
      local backing_path = safe_relative_backing_abs(paths.project, entry.backing, entry.id)
      known_paths[backing_path] = true
      known_paths[backing_path .. ".bak"] = true
      known_paths[backing_path .. ".tmp"] = true
    end
  end
  for _, doc in ipairs(core.docs or {}) do
    if is_untitled_doc(doc) and doc.intellij_untitled_id then
      known[doc.intellij_untitled_id] = true
      if doc.intellij_untitled_project_path == paths.project and doc.intellij_untitled_backing_path then
        known_paths[doc.intellij_untitled_backing_path] = true
        known_paths[doc.intellij_untitled_backing_path .. ".bak"] = true
        known_paths[doc.intellij_untitled_backing_path .. ".tmp"] = true
      end
    end
  end
  local candidates = {}
  for _, item in ipairs(system.list_dir(paths.docs) or {}) do
    local id, kind = item:match("^(.+)%.txt$"), "primary"
    if not id then id, kind = item:match("^(.+)%.txt%.bak$"), "backup" end
    if not id then id, kind = item:match("^(.+)%.txt%.tmp$"), "temp" end
    id = sanitize_id(id)
    local path = paths.docs .. PATHSEP .. item
    if id and not known[id] and not known_paths[path] then
      local group = candidates[id] or { id = id }
      group[kind] = path
      candidates[id] = group
    end
  end

  local ids = {}
  for id in pairs(candidates) do ids[#ids + 1] = id end
  table.sort(ids)

  local adopted = 0
  for _, id in ipairs(ids) do
    local group = candidates[id]
    local path = group.primary or group.backup or group.temp
    if path then
      local entry = {
        id = id,
        name = "Recovered-" .. tostring(id):sub(1, 8),
        backing = backing_rel_for_id(id),
        crlf = false,
        created_at = os.time(),
        updated_at = os.time(),
        explicit_closed = false,
      }
      if open_recovered_doc(entry, paths, path, "orphan") then
        manifest.docs[#manifest.docs + 1] = entry
        known[entry.id] = true
        adopted = adopted + 1
      end
    end
  end
  return adopted
end

local function restore_old_inline_storage(project_path)
  local ok, storage = pcall(require, "core.storage")
  if not ok then return 0 end
  local data = storage.load("untitled_recovery", project_path)
  if type(data) ~= "table" or type(data.documents) ~= "table" then return 0 end
  local restored = 0
  local failed = false
  for _, item in ipairs(data.documents) do
    if type(item) == "table" and type(item.text) == "string" then
      local existing_doc
      for _, doc in ipairs(core.docs or {}) do
        if is_untitled_doc(doc) and (doc.intellij_untitled_id == item.id
           or (doc.intellij_untitled_name == item.name and doc:get_text(1, 1, math.huge, math.huge) == item.text)) then
          existing_doc = doc
          break
        end
      end

      if existing_doc then
        local existing_text = existing_doc:get_text(1, 1, math.huge, math.huge)
        if existing_text ~= item.text then
          -- Workspace/manifest recovery has already produced an open document for
          -- this id.  Legacy inline blobs have no reliable per-document
          -- generation, so never let them overwrite newer open state; migrate the
          -- open document's current content to a backing file and clear the stale
          -- legacy blob once that succeeds.
          log_quiet(
            "Untitled recovery: ignored conflicting legacy inline text for already-open %s",
            existing_doc.intellij_untitled_name or existing_doc.intellij_untitled_id
          )
        end
        existing_doc.intellij_untitled_project_path = existing_doc.intellij_untitled_project_path or project_path
        existing_doc.intellij_untitled_force_dirty = true
        if not M.doc_backing_current(existing_doc) then
          M.ensure_doc_backing(existing_doc)
          existing_doc.intellij_untitled_backing_dirty = true
          local flushed = M.flush_doc(existing_doc, "old inline recovery existing-doc migration", true)
          if not flushed or not M.doc_backing_current(existing_doc) then failed = true end
        end
      else
        local doc = core.open_doc()
        doc.intellij_untitled = true
        doc.intellij_untitled_name = item.name or "Untitled"
        doc.intellij_untitled_id = sanitize_id(item.id) or new_doc_id()
        doc.intellij_untitled_project_path = project_path
        doc.crlf = item.crlf or false
        load_text_into_doc(doc, item.text, item.crlf)
        doc.intellij_untitled_force_dirty = true
        M.ensure_doc_backing(doc)
        local flushed = M.flush_doc(doc, "old inline recovery migration", true)
        if flushed and M.doc_backing_current(doc) then
          if core.root_panel and core.root_panel.open_doc then core.root_panel:open_doc(doc) end
          restored = restored + 1
        else
          failed = true
        end
      end
    end
  end
  if not failed then
    storage.clear("untitled_recovery", project_path)
    log_quiet("Untitled recovery: cleared migrated legacy inline recovery for %s", project_path)
  end
  if restored > 0 then log_quiet("Untitled recovery: migrated %d old inline recovery document(s)", restored) end
  return restored
end

function M.restore_project(project_path)
  project_path = project_path or current_project_path()
  local restored, manifest, paths = recover_manifest_docs(project_path)
  local adopted = scan_orphans(manifest, paths)
  if adopted > 0 then write_manifest_for(paths, manifest) end
  local migrated = restore_old_inline_storage(project_path)
  if restored > 0 or adopted > 0 or migrated > 0 then
    log_quiet("Untitled recovery: startup restored=%d adopted=%d migrated=%d for %s", restored, adopted, migrated, project_path)
  end
  return restored + adopted + migrated
end

local function remove_manifest_entry(project_path, id)
  local paths = project_paths(project_path)
  local manifest = load_manifest_for(paths)
  local kept = {}
  for _, entry in ipairs(manifest.docs or {}) do
    if entry.id ~= id then kept[#kept + 1] = entry end
  end
  manifest.docs = kept
  write_manifest_for(paths, manifest)
end

local function mark_manifest_explicit_closed(project_path, id, name, backing)
  local paths = project_paths(project_path)
  local manifest = load_manifest_for(paths)
  manifest.docs = manifest.docs or {}
  local entry = manifest_entry(manifest, id)
  if not entry then
    entry = { id = id }
    manifest.docs[#manifest.docs + 1] = entry
  end
  entry.name = entry.name or name or "Untitled"
  entry.backing = entry.backing or backing or backing_rel_for_id(id)
  entry.explicit_closed = true
  entry.updated_at = os.time()
  write_manifest_for(paths, manifest)
end

local function backing_family(path)
  if not path then return {} end
  return { path, path .. ".bak", path .. ".tmp" }
end

local function delete_backing_family(path)
  local ok = true
  for _, candidate in ipairs(backing_family(path)) do
    if system.get_file_info(candidate) then
      local removed, err = os.remove(candidate)
      if removed then
        log_quiet("Untitled recovery: deleted backing file %s", candidate)
      else
        ok = false
        core.error("Couldn't delete untitled backing file %s: %s", candidate, err)
      end
    end
  end
  return ok
end

local function quarantine_file(path, id)
  local stamp = tostring(os.time())
  local dir = TRASH_DIR .. PATHSEP .. stamp
  local moved_any = false
  for _, candidate in ipairs(backing_family(path)) do
    if system.get_file_info(candidate) then
      ensure_dir(dir)
      local suffix = candidate:sub(#path + 1)
      local dst = dir .. PATHSEP .. (sanitize_id(id) or common.basename(path)) .. ".txt" .. suffix
      local moved, err = os.rename(candidate, dst)
      if moved then
        moved_any = true
        log_quiet("Untitled recovery: quarantined discarded backing %s to %s", candidate, dst)
      else
        core.error("Couldn't quarantine untitled backing %s: %s", candidate, err)
        return false, err
      end
    end
  end
  return true, moved_any
end

function M.handle_save_as_success(doc, old)
  old = old or {}
  local path = old.backing_path or doc.intellij_untitled_backing_path
  local id = old.id or doc.intellij_untitled_id
  local project = old.project or doc.intellij_untitled_project_path or current_project_path()
  local cleaned = not path or delete_backing_family(path)
  if id then
    if cleaned then
      remove_manifest_entry(project, id)
    else
      mark_manifest_explicit_closed(project, id, old.name, old.backing_rel)
    end
  end
  return cleaned
end

function M.handle_confirmed_discard(doc)
  if not is_untitled_doc(doc) then return end
  M.ensure_doc_backing(doc)
  local id = doc.intellij_untitled_id
  local path = doc.intellij_untitled_backing_path
  local project = doc.intellij_untitled_project_path or current_project_path()
  doc.intellij_untitled_discarded = true
  doc.intellij_untitled_backing_dirty = false
  dirty_docs[doc] = nil
  local quarantined = quarantine_file(path, id)
  if quarantined then
    remove_manifest_entry(project, id)
  else
    mark_manifest_explicit_closed(project, id, doc.intellij_untitled_name, doc.intellij_untitled_backing_rel)
  end
  doc.intellij_untitled = nil
  doc.intellij_untitled_name = nil
  doc.intellij_untitled_id = nil
  doc.intellij_untitled_backing_path = nil
  doc.intellij_untitled_backing_rel = nil
  doc.intellij_untitled_backing_saved_at = nil
  doc.intellij_untitled_force_dirty = nil
  doc.intellij_untitled_project_path = nil
end

if not core.__untitled_recovery_patched then
  core.__untitled_recovery_patched = true

  local doc_is_dirty = Doc.is_dirty
  function Doc:is_dirty(...)
    if is_untitled_doc(self) and self.intellij_untitled_force_dirty then return true end
    return doc_is_dirty(self, ...)
  end

  local on_text_change = Doc.on_text_change
  function Doc:on_text_change(type, transaction, ...)
    local result = on_text_change(self, type, transaction, ...)
    if is_untitled_doc(self) then M.mark_dirty(self, transaction) end
    return result
  end

  local core_set_active_view = core.set_active_view
  function core.set_active_view(view)
    local previous = core.active_view
    local previous_doc = previous and previous.doc
    local result = core_set_active_view(view)
    local next_doc = core.active_view and core.active_view.doc
    if previous_doc and previous_doc ~= next_doc and is_untitled_doc(previous_doc) and previous_doc.intellij_untitled_backing_dirty then
      M.flush_doc(previous_doc, "document focus lost", true)
    end
    return result
  end

  local core_exit = core.exit
  function core.exit(quit_fn, force)
    M.flush_all("exit", true)
    return core_exit(quit_fn, force)
  end

  local core_set_project = core.set_project
  function core.set_project(project)
    M.flush_all("project switch", true)
    return core_set_project(project)
  end
end

return M
