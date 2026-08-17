-- mod-version:3
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local untitled_recovery = require "plugins.untitled_recovery"

if config.plugins.autosave_fast == false then
  return { enabled = false, save_all_dirty = function() return 0 end }
end

local autosave_fast = config.plugins.autosave_fast

if autosave_fast.enabled == false then
  return { enabled = false, save_all_dirty = function() return 0 end }
end

local dirty_buffers = setmetatable({}, { __mode = "k" })
local disk_state = setmetatable({}, { __mode = "k" })
local save_generation = 0
local loop_running = false
local MAX_SNAPSHOT_CONTENT_SIZE = 5 * 1024 * 1024
local protected_init_path = system.absolute_path(USERDIR .. PATHSEP .. "init.lua")
local protected_project_root
local protected_project_file

local function is_protected_buffer(buffer)
  if not buffer or not buffer.abs_filename then return false end
  local root = core.root_project and core.root_project() or nil
  if root ~= protected_project_root then
    protected_project_root = root
    protected_project_file = root and root.absolute_path
      and root:absolute_path(".anvil_project.lua")
      or system.absolute_path(".anvil_project.lua")
  end
  return common.path_equals(buffer.abs_filename, protected_init_path)
      or common.path_equals(buffer.abs_filename, protected_project_file)
end

local function is_untitled_buffer(buffer)
  return buffer and buffer.intellij_untitled and buffer.new_file and not buffer.filename
end

local function has_control_chars(path)
  return type(path) == "string" and path:find("[%z\1-\31]") ~= nil
end

local function has_invalid_save_path(buffer)
  return buffer and (has_control_chars(buffer.filename) or has_control_chars(buffer.abs_filename))
end

local function read_file_contents(filename)
  local fp = io.open(filename, "rb")
  if not fp then return nil end
  local contents = fp:read("*a")
  fp:close()
  return contents
end

local function update_disk_state(buffer)
  if buffer and buffer.abs_filename then
    local info = system.get_file_info(buffer.abs_filename)
    if info then
      disk_state[buffer] = {
        modified = info.modified,
        size = info.size,
        content = info.size <= MAX_SNAPSHOT_CONTENT_SIZE and read_file_contents(buffer.abs_filename) or nil,
      }
    else
      disk_state[buffer] = nil
    end
  else
    disk_state[buffer] = nil
  end
end

local function save_target_missing(buffer)
  if not buffer or not buffer.abs_filename then return false end
  if not system.get_file_info(buffer.abs_filename) then return true end
  return false
end

local function disk_changed_since_load_or_save(buffer)
  if not buffer or not buffer.abs_filename then return false end
  local old = disk_state[buffer]
  local info = system.get_file_info(buffer.abs_filename)
  if old and not info then return true end
  if not old or not info then return false end
  if old.modified ~= info.modified or old.size ~= info.size then return true end
  if old.content and info.size <= MAX_SNAPSHOT_CONTENT_SIZE then
    return read_file_contents(buffer.abs_filename) ~= old.content
  end
  return false
end

local function clear_dirty_if_clean(buffer)
  if not buffer or not buffer.is_dirty or not buffer:is_dirty() then
    dirty_buffers[buffer] = nil
  end
end

local function clone_lines(lines)
  local copy = {}
  for i, line in ipairs(lines or {}) do
    copy[i] = line
  end
  if #copy == 0 then copy[1] = "\n" end
  return copy
end

local function split_extension(name)
  local stem, ext = name:match("^(.*)(%.[^%.]+)$")
  if not stem or stem == "" then return name, "" end
  return stem, ext
end

local function buffer_is_open(abs_filename)
  for _, open_buffer in ipairs(core.buffers or {}) do
    if common.path_equals(open_buffer.abs_filename, abs_filename) then return true end
  end
  return false
end

local function conflict_copy_path(buffer)
  local abs = buffer and buffer.abs_filename
  if not abs then return nil, nil end
  local dir = common.dirname(abs)
  local base = common.basename(abs)
  local stem, ext = split_extension(base)
  local prefix = stem .. ".anvil-copy"
  for i = 1, 1000 do
    local suffix = i == 1 and "" or ("-" .. i)
    local abs_candidate = (dir and (dir .. PATHSEP) or "") .. prefix .. suffix .. ext
    if not system.get_file_info(abs_candidate) and not buffer_is_open(abs_candidate) then
      return core.normalize_to_project_dir(abs_candidate), abs_candidate
    end
  end
  return nil, "could not allocate copy filename for " .. abs
