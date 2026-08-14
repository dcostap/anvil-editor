-- mod-version:3
local config = require "core.config"
local core = require "core"
local common = require "core.common"
local GlobalPromptBar = require "core.global_prompt_bar"
local Editor = require "core.editor"
local RootPanel = require "core.rootpanel"

local autosave_fast
if config.plugins.autosave_fast ~= false then
  autosave_fast = require "plugins.autosave_fast"
end

local on_focus_lost = RootPanel.on_focus_lost

local function is_protected_buffer(buffer)
  if not buffer or not buffer.abs_filename then return false end
  local init_path = system.absolute_path(USERDIR .. PATHSEP .. "init.lua")
  local project_file = core.project_absolute_path and core.project_absolute_path(".anvil_project.lua")
    or system.absolute_path(".anvil_project.lua")
  return common.path_equals(buffer.abs_filename, init_path)
      or common.path_equals(buffer.abs_filename, project_file)
end

local function save_node_fallback()
  for _, buffer in ipairs(core.buffers) do
      if buffer.filename and buffer:is_dirty() and not is_protected_buffer(buffer) then
        local ok, err = pcall(buffer.save, buffer)
        if ok then
          core.log_quiet("Saved buffer \"%s\"", buffer.filename)
        elseif not tostring(err):find("file changed on disk", 1, true) then
          core.error("Couldn't save file \"%s\": %s", buffer.filename, err)
        end
      end
  end
end

function RootPanel:on_focus_lost(...)
  if autosave_fast and autosave_fast.enabled ~= false then
    autosave_fast.save_all_dirty("application focus lost")
  else
    save_node_fallback()
  end
  return on_focus_lost(self, ...)
end
