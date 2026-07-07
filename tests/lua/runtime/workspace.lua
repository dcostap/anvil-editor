local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local storage = require "core.storage"
local test = require "core.test"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function leaf_state(label)
  return {
    type = "leaf",
    active_view = 1,
    views = {
      {
        module = "core.view",
        active = true,
        state = { label = label }
      }
    }
  }
end

local function empty_leaf_state()
  return { type = "leaf", views = {} }
end

local function has_key(keys, expected)
  for _, key in ipairs(keys or {}) do
    if key == expected then return true end
  end
  return false
end

local function workspace_keys_for_path(project_path)
  local matches = {}
  for _, key in ipairs(storage.keys("ws") or {}) do
    local workspace = storage.load("ws", key)
    if type(workspace) == "table" and common.path_equals(workspace.path, project_path) then
      matches[#matches + 1] = key
    end
  end
  table.sort(matches)
  return matches
end

local function run_last_captured_thread(context)
  local thread = table.remove(context.captured_threads or {})
  test.not_nil(thread)
  local co = coroutine.create(function() thread.fn(table.unpack(thread.args or {})) end)
  while coroutine.status(co) ~= "dead" do
    local ok, err = coroutine.resume(co)
    test.ok(ok, err)
  end
end

local function make_fake_root_panel(label, state, doc)
  local view = { doc = doc }
  function view:get_state()
    return state or { label = label }
  end
  function view:get_module()
    return "core.view"
  end

  local panel = {
    root_node = {
      type = "leaf",
      views = { view },
      active_view = view
    }
  }
  function panel:close_all_docviews()
    self.root_node.views = {}
    self.root_node.active_view = nil
  end
  function panel:get_main_panel()
    return { is_empty = function() return false end }
  end
  return panel, view
end

test.describe("Workspace persistence", function()
  test.before_each(function(context)
    context.original_projects = core.projects
    context.original_recent_projects = core.recent_projects
    context.original_docs = core.docs
    context.original_visited_files = core.visited_files
    context.original_root_panel = core.root_panel
    context.original_active_view = core.active_view
    context.original_add_thread = core.add_thread
    context.original_restart = core.restart
    context.original_restart_request = core.restart_request
    context.original_quit_request = core.quit_request
    context.original_filetree_module = package.loaded["plugins.filetree"]
    context.original_cwd = system.getcwd()
    context.temp_root = USERDIR
      .. PATHSEP .. "workspace-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(join_path(context.temp_root, "source_project")))
    test.ok(common.mkdirp(join_path(context.temp_root, "test_project")))
    test.ok(common.mkdirp(join_path(context.temp_root, "other_project")))
    storage.clear("ws")
    core.add_thread = function(fn, ...)
      context.captured_threads = context.captured_threads or {}
      context.captured_threads[#context.captured_threads + 1] = { fn = fn, args = { ... } }
      return -#context.captured_threads
    end
  end)

  test.after_each(function(context)
    core.projects = context.original_projects
    core.recent_projects = context.original_recent_projects
    core.docs = context.original_docs
    core.visited_files = context.original_visited_files
    core.root_panel = context.original_root_panel
    core.active_view = context.original_active_view
    core.add_thread = context.original_add_thread
    core.restart = context.original_restart
    core.restart_request = context.original_restart_request
    core.quit_request = context.original_quit_request
    package.loaded["plugins.filetree"] = context.original_filetree_module
    if context.original_cwd then
      pcall(system.chdir, context.original_cwd)
    end
    project_paths.load_workspace_state(nil)
    project_paths.configure_project {}
    storage.clear("ws")
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.test("reuses a path-identical workspace key instead of appending another basename slot", function(context)
    if PLATFORM ~= "Windows" then return end

    local project_path = join_path(context.temp_root, "test_project")
    local other_path = join_path(context.temp_root, "other_project")
    storage.save("ws", "test_project-10", {
      path = project_path:upper(),
      documents = empty_leaf_state(),
      directories = {},
      visited_files = {}
    })
    storage.save("ws", "test_project-11", {
      path = project_path,
      documents = empty_leaf_state(),
      directories = {},
      visited_files = {}
    })

    local panel, view = make_fake_root_panel("current")
    core.projects = { Project(project_path) }
    core.recent_projects = {}
    core.docs = {}
    core.visited_files = {}
    core.root_panel = panel
    core.active_view = view

    core.set_project(other_path)

    local keys = storage.keys("ws")
    test.ok(has_key(keys, "test_project-10"), "expected existing path-identical key to be reused")
    test.not_ok(has_key(keys, "test_project-11"), "expected duplicate path-identical key to be cleared")
    test.not_ok(has_key(keys, "test_project-12"), "expected no appended duplicate key")
    test.same(workspace_keys_for_path(project_path), { "test_project-10" })

    local saved = storage.load("ws", "test_project-10")
    test.type(saved, "table")
    test.equal(#saved.documents.views, 1)
    test.equal(saved.documents.views[1].state.label, "current")
  end)

  test.test("skips views with invalid control characters in filenames", function(context)
    local project_path = join_path(context.temp_root, "source_project")
    local other_path = join_path(context.temp_root, "other_project")
    local panel, view = make_fake_root_panel("bad", { filename = "test.txt\n", scroll = { x = 0, y = 0 } })
    core.projects = { Project(project_path) }
    core.recent_projects = {}
    core.docs = {}
    core.visited_files = {}
    core.root_panel = panel
    core.active_view = view

    core.set_project(other_path)

    local keys = workspace_keys_for_path(project_path)
    test.equal(#keys, 1)
    local saved = storage.load("ws", keys[1])
    test.type(saved, "table")
    test.equal(#saved.documents.views, 0)
  end)

  test.test("skips named-file views that restored as missing new files", function(context)
    local project_path = join_path(context.temp_root, "source_project")
    local other_path = join_path(context.temp_root, "other_project")
    local doc = { filename = "missing.txt", new_file = true }
    local panel, view = make_fake_root_panel("missing", { filename = "missing.txt", scroll = { x = 0, y = 0 } }, doc)
    core.projects = { Project(project_path) }
    core.recent_projects = {}
    core.docs = { doc }
    core.visited_files = {}
    core.root_panel = panel
    core.active_view = view

    core.set_project(other_path)

    local keys = workspace_keys_for_path(project_path)
    test.equal(#keys, 1)
    local saved = storage.load("ws", keys[1])
    test.type(saved, "table")
    test.equal(#saved.documents.views, 0)
  end)

  test.test("restoring a workspace preserves local Project Paths on disk", function(context)
    local project_path = join_path(context.temp_root, "test_project")
    local source_path = join_path(context.temp_root, "source_project")
    local external_path = join_path(context.temp_root, "external_project")
    test.ok(common.mkdirp(external_path))
    storage.save("ws", "test_project-10", {
      path = project_path,
      documents = empty_leaf_state(),
      project_paths = {
        entries = {
          { path = external_path, label = "external-project", role = "external" },
        },
      },
      visited_files = {},
    })

    local panel, view = make_fake_root_panel("source")
    core.projects = { Project(source_path) }
    core.recent_projects = {}
    core.docs = {}
    core.visited_files = {}
    core.root_panel = panel
    core.active_view = view

    core.set_project(project_path)
    run_last_captured_thread(context)

    local saved = storage.load("ws", "test_project-10")
    test.type(saved, "table")
    test.type(saved.project_paths, "table")
    test.equal(saved.project_paths.entries[1].label, "external-project")
    test.equal(project_paths.resolve(join_path(external_path, "file.odin")).entry.label, "external-project")
  end)

  test.test("refreshes File Tree after Workspace Project Paths are loaded", function(context)
    local calls = 0
    package.loaded["plugins.filetree"] = {
      refresh_preserving_selection_paths = function(_, preserve_expansion)
        calls = calls + 1
        test.equal(preserve_expansion, true)
      end,
    }

    test.not_nil(core.refresh_project_path_consumers)
    core.refresh_project_path_consumers("test")
    test.equal(calls, 1)
  end)

  test.test("same-window Project switch does not overwrite destination workspace with empty tabs", function(context)
    local source_path = join_path(context.temp_root, "source_project")
    local destination_path = join_path(context.temp_root, "test_project")
    storage.save("ws", "test_project-10", {
      path = destination_path,
      documents = leaf_state("destination"),
      directories = {},
      visited_files = {}
    })

    local panel, view = make_fake_root_panel("source")
    core.projects = { Project(source_path) }
    core.recent_projects = {}
    core.docs = {}
    core.visited_files = {}
    core.root_panel = panel
    core.active_view = view
    core.restart = function()
      core.exit(function()
        context.restart_called = true
      end, true)
    end

    core.open_project_in_same_window(destination_path)

    test.ok(context.restart_called, "expected project switch to request restart")
    local destination = storage.load("ws", "test_project-10")
    test.type(destination, "table")
    test.equal(#destination.documents.views, 1)
    test.equal(destination.documents.views[1].state.label, "destination")
    test.same(workspace_keys_for_path(destination_path), { "test_project-10" })
  end)
end)
