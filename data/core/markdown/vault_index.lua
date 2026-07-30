local core = require "core"
local common = require "core.common"
local config = require "core.config"
local DirWatch = require "core.dirwatch"
local json = require "core.json"
local anchors = require "core.markdown.anchors"
local links = require "core.markdown.links"
local parser = require "core.markdown.parser"
local worker_pool = require "core.worker_pool"

local vault_index = {}

local MARKDOWN_EXTENSION_LIST = { "md", "markdown", "mdown" }
local MARKDOWN_EXTENSIONS = {}
for _, ext in ipairs(MARKDOWN_EXTENSION_LIST) do MARKDOWN_EXTENSIONS[ext] = true end

local MAX_COOPERATIVE_NOTE_BYTES = 512 * 1024
local DOC_UPDATE_DEBOUNCE_SECONDS = 0.03
local MAX_NATIVE_WATCH_DIRS = 2048

local ATTACHMENT_EXTENSIONS = {
  ["3gp"] = true,
  avif = true,
  base = true,
  bmp = true,
  canvas = true,
  gif = true,
  jpeg = true,
  jpg = true,
  m4a = true,
  mkv = true,
  png = true,
  svg = true,
  webp = true,
  mp3 = true,
  wav = true,
  flac = true,
  ogg = true,
  mp4 = true,
  webm = true,
  mov = true,
  ogv = true,
  pdf = true,
}

local indexes_by_root = {}
local link_path_policies = {}
local pending_renames = {}
local doc_hooks_installed = false

local function trim(text)
  text = text or ""
  local first = text:find("%S")
  if not first then return "" end
  local _, last = text:find("^.*%S")
  return text:sub(first, last)
end

local function extension(path)
  return (path or ""):match("%.([^.\\/]+)$") and (path or ""):match("%.([^.\\/]+)$"):lower() or nil
end

local function strip_markdown_extension(path)
  return (path:gsub("%.md$", ""):gsub("%.markdown$", ""):gsub("%.mdown$", ""))
end

local function strip_target_fragment(target)
  return (target or ""):match("^[^#?]+") or (target or "")
end

local function path_key(path)
  return common.path_compare_key(common.normalize_path(path))
end

local function display_path(path)
  return (path or ""):gsub("[/\\]", "/")
end

local function display_basename(path)
  return display_path(path):match("[^/]+$") or path
end

local function join_path(a, b)
  if not a or a == "" then return b end
  if a:sub(-1) == PATHSEP then return a .. b end
  return a .. PATHSEP .. b
end

local function absolute_path(path)
  return path and (system.absolute_path(path) or common.normalize_path(path))
end

local function file_exists(path)
  local info = path and system.get_file_info(path)
  return info and info.type == "file"
end

local function read_file(path)
  local fp = io.open(path, "rb")
  if not fp then return nil end
  local text = fp:read("*a")
  fp:close()
  return text
end

local function is_markdown(path)
  return MARKDOWN_EXTENSIONS[extension(path) or ""] == true
end

local function note_entry_for_explicit_path(index, abs)
  local entry = index:note(abs)
  if entry then return entry end
  if extension(abs) then return nil end
  for _, ext in ipairs(MARKDOWN_EXTENSION_LIST) do
    entry = index:note(abs .. "." .. ext)
    if entry then return entry end
  end
end

local function is_attachment(path)
  return ATTACHMENT_EXTENSIONS[extension(path) or ""] == true
end

local function read_obsidian_app_settings(root)
  local path = join_path(join_path(root, ".obsidian"), "app.json")
  local text = read_file(path)
  if not text then return {} end
  local ok, decoded, decode_err = pcall(json.decode, text)
  if not ok or type(decoded) ~= "table" then
    core.log_quiet("Markdown ignored malformed Obsidian app settings in %s: %s",
      path, tostring(ok and decode_err or decoded))
    return {}
  end
  return decoded
end

