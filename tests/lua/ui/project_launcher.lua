local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local panes = require "core.panes"
local storage = require "core.storage"
local launcher = require "core.project_launcher"
local test = require "core.test"
require "plugins.workspace"

local function open_project(path)
  core.set_project(path)
  local deadline = system.get_time() + 30
  while not core.workspace_restored and system.get_time() < deadline do coroutine.yield(0.01) end
  test.ok(core.workspace_restored)
end

local function labels()
  local result = {}
  for _, item in ipairs(launcher.items()) do result[#result + 1] = item.label end
  return result
end

test.describe("Project Launcher", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    -- An earlier test's View would take the keys.
    core.clear_active_view()
    context.cwd = system.getcwd()
    context.recent_projects = core.recent_projects
    context.root = USERDIR .. PATHSEP .. "project-launcher-" .. math.floor(system.get_time() * 1000000)
    context.project_path = context.root .. PATHSEP .. "project"
    test.ok(common.mkdirp(context.project_path))
    storage.clear("ws")
    -- Terminals start real shells, so these commands record their launch instead.
    context.ran, context.saved_commands = {}, {}
    for _, name in ipairs { "terminal:open_at_project_root", "terminal:open_pi" } do
      context.saved_commands[name] = command.map[name]
      command.add(nil, { [name] = function()
        context.ran[#context.ran + 1] = { name, command.get_invocation_context().placement }
      end })
    end
  end)

  test.after_each(function(context)
    keymap.unbind("launcher_confirm")
    keymap.unbind("launcher_entry")
    for name, saved in pairs(context.saved_commands) do command.map[name] = saved end
    panes.reset_for_tests()
    core.set_project(context.cwd)
    core.recent_projects = context.recent_projects
    storage.clear("ws")
    test.ok(test.remove_tree(context.root, 30))
  end)

  test.it("shows in a new Project with no selection, and a move then Enter opens a File Tree at its root",
    function(context)
    open_project(context.project_path)
    test.equal(panes.count(), 0)
    test.ok(launcher.shown())

    core.on_event("keypressed", "return", {})
    test.equal(panes.count(), 0, "Enter without a selection opens nothing")
    -- The first move selects the first button, whatever its direction.
    core.on_event("keypressed", "left", {})
    core.on_event("keypressed", "return", {})
    test.equal(panes.count(), 1)
    local view = panes.active().current_view
    test.equal(view:get_module(), "plugins.filetree")
    test.equal(core.active_view, view)
    test.ok(common.path_equals(view:get_state().root, context.project_path))
    test.ok(not launcher.shown())
  end)

  test.it("selects the first button when the Sidebar enters the Project with the keyboard", function(context)
    open_project(context.project_path)
    core.on_event("panerequest", common.serialize {action = "open_project", keyboard = true}, -1, -1, 0)
    test.equal(panes.count(), 0, "Entering the Project must not activate a button")
    core.on_event("keypressed", "return", {})
    test.equal(panes.count(), 1)
    test.equal(panes.active().current_view:get_module(), "plugins.filetree")
  end)

  test.it("keeps no selection when the Sidebar enters the Project with the mouse", function(context)
    open_project(context.project_path)
    core.on_event("panerequest", common.serialize {action = "open_project"}, -1, -1, 0)
    core.on_event("keypressed", "return", {})
    test.equal(panes.count(), 0)
  end)

  test.it("selects the first button after a Sidebar key gives the Project the keyboard", function(context)
    open_project(context.project_path)
    keymap.add_direct {launcher_entry = function() return true end}
    core.on_event("panerequest", common.serialize {action = "key", stroke = "launcher_entry", keep_sidebar = true}, -1, -1, 0)
    core.on_event("keypressed", "return", {})
    test.equal(panes.count(), 0, "A key that keeps the Sidebar keyboard must not select a button")
    core.on_event("panerequest", common.serialize {action = "key", stroke = "launcher_entry"}, -1, -1, 0)
    keymap.unbind("launcher_entry")
    core.on_event("keypressed", "return", {})
    test.equal(panes.count(), 1)
    test.equal(panes.active().current_view:get_module(), "plugins.filetree")
  end)

  for _, name in ipairs { "core:activate_point_of_interest", "core:submit_prompt" } do
    test.it("opens the keyboard-selected item through " .. name, function(context)
      open_project(context.project_path)
      keymap.add_direct { launcher_confirm = name }
      core.on_event("keypressed", "launcher_confirm", {})
      test.equal(panes.count(), 0, "Confirmation without a selection opens nothing")
      core.on_event("keypressed", "left", {})
      core.on_event("keypressed", "launcher_confirm", {})
      test.equal(panes.count(), 1)
      local view = panes.active().current_view
      test.equal(view:get_module(), "plugins.filetree")
      test.equal(core.active_view, view)
      test.ok(common.path_equals(view:get_state().root, context.project_path))
    end)
  end

  test.it("moves its selection with Tab and opens the clicked button in a new Pane", function(context)
    open_project(context.project_path)
    core.on_event("keypressed", "tab", {})
    core.on_event("keypressed", "tab", {})
    core.on_event("keypressed", "return", {})
    local pi = launcher.items()[3]
    local x, y = pi.x + pi.w / 2, pi.y + pi.h / 2
    core.on_event("mousepressed", "left", x, y, 1)
    core.on_event("mousereleased", "left", x, y)
    test.same(context.ran, { { "terminal:open_at_project_root", "new" }, { "terminal:open_pi", "new" } })
  end)

  test.it("shows no folder buttons in the Scratch Project", function()
    local scratch = USERDIR .. PATHSEP .. "scratch"
    test.ok(common.mkdirp(scratch))
    open_project(scratch)
    test.same(labels(), { "Terminal", "Pi" })
  end)
end)
