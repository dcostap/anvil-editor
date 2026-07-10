local core = require "core"
local common = require "core.common"
local config = require "core.config"
local DirWatch = require "core.dirwatch"
local anchors = require "core.markdown.anchors"
local links = require "core.markdown.links"
local parser = require "core.markdown.parser"

local vault_index = {}

local MARKDOWN_EXTENSION_LIST = { "md", "markdown", "mdown" }
local MARKDOWN_EXTENSIONS = {}
for _, ext in ipairs(MARKDOWN_EXTENSION_LIST) do MARKDOWN_EXTENSIONS[ext] = true end

local MAX_COOPERATIVE_NOTE_BYTES = 512 * 1024

local ATTACHMENT_EXTENSIONS = {
  avif = true,
  bmp = true,
  gif = true,
  jpeg = true,
  jpg = true,
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
  pdf = true,
}

local indexes_by_root = {}
local link_path_policies = {}
local doc_hooks_installed = false

local function trim(text)
  return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
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
  local entry = index.notes_by_abs[path_key(abs)]
  if entry then return entry end
  if extension(abs) then return nil end
  for _, ext in ipairs(MARKDOWN_EXTENSION_LIST) do
    entry = index.notes_by_abs[path_key(abs .. "." .. ext)]
    if entry then return entry end
  end
end

local function is_attachment(path)
  return ATTACHMENT_EXTENSIONS[extension(path) or ""] == true
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