end

local function save_conflict_copy_and_reload(buffer)
  if not buffer or not buffer.abs_filename then return false end

  local original_name = buffer.filename
  local original_abs = buffer.abs_filename
  local selection = { buffer:get_selection() }
  local snapshot = {
    lines = clone_lines(buffer.lines),
    crlf = buffer.crlf,
    encoding = buffer.encoding,
    bom = buffer.bom,
    binary = buffer.binary,
  }

  local copy_name, copy_abs = conflict_copy_path(buffer)
  if not copy_name then
    core.error("Couldn't save conflict copy: %s", copy_abs or "unknown error")
    return false
  end

  local copy_buffer = core.open_buffer(copy_name)
  copy_buffer:reset()
  copy_buffer:set_filename(copy_name, copy_abs)
  copy_buffer.lines = clone_lines(snapshot.lines)
  copy_buffer.crlf = snapshot.crlf
  copy_buffer.encoding = snapshot.encoding
  copy_buffer.bom = snapshot.bom
  copy_buffer.binary = snapshot.binary or false
  copy_buffer:reset_syntax()
  copy_buffer:clear_undo_redo()
  copy_buffer:set_selection(table.unpack(selection))

  local saved, save_err = pcall(copy_buffer.save, copy_buffer)
  if not saved then
    core.error("Couldn't save conflict copy %s: %s", copy_name, save_err)
    return false
  end

  local reloaded, reload_err = pcall(buffer.reload, buffer)
  if reloaded then
    update_disk_state(buffer)
    clear_dirty_if_clean(buffer)
  else
    core.error("Saved conflict copy %s, but couldn't reload %s: %s", copy_name, original_name or original_abs, reload_err)
  end

  update_disk_state(copy_buffer)
  clear_dirty_if_clean(copy_buffer)
  core.root_panel:open_buffer(copy_buffer)
  core.log("Saved conflict copy \"%s\"", copy_name)
  return true
end

local function save_buffer_recreating_missing_target(buffer, name)
  buffer.autosave_allow_recreate_missing = true
  local ok, err = pcall(buffer.save, buffer)
  buffer.autosave_allow_recreate_missing = nil
  if ok then
    update_disk_state(buffer)
    clear_dirty_if_clean(buffer)
    core.log("Saved \"%s\" as a new file", buffer.filename or name)
  else
    core.error("Couldn't save %s as a new file: %s", name, err)
  end
end

local function discard_missing_file_buffer(buffer, name)
  if not buffer then return end
  dirty_buffers[buffer] = nil
  disk_state[buffer] = nil
  buffer:clean()
  core.add_thread(function()
    -- Wait until NagView has finished closing before changing Pane Views.
    coroutine.yield(0)
    local panes = require "core.panes"
    local closed = 0
    for _, pane in ipairs(panes.ordered()) do
      for _, view in ipairs(panes.history_views(pane)) do
        if view.buffer == buffer then
          if panes.close_view(pane, { view = view, force = true }) then
          closed = closed + 1
          end
          break
        end
      end
    end
    core.log("Discarded missing file \"%s\"", buffer.filename or name)
    if closed == 0 then core.redraw = true end
  end)
end

