local core = require "core"
local common = require "core.common"
local panes = require "core.panes"
local storage = require "core.storage"
local test = require "core.test"
require "plugins.workspace"

test.describe("Initial Project Pane", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.cwd = system.getcwd()
    context.recent_projects = core.recent_projects
    context.root = USERDIR .. PATHSEP .. "initial-pane-" .. math.floor(system.get_time() * 1000000)
    context.project_path = context.root .. PATHSEP .. "project"
    test.ok(common.mkdirp(context.project_path))
    storage.clear("ws")
  end)

  test.after_each(function(context)
    panes.reset_for_tests()
    -- Leave the temporary Project before yielding during folder removal.
    core.set_project(context.cwd)
    core.recent_projects = context.recent_projects
    storage.clear("ws")
    test.ok(test.remove_tree(context.root, 30))
  end)

  for _, saved_empty_workspace in ipairs { false, true } do
    local name = saved_empty_workspace and "a Project with no saved Panes" or "a new Project"
    test.it("opens a focused File Tree for " .. name, function(context)
      if saved_empty_workspace then
        storage.save("ws", "project-1", {
          path = context.project_path,
          pane_state = { version = 1, groups = {}, panes = {} },
        })
      end
      core.set_project(context.project_path)
      local deadline = system.get_time() + 30
      while panes.count() == 0 and system.get_time() < deadline do coroutine.yield(0.01) end

      test.equal(panes.count(), 1)
      local view = panes.active().current_view
      test.equal(view:get_module(), "plugins.filetree")
      test.equal(core.active_view, view)
      test.ok(common.path_equals(view:get_state().root, context.project_path))
    end)
  end

  test.it("keeps a Project empty after its last Pane closes", function(context)
    core.set_project(context.project_path)
    local deadline = system.get_time() + 30
    while panes.count() == 0 and system.get_time() < deadline do coroutine.yield(0.01) end
    test.equal(panes.count(), 1)
    test.ok(panes.close(panes.active(), { force = true }))

    core.root_panel:update_suspended()
    test.equal(panes.count(), 0)

    core.root_panel:update()
    test.equal(panes.count(), 0, "a visible Project must not replace its last closed Pane")
  end)
end)
