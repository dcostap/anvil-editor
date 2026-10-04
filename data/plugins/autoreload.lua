-- mod-version:3
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Buffer = require "core.buffer"
local DirWatch = require "core.dirwatch"

local reload_diff_flash
if config.plugins.reload_diff_flash ~= false then
  local ok, module = pcall(require, "plugins.reload_diff_flash")
  if ok then
    reload_diff_flash = module
  else
    core.log_quiet("Autoreload diff flash unavailable: %s", tostring(module))
  end
end

---Configuration options for `autoreload` plugin.
---@class config.plugins.autoreload
---Always ask before auto-reloading a file that changed.
---@field always_show_nagview boolean
config.plugins.autoreload.config_spec = {
    name = "Autoreload",
    {
      label = "Always Show Nagview",
      description = "Alerts you if an opened file changes "
        .. "externally even if you haven't modified it.",
      path = "always_show_nagview",
      type = "toggle",
      default = false
    }
  }

local watch = DirWatch()
local times = setmetatable({}, { __mode = "k" })
local changed = setmetatable({}, { __mode = "k" })
local watched_paths = setmetatable({}, { __mode = "k" })

local function set_file_missing(buffer, missing)
  if (buffer.file_missing == true) == missing then return end
  buffer.file_missing = missing
  core.redraw = true
  core.log_quiet("Buffer file %s: %s", missing and "missing" or "available", buffer.abs_filename)
end

local function update_time(buffer)
  local path = buffer.abs_filename
  if not path then return end
  local info = system.get_file_info(path)
  local missing = not info or info.type ~= "file"
  local old_path = watched_paths[buffer]
  if old_path ~= path or (buffer.file_missing and not missing) then
    if old_path then watch:unwatch(old_path) end
    if missing then watch:scan(path) else watch:watch(path) end
    watched_paths[buffer] = path
    changed[buffer] = nil
  end
  times[buffer] = not missing and { modified = info.modified, size = info.size }
    or times[buffer] or {}
  set_file_missing(buffer, missing)
end

local function reload_buffer(buffer)
  if buffer.file_missing then return end
  local old_lines
  if reload_diff_flash and reload_diff_flash.clone_lines then
    old_lines = reload_diff_flash.clone_lines(buffer.lines)
  end
  buffer:reload()
  update_time(buffer)
  if old_lines and reload_diff_flash and reload_diff_flash.flash then
    reload_diff_flash.flash(buffer, old_lines, buffer.lines, { reason = "autoreload" })
  end
  core.redraw = true
  core.log_quiet("Auto-reloaded buffer \"%s\"", buffer.filename)
end

local function check_prompt_reload(buffer)
  if buffer and buffer.deferred_reload then
    core.nag_view:show(
      "File Changed",
      buffer.filename .. " has changed. Reload this file?",
      {
        { font = style.font, text = "Yes", default_yes = true },
        { font = style.font, text = "No" , default_no = true }
      }, function(item)
      if item.text == "Yes" then reload_buffer(buffer) end
      buffer.deferred_reload = false
    end)
  end
end

local function autoreload_buffer(buffer)
  if changed[buffer] then changed[buffer] = nil end
  if buffer.file_missing then return end
  if
    not buffer:is_dirty()
    and
    not config.plugins.autoreload.always_show_nagview
  then
    reload_buffer(buffer)
  elseif not buffer.deferred_reload and not buffer.autosave_conflict_prompt_visible then
    buffer.deferred_reload = true
    check_prompt_reload(buffer)
  end
end

local core_set_active_view = core.set_active_view
function core.set_active_view(view, focus_context)
  focus_context = focus_context or core.focus_change_context(2)
  core_set_active_view(view, focus_context)
  if core.active_view.buffer and changed[core.active_view.buffer] then
    local buffer = core.active_view.buffer
    core.add_thread(function()
      -- validate buffer in case the active view rapidly changed
      if buffer == core.active_view.buffer then
        autoreload_buffer(buffer)
      end
    end)
  end
end

core.add_thread(function()
  while true do
    watch:check(function(file)
      for _, buffer in ipairs(core.buffers) do
        if common.path_equals(buffer.abs_filename, file) then
          local info = system.get_file_info(buffer.abs_filename or "")
          local was_missing = buffer.file_missing
          if times[buffer] and (not info or info.type ~= "file") then
            set_file_missing(buffer, true)
            changed[buffer] = nil
            buffer.deferred_reload = false
            -- Native file watches can disappear with their file. Poll the saved
            -- path until it returns, including when its parent was removed.
            watch:unwatch(buffer.abs_filename)
            watch:scan(buffer.abs_filename)
          elseif info and info.type == "file" and was_missing then
            set_file_missing(buffer, false)
            watch:unwatch(buffer.abs_filename)
            watch:watch(buffer.abs_filename)
          end
          if
            info and info.type == "file" and times[buffer]
            and
            (
              was_missing or times[buffer].modified ~= info.modified
              or
              times[buffer].size ~= info.size
            )
          then
            if
              core.active_view
              and
              core.active_view.buffer
              and
              core.active_view.buffer == buffer
            then
              autoreload_buffer(buffer)
            elseif not buffer.deferred_reload then
              changed[buffer] = true
            end
          end
        end
      end
    end)
    coroutine.yield(1)
  end
end)

-- patch `Buffer.save|load` to store modified time
local load = Buffer.load
local save = Buffer.save
local on_close = Buffer.on_close

Buffer.load = function(self, ...)
  local res = load(self, ...)
  core.add_thread(function()
    -- apply autoreload only to Buffers loaded in the UI
    if #core.get_views_referencing_buffer(self) > 0 then
      update_time(self)
    end
  end)
  return res
end

Buffer.save = function(self, ...)
  local res = save(self, ...)
  -- if starting with an unsaved buffer with a filename.
  if #core.get_views_referencing_buffer(self) > 0 then
    update_time(self)
  end
  return res
end

Buffer.on_close = function(self)
  on_close(self)
  if watched_paths[self] then watch:unwatch(watched_paths[self]) end
  watched_paths[self], times[self], changed[self] = nil, nil, nil
end
