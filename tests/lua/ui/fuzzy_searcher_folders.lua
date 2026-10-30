local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local panes = require "core.panes"
local project_files = require "core.project_files"
local project_paths = require "core.project_paths"
local Project = require "core.project"
local test = require "core.test"
local View = require "core.view"
local fuzzy_native = require "fuzzy"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

local function write_file(path, text)
  local handle = assert(io.open(path, "wb"))
  handle:write(text or "test\n")
  handle:close()
end

local function result_for_path(results, path)
  for index, result in ipairs(results or {}) do
    if result.abs_path and common.path_equals(result.abs_path, path) then
      return result, index
    end
  end
end

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + (timeout or 30)
  while not predicate() and system.get_time() < deadline do coroutine.yield(0.02) end
  return predicate()
end

local function select_folder_action(action)
  local nag = core.nag_view
  for index, option in ipairs(nag.options or {}) do
    if option.action == action then
      nag:change_hovered(index)
      test.ok(command.perform("core:select_dialog_entry"))
      return
    end
  end
  test.fail("missing folder action: " .. tostring(action))
end

local function assert_actions_present(options, expected)
  local found = {}
  for _, option in ipairs(options or {}) do found[option.action] = true end
  for _, action in ipairs(expected) do
    test.ok(found[action], "missing folder action: " .. action)
  end
end

