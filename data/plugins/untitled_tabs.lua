-- mod-version:3
-- VSCode-like untitled tabs on top of Anvil's built-in unnamed docs.

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local common = require "core.common"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local Tabs = require "core.tabs"
local untitled_recovery = require "plugins.untitled_recovery"

local M = {}
local untitled_id_counter = 0
local TITLE_SNIPPET_MAX_BYTES = 160

local function is_untitled_doc(doc)
  return doc and doc.intellij_untitled and doc.new_file and not doc.filename
end

local function untitled_doc_has_promptable_content(doc)
  return doc and doc:get_text(1, 1, math.huge, math.huge) ~= ""
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
  untitled_recovery.ensure_doc_backing(doc, { no_manifest = true })
  return doc
end

local function utf8_prefix(text, max_bytes)
  text = tostring(text or "")
  if #text <= max_bytes then return text, false end
  local cut = max_bytes
  while cut > 0 and common.is_utf8_cont(text, cut + 1) do
    cut = cut - 1
  end
  if cut <= 0 then cut = max_bytes end
  return text:sub(1, cut), true
end

local function first_text_snippet(doc)
  if not doc then return nil end
  local change_id = doc.get_change_id and doc:get_change_id() or nil
  local line_count = #(doc.lines or {})
  local cache = doc.intellij_untitled_snippet_cache
  if cache and cache.change_id == change_id and cache.line_count == line_count then
    return cache.value
  end

  local snippet
  for _, line in ipairs(doc.lines or {}) do
    local text = tostring(line or "")
    local first = text:find("%S")
    if first then
      -- Keep tab-title probing bounded.  A huge untitled line should not be
      -- copied and trimmed in full on every tab layout/cache-token check.
      local sample = text:sub(first, math.min(#text, first + TITLE_SNIPPET_MAX_BYTES + 8))
      sample = sample:gsub("\r", ""):gsub("\n$", "")
      sample = sample:match("^(.-)%s*$") or sample
      if sample ~= "" then
        local prefix, truncated = utf8_prefix(sample, TITLE_SNIPPET_MAX_BYTES)
        snippet = (truncated or #text >= first + TITLE_SNIPPET_MAX_BYTES) and (prefix .. "…") or prefix
        break
      end
    end
  end

  doc.intellij_untitled_snippet_cache = {
    change_id = change_id,
    line_count = line_count,
    value = snippet,
  }
  return snippet
end

local function truncate_to_width(font, text, max_w)
  text = tostring(text or "")
  if max_w <= 0 then return "" end
  if font:get_width(text) <= max_w then return text end
  local dots = "…"
  local dots_w = font:get_width(dots)
  if dots_w > max_w then return "" end

  local len = text:ulen()
  local lo, hi, best = 0, len, 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local candidate = mid > 0 and text:usub(1, mid) or ""
    if font:get_width(candidate) + dots_w <= max_w then
      best = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return best > 0 and (text:usub(1, best) .. dots) or dots
end

local function secondary_font()
  local base_size = style.font:get_size()
  local desired_size = math.max(8 * SCALE, base_size * 0.85)
  if M._secondary_font
     and M._secondary_font_base == style.font
     and M._secondary_font_size == desired_size then
    return M._secondary_font
  end
  local ok, font = pcall(function()
    return style.font:copy(desired_size)
  end)
  M._secondary_font_base = style.font
  M._secondary_font_size = desired_size
  M._secondary_font = ok and font or style.font
  return M._secondary_font
end

local function title_gap()
  return math.max(2 * SCALE, style.padding.x * 0.35)
end

local function untitled_tab_title_width(view, font)
  local doc = view and view.doc
  if not is_untitled_doc(doc) then return nil end

  local secondary = doc.intellij_untitled_name or "Untitled"
  if doc:is_dirty() then secondary = secondary .. "*" end

  local primary = first_text_snippet(doc)
  local sfont = secondary_font()
  local width = sfont:get_width(secondary)
  if primary and primary ~= "" then
    width = width + title_gap() + font:get_width(primary)
  end
  return width + style.padding.x * 2 + style.divider_size * 2
end

local function draw_untitled_tab_title(view, font, is_active, is_hovered, x, y, w, h, color_override)
  local doc = view and view.doc
  if not is_untitled_doc(doc) then return false end

  local secondary = doc.intellij_untitled_name or "Untitled"
  if doc:is_dirty() then secondary = secondary .. "*" end

  local primary = first_text_snippet(doc)
  local title_color = color_override or ((is_active or is_hovered) and style.text or style.dim)
  local primary_color = title_color
  local secondary_color = title_color
  local sfont = secondary_font()
  local gap = title_gap()

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
      local recovery_state = untitled_recovery.state_for_doc(self.doc)
      state.intellij_untitled = true
      state.intellij_untitled_name = self.doc.intellij_untitled_name
      state.intellij_untitled_id = ensure_untitled_id(self.doc)
      state.intellij_untitled_backing = recovery_state and recovery_state.intellij_untitled_backing
      state.intellij_untitled_backing_current = recovery_state and recovery_state.intellij_untitled_backing_current or nil
      state.intellij_untitled_change_id = recovery_state and recovery_state.intellij_untitled_change_id or nil
      state.intellij_untitled_backing_saved_at = recovery_state and recovery_state.intellij_untitled_backing_saved_at or nil
      state.intellij_untitled_workspace_saved_at = recovery_state and recovery_state.intellij_untitled_workspace_saved_at or nil
      if recovery_state and recovery_state.intellij_untitled_backing_current then state.text = nil end
    end
    return state
  end

  local function open_untitled_doc_by_id(id)
    if not id then return nil end
    for _, doc in ipairs(core.docs or {}) do
      if is_untitled_doc(doc) and doc.intellij_untitled_id == id then return doc end
    end
  end

  local function apply_view_state(view, state)
    local file_context = require "core.file_context"
    file_context.mark_editor_view(view)
    if state.selection_state then
      view:set_selection_state(state.selection_state)
    elseif state.selection then
      view:set_selection_state({ selections = state.selection, last_selection = 1 })
    end
    view.last_line1, view.last_col1, view.last_line2, view.last_col2 = table.unpack(view.selection_state.selections, 1, 4)
    if state.scroll then
      view.scroll.x, view.scroll.to.x = state.scroll.x, state.scroll.x
      view.scroll.y, view.scroll.to.y = state.scroll.y, state.scroll.y
      view.needs_initial_scroll_validation = true
    end
  end

  local docview_from_state = DocView.from_state
  function DocView.from_state(state)
    if state and state.intellij_untitled then
      local existing_doc = open_untitled_doc_by_id(state.intellij_untitled_id)
      if existing_doc then
        local view = DocView(existing_doc)
        apply_view_state(view, state)
        if core.log_quiet then core.log_quiet("Untitled recovery: reused open document for restored view %s", state.intellij_untitled_id) end
        return view
      end
    end

    local view = docview_from_state(state)
    if view and view.doc and state and state.intellij_untitled then
      tag_doc(view.doc, state.intellij_untitled_name, state.intellij_untitled_id)
      local loaded_backing = untitled_recovery.attach_from_workspace_state(view.doc, state)
      if loaded_backing then apply_view_state(view, state) end
    end
    return view
  end

  local doc_save = Doc.save
  function Doc:save(...)
    local old_untitled = is_untitled_doc(self) and {
      id = self.intellij_untitled_id,
      name = self.intellij_untitled_name,
      backing_path = self.intellij_untitled_backing_path,
      backing_rel = self.intellij_untitled_backing_rel,
      project = self.intellij_untitled_project_path,
    } or nil
    if old_untitled then untitled_recovery.flush_doc(self, "save as", true) end
    local result = doc_save(self, ...)
    if old_untitled and self.filename then
      untitled_recovery.handle_save_as_success(self, old_untitled)
      self.intellij_untitled = nil
      self.intellij_untitled_name = nil
      self.intellij_untitled_id = nil
      self.intellij_untitled_backing_path = nil
      self.intellij_untitled_backing_rel = nil
      self.intellij_untitled_backing_dirty = nil
      self.intellij_untitled_backing_saved_at = nil
      self.intellij_untitled_force_dirty = nil
      self.intellij_untitled_project_path = nil
    end
    return result
  end

  local core_confirm_close_docs = core.confirm_close_docs
  function core.confirm_close_docs(docs, close_fn, ...)
    local filtered, dirty_untitled, explicit_untitled = {}, {}, {}
    local explicit_bulk_close = core.root_panel and close_fn == core.root_panel.close_all_views
    for _, doc in ipairs(docs or core.docs) do
      if is_untitled_doc(doc) then
        if explicit_bulk_close then explicit_untitled[#explicit_untitled + 1] = doc end
        if doc:is_dirty() and untitled_doc_has_promptable_content(doc) then dirty_untitled[#dirty_untitled + 1] = doc end
      else
        filtered[#filtered + 1] = doc
      end
    end

    local function discard_explicit_untitled_then_close(...)
      local result = table.pack(pcall(close_fn, ...))
      if result[1] then
        for _, doc in ipairs(explicit_untitled) do
          if #core.get_views_referencing_doc(doc) == 0 then
            untitled_recovery.handle_confirmed_discard(doc)
          end
        end
        return table.unpack(result, 2, result.n)
      end
      error(result[2], 0)
    end

    -- App quit/restart persists open untitled docs through the workspace plugin,
    -- so do not warn there.  Explicit tab-closing operations (close all/others)
    -- remove the tabs from the workspace, so warn before discarding them.
    if #dirty_untitled > 0 and explicit_bulk_close then
      local args = { ... }
      local text = #dirty_untitled == 1
        and string.format("Closing %s will permanently discard this untitled document. Close it anyway?", dirty_untitled[1].intellij_untitled_name or "Untitled")
        or string.format("Closing %d untitled documents will permanently discard them. Close them anyway?", #dirty_untitled)
      for _, doc in ipairs(dirty_untitled) do
        untitled_recovery.flush_doc(doc, "close untitled tabs prompt", true)
      end
      core.nag_view:show(
        "Close Untitled Tabs",
        text,
        {
          { text = "Close", default_yes = true },
          { text = "Cancel", default_no = true },
        },
        function(item)
          if item.text == "Close" then
            core_confirm_close_docs(filtered, discard_explicit_untitled_then_close, table.unpack(args))
          end
        end
      )
      return
    end

    return core_confirm_close_docs(filtered, discard_explicit_untitled_then_close, ...)
  end

  local docview_try_close = DocView.try_close
  function DocView:try_close(do_close)
    if is_untitled_doc(self.doc) and not untitled_doc_has_promptable_content(self.doc) then
      local doc = self.doc
      local ok, err = pcall(do_close)
      if ok then
        if #core.get_views_referencing_doc(doc) == 0 then
          untitled_recovery.handle_confirmed_discard(doc)
        end
        return
      end
      error(err, 0)
    end

    if is_untitled_doc(self.doc)
       and self.doc:is_dirty()
       and #core.get_views_referencing_doc(self.doc) == 1 then
      local name = self.doc.intellij_untitled_name or "Untitled"
      untitled_recovery.flush_doc(self.doc, "tab close prompt", true)
      core.nag_view:show(
        "Close Untitled Tab",
        string.format("Closing %s will permanently discard this untitled document. Close it anyway?", name),
        {
          { text = "Close", default_yes = true },
          { text = "Cancel", default_no = true },
        },
        function(item)
          if item.text == "Close" then
            local doc = self.doc
            local ok, err = pcall(do_close)
            if ok then
              if #core.get_views_referencing_doc(doc) == 0 then
                untitled_recovery.handle_confirmed_discard(doc)
              end
            else
              error(err, 0)
            end
          end
        end
      )
      return
    end
    if is_untitled_doc(self.doc) and #core.get_views_referencing_doc(self.doc) == 1 then
      local original_do_close = do_close
      local doc = self.doc
      do_close = function()
        local result = table.pack(pcall(original_do_close))
        if result[1] then
          if #core.get_views_referencing_doc(doc) == 0 then
            untitled_recovery.handle_confirmed_discard(doc)
          end
          return table.unpack(result, 2, result.n)
        end
        error(result[2], 0)
      end
    end
    return docview_try_close(self, do_close)
  end

  local tabs_get_tab_width = Tabs.get_tab_width
  local tabs_get_tab_width_cache_token = Tabs.get_tab_width_cache_token
  local function untitled_tab_width_cache_token(tabbar, idx, view)
    local doc = view and view.doc
    if is_untitled_doc(doc) then
      return table.concat({
        "untitled",
        tostring(doc.intellij_untitled_name),
        tostring(doc:is_dirty()),
        tostring(doc.get_change_id and doc:get_change_id() or 0),
        tostring(#(doc.lines or {})),
        tostring(style.font),
        tostring(style.font:get_size()),
        tostring(style.padding.x),
        tostring(style.divider_size),
        tostring(style.tab_min_width),
        tostring(style.tab_max_width),
        tostring(SCALE),
      }, "\31")
    end
    return tabs_get_tab_width_cache_token(tabbar, idx, view)
  end

  function Tabs:get_tab_width(idx)
    local function compute_width()
      local view = self:item(idx)
      local font = self:get_tab_title_font()
      local width = untitled_tab_title_width(view, font)
      if width then
        local min_w = math.max(1, style.tab_min_width)
        local max_w = math.max(min_w, style.tab_max_width)
        return common.clamp(width, min_w, max_w)
      end
      return tabs_get_tab_width(self, idx)
    end
    if self.get_cached_tab_width then
      return self:get_cached_tab_width(idx, compute_width, untitled_tab_width_cache_token)
    end
    return compute_width()
  end

  local tabs_draw_tab_title = Tabs.draw_tab_title
  function Tabs:draw_tab_title(view, font, is_active, is_hovered, x, y, w, h, color_override)
    if draw_untitled_tab_title(view, font, is_active, is_hovered, x, y, w, h, color_override) then return end
    return tabs_draw_tab_title(self, view, font, is_active, is_hovered, x, y, w, h, color_override)
  end
end

local function prompt_text_for_directory(dirname)
  local root = core.root_project and core.root_project()
  if dirname and root and (common.path_equals(dirname, root.path) or common.path_belongs_to(dirname, root.path)) then
    if common.path_equals(dirname, root.path) then return "" end
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

local function trim_path_input(text)
  return common.sanitize_prompt_path(text)
end

local function path_text_is_directory(text)
  local last = text:sub(-1)
  return last == "/" or last == "\\"
end

local function ensure_directory_exists(abs, display_path)
  local info = system.get_file_info(abs)
  if info then
    if info.type == "dir" then return true, true end
    core.error("Path exists and is not a directory: %s", display_path or abs)
    return false
  end

  local ok, err, path = common.mkdirp(abs)
  if not ok then
    info = system.get_file_info(abs)
    if err == "path exists" and info and info.type == "dir" then
      return true, true
    end
    core.error("Cannot create directory %q: %s", path or abs, err or "unknown error")
    return false
  end
  core.log_quiet("Created directory hierarchy \"%s\"", abs)
  return true, false
end

local function ensure_parent_directory_exists(abs)
  local parent = common.dirname(abs)
  if not parent then return true end

  local info = system.get_file_info(parent)
  if info then
    if info.type == "dir" then return true end
    core.error("Parent path exists and is not a directory: %s", parent)
    return false
  end

  local ok, err, path = common.mkdirp(parent)
  if not ok then
    info = system.get_file_info(parent)
    if err == "path exists" and info and info.type == "dir" then return true end
    core.error("Cannot create parent directory %q: %s", path or parent, err or "unknown error")
    return false
  end
  core.log_quiet("Created parent directory hierarchy \"%s\"", parent)
  return true
end

local function create_directory_path(normalized, abs)
  local ok, existed = ensure_directory_exists(abs, normalized)
  if not ok then return end

  command.perform("filetree:sync-path", abs)
  if existed then
    core.log("Folder already exists \"%s\"", normalized)
  else
    core.log("Created folder \"%s\"", normalized)
  end
end

local function create_empty_file(text)
  local trimmed = trim_path_input(text)
  if trimmed == "" then return end

  local is_directory = path_text_is_directory(trimmed)
  local filename = common.home_expand(trimmed)
  local normalized = core.normalize_to_project_dir(filename)
  local abs = core.project_absolute_path(normalized)

  if is_directory then
    create_directory_path(normalized, abs)
    return
  end

  if not ensure_parent_directory_exists(abs) then return end

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
    core.global_prompt_bar:enter("New File or Folder", {
      text = default_new_file_text(),
      submit = create_empty_file,
      suggest = function(text)
        return common.home_encode_list(common.path_suggest(common.home_expand(common.sanitize_prompt_path(text))))
      end,
    })
  end,
})

keymap.add_direct {
  ["ctrl+t"] = "user:new-untitled-tab",
  ["ctrl+shift+n"] = "user:new-file-with-path",
}

return M
