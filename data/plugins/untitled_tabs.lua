-- mod-version:3
-- VSCode-like untitled tabs on top of Anvil's built-in unnamed docs.

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local common = require "core.common"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local Node = require "core.node"

local M = {}
local untitled_id_counter = 0

local function is_untitled_doc(doc)
  return doc and doc.intellij_untitled and doc.new_file and not doc.filename
end

local function untitled_index(name)
  return tonumber(tostring(name or ""):match("^Untitled%-(%d+)$"))
end

local function next_untitled_name()
  local used = {}
  for _, doc in ipairs(core.docs or {}) do
    local idx = untitled_index(doc.intellij_untitled_name)
    if idx then used[idx] = true end
  end
  local idx = 1
  while used[idx] do idx = idx + 1 end
  return "Untitled-" .. idx
end

local function new_untitled_id()
  untitled_id_counter = untitled_id_counter + 1
  return string.format(
    "%s-%d-%d",
    system.get_process_id and system.get_process_id() or 0,
    math.floor(system.get_time() * 1000000),
    untitled_id_counter
  )
end

local function ensure_untitled_id(doc, id)
  if not doc then return nil end
  doc.intellij_untitled_id = id or doc.intellij_untitled_id or new_untitled_id()
  return doc.intellij_untitled_id
end

M.ensure_untitled_id = ensure_untitled_id

local function tag_doc(doc, name, id)
  if not doc or doc.filename then return doc end
  doc.intellij_untitled = true
  doc.intellij_untitled_name = name or doc.intellij_untitled_name or next_untitled_name()
  ensure_untitled_id(doc, id)
  return doc
end

local function first_text_snippet(doc)
  if not doc then return nil end
  for _, line in ipairs(doc.lines or {}) do
    local text = tostring(line or ""):gsub("\r", ""):gsub("\n$", "")
    text = text:match("^%s*(.-)%s*$")
    if text and text ~= "" then return text end
  end
end

local function truncate_to_width(font, text, max_w)
  text = tostring(text or "")
  if font:get_width(text) <= max_w then return text end
  local dots = "…"
  local dots_w = font:get_width(dots)
  local len = text:ulen()
  for i = 1, len do
    local candidate = text:usub(1, len - i)
    if font:get_width(candidate) + dots_w <= max_w then
      return candidate .. dots
    end
  end
  return dots_w <= max_w and dots or ""
end

local function secondary_font()
  if M._secondary_font and M._secondary_font_base == style.font then return M._secondary_font end
  local ok, font = pcall(function()
    return style.font:copy(math.max(8 * SCALE, style.font:get_size() * 0.85))
  end)
  M._secondary_font_base = style.font
  M._secondary_font = ok and font or style.font
  return M._secondary_font
end

local function draw_untitled_tab_title(view, font, is_active, is_hovered, x, y, w, h)
  local doc = view and view.doc
  if not is_untitled_doc(doc) then return false end

  local secondary = doc.intellij_untitled_name or "Untitled"
  if doc:is_dirty() then secondary = secondary .. "*" end

  local primary = first_text_snippet(doc)
  local primary_color = (is_active or is_hovered) and style.text or style.dim
  local secondary_color = style.dim
  local sfont = secondary_font()
  local gap = style.padding.x

  if not primary or primary == "" then
    common.draw_text(sfont, secondary_color, secondary, "center", x, y, w, h)
    return true
  end

  local secondary_w = sfont:get_width(secondary)
  local max_primary_w = math.max(0, w - secondary_w - gap)
  primary = truncate_to_width(font, primary, max_primary_w)
  local primary_w = font:get_width(primary)
  local total_w = primary_w + gap + secondary_w
  local tx = x + math.max(0, (w - total_w) / 2)
  local py = y + (h - font:get_height()) / 2
  local sy = y + (h - sfont:get_height()) / 2

  renderer.draw_text(font, primary, tx, py, primary_color)
  renderer.draw_text(sfont, secondary, tx + primary_w + gap, sy, secondary_color)
  return true
end

