-- mod-version:3
-- Git status for file labels, independent of open File Tree views.
local common = require "core.common"
local core = require "core"
local project_paths = require "core.project_paths"
local git_status = require "plugins.filetree.git_status"

local file_git_status = {}
local roots = {}

function file_git_status.lookup(path)
  if not path or not common.is_absolute_path(path) then return nil end
  local resolved = project_paths.resolve(path)
  local root = resolved and resolved.entry.path or common.dirname(path)
  local key = common.path_compare_key(root)
  local state = roots[key]
  if not state then
    state = { last_used = system.get_time() }
    state.controller = git_status.new {
      root = function() return root end,
      presented = function() return system.get_time() - state.last_used < 15 end,
      publish = function() core.redraw = true end,
    }
    roots[key] = state
    core.log_quiet("File label Git status started: root=%s", root)
    core.add_thread(function()
      while system.get_time() - state.last_used < 15 do
        local controller = state.controller
        if not controller.active then controller:request("file-label-refresh") end
        controller:update()
        coroutine.yield(3)
      end
      state.controller:cancel_active("file-labels-hidden")
      roots[key] = nil
      core.log_quiet("File label Git status stopped: root=%s", root)
    end)
  end
  state.last_used = system.get_time()
  local info = state.controller:lookup(path, false)
  if not info then return nil end
  return {
    kind = info.kind,
    stat = info.additions ~= nil and { additions = info.additions, deletions = info.deletions } or nil,
  }
end

return file_git_status
