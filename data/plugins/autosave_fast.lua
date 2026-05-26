-- mod-version:3
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local storage = require "core.storage"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"

if config.plugins.autosave_fast == false then
  return { enabled = false, save_all_dirty = function() return 0 end }
end

local autosave_fast = common.merge({
  enabled = true,
  -- Save after this many seconds with no further edits.
  timeout = 3,
  -- IntelliJ-style autosave keeps normal file tabs visually clean: dirty
  -- file-backed docs are saved automatically, so don't expose a transient
  -- unsaved marker while the idle timer has not fired yet.
  hide_dirty_markers = true,
}, type(config.plugins.autosave_fast) == "table" and config.plugins.autosave_fast or {})
config.plugins.autosave_fast = autosave_fast

if autosave_fast.enabled == false then
  return { enabled = false, save_all_dirty = function() return 0 end }
end

local dirty_docs = setmetatable({}, { __mode = "k" })
local disk_state = setmetatable({}, { __mode = "k" })
local save_generation = 0
local loop_running = false
local recovery_restored = false
local recovery_dirty = false

local RECOVERY_MODULE = "untitled_recovery"
local MAX_SNAPSHOT_CONTENT_SIZE = 5 * 1024 * 1024

local function project_key()
  local project = core.root_project and core.root_project()
  return project and project.path or "default"
end

local function is_protected_doc(doc)
  if not doc or not doc.abs_filename then return false end
  local init_path = system.absolute_path(USERDIR .. PATHSEP .. "init.lua")
  local project_file = core.project_absolute_path and core.project_absolute_path(".anvil_project.lua")
    or system.absolute_path(".anvil_project.lua")
  return doc.abs_filename == init_path or doc.abs_filename == project_file
end

local function is_untitled_doc(doc)
  return doc and doc.intellij_untitled and doc.new_file and not doc.filename
end

local function read_file_contents(filename)
  local fp = io.open(filename, "rb")
  if not fp then return nil end
  local contents = fp:read("*a")
  fp:close()
  return contents
end

local function update_disk_state(doc)
  if doc and doc.abs_filename then
    local info = system.get_file_info(doc.abs_filename)
    if info then
      disk_state[doc] = {
        modified = info.modified,
        size = info.size,
        content = info.size <= MAX_SNAPSHOT_CONTENT_SIZE and read_file_contents(doc.abs_filename) or nil,
      }
    else
      disk_state[doc] = nil
    end
  else
    disk_state[doc] = nil
  end
end

local function disk_changed_since_load_or_save(doc)
  if not doc or not doc.abs_filename then return false end
  local old = disk_state[doc]
  local info = system.get_file_info(doc.abs_filename)
  if old and not info then return true end
  if not old or not info then return false end
  if old.modified ~= info.modified or old.size ~= info.size then return true end
  if old.content and info.size <= MAX_SNAPSHOT_CONTENT_SIZE then
    return read_file_contents(doc.abs_filename) ~= old.content
  end
  return false
end

local function clear_dirty_if_clean(doc)
  if not doc or not doc.is_dirty or not doc:is_dirty() then
    dirty_docs[doc] = nil
  end
end

local function save_doc_as(doc, default_name)
  core.command_view:enter("Save As", {
    text = default_name or doc.filename,
    submit = function(filename)
      filename = common.home_expand(filename)
      local normalized = core.normalize_to_project_dir(filename)
      local abs = core.project_absolute_path(normalized)
      local ok, err = pcall(doc.save, doc, normalized, abs)
      if ok then
        update_disk_state(doc)
        clear_dirty_if_clean(doc)
        core.log("Saved \"%s\"", doc.filename)
      else
        core.error("Couldn't save %s: %s", normalized, err)
      end
    end,
    suggest = function(text)
      return common.home_encode_list(common.path_suggest(common.home_expand(text)))
    end,
  })
end

