-- mod-version:3
-- VSCode-like untitled tabs on top of Anvil's built-in unnamed buffers.

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local Tabs = require "core.tabs"
local untitled_recovery = require "plugins.untitled_recovery"

local M = {}
local untitled_id_counter = 0
local TITLE_SNIPPET_MAX_BYTES = 160

local function is_untitled_buffer(buffer)
  return buffer and buffer.intellij_untitled and buffer.new_file and not buffer.filename
end

local function untitled_buffer_has_promptable_content(buffer)
  return buffer and buffer:get_text(1, 1, math.huge, math.huge) ~= ""
end

local function untitled_index(name)
  return tonumber(tostring(name or ""):match("^Untitled%-(%d+)$"))
end

local function next_untitled_name()
  local used = {}
  for _, buffer in ipairs(core.buffers or {}) do
    local idx = untitled_index(buffer.intellij_untitled_name)
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

local function ensure_untitled_id(buffer, id)
  if not buffer then return nil end
  buffer.intellij_untitled_id = id or buffer.intellij_untitled_id or new_untitled_id()
  return buffer.intellij_untitled_id
end

M.ensure_untitled_id = ensure_untitled_id

local function tag_buffer(buffer, name, id)
  if not buffer or buffer.filename then return buffer end
  buffer.intellij_untitled = true
  buffer.intellij_untitled_name = name or buffer.intellij_untitled_name or next_untitled_name()
  buffer.display_name = buffer.intellij_untitled_name
  ensure_untitled_id(buffer, id)
  untitled_recovery.ensure_buffer_backing(buffer, { no_manifest = true })
  return buffer
end
M.tag_buffer = tag_buffer

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

