local core = require "core"
local common = require "core.common"
local anchors = require "core.markdown.anchors"
local links = require "core.markdown.links"
local parser = require "core.markdown.parser"

local vault_index = {}

local MARKDOWN_EXTENSIONS = {
  md = true,
  markdown = true,
  mdown = true,
}

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
    generation = 0,
    notes_by_abs = {},
    attachments_by_abs = {},
    note_keys = {},
    note_keys_ci = {},
    attachment_keys = {},
    attachment_keys_ci = {},
    doc_listeners = setmetatable({}, { __mode = "k" }),
  }, self)
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
    return true
  end
  return false
end

function Index:make_note_entry(path, text)
  text = text or read_file(path) or ""
  local parsed = parser.parse(text)
  local anchor_index = anchors.index_document(parsed)
  local headings_by_slug = {}
  local headings_by_text = {}
  local blocks_by_id = {}
  for _, heading in ipairs(anchor_index.headings) do
    headings_by_slug[heading.slug] = heading
    headings_by_text[anchors.normalize_heading(heading.text or "")] = heading
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
    blocks = anchor_index.blocks,
    blocks_by_id = blocks_by_id,
  }
end

function Index:make_attachment_entry(path)
  return {
    kind = "attachment",
    abs_path = common.normalize_path(path),
    rel_path = self:relative_path(path),
    display_name = display_basename(path),
  }
end

function Index:scan_dir(dir, skip_key)
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
  self:clear()
  self:scan_dir(self.root, opts.skip_path and path_key(opts.skip_path) or nil)
  core.log_quiet("Markdown vault index rebuilt %s: %d notes, %d attachments", reason or "manual", self:note_count(), self:attachment_count())
  return self
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

function Index:update_path(path, opts)
  opts = opts or {}
  path = absolute_path(path)
  if not path then return false end
  if is_markdown(path) and file_exists(path) then
    self:add_note_entry(self:make_note_entry(path, opts.text))
  elseif is_attachment(path) and file_exists(path) then
    self:add_attachment_entry(self:make_attachment_entry(path))
  else
    return false
  end
  if not opts.rebuilding then self.generation = self.generation + 1 end
  return true
end

function Index:update_doc(doc)
  if not (doc and doc.abs_filename and is_markdown(doc.abs_filename)) then return false end
  if not common.path_belongs_to(common.normalize_path(doc.abs_filename), self.root) then return false end
  local text = doc:get_text(1, 1, math.huge, math.huge)
  self:add_note_entry(self:make_note_entry(doc.abs_filename, text))
  self.generation = self.generation + 1
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
  self.doc_listeners[doc] = id
  self:update_doc(doc)
  return true
end

function Index:untrack_doc(doc)
  local id = self.doc_listeners[doc]
  if not id then return false end
  if doc and doc.remove_text_change_listener then doc:remove_text_change_listener(id) end
  self.doc_listeners[doc] = nil
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
    local slug = anchors.normalize_heading(subtarget.text or "")
    local heading = entry.headings_by_slug[slug] or entry.headings_by_text[slug]
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
  local target = strip_target_fragment(link.raw_target or link.path or "")
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
      local entry = self.notes_by_abs[path_key(abs)] or self.notes_by_abs[path_key(abs .. ".md")] or self.attachments_by_abs[path_key(abs)]
      if entry then
        return self:resolve_entry_result(entry, link, target)
      end
    end
  end

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

function vault_index.resolve(link_or_target, source_path)
  return vault_index.index_for_path(source_path):resolve(link_or_target, source_path)
end

function vault_index.track_doc(doc)
  if not (doc and doc.abs_filename) then return false end
  return vault_index.index_for_path(doc.abs_filename):track_doc(doc)
end

function vault_index.on_doc_filename_changed(doc, old_abs_filename)
  if old_abs_filename then
    local old_index = vault_index.index_for_path(old_abs_filename)
    old_index:remove_path(old_abs_filename)
    if not (doc and doc.abs_filename and common.path_belongs_to(common.normalize_path(doc.abs_filename), old_index.root)) then
      old_index:untrack_doc(doc)
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