test.describe("Project File Search folders", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.projects = core.projects
    context.visited_files = core.visited_files
    context.open_project_in_same_window = core.open_project_in_same_window
    context.open_project_in_new_window = core.open_project_in_new_window
    context.cwd = system.getcwd()
    context.root = USERDIR .. PATHSEP .. "fuzzy-folders-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    context.widgets = context.root .. PATHSEP .. "src" .. PATHSEP .. "widgets"
    context.button = context.widgets .. PATHSEP .. "button.lua"
    context.empty = context.root .. PATHSEP .. "empty" .. PATHSEP .. "nested"
    context.ignored = context.root .. PATHSEP .. "ignored"
    context.ignored_deep = context.ignored .. PATHSEP .. "deep"
    test.ok(common.mkdirp(context.root .. PATHSEP .. ".git"))
    test.ok(common.mkdirp(context.widgets))
    test.ok(common.mkdirp(context.empty))
    test.ok(common.mkdirp(context.ignored_deep))
    test.ok(common.mkdirp(context.root .. PATHSEP .. ".hidden" .. PATHSEP .. "nested"))
    write_file(context.root .. PATHSEP .. ".gitignore", "ignored/\n")
    write_file(context.button)
    write_file(context.ignored_deep .. PATHSEP .. "generated.lua")
    core.projects = { Project(context.root) }
    core.visited_files = {}
    project_paths.configure_workspace {}
    system.chdir(context.root)
    context.source = View()
    context.pane = panes.create { factory = function() return context.source end }
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    if context.original_file_index_builder then
      context.release_scan = true
      test.ok(wait_until(function()
        return not fuzzy_searcher._test.file_index_status().indexing
      end, 30), "the controlled file index scan did not finish")
      fuzzy_native.file_index_builder = context.original_file_index_builder
    end
    fuzzy_searcher._test.clear_file_subscriptions_for_test()
    project_files.invalidate(context.root)
    coroutine.yield(0.05)
    project_paths.configure_workspace {}
    panes.reset_for_tests()
    if context.filetree_was_opened then coroutine.yield(0.3) end
    core.projects = context.projects
    core.visited_files = context.visited_files
    core.open_project_in_same_window = context.open_project_in_same_window
    core.open_project_in_new_window = context.open_project_in_new_window
    if context.is_hosted_surface then system.is_hosted_surface = context.is_hosted_surface end
    if context.transitions ~= nil then config.transitions, core.fps = context.transitions, context.fps end
    if context.cwd then pcall(system.chdir, context.cwd) end
    if context.root then test.ok(test.remove_tree(context.root)) end
  end)

  test.it("finds empty folders and stops at ignored folder roots", function(context)
    fuzzy_searcher.open("empty nested")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return result_for_path(picker.results, context.empty) ~= nil end))
    local empty = result_for_path(picker.results, context.empty)
    test.equal(empty.kind, "folder")
    test.ok(empty.is_folder)

    picker.input:set_text("ignored")
    test.ok(wait_until(function() return result_for_path(picker.results, context.ignored) ~= nil end))
    test.is_nil(result_for_path(picker.results, context.ignored_deep))

    local previous_status = picker.status
    picker.input:set_text("hidden nested")
    test.ok(wait_until(function()
      return picker.status ~= previous_status
        and not picker.status:find("Searching", 1, true)
        and not picker.status:find("Indexing", 1, true)
    end), "expected the hidden-folder search to finish: " .. tostring(picker.status))
    test.is_nil(result_for_path(picker.results, context.root .. PATHSEP .. ".hidden" .. PATHSEP .. "nested"))
  end)

  test.it("finds folders when the Project has no searchable files", function(context)
    test.ok(os.remove(context.button))
    fuzzy_searcher.open("empty nested")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return result_for_path(picker.results, context.empty) ~= nil end))
  end)

  test.it("keeps folder results available while replacing a large index", function(context)
    for i = 1, 1000 do
      test.ok(common.mkdirp(context.root .. PATHSEP .. "folder-" .. i))
    end
    test.ok(fuzzy_searcher._test.prewarm_file_index_for_test())
    test.ok(wait_until(function()
      local status = fuzzy_searcher._test.file_index_status()
      return status.native and not status.indexing
    end), "expected the initial file and folder index")

    fuzzy_searcher.open("src widgets")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return result_for_path(picker.results, context.widgets) end),
      "expected the initial folder result")

    context.original_file_index_builder = fuzzy_native.file_index_builder
    local native_index = { true }
    function native_index:search_async()
      return { poll = function() return {} end }
    end
    function native_index:free() end
    fuzzy_native.file_index_builder = function()
      return {
        feed = function() end,
        free = function() end,
        finish_async = function()
          context.scan_finish_started = true
          return {
            poll = function()
              if not context.release_scan then return nil end
              return native_index, {}
            end,
          }
        end,
      }
    end
    fuzzy_searcher._test.refresh_file_index_for_test()
    test.ok(wait_until(function() return context.scan_finish_started end, 30),
      "expected the replacement scan to wait at the native index boundary")

    picker.input:set_text("empty nested")
    test.ok(wait_until(function()
      return result_for_path(picker.results, context.empty) ~= nil
    end), "expected folder results while the replacement scan is pending")
  end)

  test.it("uses updated Project Path labels when they change during prewarm", function(context)
    local target = context.empty .. PATHSEP .. "labelled.lua"
    write_file(target)
    project_paths.configure_workspace {
      vendored = { { path = context.empty, label = "Old" } },
    }
    test.ok(fuzzy_searcher._test.prewarm_file_index_for_test())
    local entry = project_paths.resolve(context.empty).entry
    test.ok(project_paths.set_label(entry.id, "Renamed"))

    fuzzy_searcher.open("labelled")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return result_for_path(picker.results, target) ~= nil end),
      "expected the labelled Project file to become searchable")
    test.equal(result_for_path(picker.results, target).root_label, "Renamed")
  end)

  test.it("ranks a matching folder before files inside it", function(context)
    fuzzy_searcher.open("src widgets")
    local picker = assert(core.fuzzy_searcher_active_view)
    local folder_index, file_index
    test.ok(wait_until(function()
      local folder_result, file_result
      folder_result, folder_index = result_for_path(picker.results, context.widgets)
      file_result, file_index = result_for_path(picker.results, context.button)
      return folder_index ~= nil and file_index ~= nil
    end))
    test.ok(folder_index < file_index)
  end)

  test.it("matches a folder when the query ends with a path separator", function(context)
    fuzzy_searcher.open("empty/nested/")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return result_for_path(picker.results, context.empty) ~= nil end))

    picker.input:set_text("empty\\nested\\")
    test.ok(wait_until(function() return result_for_path(picker.results, context.empty) ~= nil end))
  end)

  test.it("asks whether to open a folder as a File Tree or Project", function(context)
    fuzzy_searcher.open("empty nested")
    local picker = assert(core.fuzzy_searcher_active_view)
    local index
    test.ok(wait_until(function()
      local result
      result, index = result_for_path(picker.results, context.empty)
      return index ~= nil
    end))

    picker.selected = index
    picker:confirm(false)

    test.equal(core.nag_view:get_title(), "Open Folder")
    assert_actions_present(core.nag_view.options,
      { "filetree", "project_here", "project_new", "cancel" })
    select_folder_action("cancel")
    test.equal(core.fuzzy_searcher_active_view, picker)
  end)

  test.it("opens a folder result as a File Tree", function(context)
    fuzzy_searcher.open("empty nested")
    local picker = assert(core.fuzzy_searcher_active_view)
    local index
    test.ok(wait_until(function()
      local result
      result, index = result_for_path(picker.results, context.empty)
      return index ~= nil
    end))
    picker.selected = index
    picker:confirm(false)
    context.filetree_was_opened = true
    select_folder_action("filetree")
    test.ok(wait_until(function()
      return context.pane.current_view.root_dir == common.normalize_path(context.empty)
    end))
  end)

  test.it("opens a folder result in a new Pane Group with alternate activation", function(context)
    fuzzy_searcher.open("empty nested")
    local picker = assert(core.fuzzy_searcher_active_view)
    local index
    test.ok(wait_until(function()
      local result
      result, index = result_for_path(picker.results, context.empty)
      return index ~= nil
    end))
    picker.selected = index
    picker:confirm(true)
    context.filetree_was_opened = true
    select_folder_action("filetree")
    test.ok(wait_until(function() return panes.count() == 2 end))
    test.equal(context.pane.current_view, context.source)
    test.not_equal(panes.active().group, context.pane.group)
    test.equal(panes.active().current_view.root_dir, common.normalize_path(context.empty))
  end)

  test.it("opens a folder as a Project in this window", function(context)
    local opened
    core.open_project_in_same_window = function(path) opened = path; return true end

    fuzzy_searcher.open("empty nested")
    local picker = assert(core.fuzzy_searcher_active_view)
    local index
    test.ok(wait_until(function()
      local result
      result, index = result_for_path(picker.results, context.empty)
      return index ~= nil
    end))
    picker.selected = index
    picker:confirm(false)
    select_folder_action("project_here")

    test.ok(wait_until(function() return opened ~= nil end))
    test.ok(common.path_equals(opened, context.empty))
  end)

  test.it("opens a folder as a Project in a new window", function(context)
    local opened
    core.open_project_in_new_window = function(path) opened = path; return true end

    fuzzy_searcher.open("empty nested")
    local picker = assert(core.fuzzy_searcher_active_view)
    local index
    test.ok(wait_until(function()
      local result
      result, index = result_for_path(picker.results, context.empty)
      return index ~= nil
    end))
    picker.selected = index
    picker:confirm(false)
    select_folder_action("project_new")

    test.ok(wait_until(function() return opened ~= nil end))
    test.ok(common.path_equals(opened, context.empty))
  end)

  test.it("opens a Project result in this Anvil Window without asking under the shell", function(context)
    local opened, new_window, picker, picker_closed
    context.transitions, context.fps = config.transitions, core.fps
    config.transitions, core.fps = true, 60
    context.is_hosted_surface = system.is_hosted_surface
    system.is_hosted_surface = function() return true end
    core.open_project_in_same_window = function(path)
      opened, picker_closed = path, picker.closed
      return true
    end
    core.open_project_in_new_window = function(path) new_window = path; return true end

    fuzzy_searcher.open_static_results("Projects", {
      { kind = "project", label = context.empty, project = context.empty },
    })
    picker = assert(core.fuzzy_searcher_active_view)
    -- The user sees the picker before choosing a Project.
    coroutine.yield(0.2)
    picker.selected = 1
    picker:confirm(false)

    test.ok(not core.nag_view.visible, "expected no Open Folder prompt")
    test.ok(wait_until(function() return opened ~= nil end))
    test.ok(common.path_equals(opened, context.empty))
    test.is_nil(new_window)
    -- The shell keeps this Window's last frame until the selected Project presents. That frame must not show a
    -- half-closed picker.
    test.ok(picker_closed, "expected the picker to close before the Project request")
  end)

  test.it("opens a Project in a new Anvil Window with alternate activation under the shell", function(context)
    local opened, same_window
    context.is_hosted_surface = system.is_hosted_surface
    system.is_hosted_surface = function() return true end
    core.open_project_in_same_window = function(path) same_window = path; return true end
    core.open_project_in_new_window = function(path) opened = path; return true end

    fuzzy_searcher.open_static_results("Projects", {
      { kind = "project", label = context.empty, project = context.empty },
    })
    local picker = assert(core.fuzzy_searcher_active_view)
    picker.selected = 1
    picker:confirm(true)

    test.ok(not core.nag_view.visible, "expected no Open Folder prompt")
    test.ok(wait_until(function() return opened ~= nil or same_window ~= nil end))
    test.is_nil(same_window, "alternate activation must not select the Project in this Window")
    test.ok(common.path_equals(opened, context.empty))
  end)

  test.it("offers a folder as a File Tree or Project in this Anvil Window under the shell", function(context)
    context.is_hosted_surface = system.is_hosted_surface
    system.is_hosted_surface = function() return true end
    fuzzy_searcher.open("empty nested")
    local picker = assert(core.fuzzy_searcher_active_view)
    local index
    test.ok(wait_until(function()
      local result
      result, index = result_for_path(picker.results, context.empty)
      return index ~= nil
    end))

    picker.selected = index
    picker:confirm(false)

    assert_actions_present(core.nag_view.options, { "filetree", "project_here", "cancel" })
    select_folder_action("cancel")
  end)

  test.it("opens an exact Project folder path as a File Tree", function(context)
    fuzzy_searcher.open("./empty/nested")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return result_for_path(picker.results, context.empty) ~= nil end))
    local _, index = result_for_path(picker.results, context.empty)
    picker.selected = index
    picker:confirm(false)
    context.filetree_was_opened = true
    select_folder_action("filetree")
    test.ok(wait_until(function()
      return context.pane.current_view.root_dir == common.normalize_path(context.empty)
    end))
  end)
end)