local function first_text_snippet(buffer)
  if not buffer then return nil end
  local change_id = buffer.get_change_id and buffer:get_change_id() or nil
  local line_count = #(buffer.lines or {})
  local cache = buffer.intellij_untitled_snippet_cache
  if cache and cache.change_id == change_id and cache.line_count == line_count then
    return cache.value
  end

  local snippet
  for _, line in ipairs(buffer.lines or {}) do
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

  buffer.intellij_untitled_snippet_cache = {
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

local function title_gap()
  return math.max(2 * SCALE, style.padding.x * 0.35)
end

local function untitled_tab_title_width(view, font)
  local buffer = view and view.buffer
  if not is_untitled_buffer(buffer) then return nil end

  local secondary = buffer.intellij_untitled_name or "Untitled"
  if buffer:is_dirty() then secondary = secondary .. "*" end

  local primary = first_text_snippet(buffer)
  local width = font:get_width(secondary)
  if primary and primary ~= "" then
    width = width + title_gap() + font:get_width(primary)
  end
  return width + style.padding.x * 2 + style.divider_size * 2
end

local function draw_untitled_tab_title(view, font, is_active, is_hovered, x, y, w, h, color_override)
  local buffer = view and view.buffer
  if not is_untitled_buffer(buffer) then return false end

  local secondary = buffer.intellij_untitled_name or "Untitled"
  if buffer:is_dirty() then secondary = secondary .. "*" end

  local primary = first_text_snippet(buffer)
  local title_color = color_override or ((is_active or is_hovered) and style.text or style.dim)
  local primary_color = title_color
  local secondary_color = title_color
  local sfont = font
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

  local editor_get_state = Editor.get_state
  function Editor:get_state()
    local state = editor_get_state(self)
    if is_untitled_buffer(self.buffer) then
      local recovery_state = untitled_recovery.state_for_buffer(self.buffer)
      state.intellij_untitled = true
      state.intellij_untitled_name = self.buffer.intellij_untitled_name
      state.intellij_untitled_id = ensure_untitled_id(self.buffer)
      state.intellij_untitled_backing = recovery_state and recovery_state.intellij_untitled_backing
      state.intellij_untitled_backing_current = recovery_state and recovery_state.intellij_untitled_backing_current or nil
      state.intellij_untitled_change_id = recovery_state and recovery_state.intellij_untitled_change_id or nil
      state.intellij_untitled_backing_saved_at = recovery_state and recovery_state.intellij_untitled_backing_saved_at or nil
      state.intellij_untitled_workspace_saved_at = recovery_state and recovery_state.intellij_untitled_workspace_saved_at or nil
      if recovery_state and recovery_state.intellij_untitled_backing_current then state.text = nil end
    end
    return state
  end

  local function open_untitled_buffer_by_id(id)
    if not id then return nil end
    for _, buffer in ipairs(core.buffers or {}) do
      if is_untitled_buffer(buffer) and buffer.intellij_untitled_id == id then return buffer end
    end
  end

  local function apply_view_state(view, state)
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

  local editor_from_state = Editor.from_state
  function Editor.from_state(state)
    if state and state.intellij_untitled then
      local existing_buffer = open_untitled_buffer_by_id(state.intellij_untitled_id)
      if existing_buffer then
        local view = Editor(existing_buffer)
        apply_view_state(view, state)
        if core.log_quiet then core.log_quiet("Untitled recovery: reused open buffer for restored view %s", state.intellij_untitled_id) end
        return view
      end
    end

    local view = editor_from_state(state)
    if view and view.buffer and state and state.intellij_untitled then
      tag_buffer(view.buffer, state.intellij_untitled_name, state.intellij_untitled_id)
      local loaded_backing = untitled_recovery.attach_from_workspace_state(view.buffer, state)
      if loaded_backing then apply_view_state(view, state) end
    end
    return view
  end

  local buffer_save = Buffer.save
  function Buffer:save(...)
    local old_untitled = is_untitled_buffer(self) and {
      id = self.intellij_untitled_id,
      name = self.intellij_untitled_name,
      backing_path = self.intellij_untitled_backing_path,
      backing_rel = self.intellij_untitled_backing_rel,
      project = self.intellij_untitled_project_path,
    } or nil
    if old_untitled then untitled_recovery.flush_buffer(self, "save as", true) end
    local result = buffer_save(self, ...)
    if old_untitled and self.filename then
      untitled_recovery.handle_save_as_success(self, old_untitled)
      self.intellij_untitled = nil
      self.intellij_untitled_name = nil
      self.display_name = nil
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

  local core_confirm_close_buffers = core.confirm_close_buffers
  function core.confirm_close_buffers(buffers, close_fn, ...)
    local filtered, dirty_untitled, explicit_untitled = {}, {}, {}
    local explicit_bulk_close = core.root_panel and close_fn == core.root_panel.close_all_views
    for _, buffer in ipairs(buffers or core.buffers) do
      if is_untitled_buffer(buffer) then
        if explicit_bulk_close then explicit_untitled[#explicit_untitled + 1] = buffer end
        if buffer:is_dirty() and untitled_buffer_has_promptable_content(buffer) then dirty_untitled[#dirty_untitled + 1] = buffer end
      else
        filtered[#filtered + 1] = buffer
      end
    end

    local function discard_explicit_untitled_then_close(...)
      local result = table.pack(pcall(close_fn, ...))
      if result[1] then
        for _, buffer in ipairs(explicit_untitled) do
          if #core.get_views_referencing_buffer(buffer) == 0 then
            untitled_recovery.handle_confirmed_discard(buffer)
          end
        end
        return table.unpack(result, 2, result.n)
      end
      error(result[2], 0)
    end

    -- App quit/restart persists open untitled buffers through the workspace plugin,
    -- so do not warn there.  Explicit tab-closing operations (close all/others)
    -- remove the tabs from the workspace, so warn before discarding them.
    if #dirty_untitled > 0 and explicit_bulk_close then
      local args = { ... }
      local text = #dirty_untitled == 1
        and string.format("Closing %s will permanently discard this untitled buffer. Close it anyway?", dirty_untitled[1].intellij_untitled_name or "Untitled")
        or string.format("Closing %d Untitled Editors will permanently discard them. Close them anyway?", #dirty_untitled)
      for _, buffer in ipairs(dirty_untitled) do
        untitled_recovery.flush_buffer(buffer, "close untitled tabs prompt", true)
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
            core_confirm_close_buffers(filtered, discard_explicit_untitled_then_close, table.unpack(args))
          end
        end
      )
      return
    end

    return core_confirm_close_buffers(filtered, discard_explicit_untitled_then_close, ...)
  end

  local editor_can_close = Editor.can_close
  local function approve_untitled_close(buffer, approve)
    local result = table.pack(pcall(approve))
    if result[1] then
      if #core.get_views_referencing_buffer(buffer) == 0 then
        untitled_recovery.handle_confirmed_discard(buffer)
      end
      return table.unpack(result, 2, result.n)
    end
    error(result[2], 0)
  end

  function Editor:can_close(approve)
    if is_untitled_buffer(self.buffer) and not untitled_buffer_has_promptable_content(self.buffer) then
      return approve_untitled_close(self.buffer, approve)
    end

    if is_untitled_buffer(self.buffer)
       and self.buffer:is_dirty()
       and #core.get_views_referencing_buffer(self.buffer) == 1 then
      local name = self.buffer.intellij_untitled_name or "Untitled"
      untitled_recovery.flush_buffer(self.buffer, "tab close prompt", true)
      core.nag_view:show(
        "Close Untitled Tab",
        string.format("Closing %s will permanently discard this untitled buffer. Close it anyway?", name),
        {
          { text = "Close", default_yes = true },
          { text = "Cancel", default_no = true },
        },
        function(item)
          if item.text == "Close" then
            approve_untitled_close(self.buffer, approve)
          end
        end
      )
      return
    end
    if is_untitled_buffer(self.buffer) and #core.get_views_referencing_buffer(self.buffer) == 1 then
      local buffer = self.buffer
      local original_approve = approve
      approve = function()
        return approve_untitled_close(buffer, original_approve)
      end
    end
    return editor_can_close(self, approve)
  end

  local editor_get_name = Editor.get_name
  function Editor:get_name()
    if is_untitled_buffer(self.buffer) then
      local name = self.buffer.intellij_untitled_name or "Untitled"
      local dirty = self.buffer:is_dirty()
        and untitled_buffer_has_promptable_content(self.buffer)
      return name .. (dirty and "*" or "")
    end
    return editor_get_name(self)
  end

  local tabs_get_tab_preferred_width = Tabs.get_tab_preferred_width
  local tabs_get_tab_width_cache_token = Tabs.get_tab_width_cache_token
  local function untitled_tab_width_cache_token(tabbar, idx, view)
    local buffer = view and view.buffer
    if is_untitled_buffer(buffer) then
      return table.concat({
        "untitled",
        tostring(buffer.intellij_untitled_name),
        tostring(buffer:is_dirty()),
        tostring(buffer.get_change_id and buffer:get_change_id() or 0),
        tostring(#(buffer.lines or {})),
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

  function Tabs:get_tab_preferred_width(idx)
    local function compute_width()
      local view = self:item(idx)
      local font = self:get_tab_title_font()
      local width = untitled_tab_title_width(view, font)
      if width then return width end
      return tabs_get_tab_preferred_width(self, idx)
    end
    if self.get_cached_tab_preferred_width then
      return self:get_cached_tab_preferred_width(idx, compute_width, untitled_tab_width_cache_token)
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
  local buffer = view.buffer
  if not buffer or type(buffer.get_selection) ~= "function" then return nil end
  local line = buffer:get_selection(true)
  local ok, entry = pcall(view.entry_for_line, view, line)
  if not ok or not entry or not entry.abs then return nil end
  local path = entry.type == "dir" and entry.abs or common.dirname(entry.abs)
  return nearest_existing_directory(path)
end

local function default_new_file_text()
  local view = core.active_view
  local filetree_dir = selected_filetree_directory(view)
  if filetree_dir then return prompt_text_for_directory(filetree_dir) end

  local buffer = view and view.buffer
  local filename = buffer and buffer.abs_filename
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

local function create_directory_path(normalized, abs, source_view)
  local ok, existed = ensure_directory_exists(abs, normalized)
  if not ok then return end

  command.perform("filetree:sync-path", abs, source_view)
  if existed then
    core.log("Folder already exists \"%s\"", normalized)
  else
    core.log("Created folder \"%s\"", normalized)
  end
end

local function create_empty_file(text, source_view)
  local trimmed = trim_path_input(text)
  if trimmed == "" then return end

  local is_directory = path_text_is_directory(trimmed)
  local filename = common.home_expand(trimmed)
  local normalized = core.normalize_to_project_dir(filename)
  local abs = core.project_absolute_path(normalized)

  if is_directory then
    create_directory_path(normalized, abs, source_view)
    return
  end

  if not ensure_parent_directory_exists(abs) then return end

  local buffer = core.open_buffer(normalized)
  core.root_panel:open_buffer(buffer)
  local ok, err = pcall(buffer.save, buffer, normalized, abs)
  if ok then
    command.perform("filetree:sync-path", abs, source_view)
    core.log("Created \"%s\"", normalized)
  else
    core.error(err)
  end
end

command.add(nil, {
  ["user:new-file-with-path"] = function()
    local panes = require "core.panes"
    local source_view = panes.owner_for_view(core.active_view) or core.active_view
    core.global_prompt_bar:enter("New File or Folder", {
      text = default_new_file_text(),
      submit = function(text) create_empty_file(text, source_view) end,
      suggest = function(text)
        return common.home_encode_list(common.path_suggest(
          common.home_expand(common.sanitize_prompt_path(text)), nil,
          config.max_visible_commands
        ))
      end,
    })
  end,
})

keymap.add_direct {
  ["ctrl+t"] = "pane:new",
  ["ctrl+shift+n"] = "user:new-file-with-path",
}

return M
