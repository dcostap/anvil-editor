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

local function update_time(buffer)
  if buffer.abs_filename then
    local info = system.get_file_info(buffer.abs_filename)
    times[buffer] = info and { modified = info.modified, size = info.size }
  end
end

local function reload_buffer(buffer)
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
  if
    not buffer:is_dirty()
    and
    not config.plugins.autoreload.always_show_nagview
  then
    reload_buffer(buffer)
  elseif not buffer.deferred_reload then
    buffer.deferred_reload = true
    check_prompt_reload(buffer)
  end
end

local core_set_active_view = core.set_active_view
function core.set_active_view(view)
  core_set_active_view(view)
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
          if
            info and info.type == "file" and times[buffer]
            and
            (
              times[buffer].modified ~= info.modified
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
      if not times[self] then watch:watch(self.abs_filename) end
      update_time(self)
    end
  end)
  return res
end

Buffer.save = function(self, ...)
  local res = save(self, ...)
  -- if starting with an unsaved buffer with a filename.
  if #core.get_views_referencing_buffer(self) > 0 then
    if not times[self] then watch:watch(self.abs_filename) end
    update_time(self)
  end
  return res
end

Buffer.on_close = function(self)
  on_close(self)
  if times[self] then
    times[self] = nil
    watch:unwatch(self.abs_filename)
    if changed[self] then changed[self] = nil end
  end
end
