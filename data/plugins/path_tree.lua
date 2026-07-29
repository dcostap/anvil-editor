-- mod-version:3
-- Reusable hierarchy and DocView presentation for arbitrary file path sets.

local common = require "core.common"
local config = require "core.config"
local DocView = require "core.docview"
local Object = require "core.object"
local style = require "core.style"
local file_icons = require "core.file_icons"

local path_tree = {}

local KIND_RANK = {
  deleted = 7,
  added = 6,
  modified = 5,
  renamed = 5,
  copied = 5,
  typechange = 5,
  unmerged = 5,
  untracked = 2,
  ignored = 1,
}

local KIND_ALIASES = {
  a = "added",
  c = "copied",
  d = "deleted",
  m = "modified",
  r = "renamed",
  t = "typechange",
  u = "unmerged",
  ["??"] = "untracked",
  ["!!"] = "ignored",
}

local function default_record_path(record)
  return record and (record.path or record.new_path or record.old_path) or ""
end

local function default_record_kind(record)
  return record and (record.kind or record.status or record.raw_status or record.xy) or nil
end

local function normalize_kind(kind)
  if type(kind) ~= "string" or kind == "" then return nil end
  local lower = kind:lower()
  if KIND_RANK[lower] then return lower end
  if KIND_ALIASES[lower] then return KIND_ALIASES[lower] end
  if #lower > 4 then return lower end
  local result
  for token in lower:gmatch("[%a%?%!]") do
    local normalized = KIND_ALIASES[token]
    if normalized then result = path_tree.stronger_kind(result, normalized) end
  end
  return result or lower
end

function path_tree.stronger_kind(a, b)
  a, b = normalize_kind(a), normalize_kind(b)
  if not a or (KIND_RANK[b] or 0) > (KIND_RANK[a] or 0) then return b end
  return a
end

local function clone_stat(stat)
  if not stat then return nil end
  local additions = tonumber(stat.additions) or 0
  local deletions = tonumber(stat.deletions) or 0
  if additions == 0 and deletions == 0 then return nil end
  return { additions = additions, deletions = deletions }
end

local function add_stat(total, stat)
  stat = clone_stat(stat)
  if not stat then return total end
  total = total or { additions = 0, deletions = 0 }
  total.additions = total.additions + stat.additions
  total.deletions = total.deletions + stat.deletions
  return total
end

