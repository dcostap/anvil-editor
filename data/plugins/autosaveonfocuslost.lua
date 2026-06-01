-- mod-version:3
local config = require "core.config"
local core = require "core"
local common = require "core.common"
local GlobalPromptBar = require "core.global_prompt_bar"
local DocView = require "core.docview"
local RootPanel = require "core.rootpanel"

local autosave_fast
if config.plugins.autosave_fast ~= false then
  autosave_fast = require "plugins.autosave_fast"
end

local on_focus_lost = RootPanel.on_focus_lost

local function is_protected_doc(doc)
  if not doc or not doc.abs_filename then return false end
  local init_path = system.absolute_path(USERDIR .. PATHSEP .. "init.lua")
  local project_file = core.project_absolute_path and core.project_absolute_path(".anvil_project.lua")
    or system.absolute_path(".anvil_project.lua")
  return common.path_equals(doc.abs_filename, init_path)
      or common.path_equals(doc.abs_filename, project_file)
end

local function save_node_fallback(node)
  if node.type == "leaf" then
    local i = 1
    while i <= #node.views do
      local view = node.views[i]
      if view:is(DocView) and not view:is(GlobalPromptBar)
          and view.doc.filename and view.doc:is_dirty()
          and not is_protected_doc(view.doc) then
        local ok, err = pcall(view.doc.save, view.doc)
        if ok then
          core.log_quiet("Saved doc \"%s\"", view.doc.filename)
        elseif not tostring(err):find("file changed on disk", 1, true) then
          core.error("Couldn't save file \"%s\": %s", view.doc.filename, err)
        end
      end
      i = i + 1
    end
  else
    if node.a then save_node_fallback(node.a) end
    if node.b then save_node_fallback(node.b) end
  end
end

function RootPanel:on_focus_lost(...)
  if autosave_fast and autosave_fast.enabled ~= false then
    autosave_fast.save_all_dirty("application focus lost")
  else
    save_node_fallback(core.root_panel.root_node)
  end
  return on_focus_lost(self, ...)
end
