local core = require "core"
local common = require "core.common"
local panes = require "core.panes"
local project_files = require "core.project_files"
local project_paths = require "core.project_paths"
local Project = require "core.project"
local test = require "core.test"
local View = require "core.view"

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
  local deadline = system.get_time() + (timeout or 5)
  while not predicate() and system.get_time() < deadline do coroutine.yield(0.02) end
  return predicate()
end

test.describe("Project File Search folders", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.projects = core.projects
    context.visited_files = core.visited_files
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
    project_paths.configure_project {}
    system.chdir(context.root)
    context.source = View()
    context.pane = panes.create { factory = function() return context.source end }
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    fuzzy_searcher._test.cancel_file_index_for_test()
    project_files.invalidate(context.root)
    project_paths.configure_project {}
    panes.reset_for_tests()
    core.projects = context.projects
    core.visited_files = context.visited_files
    if context.cwd then pcall(system.chdir, context.cwd) end
    if context.root and system.get_file_info(context.root) then
      local ok, err = common.rm(context.root, true)
      test.ok(ok, err)
    end
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

    picker.input:set_text("hidden nested")
    coroutine.yield(0.1)
    test.is_nil(result_for_path(picker.results, context.root .. PATHSEP .. ".hidden" .. PATHSEP .. "nested"))
  end)

  test.it("finds folders when the Project has no searchable files", function(context)
    test.ok(os.remove(context.button))
    fuzzy_searcher.open("empty nested")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return result_for_path(picker.results, context.empty) ~= nil end))
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
    test.equal(context.pane.current_view.root_dir, common.normalize_path(context.empty))
  end)

  test.it("opens a folder result in a split with alternate activation", function(context)
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
    test.equal(panes.count(), 2)
    test.equal(context.pane.current_view, context.source)
    test.equal(panes.active().current_view.root_dir, common.normalize_path(context.empty))
  end)

  test.it("opens an exact Project folder path as a File Tree", function(context)
    fuzzy_searcher.open("./empty/nested")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return result_for_path(picker.results, context.empty) ~= nil end))
    local _, index = result_for_path(picker.results, context.empty)
    picker.selected = index
    picker:confirm(false)
    test.equal(context.pane.current_view.root_dir, common.normalize_path(context.empty))
  end)
end)