local function show_conflict_prompt(doc, explicit)
  if doc.autosave_conflict_prompt_visible then return end
  doc.autosave_conflict_prompt_visible = true
  local name = doc.filename or doc.abs_filename or "this file"
  local buttons = {
    { font = style.font, text = "Overwrite Disk", default_yes = false },
    { font = style.font, text = "Reload From Disk (Discard Anvil Edits)" },
  }
  if explicit then
    buttons[#buttons + 1] = { font = style.font, text = "Save As..." }
  end
  buttons[#buttons + 1] = { font = style.font, text = "Cancel", default_no = true }

  core.nag_view:show(
    "File Changed on Disk",
    string.format(
      "%s has changed on disk since Anvil loaded or saved it.\n\nAnvil did not overwrite it. Reloading from disk will discard your unsaved Anvil edits. What do you want to do?",
      name
    ),
    buttons,
    function(item)
      doc.autosave_conflict_prompt_visible = false
      if item.text == "Overwrite Disk" then
        doc.autosave_ignore_next_conflict = true
        local ok, err = pcall(doc.save, doc)
        doc.autosave_ignore_next_conflict = nil
        if ok then
          update_disk_state(doc)
          clear_dirty_if_clean(doc)
          core.log("Saved \"%s\"", doc.filename or name)
        else
          core.error("Couldn't save %s: %s", name, err)
        end
      elseif item.text == "Reload From Disk (Discard Anvil Edits)" then
        local ok, err = pcall(doc.reload, doc)
        if ok then
          update_disk_state(doc)
          clear_dirty_if_clean(doc)
          core.log("Reloaded \"%s\"", doc.filename or name)
        else
          core.error("Couldn't reload %s: %s", name, err)
        end
      elseif item.text == "Save As..." then
        core.add_thread(function()
          save_doc_as(doc, name)
        end)
      end
    end
  )
end

local function should_autosave_doc(doc)
  return autosave_fast.enabled
    and doc
    and doc.filename
    and not is_protected_doc(doc)
    and doc.is_dirty
    and doc:is_dirty()
end

local function should_hide_dirty_marker(doc)
  return autosave_fast.enabled
    and autosave_fast.hide_dirty_markers ~= false
    and doc
    and doc.filename
    and not is_protected_doc(doc)
end

function autosave_fast.should_hide_dirty_marker(doc)
  return should_hide_dirty_marker(doc)
end

local function collect_untitled_recovery()
  local items = {}
  for _, doc in ipairs(core.docs or {}) do
    if is_untitled_doc(doc) then
      items[#items + 1] = {
        name = doc.intellij_untitled_name,
        text = doc:get_text(1, 1, math.huge, math.huge),
        crlf = doc.crlf,
      }
    end
  end
  return items
end

local function save_untitled_recovery(force)
  if not force and not recovery_dirty then return end
  recovery_dirty = false
  local items = collect_untitled_recovery()
  if #items > 0 then
    storage.save(RECOVERY_MODULE, project_key(), {
      project = project_key(),
      saved_at = os.time(),
      documents = items,
    })
  else
    storage.clear(RECOVERY_MODULE, project_key())
  end
end

local function same_untitled_exists(name, text)
  for _, doc in ipairs(core.docs or {}) do
    if is_untitled_doc(doc)
       and doc.intellij_untitled_name == name
       and doc:get_text(1, 1, math.huge, math.huge) == text then
      return true
    end
  end
  return false
end

local function restore_untitled_recovery()
  if recovery_restored then return end
  recovery_restored = true
  local data = storage.load(RECOVERY_MODULE, project_key())
  if type(data) ~= "table" or type(data.documents) ~= "table" then return end

  local restored = 0
  for _, item in ipairs(data.documents) do
    if type(item) == "table" and type(item.text) == "string"
       and not same_untitled_exists(item.name, item.text) then
      local doc = core.open_doc()
      doc.intellij_untitled = true
      doc.intellij_untitled_name = item.name
      doc.crlf = item.crlf
      doc.lines = {}
      for line in (item.text .. "\n"):gmatch("(.-\n)") do
        doc.lines[#doc.lines + 1] = line
      end
      if #doc.lines == 0 then doc.lines[1] = "\n" end
      doc:reset_syntax()
      doc:clear_undo_redo()
      doc:clean()
      core.root_view:open_doc(doc)
      restored = restored + 1
    end
  end
  if restored > 0 then
    core.log_quiet("Restored %d untitled autosave buffer(s)", restored)
  end
end

local function note_untitled_snapshot(doc)
  if is_untitled_doc(doc) then
    dirty_docs[doc] = nil
    recovery_dirty = true
  end
end

local function save_doc(doc, reason)
  if is_untitled_doc(doc) then
    note_untitled_snapshot(doc)
    return false
  end
  if not should_autosave_doc(doc) then
    clear_dirty_if_clean(doc)
    return false
  end

  doc.autosave_save_reason = reason or true
  local ok, err = pcall(doc.save, doc)
  doc.autosave_save_reason = nil
  if ok then
    update_disk_state(doc)
    clear_dirty_if_clean(doc)
    core.log_quiet("Autosaved \"%s\"%s", doc.filename, reason and (" (" .. reason .. ")") or "")
    return true
  end
  if disk_changed_since_load_or_save(doc) then
    show_conflict_prompt(doc, false)
  else
    core.error("Autosave failed for %s: %s", doc.filename or "document", err)
  end
  return false
end

function autosave_fast.save_all_dirty(reason)
  -- Include docs dirtied by commands/plugins that may not route through
  -- Doc:on_text_change after this plugin was loaded.
  for _, doc in ipairs(core.docs or {}) do
    if should_autosave_doc(doc) then dirty_docs[doc] = true end
  end

  save_untitled_recovery(true)

  local saved = 0
  for doc in pairs(dirty_docs) do
    if save_doc(doc, reason) then saved = saved + 1 end
  end
  return saved
end

function autosave_fast.save_before_close(doc, reason)
  if not should_autosave_doc(doc) then return false, false end
  local saved = save_doc(doc, reason or "tab close")
  return saved and not doc:is_dirty(), true
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

local on_text_change = Doc.on_text_change
function Doc:on_text_change(type)
  local result = on_text_change(self, type)
  if autosave_fast.enabled then
    if is_untitled_doc(self) then
      note_untitled_snapshot(self)
      schedule_idle_save()
    elseif self.filename and not is_protected_doc(self) then
      dirty_docs[self] = true
      schedule_idle_save()
    end
  end
  return result
end

local load = Doc.load
function Doc:load(...)
  local result = load(self, ...)
  update_disk_state(self)
  clear_dirty_if_clean(self)
  return result
end

local save = Doc.save
function Doc:save(filename, abs_filename)
  local was_untitled = is_untitled_doc(self)
  local saving_current_file = not filename
    or (self.abs_filename and abs_filename and self.abs_filename == abs_filename)
  if saving_current_file
     and self.filename
     and not self.autosave_ignore_next_conflict
     and not is_protected_doc(self)
     and disk_changed_since_load_or_save(self) then
    if not self.deferred_reload then
      show_conflict_prompt(self, not self.autosave_save_reason)
    end
    error(string.format("not saving %s: file changed on disk", self.filename))
  end
  local result = save(self, filename, abs_filename)
  update_disk_state(self)
  clear_dirty_if_clean(self)
  if was_untitled then recovery_dirty = true end
  save_untitled_recovery(was_untitled)
  return result
end

local on_close = Doc.on_close
function Doc:on_close(...)
  dirty_docs[self] = nil
  disk_state[self] = nil
  local result = on_close(self, ...)
  recovery_dirty = true
  save_untitled_recovery(false)
  return result
end

local core_set_active_view = core.set_active_view
function core.set_active_view(view)
  local previous = core.active_view
  local previous_doc = previous and previous.doc
  local result = core_set_active_view(view)
  local next_doc = core.active_view and core.active_view.doc
  if previous_doc and previous_doc ~= next_doc and DocView:is_extended_by(previous) then
    save_doc(previous_doc, "document focus lost")
  end
  return result
end

local docview_try_close = DocView.try_close
function DocView:try_close(do_close)
  if self.doc:is_dirty()
     and #core.get_views_referencing_doc(self.doc) == 1 then
    local saved, handled = autosave_fast.save_before_close(self.doc, "tab close")
    if saved then
      do_close()
      return
    elseif handled then
      return
    end
  end
  return docview_try_close(self, do_close)
end

local docview_get_name = DocView.get_name
function DocView:get_name()
  local name = docview_get_name(self)
  if self.doc and self.doc:is_dirty() and should_hide_dirty_marker(self.doc) then
    return (name:gsub("%*$", ""))
  end
  return name
end

local docview_get_filename = DocView.get_filename
function DocView:get_filename()
  local filename = docview_get_filename(self)
  if self.doc and self.doc:is_dirty() and should_hide_dirty_marker(self.doc) then
    return (filename:gsub("%*$", ""))
  end
  return filename
end

local core_get_view_title = core.get_view_title
function core.get_view_title(view)
  local title = core_get_view_title(view)
  local doc = view and view.doc
  if doc and doc.is_dirty and doc:is_dirty() and should_hide_dirty_marker(doc) then
    title = title:gsub("%* %-", " -", 1):gsub("%*$", "")
  end
  return title
end

local core_confirm_close_docs = core.confirm_close_docs
function core.confirm_close_docs(docs, close_fn, ...)
  for _, doc in ipairs(docs or core.docs or {}) do
    if doc and doc.is_dirty and doc:is_dirty() then
      local saved, handled = autosave_fast.save_before_close(doc, "close")
      if handled and not saved then return end
    end
  end
  return core_confirm_close_docs(docs, close_fn, ...)
end

for _, doc in ipairs(core.docs or {}) do
  update_disk_state(doc)
end

core.add_thread(function()
  -- Let workspace/session restoration run first, then add any autosaved
  -- untitled buffers not already restored by workspace state.
  coroutine.yield(3)
  restore_untitled_recovery()
end)

return autosave_fast