local function show_conflict_prompt(buffer, explicit)
  if buffer.autosave_conflict_prompt_visible then return end
  buffer.autosave_conflict_prompt_visible = true
  local name = buffer.filename or buffer.abs_filename or "this file"
  local missing = save_target_missing(buffer)
  local buttons
  if missing then
    buttons = {
      { font = style.font, text = "Save as New File", default_yes = true },
      { font = style.font, text = "Discard File" },
      { font = style.font, text = "Cancel", default_no = true },
    }
  else
    buttons = {
      { font = style.font, text = "Overwrite Disk", default_yes = false },
      { font = style.font, text = "Reload From Disk (Discard Anvil Edits)" },
    }
    if explicit then
      buttons[#buttons + 1] = { font = style.font, text = "Save Copy of Current File" }
    end
    buttons[#buttons + 1] = { font = style.font, text = "Cancel", default_no = true }
  end

  core.nag_view:show(
    missing and "File Missing on Disk" or "File Changed on Disk",
    missing and string.format(
      "%s no longer exists at its saved path.\n\nAnvil can save your current buffer as a new file at the same path and recreate any missing parent folders, or discard it and close the buffer.",
      name
    ) or string.format(
      "%s has changed on disk since Anvil loaded or saved it.\n\nAnvil did not overwrite it. Reloading from disk will discard your unsaved Anvil edits. What do you want to do?",
      name
    ),
    buttons,
    function(item)
      buffer.autosave_conflict_prompt_visible = false
      if item.text == "Save as New File" then
        save_buffer_recreating_missing_target(buffer, name)
      elseif item.text == "Discard File" then
        discard_missing_file_buffer(buffer, name)
      elseif item.text == "Overwrite Disk" then
        buffer.autosave_ignore_next_conflict = true
        local ok, err = pcall(buffer.save, buffer)
        buffer.autosave_ignore_next_conflict = nil
        if ok then
          update_disk_state(buffer)
          clear_dirty_if_clean(buffer)
          core.log("Saved \"%s\"", buffer.filename or name)
        else
          core.error("Couldn't save %s: %s", name, err)
        end
      elseif item.text == "Reload From Disk (Discard Anvil Edits)" then
        local ok, err = pcall(buffer.reload, buffer)
        if ok then
          update_disk_state(buffer)
          clear_dirty_if_clean(buffer)
          core.log("Reloaded \"%s\"", buffer.filename or name)
        else
          core.error("Couldn't reload %s: %s", name, err)
        end
      elseif item.text == "Save Copy of Current File" then
        core.add_thread(function()
          -- Wait until NagView has finished closing; opening a new tab while
          -- the modal owns the active locked node raises "Tried to add view
          -- to locked node".
          coroutine.yield(0)
          save_conflict_copy_and_reload(buffer)
        end)
      end
    end
  )
end

local function should_autosave_buffer(buffer)
  return autosave_fast.enabled
    and buffer
    and buffer.filename
    and not has_invalid_save_path(buffer)
    and not is_protected_buffer(buffer)
    and buffer.is_dirty
    and buffer:is_dirty()
end

local function should_hide_dirty_marker(buffer)
  return autosave_fast.enabled
    and autosave_fast.hide_dirty_markers ~= false
    and buffer
    and buffer.filename
    and not has_invalid_save_path(buffer)
    and not is_protected_buffer(buffer)
end

function autosave_fast.should_hide_dirty_marker(buffer)
  return should_hide_dirty_marker(buffer)
end

local function save_buffer(buffer, reason)
  if is_untitled_buffer(buffer) then
    untitled_recovery.flush_buffer(buffer, reason or "autosave", true)
    dirty_buffers[buffer] = nil
    return false
  end
  if not should_autosave_buffer(buffer) then
    clear_dirty_if_clean(buffer)
    return false
  end

  buffer.autosave_save_reason = reason or true
  local ok, err = pcall(buffer.save, buffer)
  buffer.autosave_save_reason = nil
  if ok then
    update_disk_state(buffer)
    clear_dirty_if_clean(buffer)
    core.log_quiet("Autosaved \"%s\"%s", buffer.filename, reason and (" (" .. reason .. ")") or "")
    return true
  end
  if disk_changed_since_load_or_save(buffer) then
    show_conflict_prompt(buffer, false)
    return false, "conflict"
  else
    core.error("Autosave failed for %s: %s", buffer.filename or "buffer", err)
  end
  return false, err
end

function autosave_fast.save_all_dirty(reason)
  -- Include buffers dirtied by commands/plugins that may not route through
  -- Buffer:on_text_change after this plugin was loaded.
  for _, buffer in ipairs(core.buffers or {}) do
    if should_autosave_buffer(buffer) then dirty_buffers[buffer] = true end
  end

  untitled_recovery.flush_all(reason or "autosave all")

  local saved = 0
  for buffer in pairs(dirty_buffers) do
    if save_buffer(buffer, reason) then saved = saved + 1 end
  end
  return saved
end

function autosave_fast.save_before_close(buffer, reason)
  if not should_autosave_buffer(buffer) then return false, false end
  local saved, failure = save_buffer(buffer, reason or "tab close")
  if saved and not buffer:is_dirty() then return true, true end
  if failure == "conflict" or buffer.autosave_conflict_prompt_visible then
    return false, true
  end
  core.log_quiet(
    "Autosave before close failed for %s; falling back to normal dirty-close prompt",
    buffer.filename or "buffer"
  )
  return false, false
end

local function schedule_idle_save()
  save_generation = save_generation + 1
  if loop_running then return end
  loop_running = true
  core.add_thread(function()
    local seen
    repeat
      seen = save_generation
      coroutine.yield(autosave_fast.timeout)
    until seen == save_generation

    autosave_fast.save_all_dirty("idle")
    loop_running = false
    if seen ~= save_generation then schedule_idle_save() end
  end)
end

local on_text_change = Buffer.on_text_change
function Buffer:on_text_change(type, transaction, ...)
  local result = on_text_change(self, type, transaction, ...)
  if autosave_fast.enabled then
    if is_untitled_buffer(self) then
      dirty_buffers[self] = nil
    elseif self.filename and not is_protected_buffer(self) then
      dirty_buffers[self] = true
      schedule_idle_save()
    end
  end
  return result
end

local load = Buffer.load
function Buffer:load(...)
  local result = load(self, ...)
  update_disk_state(self)
  clear_dirty_if_clean(self)
  return result
end

local save = Buffer.save
function Buffer:save(filename, abs_filename)
  local was_untitled = is_untitled_buffer(self)
  local saving_current_file = not filename
    or (self.abs_filename and abs_filename and common.path_equals(self.abs_filename, abs_filename))
  if saving_current_file
     and self.filename
     and not self.autosave_ignore_next_conflict
     and not is_protected_buffer(self)
     and disk_changed_since_load_or_save(self) then
    if self.autosave_allow_recreate_missing and save_target_missing(self) then
      core.log_quiet("Saving missing file target as a new file: %s", self.filename)
    else
      if not self.deferred_reload then
        show_conflict_prompt(self, not self.autosave_save_reason)
      end
      error(string.format("not saving %s: file changed on disk", self.filename))
    end
  end
  local result = save(self, filename, abs_filename)
  update_disk_state(self)
  clear_dirty_if_clean(self)
  if was_untitled then untitled_recovery.flush_all("save as") end
  return result
end

local on_close = Buffer.on_close
function Buffer:on_close(...)
  dirty_buffers[self] = nil
  disk_state[self] = nil
  local result = on_close(self, ...)
  return result
end

local core_set_active_view = core.set_active_view
function core.set_active_view(view, focus_context)
  focus_context = focus_context or core.focus_change_context(2)
  local previous = core.active_view
  local previous_buffer = previous and previous.buffer
  local result = core_set_active_view(view, focus_context)
  local next_buffer = core.active_view and core.active_view.buffer
  if previous_buffer and previous_buffer ~= next_buffer and TextView:is_extended_by(previous) then
    save_buffer(previous_buffer, "buffer focus lost")
  end
  return result
end

local textview_try_close = TextView.try_close
function TextView:try_close(do_close)
  if has_invalid_save_path(self.buffer) then
    if core.log_quiet then core.log_quiet("Closing invalid saved-path tab without save prompt: %q", self.buffer.filename or self.buffer.abs_filename) end
    do_close()
    return
  end
  if self.buffer:is_dirty()
     and #core.get_views_referencing_buffer(self.buffer) == 1 then
    local saved, handled = autosave_fast.save_before_close(self.buffer, "tab close")
    if saved then
      do_close()
      return
    elseif handled then
      return
    end
  end
  return textview_try_close(self, do_close)
end

local textview_get_name = TextView.get_name
function TextView:get_name()
  local name = textview_get_name(self)
  if self.buffer and self.buffer:is_dirty() and should_hide_dirty_marker(self.buffer) then
    return (name:gsub("%*$", ""))
  end
  return name
end

local textview_get_filename = TextView.get_filename
function TextView:get_filename()
  local filename = textview_get_filename(self)
  if self.buffer and self.buffer:is_dirty() and should_hide_dirty_marker(self.buffer) then
    return (filename:gsub("%*$", ""))
  end
  return filename
end

local core_get_view_title = core.get_view_title
function core.get_view_title(view)
  local title = core_get_view_title(view)
  local buffer = view and view.buffer
  if buffer and buffer.is_dirty and buffer:is_dirty() and should_hide_dirty_marker(buffer) then
    title = title:gsub("%* %-", " -", 1):gsub("%*$", "")
  end
  return title
end

local core_confirm_close_buffers = core.confirm_close_buffers
function core.confirm_close_buffers(buffers, close_fn, ...)
  for _, buffer in ipairs(buffers or core.buffers or {}) do
    if buffer and buffer.is_dirty and buffer:is_dirty() then
      local saved, handled = autosave_fast.save_before_close(buffer, "close")
      if handled and not saved then return end
    end
  end
  return core_confirm_close_buffers(buffers, close_fn, ...)
end

for _, buffer in ipairs(core.buffers or {}) do
  update_disk_state(buffer)
end

return autosave_fast