local function parse_frontmatter_aliases(text)
  local aliases = {}
  if not text:match("^%-%-%-\n") and not text:match("^%-%-%-%r\n") then
    return aliases
  end

  local body = text:gsub("\r\n", "\n")
  local finish = body:find("\n%-%-%-\n", 5)
  if not finish then return aliases end
  local frontmatter = body:sub(5, finish - 1)
  local current_alias_list = false
  for line in (frontmatter .. "\n"):gmatch("(.-)\n") do
    local key, value = line:match("^([%w_%-]+):%s*(.-)%s*$")
    if key then
      current_alias_list = (key == "aliases" or key == "alias") and value == ""
      if key == "aliases" or key == "alias" then
        if value:sub(1, 1) == "[" and value:sub(-1) == "]" then
          for alias in value:sub(2, -2):gmatch("[^,]+") do
            aliases[#aliases + 1] = trim(alias:gsub("^[\"']", ""):gsub("[\"']$", ""))
          end
        elseif value ~= "" then
          aliases[#aliases + 1] = trim(value:gsub("^[\"']", ""):gsub("[\"']$", ""))
        end
      end
    elseif current_alias_list then
      local alias = line:match("^%s*%-%s*(.-)%s*$")
      if alias and alias ~= "" then
        aliases[#aliases + 1] = trim(alias:gsub("^[\"']", ""):gsub("[\"']$", ""))
      end
    end
  end
  return aliases
end

local Index = {}
Index.__index = Index

function Index:new(root)
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
    consumers = {},
    watcher = nil,
    watcher_serial = 0,
    watched_dirs = {},
    pending_watch_dirs = {},
    pending_scan_dirs = {},
    subtree_scan_running = false,
  }, self)
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
  self.generation = self.generation + 1
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
  local removed = self:remove_path_entry(path)
  if removed then
    self.generation = self.generation + 1
    self:notify("path-removed", path)
    return true
  end
  return false
end

function Index:make_note_entry(path, text, opts)
  opts = opts or {}
  local file_info = system.get_file_info(path)
  text = text or (not opts.shallow and read_file(path)) or ""
  local anchor_index
  if opts.shallow then
    anchor_index = { headings = {}, blocks = {} }
  else
    anchor_index = anchors.index_document(parser.parse(text))
  end
  local headings_by_slug = {}
  local headings_by_text = {}
  local headings_by_path = {}
  local blocks_by_id = {}
  for _, heading in ipairs(anchor_index.headings) do
    headings_by_slug[heading.slug] = heading
    headings_by_text[anchors.normalize_heading(heading.text or "")] = heading
    if heading.path_slug and heading.path_slug ~= "" then
      headings_by_path[heading.path_slug] = heading
    end
  end
  for _, block in ipairs(anchor_index.blocks) do
    blocks_by_id[block.id] = block
  end

  local rel = self:relative_path(path)
  local display_name = display_basename(strip_markdown_extension(rel))
  return {
    kind = "note",
    abs_path = common.normalize_path(path),
    rel_path = rel,
    display_name = display_name,
    aliases = parse_frontmatter_aliases(text),
    headings = anchor_index.headings,
    headings_by_slug = headings_by_slug,
    headings_by_text = headings_by_text,
    headings_by_path = headings_by_path,
    blocks = anchor_index.blocks,
    blocks_by_id = blocks_by_id,
    modified = file_info and file_info.modified,
    size = file_info and file_info.size,
  }
end

function Index:make_attachment_entry(path)
  local file_info = system.get_file_info(path)
  return {
    kind = "attachment",
    abs_path = common.normalize_path(path),
    rel_path = self:relative_path(path),
    display_name = display_basename(path),
    modified = file_info and file_info.modified,
    size = file_info and file_info.size,
  }
end

function Index:watch_dir(dir)
  if not self.watcher or self.watched_dirs[dir] then return false end
  local info = system.get_file_info(dir)
  if not (info and info.type == "dir") then return false end
  self.watcher:watch(dir)
  self.watched_dirs[dir] = true
  return true
end

function Index:scan_dir(dir, skip_key)
  self:watch_dir(dir)
  for _, name in ipairs(system.list_dir(dir) or {}) do
    if name ~= ".git" and name ~= ".run-meson-tests" then
      local path = join_path(dir, name)
      local info = system.get_file_info(path)
      if info and info.type == "dir" then
        self:scan_dir(path, skip_key)
      elseif info and info.type == "file" and path_key(path) ~= skip_key then
        self:update_path(path, { rebuilding = true })
      end
    end
  end
end

function Index:rebuild(reason, opts)
  opts = opts or {}
  self.rebuild_serial = self.rebuild_serial + 1
  self.status, self.reason = "indexing", reason or "manual"
  self:clear()
  self:scan_dir(self.root, opts.skip_path and path_key(opts.skip_path) or nil)
  for doc in pairs(self.doc_listeners) do self:update_doc(doc, { rebuilding = true }) end
  self.status, self.reason = "ready", nil
  self.generation = self.generation + 1
  self:notify("ready")
  core.log_quiet("Markdown vault index rebuilt %s: %d notes, %d attachments", reason or "manual", self:note_count(), self:attachment_count())
  return self
end

local function entry_is_current(entry, info)
  return entry and entry.modified == info.modified and entry.size == info.size
end

function Index:queue_subtree_scan(dirs, reason)
  for _, dir in ipairs(dirs or {}) do self.pending_scan_dirs[dir] = true end
  if self.subtree_scan_running then return false end
  self.subtree_scan_running = true
  local watcher_serial = self.watcher_serial
  core.add_thread(function()
    local changed = false
    while next(self.pending_scan_dirs) do
      if not self.watcher or self.watcher_serial ~= watcher_serial then
        self.subtree_scan_running = false
        return
      end
      local roots = self.pending_scan_dirs
      self.pending_scan_dirs = {}
      local stack, processed = {}, 0
      for dir in pairs(roots) do stack[#stack + 1] = dir end
      while #stack > 0 do
        if not self.watcher or self.watcher_serial ~= watcher_serial then
          self.subtree_scan_running = false
          return
        end
        local dir = table.remove(stack)
        self:watch_dir(dir)
        for _, name in ipairs(system.list_dir(dir) or {}) do
          if name ~= ".git" and name ~= ".run-meson-tests" then
            local path = join_path(dir, name)
            local info = system.get_file_info(path)
            if info and info.type == "dir" then
              stack[#stack + 1] = path
            elseif info and info.type == "file" then
              local key = path_key(path)
              local entry = self.notes_by_abs[key] or self.attachments_by_abs[key]
              if not (entry and entry.doc) and (is_markdown(path) or is_attachment(path)) then
                self:update_path(path, { rebuilding = true, cooperative = true })
                changed = true
              end
            end
            processed = processed + 1
            if processed % 32 == 0 then coroutine.yield(0) end
          end
        end
      end
    end
    for doc in pairs(self.doc_listeners) do self:update_doc(doc, { rebuilding = true }) end
    self.subtree_scan_running = false
    if changed then
      self.generation = self.generation + 1
      self:notify("filesystem-reconciled", { reason = reason or "watch-subtree" })
      core.redraw = true
      core.log_quiet("Markdown index cooperatively adopted new filesystem subtree in %s", self.root)
    end
  end)
  return true
end

function Index:reconcile_dir(dir, reason, opts)
  opts = opts or {}
  local ok, normalized = pcall(common.normalize_path, dir)
  if not ok or not normalized or (
    path_key(normalized) ~= path_key(self.root)
    and not common.path_belongs_to(normalized, self.root)
  ) then return false end
  local info = system.get_file_info(normalized)
  if not (info and info.type == "dir") then normalized = common.dirname(normalized) end
  info = system.get_file_info(normalized)
  if not (info and info.type == "dir") then return false end

  self:watch_dir(normalized)
  local seen, changed, discovered_dirs = {}, false, {}
  for _, name in ipairs(system.list_dir(normalized) or {}) do
    if name ~= ".git" and name ~= ".run-meson-tests" then
      local path = join_path(normalized, name)
      local child_info = system.get_file_info(path)
      if child_info and child_info.type == "dir" then
        if not self.watched_dirs[path] then discovered_dirs[#discovered_dirs + 1] = path end
        self:watch_dir(path)
      elseif child_info and child_info.type == "file" and (is_markdown(path) or is_attachment(path)) then
        local key = path_key(path)
        seen[key] = true
        local entry = self.notes_by_abs[key] or self.attachments_by_abs[key]
        if not (entry and entry.doc) and not entry_is_current(entry, child_info) then
          self:update_path(path, { rebuilding = true, cooperative = true })
          changed = true
        end
      end
    end
  end

  for _, map in ipairs({ self.notes_by_abs, self.attachments_by_abs }) do
    local remove = {}
    for key, entry in pairs(map) do
      if not entry.doc and (
        (common.dirname(entry.abs_path) == normalized and not seen[key])
        or (common.path_belongs_to(entry.abs_path, normalized) and not file_exists(entry.abs_path))
      ) then
        remove[#remove + 1] = entry.abs_path
      end
    end
    for _, path in ipairs(remove) do self:remove_path_entry(path); changed = true end
  end

  if #discovered_dirs > 0 then
    if opts.cooperative then
      self:queue_subtree_scan(discovered_dirs, reason)
    else
      for _, path in ipairs(discovered_dirs) do self:scan_dir(path) end
      for doc in pairs(self.doc_listeners) do self:update_doc(doc, { rebuilding = true }) end
      changed = true
    end
  end
  if changed then
    self.generation = self.generation + 1
    self:notify("filesystem-reconciled", { path = normalized, reason = reason or "watch" })
    core.redraw = true
    core.log_quiet("Markdown index reconciled filesystem directory %s", normalized)
  end
  return changed
end

function Index:start_watcher()
  if self.watcher then return false end
  local ok, watcher = pcall(DirWatch)
  if not ok then
    core.log_quiet("Markdown index filesystem watcher unavailable for %s: %s", self.root, tostring(watcher))
    return false
  end
  self.watcher = watcher
  self.watcher_serial = self.watcher_serial + 1
  local serial = self.watcher_serial
  self:watch_dir(self.root)
  core.add_thread(function()
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
  self.rebuild_serial = self.rebuild_serial + 1
  local serial = self.rebuild_serial
  self.status, self.reason = "indexing", reason or "async-rebuild"
  self:clear()
  self:notify("indexing")
  core.log_quiet("Markdown vault index scheduled cooperative rebuild: %s", tostring(self.reason))
  core.add_thread(function()
    local dirs, processed = { self.root }, 0
    while #dirs > 0 do
      if serial ~= self.rebuild_serial then return end
      local dir = table.remove(dirs)
      for _, name in ipairs(system.list_dir(dir) or {}) do
        if name ~= ".git" and name ~= ".run-meson-tests" then
          local path = join_path(dir, name)
          local info = system.get_file_info(path)
          if info and info.type == "dir" then
            dirs[#dirs + 1] = path
          elseif info and info.type == "file" then
            local tracked = false
            for doc in pairs(self.doc_listeners) do
              if doc.abs_filename and path_key(doc.abs_filename) == path_key(path) then tracked = true break end
            end
            if not tracked then
              local ok, err = pcall(self.update_path, self, path, {
                rebuilding = true,
                cooperative = true,
              })
              if not ok then core.log_quiet("Markdown index skipped %s: %s", path, tostring(err)) end
            end
          end
          processed = processed + 1
          if processed % 32 == 0 then coroutine.yield(0) end
        end
      end
    end
    if serial ~= self.rebuild_serial then return end
    for doc in pairs(self.doc_listeners) do self:update_doc(doc, { rebuilding = true }) end
    self.status, self.reason = "ready", nil
    self.generation = self.generation + 1
    self:notify("ready")
    core.redraw = true
    core.log_quiet(
      "Markdown vault index cooperative rebuild ready: notes=%d attachments=%d",
      self:note_count(), self:attachment_count()
    )
  end)
  return false
end

function Index:note_count()
  local count = 0
  for _ in pairs(self.notes_by_abs) do count = count + 1 end
  return count
end

function Index:attachment_count()
  local count = 0
  for _ in pairs(self.attachments_by_abs) do count = count + 1 end
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
  if is_markdown(path) and file_exists(path) then
    local info = system.get_file_info(path)
    local shallow = opts.cooperative and info and (info.size or 0) > MAX_COOPERATIVE_NOTE_BYTES
    self:add_note_entry(self:make_note_entry(path, opts.text, { shallow = shallow }))
    if shallow then
      core.log_quiet("Markdown index shallow-indexed oversized note %s (%d bytes)", path, info.size)
    end
  elseif is_attachment(path) and file_exists(path) then
    self:add_attachment_entry(self:make_attachment_entry(path))
  else
    return false
  end
  if not opts.rebuilding then
    self.generation = self.generation + 1
    self:notify("path-updated", path)
  end
  return true
end

function Index:update_doc(doc, opts)
  opts = opts or {}
  if not (doc and doc.abs_filename and is_markdown(doc.abs_filename)) then return false end
  if not common.path_belongs_to(common.normalize_path(doc.abs_filename), self.root) then return false end
  local text = doc:get_text(1, 1, math.huge, math.huge)
  local entry = self:make_note_entry(doc.abs_filename, text)
  entry.doc = doc
  self:add_note_entry(entry)
  if not opts.rebuilding then
    self.generation = self.generation + 1
    self:notify("document-updated", doc)
  end
  core.log_quiet("Markdown vault index updated doc %s", doc.abs_filename)
  return true
end

function Index:track_doc(doc)
  if not (doc and doc.add_text_change_listener) then return false end
  if not (doc.abs_filename and common.path_belongs_to(common.normalize_path(doc.abs_filename), self.root)) then return false end
  if self.doc_listeners[doc] then
    self:update_doc(doc)
    return false
  end
  local id = "markdown-vault-index-" .. tostring(self)
  doc:add_text_change_listener(id, {
    after_change = function()
      self:update_doc(doc)
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
  self.doc_listeners[doc] = nil
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
    if not extra then return missing(target, err) end
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
    local entry = self.notes_by_abs[path_key(abs)] or self.attachments_by_abs[path_key(abs)]
    if not entry then return missing(target) end
    return self:resolve_entry_result(entry, link, target)
  end

  local explicit_path = target:find("/", 1, true) or target:find("\\", 1, true) or target:find("^%.") ~= nil
  if explicit_path and source_dir then
    local abs = absolute_path(join_path(source_dir, target))
    if abs and common.path_belongs_to(abs, self.root) then
      local entry = note_entry_for_explicit_path(self, abs) or self.attachments_by_abs[path_key(abs)]
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