local function add_to_multi(map, key, value)
  if not key or key == "" then return end
  local item = map[key]
  if not item then
    map[key] = value
  elseif item == value then
    return
  elseif item[1] then
    for _, existing in ipairs(item) do
      if existing == value then return end
    end
    item[#item + 1] = value
  else
    map[key] = { item, value }
  end
end

local function remove_from_multi(map, key, value)
  local item = map[key]
  if not item then return end
  if item == value then
    map[key] = nil
  elseif item[1] then
    for i = #item, 1, -1 do
      if item[i] == value then table.remove(item, i) end
    end
    if #item == 0 then
      map[key] = nil
    elseif #item == 1 then
      map[key] = item[1]
    end
  end
end

local function add_unique(items, seen, key)
  if key and key ~= "" and not seen[key] then
    seen[key] = true
    items[#items + 1] = key
  end
end

local function unique_item(item)
  if not item then return nil end
  if item[1] then
    if #item == 1 then return item[1] end
    return nil, item
  end
  return item
end

local Index = {}
Index.__index = Index

function Index:new(root)
  local obsidian_settings = read_obsidian_app_settings(root)
  return setmetatable({
    root = common.normalize_path(root),
    link_path_policy = link_path_policies[path_key(root)] or config.markdown_live_link_path_policy
      or "shortest_unique",
    generation = 0,
    status = "cold",
    reason = "not indexed",
    rebuild_serial = 0,
    listeners = {},
    notes_by_abs = {},
    attachments_by_abs = {},
    note_keys = {},
    note_keys_ci = {},
    attachment_keys = {},
    attachment_keys_ci = {},
    doc_listeners = setmetatable({}, { __mode = "k" }),
    doc_overlays = setmetatable({}, { __mode = "k" }),
    doc_overlay_jobs = setmetatable({}, { __mode = "k" }),
    consumers = {},
    watcher = nil,
    watcher_serial = 0,
    watched_dirs = {},
    pending_watch_dirs = {},
    pending_scan_dirs = {},
    subtree_scan_running = false,
    doc_update_serials = setmetatable({}, { __mode = "k" }),
    doc_overlay_serials = setmetatable({}, { __mode = "k" }),
    watch_dir_limit = MAX_NATIVE_WATCH_DIRS,
    watch_dir_count = 0,
    watcher_mode = "stopped",
    show_unsupported_files = obsidian_settings.showUnsupportedFiles == true,
    diagnostics = {
      doc_updates = 0,
      doc_updates_coalesced = 0,
      degraded_rescans = 0,
      last_rebuild = nil,
    },
    removed_paths = {},
  }, self)
end

function Index:refresh_obsidian_settings()
  local settings = read_obsidian_app_settings(self.root)
  self.show_unsupported_files = settings.showUnsupportedFiles == true
end

function Index:is_attachment(path)
  return is_attachment(path) or (self.show_unsupported_files and not is_markdown(path))
end

function Index:add_listener(id, fn)
  assert(type(id) == "string" and id ~= "", "Markdown index listener id is required")
  assert(type(fn) == "function", "Markdown index listener must be a function")
  self.listeners[id] = fn
end

function Index:remove_listener(id)
  if not self.listeners[id] then return false end
  self.listeners[id] = nil
  return true
end

function Index:notify(reason, detail)
  for id, fn in pairs(self.listeners) do
    local ok, err = pcall(fn, self, reason, detail)
    if not ok then core.log_quiet("Markdown index listener %s failed: %s", id, tostring(err)) end
  end
end

function Index:relative_path(path)
  return display_path(common.relative_path(self.root, common.normalize_path(path)))
end

function Index:clear()
  self.notes_by_abs = {}
  self.attachments_by_abs = {}
  self.note_keys = {}
  self.note_keys_ci = {}
  self.attachment_keys = {}
  self.attachment_keys_ci = {}
end

local function release_vault_snapshot(snapshot)
  if not snapshot then return end
  local pool = worker_pool.current_system()
  if not pool then snapshot:close(); return end
  local handle = pool:submit {
    kind = "markdown-vault-snapshot-release",
    priority = "background",
    native = true,
    native_kind = "markdown_vault_snapshot_release",
    native_payload = { release_markdown_vault_snapshot = snapshot },
  }
  if not handle then snapshot:close() end
end

function Index:note(path)
  if type(path) ~= "string" or path == "" then return nil end
  local absolute = common.is_absolute_path(path) and path or join_path(self.root, path)
  absolute = common.normalize_path(absolute)
  if self.removed_paths[path_key(absolute)] then return nil end
  local overlay = self.notes_by_abs[path_key(absolute)]
  if overlay then return overlay end
  return self.disk_snapshot and self.disk_snapshot:note(absolute) or nil
end

function Index:attachment(path)
  if type(path) ~= "string" or path == "" then return nil end
  local absolute = common.is_absolute_path(path) and path or join_path(self.root, path)
  absolute = common.normalize_path(absolute)
  return self.attachments_by_abs[path_key(absolute)]
    or (self.disk_snapshot and self.disk_snapshot:attachment(absolute))
end

function Index:remove_path_entry(path)
  local key = path_key(path)
  local note = self.notes_by_abs[key]
  if note then
    for _, item_key in ipairs(note.note_keys or {}) do
      remove_from_multi(self.note_keys, item_key, note)
    end
    for _, item_key in ipairs(note.note_keys_ci or {}) do
      remove_from_multi(self.note_keys_ci, item_key, note)
    end
    self.notes_by_abs[key] = nil
  end

  local attachment = self.attachments_by_abs[key]
  if attachment then
    for _, item_key in ipairs(attachment.attachment_keys or {}) do
      remove_from_multi(self.attachment_keys, item_key, attachment)
    end
    for _, item_key in ipairs(attachment.attachment_keys_ci or {}) do
      remove_from_multi(self.attachment_keys_ci, item_key, attachment)
    end
    self.attachments_by_abs[key] = nil
  end
  return note or attachment
end

function Index:add_note_entry(entry)
  local abs_key = path_key(entry.abs_path)
  self:remove_path_entry(entry.abs_path)
  self.notes_by_abs[abs_key] = entry

  local keys, seen = {}, {}
  local rel = entry.rel_path
  local rel_no_ext = strip_markdown_extension(rel)
  local base = display_basename(rel_no_ext)
  for _, key in ipairs({ rel, rel_no_ext, base, entry.display_name }) do
    add_unique(keys, seen, key)
  end
  for _, alias in ipairs(entry.aliases or {}) do
    add_unique(keys, seen, alias)
  end

  entry.note_keys = keys
  entry.note_keys_ci = {}
  local seen_ci = {}
  for _, key in ipairs(keys) do
    add_to_multi(self.note_keys, key, entry)
    add_unique(entry.note_keys_ci, seen_ci, key:lower())
  end
  for _, key in ipairs(entry.note_keys_ci) do
    add_to_multi(self.note_keys_ci, key, entry)
  end
end

function Index:add_attachment_entry(entry)
  local abs_key = path_key(entry.abs_path)
  self:remove_path_entry(entry.abs_path)
  self.attachments_by_abs[abs_key] = entry
  local rel = entry.rel_path
  local base = display_basename(rel)
  local keys, seen = {}, {}
  for _, key in ipairs({ rel, base }) do
    add_unique(keys, seen, key)
  end
  entry.attachment_keys = keys
  entry.attachment_keys_ci = {}
  local seen_ci = {}
  for _, key in ipairs(keys) do
    add_to_multi(self.attachment_keys, key, entry)
    add_unique(entry.attachment_keys_ci, seen_ci, key:lower())
  end
  for _, key in ipairs(entry.attachment_keys_ci) do
    add_to_multi(self.attachment_keys_ci, key, entry)
  end
end

function Index:remove_path(path)
  local existing = self:note(path) or self:attachment(path)
  local removed = self:remove_path_entry(path)
  if existing then
    self.removed_paths[path_key(path)] = { path = common.normalize_path(path), serial = self.rebuild_serial }
  end
  if removed or existing then
    self.generation = self.generation + 1
    self:notify("path-removed", path)
    return true
  end
  return false
end

function Index:watch_dir(dir)
  if not self.watcher or self.watched_dirs[dir] then return false end
  local info = system.get_file_info(dir)
  if not (info and info.type == "dir") then return false end
  local monitor = self.watcher.monitor
  if monitor and monitor.mode and monitor:mode() == "single" and next(self.watched_dirs) then
    return true
  end
  if self.watch_dir_count >= self.watch_dir_limit then
    if self.watcher_mode ~= "degraded" then
      self.watcher_mode = "degraded"
      core.log_quiet(
        "Markdown index watcher budget exhausted for %s after %d directories; enabling bounded rescans",
        self.root, self.watch_dir_count
      )
    end
    return false
  end
  self.watcher:watch(dir)
  self.watched_dirs[dir] = true
  self.watch_dir_count = self.watch_dir_count + 1
  if self.watcher.scanned and self.watcher.scanned[dir] then self.watcher_mode = "degraded" end
  return true
end

function Index:rebuild(reason, opts)
  opts = opts or {}
  self:rebuild_async(reason or "manual")
  local serial = self.rebuild_serial
  while self.status == "indexing" and self.rebuild_serial == serial do
    coroutine.yield(0.001)
  end
  if opts.skip_path and self.status == "ready" then self:remove_path_entry(opts.skip_path) end
  return self
end

function Index:queue_subtree_scan(dirs, reason)
  for _, dir in ipairs(dirs or {}) do self.pending_scan_dirs[dir] = true end
  self.pending_scan_dirs = {}
  return self:rebuild_async(reason or "watch-subtree")
end

function Index:reconcile_dir(dir, reason, opts)
  opts = opts or {}
  local ok, normalized = pcall(common.normalize_path, dir)
  if not ok or not normalized or (
    path_key(normalized) ~= path_key(self.root)
    and not common.path_belongs_to(normalized, self.root)
  ) then return false end
  if opts.cooperative then self:rebuild_async(reason or "watch")
  else self:rebuild(reason or "filesystem-reconcile") end
  return true
end

function Index:start_watcher()
  if self.watcher then return false end
  local ok, watcher = pcall(DirWatch)
  if not ok then
    core.log_quiet("Markdown index filesystem watcher unavailable for %s: %s", self.root, tostring(watcher))
    return false
  end
  self.watcher = watcher
  self.watcher_mode = "native"
  self.watch_dir_count = 0
  self.watcher_serial = self.watcher_serial + 1
  local serial = self.watcher_serial
  self:watch_dir(self.root)
  core.add_thread(function()
    local next_degraded_rescan = system.get_time() + 5
    while self.watcher == watcher and self.watcher_serial == serial do
      local checked, err = pcall(watcher.check, watcher, function(path)
        self.pending_watch_dirs[path] = true
      end)
      if not checked then
        core.log_quiet("Markdown index filesystem watcher failed for %s: %s", self.root, tostring(err))
      end
      local pending = self.pending_watch_dirs
      self.pending_watch_dirs = {}
      for path in pairs(pending) do
        if self.watcher ~= watcher or self.watcher_serial ~= serial then return end
        local reconciled, reconcile_err = pcall(
          self.reconcile_dir, self, path, "watch", { cooperative = true }
        )
        if not reconciled then
          core.log_quiet("Markdown index filesystem reconciliation failed for %s: %s", tostring(path), tostring(reconcile_err))
        end
        coroutine.yield(0)
      end
      if self.watcher_mode == "degraded" and system.get_time() >= next_degraded_rescan then
        self.diagnostics.degraded_rescans = self.diagnostics.degraded_rescans + 1
        self:queue_subtree_scan({ self.root }, "watcher-degraded")
        next_degraded_rescan = system.get_time() + 5
      end
      coroutine.yield(0.2)
    end
  end)
  core.log_quiet("Markdown index started filesystem watcher for %s", self.root)
  return true
end

function Index:stop_watcher()
  local watcher = self.watcher
  if not watcher then return false end
  self.watcher = nil
  self.watcher_serial = self.watcher_serial + 1
  for dir in pairs(self.watched_dirs) do pcall(watcher.unwatch, watcher, dir) end
  self.watched_dirs = {}
  self.watch_dir_count = 0
  self.watcher_mode = "stopped"
  self.pending_watch_dirs = {}
  self.pending_scan_dirs = {}
  self.subtree_scan_running = false
  core.log_quiet("Markdown index stopped filesystem watcher for %s", self.root)
  return true
end

function Index:acquire(id)
  if self.consumers[id] then return false end
  self.consumers[id] = true
  self:start_watcher()
  return true
end

function Index:release(id)
  if not self.consumers[id] then return false end
  self.consumers[id] = nil
  if not next(self.consumers) then self:stop_watcher() end
  return true
end

function Index:ensure(reason)
  if self.status == "ready" then return true end
  if self.status == "indexing" then return false end
  return self:rebuild_async(reason or "first-use")
end

function Index:rebuild_async(reason)
  local started_at = system.get_time()
  local rebuild_reason = reason or "async-rebuild"
  if self.manifest_job then
    self.pending_manifest_reason = rebuild_reason
    core.log_quiet("Markdown vault index coalesced native manifest request: root=%s reason=%s",
      self.root, rebuild_reason)
    return false
  end
  self:refresh_obsidian_settings()
  self.rebuild_serial = self.rebuild_serial + 1
  local serial = self.rebuild_serial
  self.status, self.reason = "indexing", rebuild_reason
  self:notify("indexing")
  core.log_quiet(
    "Markdown vault index scheduled native manifest: root=%s generation=%d reason=%s",
    self.root, serial,
    rebuild_reason
  )

  local pool = worker_pool.system()
  local function finish_error(message)
    if serial ~= self.rebuild_serial then return end
    self.manifest_job = nil
    self.vault_job = nil
    self.status, self.reason = "error", tostring(message and (message.error or message) or "manifest failed")
    self:notify("error", self.reason)
    core.log_quiet("Markdown native manifest failed: root=%s generation=%d error=%s",
      self.root, serial, self.reason)
  end

  local handle, submit_error = pool:submit {
    kind = "markdown-project-file-manifest",
    generation = serial,
    phase = "manifest",
    priority = "background",
    native = true,
    native_kind = "project_file_manifest",
    native_payload = {
      project_root = self.root,
      show_unsupported_files = self.show_unsupported_files,
    },
    is_stale = function() return serial ~= self.rebuild_serial end,
    on_stale = function(message)
      local manifest = message.manifest or (message.payload and message.payload.manifest)
      if manifest then manifest:close() end
    end,
    on_error = finish_error,
    on_cancelled = function(message)
      if serial == self.rebuild_serial then finish_error(message or "cancelled") end
    end,
    on_result = function(message)
      local manifest = message.manifest or (message.payload and message.payload.manifest)
      if not manifest and message.type == "final" then return end
      if not manifest then return finish_error("native manifest result missing snapshot") end
      self.manifest_job = nil
      if serial ~= self.rebuild_serial then manifest:close(); return end
      local manifest_summary = manifest:summary()
      local vault_handle, vault_error = pool:submit {
        kind = "markdown-vault-index",
        generation = serial,
        phase = "vault",
        priority = "background",
        native = true,
        native_kind = "markdown_vault_index",
        native_payload = {
          manifest = manifest,
          previous_vault_snapshot = self.disk_snapshot,
          shallow_note_bytes = MAX_COOPERATIVE_NOTE_BYTES,
        },
        is_stale = function() return serial ~= self.rebuild_serial end,
        on_stale = function(vault_message)
          local snapshot = vault_message.vault_snapshot or (vault_message.payload and vault_message.payload.vault_snapshot)
          if snapshot then release_vault_snapshot(snapshot) end
        end,
        on_error = function(vault_message) manifest:close(); finish_error(vault_message) end,
        on_cancelled = function(vault_message) manifest:close(); finish_error(vault_message or "cancelled") end,
        on_result = function(vault_message)
          local snapshot = vault_message.vault_snapshot or (vault_message.payload and vault_message.payload.vault_snapshot)
          if not snapshot and vault_message.type == "final" then return end
          if not snapshot then manifest:close(); return finish_error("native vault result missing snapshot") end
          if serial ~= self.rebuild_serial then manifest:close(); release_vault_snapshot(snapshot); return end
          self.vault_job = nil
          local overlays = {}
          for _, entry in pairs(self.notes_by_abs) do if entry.doc then overlays[#overlays + 1] = entry end end
          self.notes_by_abs, self.attachments_by_abs = {}, {}
          self.note_keys, self.note_keys_ci = {}, {}
          self.attachment_keys, self.attachment_keys_ci = {}, {}
          for _, entry in ipairs(overlays) do self:add_note_entry(entry) end
          release_vault_snapshot(self.disk_snapshot)
          self.disk_snapshot = snapshot
          for key, removed in pairs(self.removed_paths) do
            if serial > (removed.serial or 0)
              and (snapshot:note(removed.path) or snapshot:attachment(removed.path))
            then
              self.removed_paths[key] = nil
            end
          end
          if self.manifest_snapshot then self.manifest_snapshot:close() end
          self.manifest_snapshot = manifest
          self.status, self.reason = "ready", nil
          self.generation = self.generation + 1
          self:notify("ready")
          core.redraw = true
          local vault_summary = snapshot:summary()
          local elapsed_ms = (system.get_time() - started_at) * 1000
          self.diagnostics.last_rebuild = {
            reason = rebuild_reason,
            elapsed_ms = elapsed_ms,
            directories = manifest_summary.directories + 1,
            files = manifest_summary.files,
            notes = self:note_count(),
            attachments = self:attachment_count(),
            cooperative = true,
            native_manifest = true,
            native_vault = true,
            manifest_ms = manifest_summary.scan_ms,
            vault_ms = vault_summary.build_ms,
            bytes_read = vault_summary.bytes_read,
            notes_reused = vault_summary.reused_notes,
            notes_rebuilt = vault_summary.rebuilt_notes,
          }
          core.log_quiet(
            "Markdown vault native snapshot published: root=%s generation=%d elapsed=%.1fms manifest=%.1fms vault=%.1fms notes=%d attachments=%d reused=%d rebuilt=%d bytes=%d",
            self.root, serial, elapsed_ms, manifest_summary.scan_ms, vault_summary.build_ms,
            self:note_count(), self:attachment_count(), vault_summary.reused_notes,
            vault_summary.rebuilt_notes, vault_summary.bytes_read
          )
          local pending = self.pending_manifest_reason
          self.pending_manifest_reason = nil
          if pending then self:rebuild_async(pending) end
        end,
      }
      if not vault_handle then manifest:close(); finish_error(vault_error or "native vault submission failed")
      else self.vault_job = vault_handle end
    end,
  }
  if not handle then
    finish_error(submit_error or "native manifest submission failed")
  else
    self.manifest_job = handle
  end
  return false
end

function Index:note_count()
  local count = self.disk_snapshot and self.disk_snapshot:summary().note_count or 0
  for _, entry in pairs(self.notes_by_abs) do
    if not (self.disk_snapshot and self.disk_snapshot:note(entry.abs_path)) then count = count + 1 end
  end
  return count
end

function Index:attachment_count()
  local count = self.disk_snapshot and self.disk_snapshot:summary().attachment_count or 0
  for _, entry in pairs(self.attachments_by_abs) do
    if not (self.disk_snapshot and self.disk_snapshot:attachment(entry.abs_path)) then count = count + 1 end
  end
  return count
end

local LINK_PATH_POLICIES = {
  shortest_unique = true,
  relative = true,
  root = true,
}

function Index:set_link_path_policy(policy)
  assert(LINK_PATH_POLICIES[policy], "invalid Markdown link path policy: " .. tostring(policy))
  if self.link_path_policy == policy then return false end
  self.link_path_policy = policy
  link_path_policies[path_key(self.root)] = policy
  self.generation = self.generation + 1
  self:notify("link-path-policy", policy)
  return true
end

local function canonical_note_target(index, entry, source_path)
  local rel_no_ext = strip_markdown_extension(entry.rel_path)
  if index.link_path_policy == "root" then return rel_no_ext end
  if index.link_path_policy == "relative" and source_path then
    local relative = strip_markdown_extension(display_path(
      common.relative_path(common.dirname(source_path), entry.abs_path)
    ))
    if not relative:find("/", 1, true) then relative = "./" .. relative end
    return relative
  end
  local base = display_basename(rel_no_ext)
  for _, target in ipairs({ base, rel_no_ext, entry.rel_path }) do
    local unique = unique_item(index.note_keys[target])
    if unique == entry then return target end
  end
  return entry.rel_path
end

local function rename_note_target(index, old_entry, new_path, source_path)
  local rel = index:relative_path(new_path)
  local replacement = {
    abs_path = common.normalize_path(new_path),
    rel_path = rel,
    display_name = display_basename(strip_markdown_extension(rel)),
  }
  if index.link_path_policy == "root" then return strip_markdown_extension(rel) end
  if index.link_path_policy == "relative" then
    local relative = strip_markdown_extension(display_path(
      common.relative_path(common.dirname(source_path), replacement.abs_path)
    ))
    return relative:find("/", 1, true) and relative or "./" .. relative
  end
  local base = replacement.display_name
  local existing = index.note_keys[base]
  local unique = unique_item(existing)
  if not existing or unique == old_entry then return base end
  return strip_markdown_extension(rel)
end

local function subtarget_suffix(link)
  local raw_target = link and link.raw_target or ""
  local query = raw_target:match("(%?[^#]*)") or ""
  local subtarget = link and link.subtarget
  if not subtarget then return query end
  if subtarget.type == "block" then return query .. "#^" .. (subtarget.id or "") end
  return query .. "#" .. (subtarget.text or "")
end

local function target_edit_for_link(line_text, link, target)
  local col1, col2 = link.source_col1, link.source_col2
  local source = line_text:sub(col1, col2 - 1)
  if link.kind == "wiki" or link.kind == "embed" then
    local opener = link.kind == "embed" and 3 or 2
    local close = source:find("]]", opener + 1, true)
    if not close then return nil end
    local pipe = source:find("|", opener + 1, true)
    local finish = pipe and pipe - 1 or close - 1
    local raw = source:sub(opener + 1, finish)
    local leading = #(raw:match("^%s*") or "")
    local trailing = #(raw:match("%s*$") or "")
    local edit = {
      line1 = link.source_line, line2 = link.source_line,
      col1 = col1 + opener + leading,
      col2 = col1 + opener + #raw - trailing,
      text = target,
    }
    edit.expected_text = line_text:sub(edit.col1, edit.col2 - 1)
    return edit
  elseif link.kind == "markdown" or link.kind == "image" then
    local destination_open = source:find("](", 1, true)
    if not destination_open then return nil end
    local search_start = col1 + destination_open + 1
    local raw_target = link.raw_target or ""
    local found = line_text:find(raw_target, search_start, true)
    if not found or found >= col2 then return nil end
    if target:find("%s") and line_text:sub(found - 1, found - 1) ~= "<" then
      target = "<" .. target .. ">"
    end
    local edit = {
      line1 = link.source_line, line2 = link.source_line,
      col1 = found, col2 = found + #raw_target, text = target,
    }
    edit.expected_text = line_text:sub(edit.col1, edit.col2 - 1)
    return edit
  end
end

function Index:plan_note_rename(old_path, new_path)
  old_path, new_path = absolute_path(old_path), absolute_path(new_path)
  if not (old_path and new_path and is_markdown(old_path) and is_markdown(new_path)) then return nil end
  local old_entry = self:note(old_path)
  if not old_entry then return nil end
  local files = {}
  local entries, seen_entries = {}, {}
  for _, entry in pairs(self.notes_by_abs) do
    entries[#entries + 1] = entry
    seen_entries[path_key(entry.abs_path)] = true
  end
  for _, entry in ipairs(self.disk_snapshot and self.disk_snapshot:linked_notes(old_path) or {}) do
    if not seen_entries[path_key(entry.abs_path)] then entries[#entries + 1] = entry end
  end
  for _, entry in ipairs(entries) do
    local source_path = common.path_equals(entry.abs_path, old_path) and new_path or entry.abs_path
    local text = entry.doc and entry.doc:get_text(1, 1, math.huge, math.huge) or read_file(entry.abs_path)
    if text then
      local lines = parser.split_lines(text)
      local edits = {}
      for _, link in ipairs(entry.outbound_links or {}) do
        local resolution = self:resolve(link, entry.abs_path)
        if resolution.status == "resolved" and common.path_equals(resolution.path, old_path) then
          local base
          if link.kind == "wiki" or link.kind == "embed" then
            base = rename_note_target(self, old_entry, new_path, source_path)
          else
            base = display_path(common.relative_path(common.dirname(source_path), new_path))
          end
          local edit = target_edit_for_link(lines[link.source_line] or "", link,
            base .. subtarget_suffix(link))
          if edit then edits[#edits + 1] = edit end
        end
      end
      if #edits > 0 then
        table.sort(edits, function(a, b)
          if a.line1 ~= b.line1 then return a.line1 < b.line1 end
          return a.col1 < b.col1
        end)
        files[#files + 1] = {
          path = common.normalize_path(source_path),
          old_source_path = entry.abs_path,
          doc = entry.doc,
          edits = edits,
        }
      end
    end
  end
  table.sort(files, function(a, b) return path_key(a.path) < path_key(b.path) end)
  return { old_path = old_path, new_path = new_path, index = self, files = files }
end

function Index:completion_candidates(mode, query, source_path, limit)
  source_path = source_path and absolute_path(source_path) or nil
  query = tostring(query or ""):lower()
  limit = math.max(1, tonumber(limit) or 200)
  local candidates, seen = {}, {}
  local function add(text, target, kind, entry, line, info)
    local key = kind .. "\0" .. target .. "\0" .. tostring(entry and entry.abs_path or "")
    if seen[key] then return end
    local haystack = (text .. " " .. target .. " " .. tostring(info or "")):lower()
    if query ~= "" and not haystack:find(query, 1, true) then return end
    seen[key] = true
    candidates[#candidates + 1] = {
      text = text,
      target = target,
      kind = kind,
      path = entry and entry.abs_path,
      rel_path = entry and entry.rel_path,
      line = line,
      info = info,
    }
  end

  if self.disk_snapshot then
    for _, candidate in ipairs(self.disk_snapshot:completion(
      mode, query, source_path or "", self.link_path_policy, limit
    )) do
      if not (candidate.path and self.notes_by_abs[path_key(candidate.path)]) then
        local key = candidate.kind .. "\0" .. candidate.target .. "\0" .. tostring(candidate.path or "")
        seen[key] = true
        candidates[#candidates + 1] = candidate
      end
    end
  end

  local source_entry = source_path and self.notes_by_abs[path_key(source_path)] or nil
  if mode == "note" then
    for _, entry in pairs(self.notes_by_abs) do
      local target = canonical_note_target(self, entry, source_path)
      add(entry.display_name, target, "note", entry, 1, entry.rel_path)
      for _, alias in ipairs(entry.aliases or {}) do
        add(alias, target .. "|" .. alias, "alias", entry, 1, entry.rel_path)
      end
    end
    for _, entry in pairs(self.attachments_by_abs) do
      add(entry.display_name, entry.rel_path, "attachment", entry, 1, entry.rel_path)
    end
  elseif mode == "current_heading" and source_entry then
    for _, heading in ipairs(source_entry.headings or {}) do
      local heading_target = heading.path_text or heading.text
      add(heading_target, "#" .. heading_target, "heading", source_entry, heading.line, source_entry.rel_path)
    end
  elseif mode == "global_heading" then
    for _, entry in pairs(self.notes_by_abs) do
      local note_target = canonical_note_target(self, entry, source_path)
      for _, heading in ipairs(entry.headings or {}) do
        local heading_target = heading.path_text or heading.text
        add(heading_target .. " — " .. entry.display_name, note_target .. "#" .. heading_target,
          "heading", entry, heading.line, entry.rel_path)
      end
    end
  elseif mode == "current_block" and source_entry then
    for _, block in ipairs(source_entry.blocks or {}) do
      add(block.id, "^" .. block.id, "block", source_entry, block.line, source_entry.rel_path)
    end
  elseif mode == "global_block" then
    for _, entry in pairs(self.notes_by_abs) do
      local note_target = canonical_note_target(self, entry, source_path)
      for _, block in ipairs(entry.blocks or {}) do
        add(block.id .. " — " .. entry.display_name, note_target .. "#^" .. block.id,
          "block", entry, block.line, entry.rel_path)
      end
    end
  end

  table.sort(candidates, function(a, b)
    local at, bt = a.text:lower(), b.text:lower()
    if at ~= bt then return at < bt end
    return (a.rel_path or "") < (b.rel_path or "")
  end)
  while #candidates > limit do candidates[#candidates] = nil end
  return candidates
end

function Index:update_path(path, opts)
  opts = opts or {}
  path = absolute_path(path)
  if not path then return false end
  self.removed_paths[path_key(path)] = nil
  if not ((is_markdown(path) or self:is_attachment(path)) and file_exists(path)) then return false end
  self:rebuild(opts.reason or "path-updated")
  return self:note(path) ~= nil or self:attachment(path) ~= nil
end

function Index:update_doc(doc, opts)
  opts = opts or {}
  if not (doc and doc.abs_filename and is_markdown(doc.abs_filename)) then return false end
  if not common.path_belongs_to(common.normalize_path(doc.abs_filename), self.root) then return false end
  local pool = worker_pool.current_system()
  if not pool then return false end
  local text = doc:get_text(1, 1, math.huge, math.huge)
  local serial = (self.doc_overlay_serials[doc] or 0) + 1
  self.doc_overlay_serials[doc] = serial
  local old_job = self.doc_overlay_jobs[doc]
  if old_job then pool:cancel(old_job) end
  local path = common.normalize_path(doc.abs_filename)
  local handle, submit_error = pool:submit {
    kind = "markdown-vault-overlay",
    generation = serial,
    priority = "interactive",
    native = true,
    native_kind = "markdown_vault_overlay",
    native_payload = {
      path = path,
      relpath = self:relative_path(path),
      text = text,
      shallow_note_bytes = MAX_COOPERATIVE_NOTE_BYTES,
    },
    is_stale = function()
      return not self.doc_listeners[doc] or self.doc_overlay_serials[doc] ~= serial
        or not doc.abs_filename or not common.path_equals(doc.abs_filename, path)
    end,
    on_stale = function(message)
      local snapshot = message.vault_snapshot or (message.payload and message.payload.vault_snapshot)
      if snapshot then release_vault_snapshot(snapshot) end
      core.log_quiet("Markdown vault stale overlay released: path=%s request=%d current=%s tracked=%s current_path=%s",
        path, serial, tostring(self.doc_update_serials[doc]), tostring(self.doc_listeners[doc] ~= nil), tostring(doc.abs_filename))
    end,
    on_error = function(message)
      if self.doc_overlay_serials[doc] == serial then self.doc_overlay_jobs[doc] = nil end
      core.log_quiet("Markdown vault overlay failed for %s: %s", path, tostring(message.error or message))
    end,
    on_cancelled = function()
      if self.doc_overlay_serials[doc] == serial then self.doc_overlay_jobs[doc] = nil end
    end,
    on_result = function(message)
      local snapshot = message.vault_snapshot or (message.payload and message.payload.vault_snapshot)
      if not snapshot and message.type == "final" then return end
      if not snapshot then return end
      self.doc_overlay_jobs[doc] = nil
      local entry = snapshot:note(path)
      if not entry then release_vault_snapshot(snapshot); return end
      entry.doc = doc
      local previous_entry = self.notes_by_abs[path_key(path)]
      local facts_changed = not previous_entry or previous_entry.fact_signature ~= entry.fact_signature
      local previous_overlay = self.doc_overlays[doc]
      self.doc_overlays[doc] = { snapshot = snapshot, path = path, serial = serial }
      self:add_note_entry(entry)
      if previous_overlay and previous_overlay.snapshot ~= snapshot then
        release_vault_snapshot(previous_overlay.snapshot)
      end
      self.diagnostics.doc_updates = self.diagnostics.doc_updates + 1
      if not opts.rebuilding and facts_changed then
        self.generation = self.generation + 1
        self:notify("document-updated", doc)
      end
      core.log_quiet("Markdown vault native overlay published: path=%s generation=%d bytes=%d shallow=%s",
        path, serial, #text, tostring(entry.shallow == true))
    end,
  }
  if not handle then
    core.log_quiet("Markdown vault overlay submission failed for %s: %s", path, tostring(submit_error))
    return false
  end
  self.doc_overlay_jobs[doc] = handle
  return true
end

function Index:schedule_doc_update(doc)
  local serial = (self.doc_update_serials[doc] or 0) + 1
  if serial > 1 then
    self.diagnostics.doc_updates_coalesced = self.diagnostics.doc_updates_coalesced + 1
  end
  self.doc_update_serials[doc] = serial
  core.add_thread(function()
    coroutine.yield(DOC_UPDATE_DEBOUNCE_SECONDS)
    if self.doc_listeners[doc] and self.doc_update_serials[doc] == serial then
      self:update_doc(doc, { cooperative = true })
    end
  end)
  return true
end

function Index:track_doc(doc)
  if not (doc and doc.add_text_change_listener) then return false end
  if not (doc.abs_filename and common.path_belongs_to(common.normalize_path(doc.abs_filename), self.root)) then return false end
  if self.doc_listeners[doc] then
    self:schedule_doc_update(doc)
    return false
  end
  local id = "markdown-vault-index-" .. tostring(self)
  doc:add_text_change_listener(id, {
    after_change = function()
      self:schedule_doc_update(doc)
    end,
  })
  if doc.add_metadata_listener then
    doc:add_metadata_listener(id, function(_, event)
      if event and event.kind == "close" then self:on_doc_closed(doc) end
    end)
  end
  self.doc_listeners[doc] = id
  self:update_doc(doc)
  return true
end

function Index:untrack_doc(doc)
  local id = self.doc_listeners[doc]
  if not id then return false end
  if doc and doc.remove_text_change_listener then doc:remove_text_change_listener(id) end
  if doc and doc.remove_metadata_listener then doc:remove_metadata_listener(id) end
  self.doc_update_serials[doc] = nil
  self.doc_overlay_serials[doc] = nil
  self.doc_listeners[doc] = nil
  local job = self.doc_overlay_jobs[doc]
  local pool = worker_pool.current_system()
  if job and pool then pool:cancel(job) end
  self.doc_overlay_jobs[doc] = nil
  local overlay = self.doc_overlays[doc]
  if overlay then
    self:remove_path_entry(overlay.path)
    release_vault_snapshot(overlay.snapshot)
  end
  self.doc_overlays[doc] = nil
  return true
end

function Index:on_doc_closed(doc)
  local path = doc and doc.abs_filename
  if not self:untrack_doc(doc) then return false end
  if path then
    self:remove_path_entry(path)
    if file_exists(path) then
      self:update_path(path, { rebuilding = true, cooperative = true })
    end
  end
  self.generation = self.generation + 1
  self:notify("document-closed", doc)
  core.log_quiet("Markdown vault index released closed Document overlay %s", tostring(path))
  return true
end

local function missing(target, reason)
  return { status = "missing", target = target, reason = reason or "not found" }
end

local function ambiguous(target, candidates)
  return { status = "ambiguous", target = target, candidates = candidates, reason = "ambiguous target" }
end

local function resolved(kind, entry, extra)
  local result = { status = "resolved", kind = kind, path = entry.abs_path, entry = entry }
  if extra then for key, value in pairs(extra) do result[key] = value end end
  return result
end

function Index:resolve_subtarget(entry, subtarget)
  if not subtarget then return {} end
  if subtarget.type == "heading" then
    local text = subtarget.text or ""
    local path_slugs = {}
    for part in (text .. "#"):gmatch("(.-)#") do
      if part ~= "" then path_slugs[#path_slugs + 1] = anchors.normalize_heading(part) end
    end
    local path_slug = table.concat(path_slugs, "#")
    local slug = anchors.normalize_heading(text)
    local heading = entry.headings_by_path[path_slug]
      or entry.headings_by_slug[slug] or entry.headings_by_text[slug]
    if heading then return { line = heading.line, heading = heading } end
    return nil, "heading not found"
  elseif subtarget.type == "block" then
    local block = entry.blocks_by_id[subtarget.id or ""]
    if block then return { line = block.line, block = block } end
    return nil, "block not found"
  end
  return {}
end

function Index:resolve_entry_result(entry, link, target)
  if entry.kind == "note" then
    local extra, err = self:resolve_subtarget(entry, link.subtarget)
    if not extra then
      return resolved(entry.kind, entry, {
        line = 1,
        subtarget_missing = true,
        reason = err,
      })
    end
    return resolved(entry.kind, entry, extra)
  end
  return resolved(entry.kind, entry)
end

function Index:resolve_note_entry(target)
  local exact = self.note_keys[target]
  local entry, candidates = unique_item(exact)
  if entry then return entry end
  if candidates then return nil, candidates end

  local ci = self.note_keys_ci[target:lower()]
  entry, candidates = unique_item(ci)
  if entry then return entry end
  if candidates then return nil, candidates end

  if self.disk_snapshot then
    local native, filtered = self.disk_snapshot:resolve_notes(target), {}
    for _, candidate in ipairs(native) do
      local key = path_key(candidate.abs_path)
      if not self.removed_paths[key] and not self.notes_by_abs[key] then filtered[#filtered + 1] = candidate end
    end
    native = filtered
    if #native == 1 then return native[1] end
    if #native > 1 then return nil, native end
  end

end

function Index:resolve_attachment_entry(target)
  local exact = self.attachment_keys[target]
  local entry, candidates = unique_item(exact)
  if entry then return entry end
  if candidates then return nil, candidates end

  local ci = self.attachment_keys_ci[target:lower()]
  entry, candidates = unique_item(ci)
  if entry then return entry end
  if candidates then return nil, candidates end

  if self.disk_snapshot then
    local native, filtered = self.disk_snapshot:resolve_attachments(target), {}
    for _, candidate in ipairs(native) do
      local key = path_key(candidate.abs_path)
      if not self.removed_paths[key] and not self.attachments_by_abs[key] then filtered[#filtered + 1] = candidate end
    end
    native = filtered
    if #native == 1 then return native[1] end
    if #native > 1 then return nil, native end
  end
end

function Index:resolve(link_or_target, source_path)
  local link = type(link_or_target) == "table" and link_or_target or links.find_links("[[" .. tostring(link_or_target or "") .. "]]", 1)[1]
  local target = strip_target_fragment(
    link.path ~= nil and link.path or link.raw_target or ""
  )
  local source_dir = source_path and common.dirname(source_path)

  if target == "" and link.subtarget then
    if source_path then target = self:relative_path(source_path) else return missing(target, "current note is unknown") end
  end

  if target == "" then return missing(target, "empty target") end

  if not common.is_absolute_path(target) and target:match("^[%a][%w+.-]*:") then
    return { status = "external", target = target, path = target, reason = "URI scheme" }
  end

  if common.is_absolute_path(target) then
    local abs = common.normalize_path(target)
    if not common.path_belongs_to(abs, self.root) then
      return { status = "external", target = target, path = abs, reason = "outside vault" }
    end
    local entry = self:note(abs) or self:attachment(abs)
    if not entry then return missing(target) end
    return self:resolve_entry_result(entry, link, target)
  end

  local explicit_path = target:find("/", 1, true) or target:find("\\", 1, true) or target:find("^%.") ~= nil
  if explicit_path and source_dir then
    local abs = absolute_path(join_path(source_dir, target))
    if abs and common.path_belongs_to(abs, self.root) then
      local entry = note_entry_for_explicit_path(self, abs) or self:attachment(abs)
      if entry then
        return self:resolve_entry_result(entry, link, target)
      end
    end
  end

  local root_abs = absolute_path(join_path(self.root, target))
  local root_entry = root_abs and note_entry_for_explicit_path(self, root_abs)
  if root_entry then return self:resolve_entry_result(root_entry, link, target) end

  local target_ext = extension(target)
  local entry, candidates
  if target_ext and not MARKDOWN_EXTENSIONS[target_ext] then
    entry, candidates = self:resolve_attachment_entry(display_path(target))
  else
    entry, candidates = self:resolve_note_entry(display_path(target))
  end
  if candidates then
    core.log_quiet("Markdown vault link ambiguous %s", target)
    return ambiguous(target, candidates)
  end
  if not entry then return missing(target) end

  return self:resolve_entry_result(entry, link, target)
end

function vault_index.get_index(root)
  root = common.normalize_path(root)
  local key = path_key(root)
  local index = indexes_by_root[key]
  if not index then
    index = Index:new(root)
    indexes_by_root[key] = index
  end
  return index
end

function vault_index.index_for_path(path)
  local project = core.current_project(path)
  local root = project and project.path or common.dirname(path) or system.getcwd()
  return vault_index.get_index(root)
end

function vault_index.rebuild_for_path(path, reason)
  return vault_index.index_for_path(path):rebuild(reason)
end

function vault_index.set_link_path_policy(root, policy)
  local normalized = common.normalize_path(root)
  assert(normalized, "Markdown link policy root is required")
  assert(LINK_PATH_POLICIES[policy], "invalid Markdown link path policy: " .. tostring(policy))
  link_path_policies[path_key(normalized)] = policy
  local index = indexes_by_root[path_key(normalized)]
  if index then return index:set_link_path_policy(policy) end
  return true
end

function vault_index.resolve(link_or_target, source_path)
  return vault_index.index_for_path(source_path):resolve(link_or_target, source_path)
end

function vault_index.track_doc(doc)
  if not (doc and doc.abs_filename) then return false end
  return vault_index.index_for_path(doc.abs_filename):track_doc(doc)
end

function vault_index.on_doc_filename_changed(doc, old_abs_filename)
  if old_abs_filename and doc and doc.abs_filename
    and common.path_equals(old_abs_filename, doc.abs_filename)
  then
    vault_index.track_doc(doc)
    return
  end
  if old_abs_filename then
    local old_index = vault_index.index_for_path(old_abs_filename)
    if doc and doc.abs_filename and is_markdown(old_abs_filename) and is_markdown(doc.abs_filename)
      and common.path_belongs_to(common.normalize_path(doc.abs_filename), old_index.root)
    then
      local plan = old_index:plan_note_rename(old_abs_filename, doc.abs_filename)
      if plan and #plan.files > 0 then
        pending_renames[path_key(doc.abs_filename)] = plan
        core.log_quiet("Markdown rename found %d affected files for %s -> %s",
          #plan.files, old_abs_filename, doc.abs_filename)
        core.add_thread(function()
          coroutine.yield(0)
          local ok, maintenance = pcall(require, "core.markdown.rename_links")
          if ok then maintenance.present(plan) end
        end)
      end
    end
    old_index:remove_path(old_abs_filename)
    if file_exists(old_abs_filename) then
      old_index:update_path(old_abs_filename, { cooperative = true })
    end
    if not (doc and doc.abs_filename and common.path_belongs_to(common.normalize_path(doc.abs_filename), old_index.root)) then
      old_index:untrack_doc(doc)
    end
    if old_index.status == "indexing" then
      old_index:rebuild_async("tracked-document-moved")
    end
  end
  if doc and doc.abs_filename then
    vault_index.track_doc(doc)
  end
end

function vault_index.pending_rename(path, consume)
  local key = path and path_key(path)
  local plan = key and pending_renames[key] or nil
  if consume and key then pending_renames[key] = nil end
  return plan
end

function vault_index.install_doc_hooks()
  if doc_hooks_installed then return end
  doc_hooks_installed = true
  local Doc = require "core.doc"
  local old_set_filename = Doc.set_filename
  function Doc:set_filename(...)
    local old_abs_filename = self.abs_filename
    local result = old_set_filename(self, ...)
    vault_index.on_doc_filename_changed(self, old_abs_filename)
    return result
  end
end

vault_index.Index = Index
vault_index.is_markdown = is_markdown
vault_index.is_attachment = is_attachment

vault_index.install_doc_hooks()

return vault_index