if not core.__untitled_tabs_patched then
  core.__untitled_tabs_patched = true

  local docview_get_state = DocView.get_state
  function DocView:get_state()
    local state = docview_get_state(self)
    if is_untitled_doc(self.doc) then
      state.intellij_untitled = true
      state.intellij_untitled_name = self.doc.intellij_untitled_name
      state.intellij_untitled_id = ensure_untitled_id(self.doc)
    end
    return state
  end

  local docview_from_state = DocView.from_state
  function DocView.from_state(state)
    local view = docview_from_state(state)
    if view and view.doc and state and state.intellij_untitled then
      tag_doc(view.doc, state.intellij_untitled_name, state.intellij_untitled_id)
    end
    return view
  end

  local doc_save = Doc.save
  function Doc:save(...)
    local result = doc_save(self, ...)
    if self.intellij_untitled and self.filename then
      self.intellij_untitled = nil
      self.intellij_untitled_name = nil
      self.intellij_untitled_id = nil
    end
    return result
  end

  local core_confirm_close_docs = core.confirm_close_docs
  function core.confirm_close_docs(docs, close_fn, ...)
    local filtered, dirty_untitled = {}, {}
    for _, doc in ipairs(docs or core.docs) do
      if is_untitled_doc(doc) then
        if doc:is_dirty() then dirty_untitled[#dirty_untitled + 1] = doc end
      else
        filtered[#filtered + 1] = doc
      end
    end

    -- App quit/restart persists open untitled docs through the workspace plugin,
    -- so do not warn there.  Explicit tab-closing operations (close all/others)
    -- remove the tabs from the workspace, so warn before discarding them.
    if #dirty_untitled > 0 and close_fn ~= core.exit then
      local args = { ... }
      local text = #dirty_untitled == 1
        and string.format("Closing %s will permanently discard this untitled document. Close it anyway?", dirty_untitled[1].intellij_untitled_name or "Untitled")
        or string.format("Closing %d untitled documents will permanently discard them. Close them anyway?", #dirty_untitled)
      core.nag_view:show(
        "Close Untitled Tabs",
        text,
        {
          { text = "Close", default_yes = true },
          { text = "Cancel", default_no = true },
        },
        function(item)
          if item.text == "Close" then
            core_confirm_close_docs(filtered, close_fn, table.unpack(args))
          end
        end
      )
      return
    end

    return core_confirm_close_docs(filtered, close_fn, ...)
  end

  local docview_try_close = DocView.try_close
  function DocView:try_close(do_close)
    if is_untitled_doc(self.doc)
       and self.doc:is_dirty()
       and #core.get_views_referencing_doc(self.doc) == 1 then
      local name = self.doc.intellij_untitled_name or "Untitled"
      core.nag_view:show(
        "Close Untitled Tab",
        string.format("Closing %s will permanently discard this untitled document. Close it anyway?", name),
        {
          { text = "Close", default_yes = true },
          { text = "Cancel", default_no = true },
        },
        function(item)
          if item.text == "Close" then do_close() end
        end
      )
      return
    end
    return docview_try_close(self, do_close)
  end

  local node_draw_tab_title = Node.draw_tab_title
  function Node:draw_tab_title(view, font, is_active, is_hovered, x, y, w, h)
    if draw_untitled_tab_title(view, font, is_active, is_hovered, x, y, w, h) then return end
    return node_draw_tab_title(self, view, font, is_active, is_hovered, x, y, w, h)
  end
end

local function prompt_text_for_directory(dirname)
  local root = core.root_project and core.root_project()
  if dirname and root and (dirname == root.path or common.path_belongs_to(dirname, root.path)) then
    if dirname == root.path then return "" end
    local rel = common.relative_path(root.path, dirname)
    return common.home_encode(rel) .. PATHSEP
  elseif dirname then
    return common.home_encode(dirname) .. PATHSEP
  end
  return ""
end

local function nearest_existing_directory(path)
  while path and path ~= "" do
    local info = system.get_file_info(path)
    if info and info.type == "dir" then return path end
    local parent = common.dirname(path)
    if not parent or parent == path then break end
    path = parent
  end
end

local function selected_filetree_directory(view)
  if tostring(view) ~= "FileTreeView" or type(view.entry_for_line) ~= "function" then return nil end
  local doc = view.doc
  if not doc or type(doc.get_selection) ~= "function" then return nil end
  local line = doc:get_selection(true)
  local ok, entry = pcall(view.entry_for_line, view, line)
  if not ok or not entry or not entry.abs then return nil end
  local path = entry.type == "dir" and entry.abs or common.dirname(entry.abs)
  return nearest_existing_directory(path)
end

local function default_new_file_text()
  local view = core.active_view
  local filetree_dir = selected_filetree_directory(view)
  if filetree_dir then return prompt_text_for_directory(filetree_dir) end

  local doc = view and view.doc
  local filename = doc and doc.abs_filename
  if filename then
    return prompt_text_for_directory(common.dirname(filename))
  end
  return ""
end

local function create_empty_file(filename)
  filename = common.home_expand(filename or "")
  if filename == "" then return end
  local normalized = core.normalize_to_project_dir(filename)
  local abs = core.project_absolute_path(normalized)
  local parent = common.dirname(abs)
  if parent and not system.get_file_info(parent) then
    core.error("Directory does not exist: %s", parent)
    return
  end

  local doc = core.open_doc(normalized)
  core.root_panel:open_doc(doc)
  local ok, err = pcall(doc.save, doc, normalized, abs)
  if ok then
    command.perform("filetree:sync-path", abs)
    core.log("Created \"%s\"", normalized)
  else
    core.error(err)
  end
end

command.add(nil, {
  ["user:new-untitled-tab"] = function()
    local doc = tag_doc(core.open_doc())
    core.root_panel:open_doc(doc)
  end,

  ["user:new-file-with-path"] = function()
    core.global_prompt_bar:enter("New File", {
      text = default_new_file_text(),
      submit = create_empty_file,
      suggest = function(text)
        return common.home_encode_list(common.path_suggest(common.home_expand(text)))
      end,
    })
  end,
})

keymap.add_direct {
  ["ctrl+t"] = "user:new-untitled-tab",
  ["ctrl+shift+n"] = "user:new-file-with-path",
}

return M