local function split_path(path)
  local parts = {}
  path = tostring(path or ""):gsub("\\", "/")
  for part in path:gmatch("[^/]+") do
    if part ~= "." then parts[#parts + 1] = part end
  end
  return parts
end

local function child_less(a, b)
  if a.type ~= b.type then return a.type == "dir" end
  local al, bl = a.name:lower(), b.name:lower()
  if al ~= bl then return al < bl end
  if a.name ~= b.name then return a.name < b.name end
  return a.path < b.path
end

local Tree = Object:extend()

function Tree:new(records, opts)
  self.options = opts or {}
  self.records = records or {}
  self.collapsed = self.options.collapsed or {}
  self.root = { type = "dir", name = "", path = "", children = {}, children_by_key = {} }
  self.rows = {}
  self.record_to_line = {}
  self.line_to_record = {}
  self:rebuild()
end

function Tree:record_path(record, index)
  local getter = self.options.record_path or default_record_path
  return getter(record, index)
end

function Tree:record_kind(record, index)
  local getter = self.options.record_kind or default_record_kind
  return normalize_kind(getter(record, index))
end

function Tree:insert_record(record, index)
  local raw_path = self:record_path(record, index)
  local parts = split_path(raw_path)
  if #parts == 0 then return end

  local parent = self.root
  local prefix = ""
  for depth, name in ipairs(parts) do
    prefix = prefix == "" and name or (prefix .. "/" .. name)
    local leaf = depth == #parts
    local node_type = leaf and "file" or "dir"
    local child_key = node_type .. "\0" .. name
    local node = parent.children_by_key[child_key]
    if not node then
      node = {
        name = name,
        path = prefix,
        type = node_type,
        depth = depth - 1,
        parent = parent,
        children = {},
        children_by_key = {},
        record_indices = {},
      }
      parent.children_by_key[child_key] = node
      parent.children[#parent.children + 1] = node
      if node_type == "dir" then self.dir_nodes_by_path[prefix] = node end
    end
    parent = node
  end

  parent.record = parent.record or record
  parent.record_index = parent.record_index or index
  parent.record_indices[#parent.record_indices + 1] = index
  self.record_nodes[index] = parent
  parent.kind = path_tree.stronger_kind(parent.kind, self:record_kind(record, index))
  parent.stat = add_stat(parent.stat, record and record.stat)
end

local function aggregate_node(node)
  table.sort(node.children, child_less)
  for _, child in ipairs(node.children) do
    aggregate_node(child)
    node.kind = path_tree.stronger_kind(node.kind, child.kind)
    node.stat = add_stat(node.stat, child.stat)
  end
end

function Tree:flatten(node)
  for _, child in ipairs(node.children) do
    local row_node = child
    local compact_nodes = { child }
    if self.options.compact_directories and child.type == "dir" then
      while not self.collapsed[row_node.path]
          and #row_node.children == 1
          and row_node.children[1].type == "dir" do
        row_node = row_node.children[1]
        compact_nodes[#compact_nodes + 1] = row_node
      end
    end

    local compact_paths = {}
    local display_names = {}
    for _, compact_node in ipairs(compact_nodes) do
      compact_paths[#compact_paths + 1] = compact_node.path
      display_names[#display_names + 1] = compact_node.name
    end

    local line = #self.rows + 1
    local row = {
      id = (row_node.type == "dir" and "dir:" or "file:") .. row_node.path,
      name = row_node.name,
      display_name = table.concat(display_names, "/"),
      path = row_node.path,
      depth = child.depth,
      type = row_node.type,
      kind = child.kind,
      stat = clone_stat(child.stat),
      record = row_node.record,
      record_index = row_node.record_index,
      record_indices = row_node.record_indices,
      node = row_node,
      compact_paths = compact_paths,
      expanded = row_node.type ~= "dir" or not self.collapsed[row_node.path],
      text = string.rep("\t", child.depth) .. table.concat(display_names, "/")
        .. (row_node.type == "dir" and "/" or ""),
    }
    self.rows[line] = row
    self.line_to_record[line] = row_node.record_index
    for _, compact_node in ipairs(compact_nodes) do
      self.path_to_line[compact_node.path] = line
      if compact_node.type == "dir" then self.dir_path_to_line[compact_node.path] = line end
    end
    for _, index in ipairs(row_node.record_indices) do self.record_to_line[index] = line end
    if row_node.type == "dir" and row.expanded then self:flatten(row_node) end
  end
end

function Tree:refresh_rows()
  self.rows = {}
  self.record_to_line = {}
  self.line_to_record = {}
  self.path_to_line = {}
  self.dir_path_to_line = {}
  self:flatten(self.root)
end

function Tree:rebuild()
  self.root = { type = "dir", name = "", path = "", children = {}, children_by_key = {} }
  self.dir_nodes_by_path = {}
  self.rows = {}
  self.record_to_line = {}
  self.line_to_record = {}
  self.record_nodes = {}
  self.path_to_line = {}
  self.dir_path_to_line = {}
  for index, record in ipairs(self.records) do self:insert_record(record, index) end
  aggregate_node(self.root)
  self:refresh_rows()
end

function Tree:lines()
  local lines = {}
  for i, row in ipairs(self.rows) do lines[i] = row.text end
  return lines
end

function Tree:document_lines()
  local lines = self:lines()
  for i, line in ipairs(lines) do lines[i] = line .. "\n" end
  if #lines == 0 then lines[1] = "\n" end
  return lines
end

function Tree:row(line)
  return self.rows[line]
end

function Tree:line_for_record(index)
  return self.record_to_line[index]
end

function Tree:record_for_line(line)
  local index = self.line_to_record[line]
  return index and self.records[index] or nil
end

function Tree:visible_line_for_record(index)
  local line = self:line_for_record(index)
  if line then return line end
  local node = self.record_nodes[index]
  node = node and node.parent
  while node and node ~= self.root do
    line = self:line_for_path(node.path, "dir")
    if line then return line end
    node = node.parent
  end
end

function Tree:line_for_path(path, entry_type)
  path = tostring(path or ""):gsub("\\", "/")
  if entry_type == "dir" then return self.dir_path_to_line[path] end
  return self.path_to_line[path]
end

function Tree:is_expanded(path)
  return not self.collapsed[tostring(path or ""):gsub("\\", "/")]
end

function Tree:set_expanded(path, expanded)
  path = tostring(path or ""):gsub("\\", "/")
  local node = self.dir_nodes_by_path[path]
  if not (node and node.type == "dir") then return false end
  if expanded == false then
    self.collapsed[path] = true
  else
    self.collapsed[path] = nil
  end
  self:refresh_rows()
  return true
end

function Tree:toggle(path)
  return self:set_expanded(path, not self:is_expanded(path))
end

function path_tree.build(records, opts)
  return Tree(records, opts)
end

function path_tree.git_text_color(kind)
  kind = normalize_kind(kind)
  if kind == "ignored" then return style.filetree_git_status_ignored end
  if kind == "untracked" then return style.filetree_git_status_untracked end
  if kind == "added" then return style.filetree_git_status_added end
  if kind == "modified" or kind == "renamed" or kind == "copied" or kind == "typechange" or kind == "unmerged" then
    return style.filetree_git_status_modified
  end
  if kind == "deleted" then return style.filetree_git_status_deleted end
end

function path_tree.git_gutter_color(kind)
  kind = normalize_kind(kind)
  if kind == "addition" or kind == "added" or kind == "untracked" then return style.git_change_addition end
  if kind == "modification" or kind == "modified" or kind == "renamed" or kind == "copied" or kind == "typechange" or kind == "unmerged" then
    return style.git_change_modification
  end
  if kind == "deletion" or kind == "deleted" then return style.git_change_deletion end
end

function path_tree.changed_stat_segments(stat, font)
  if not (stat and ((stat.additions or 0) > 0 or (stat.deletions or 0) > 0)) then return nil end
  return {
    { text = string.format("+%d", stat.additions or 0), font = font, color = style.filetree_git_line_additions },
    { text = string.format(" −%d", stat.deletions or 0), font = font, color = style.filetree_git_line_deletions },
  }
end

function path_tree.draw_folder_row_background(view, is_dir, x, y, width)
  local color = config.plugins.filetree and config.plugins.filetree.folder_row_background
  if not (is_dir and color) then return false end
  renderer.draw_rect(x, y, width, view:get_line_height(), color)
  return true
end

function path_tree.row_text_color(kind, is_dir)
  return path_tree.git_text_color(kind)
    or (is_dir and config.plugins.filetree and config.plugins.filetree.folder_color)
    or (is_dir and style.filetree_folder)
    or nil
end

function path_tree.draw_row_text(view, text, x, y, kind, is_dir)
  local color = path_tree.row_text_color(kind, is_dir)
  if not color then return false end
  renderer.draw_text(
    view:get_font(), text, x, y + view:get_line_text_y_offset(), color,
    { tab_offset = 0 }
  )
  return true
end

function path_tree.gutter_width(view)
  local left_padding = math.max(1, math.floor(2 * (SCALE or 1) + 0.5))
  return left_padding + file_icons.column_width(view:get_line_height()), 0
end

function path_tree.draw_file_icon(view, name, x, y, width)
  local line_height = view:get_line_height()
  local icon_width = file_icons.column_width(line_height)
  return file_icons.draw(name, x + math.max(0, width - icon_width), y, line_height)
end

local PathTreeView = DocView:extend()
PathTreeView.show_line_numbers = false

function PathTreeView:new(doc)
  PathTreeView.super.new(self, doc)
  self:set_wrapping_enabled(false)
  self.path_tree = nil
  self.path_tree_line_offset = 0
end

function PathTreeView:invalidate_path_tree_document(old_line_count)
  local line_count = math.max(1, tonumber(old_line_count) or 0, #self.doc.lines)
  if self.doc.highlighter then self.doc.highlighter:soft_reset() end
  self.doc:clear_cache(1, line_count)
  self.doc.text_revision = (self.doc.text_revision or 0) + 1
  self.doc:sanitize_selection()
  self:invalidate_line_render("path-tree-document")
  self:invalidate_visual_metrics("path-tree-document")
end

function PathTreeView:set_path_tree(tree, line_offset)
  self.path_tree = tree
  self.path_tree_line_offset = math.max(0, tonumber(line_offset) or 0)
  self.path_tree_embedded = line_offset ~= nil
  self.path_tree_line_count = tree and #tree.rows or 0
  if tree and line_offset == nil then
    local old_line_count = #self.doc.lines
    self.doc.lines = tree:document_lines()
    self:invalidate_path_tree_document(old_line_count)
    self.doc:clear_undo_redo()
    self.doc:clean()
    local line = math.max(1, math.min(#self.doc.lines, self.doc:get_selection() or 1))
    self.doc:set_selection(line, 1, line, 1)
  end
  return self
end

function PathTreeView:refresh_path_tree_lines()
  if not self.path_tree then return false end
  local old_line_count = #self.doc.lines
  local replacement = self.path_tree:document_lines()
  if #self.path_tree.rows == 0 then replacement = {} end
  if self.path_tree_embedded then
    local first = self.path_tree_line_offset + 1
    local old_count = self.path_tree_line_count or 0
    for _ = 1, old_count do table.remove(self.doc.lines, first) end
    for i = #replacement, 1, -1 do table.insert(self.doc.lines, first, replacement[i]) end
    if #self.doc.lines == 0 then self.doc.lines[1] = "\n" end
  else
    self.doc.lines = #replacement > 0 and replacement or { "\n" }
  end
  self.path_tree_line_count = #self.path_tree.rows
  self:invalidate_path_tree_document(old_line_count)
  self.doc:clear_undo_redo()
  self.doc:clean()
  if self.doc.git_view_pane_text ~= nil then self.doc.git_view_pane_text = table.concat(self.doc.lines) end
  return true
end

function PathTreeView:toggle_path_tree_folder(line)
  local row = self:path_tree_row(line)
  if not (row and row.type == "dir" and self.path_tree:toggle(row.path)) then return false end
  self:refresh_path_tree_lines()
  local new_line = self.path_tree:line_for_path(row.path, "dir")
  if new_line then
    new_line = new_line + self.path_tree_line_offset
    self.doc:set_selection(new_line, 1, new_line, 1)
    self:scroll_to_make_visible(new_line, 1, true)
  end
  return true
end

function PathTreeView:path_tree_row(line)
  if not self.path_tree then return nil end
  return self.path_tree:row(line - self.path_tree_line_offset)
end

function PathTreeView:path_tree_record_for_line(line)
  if not self.path_tree then return nil end
  return self.path_tree:record_for_line(line - self.path_tree_line_offset)
end

function PathTreeView:get_gutter_width()
  return path_tree.gutter_width(self)
end

function PathTreeView:draw_line_body(line, x, y)
  local row = self:path_tree_row(line)
  local gutter_width = self:get_gutter_width()
  path_tree.draw_folder_row_background(
    self, row and row.type == "dir", x + self.scroll.x, y,
    math.max(0, self.size.x - gutter_width)
  )
  return PathTreeView.super.draw_line_body(self, line, x, y)
end

function PathTreeView:draw_line_text(line, x, y)
  local row = self:path_tree_row(line)
  if row then
    local text = (self.doc:get_utf8_line(line) or ""):gsub("\n$", "")
    if path_tree.draw_row_text(self, text, x, y, row.kind, row.type == "dir") then
      return self:get_line_height()
    end
  end
  return PathTreeView.super.draw_line_text(self, line, x, y)
end

function PathTreeView:draw_line_gutter(line, x, y, width)
  local row = self:path_tree_row(line)
  path_tree.draw_folder_row_background(self, row and row.type == "dir", self.position.x, y, width)
  if row and row.type == "file" then path_tree.draw_file_icon(self, row.name, x, y, width) end
  return self:get_line_height()
end

function PathTreeView:get_line_hint(line)
  local row = self:path_tree_row(line)
  local font = style.get_small_font(self:get_font())
  return row and path_tree.changed_stat_segments(row.stat, font) or nil
end

path_tree.Tree = Tree
path_tree.View = PathTreeView

return path_tree
