local native_text = require "native_text"
require "plugins.native_editor"
local core = require "core"
local common = require "core.common"
local Node = require "core.node"
local Project = require "core.project"
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

local function assert_same_paths(actual, expected)
  test.equal(#actual, #expected)
  for i, path in ipairs(expected) do
    test.ok(common.path_equals(actual[i], path), string.format("expected path %s but got %s", tostring(path), tostring(actual[i])))
  end
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

local function make_fake_root_panel(label)
  local view = {}
  function view:get_state()
    return { label = label }
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
  return panel, view
end

local function make_node_root_panel()
  local panel = { root_node = Node() }
  panel.root_node.is_main_panel_node = true
  panel.root_node.is_primary_node = true
  function panel:get_main_panel()
    return self.root_node
  end
  function panel:close_all_docviews()
    self.root_node = Node()
    self.root_node.is_main_panel_node = true
    self.root_node.is_primary_node = true
  end
  return panel
end

local function run_captured_threads(context)
  for _, item in ipairs(context.captured_threads or {}) do
    local co = coroutine.create(item.fn)
    while coroutine.status(co) ~= "dead" do
      local ok, err = coroutine.resume(co, table.unpack(item.args))
      if not ok then error(err, 0) end
    end
  end
  context.captured_threads = {}
end

local function write_file(path, text)
  local fp = assert(io.open(path, "wb"))
  fp:write(text)
  fp:close()
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
    if context.original_cwd then
      pcall(system.chdir, context.original_cwd)
    end
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

  test.test("saves native editor views in split workspace layouts", function(context)
    local project_path = join_path(context.temp_root, "test_project")
    local other_path = join_path(context.temp_root, "other_project")
    local file_a = join_path(project_path, "save-a.txt")
    local file_b = join_path(project_path, "save-b.txt")
    write_file(file_a, "alpha\none")
    write_file(file_b, "beta\ntwo")

    core.projects = { Project(project_path) }
    core.recent_projects = {}
    core.docs = {}
    core.visited_files = { file_b }
    core.root_panel = make_node_root_panel()

    local NativeEditorView = require "plugins.native_editor"
    local view_a = NativeEditorView(nil, file_a)
    view_a.editor:set_cursor(2)
    view_a.scroll.x = 3
    view_a.scroll.y = 7
    view_a.scroll.to.x = 5
    view_a.scroll.to.y = 11
    core.root_panel.root_node:add_view(view_a)
    local right = core.root_panel.root_node:split("right")
    local view_b = NativeEditorView(nil, file_b)
    view_b.editor:set_cursor(4, 1)
    right:add_view(view_b)
    core.root_panel.root_node.divider = 0.4
    core.root_panel.root_node.a:set_active_view(view_a)

    core.set_project(other_path)

    local saved = storage.load("ws", "test_project-1")
    test.type(saved, "table")
    test.ok(common.path_equals(saved.path, project_path))
    test.equal(saved.documents.type, "hsplit")
    test.equal(saved.documents.divider, 0.4)
    test.equal(saved.documents.a.views[1].module, "plugins.native_editor")
    test.equal(saved.documents.a.views[1].state.filename, file_a)
    test.equal(saved.documents.a.views[1].state.scroll.x, 3)
    test.equal(saved.documents.a.views[1].state.scroll_to.y, 11)
    test.same(saved.documents.a.views[1].state.cursors[1], { cursor = 2 })
    test.equal(saved.documents.b.views[1].module, "plugins.native_editor")
    test.equal(saved.documents.b.views[1].state.filename, file_b)
    test.same(saved.documents.b.views[1].state.cursors[1], { cursor = 4, selection = 1 })
    assert_same_paths(saved.visited_files, { file_a, file_b })

    for _, view in ipairs({ view_a, view_b }) do
      local path = view.buffer:path()
      local absolute = system.absolute_path(path) or path
      native_text.release_file_buffer(common.path_compare_key(absolute), view.buffer)
    end
  end)

  test.test("restores legacy sandbox module workspace entries as native editor views", function(context)
    local project_path = join_path(context.temp_root, "test_project")
    local file_a = join_path(project_path, "legacy.txt")
    write_file(file_a, "legacy")
    storage.save("ws", "test_project-10", {
      path = project_path,
      documents = {
        type = "leaf",
        active_view = 1,
        views = {
          {
            module = "plugins.native_text_sandbox",
            active = true,
            state = { filename = file_a, cursors = { { cursor = 3 } } }
          }
        }
      },
      directories = {},
      visited_files = {},
    })

    core.projects = { Project(join_path(context.temp_root, "source_project")) }
    core.recent_projects = {}
    core.docs = {}
    core.visited_files = {}
    core.root_panel = make_node_root_panel()
    core.active_view = core.root_panel.root_node.active_view

    core.set_project(project_path)
    run_captured_threads(context)

    local views = core.root_panel.root_node:get_children()
    test.ok(core.is_native_editor_view(views[1]))
    test.equal(views[1]:get_module(), "plugins.native_editor")
    test.equal(views[1].buffer:text(), "legacy")
    test.same(views[1].editor:cursor(1), { cursor = 3 })

    local absolute = system.absolute_path(file_a) or file_a
    native_text.release_file_buffer(common.path_compare_key(absolute), views[1].buffer)
  end)

  test.test("restores native editor views in split workspace layouts", function(context)
    local project_path = join_path(context.temp_root, "test_project")
    local file_a = join_path(project_path, "a.txt")
    local file_b = join_path(project_path, "b.txt")
    write_file(file_a, "alpha\none")
    write_file(file_b, "beta\ntwo")
    storage.save("ws", "test_project-10", {
      path = project_path,
      documents = {
        type = "hsplit",
        divider = 0.4,
        a = {
          type = "leaf",
          active_view = 1,
          views = {
            {
              module = "plugins.native_editor",
              active = true,
              state = {
                filename = file_a,
                scroll = { x = 3, y = 7 },
                scroll_to = { x = 5, y = 11 },
                cursors = { { cursor = 2 } },
              }
            }
          }
        },
        b = {
          type = "leaf",
          active_view = 1,
          views = {
            {
              module = "plugins.native_editor",
              state = {
                filename = file_b,
                cursors = { { cursor = 4, selection = 1 } },
              }
            }
          }
        }
      },
      directories = {},
      visited_files = { file_a },
    })

    core.projects = { Project(join_path(context.temp_root, "source_project")) }
    core.recent_projects = {}
    core.docs = {}
    core.visited_files = {}
    core.root_panel = make_node_root_panel()
    core.active_view = core.root_panel.root_node.active_view

    core.set_project(project_path)
    run_captured_threads(context)

    test.equal(core.root_panel.root_node.type, "hsplit")
    test.equal(core.root_panel.root_node.divider, 0.4)
    local views = core.root_panel.root_node:get_children()
    local native_views = {}
    for _, view in ipairs(views) do
      if core.is_native_editor_view(view) then native_views[#native_views + 1] = view end
    end
    test.equal(#native_views, 2)
    test.equal(native_views[1].buffer:text(), "alpha\none")
    test.equal(native_views[2].buffer:text(), "beta\ntwo")
    test.equal(native_views[1].scroll.x, 3)
    test.equal(native_views[1].scroll.to.y, 11)
    test.same(native_views[1].editor:cursor(1), { cursor = 2 })
    test.same(native_views[2].editor:cursor(1), { cursor = 4, selection = 1 })
    test.equal(core.active_view, native_views[1])
    assert_same_paths(core.visited_files, { file_a, file_b })
    test.same(workspace_keys_for_path(project_path), {})

    for _, view in ipairs(native_views) do
      local path = view.buffer:path()
      local absolute = system.absolute_path(path) or path
      native_text.release_file_buffer(common.path_compare_key(absolute), view.buffer)
    end
  end)
end)
