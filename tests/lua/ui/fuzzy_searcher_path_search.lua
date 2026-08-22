local core = require "core"
local common = require "core.common"
local http = require "core.http"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"
local helpers = fuzzy_searcher._test

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function mkdirp(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
end

local function write_file(path, text)
  local fp = assert(io.open(path, "wb"))
  fp:write(text or "test\n")
  fp:close()
end

local function result_for_path(results, path)
  for _, result in ipairs(results or {}) do
    if result.path and common.path_equals(result.path, path) then return result end
  end
end

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + (timeout or 2)
  while not predicate() and system.get_time() < deadline do coroutine.yield(0.02) end
  return predicate()
end

test.describe("Fuzzy Searcher Path Search", function()
  test.before_each(function(context)
    context.http_get = http.get
    context.everything_state = helpers.everything_state()
    context.original_projects = core.projects
    context.original_recent_projects = core.recent_projects
    context.original_open_file = core.open_file
    context.original_cwd = system.getcwd()
    context.temp_root = common.normalize_path(USERDIR
      .. PATHSEP .. "fuzzy-path-search-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000))
    context.project_root = join_path(context.temp_root, "project")
    context.external_root = join_path(context.temp_root, "external")
    mkdirp(join_path(context.project_root, "src"))
    mkdirp(context.external_root)
    core.projects = { Project(context.project_root) }
    core.recent_projects = {}
    system.chdir(context.project_root)
    project_paths.configure_project {}
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    http.get = context.http_get
    helpers.set_everything_state(context.everything_state)
    project_paths.configure_project {}
    project_paths.load_workspace_state(nil)
    core.projects = context.original_projects
    core.recent_projects = context.original_recent_projects
    core.open_file = context.original_open_file
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
    if context.home_root and system.get_file_info(context.home_root) then
      local ok, err = common.rm(context.home_root, true)
      test.ok(ok, err)
    end
  end)

  test.it("keeps absolute paths inside the Project in Project File Search", function(context)
    local requests = {}
    http.get = function(_, params) requests[#requests+1] = params end
    helpers.set_everything_state("available")

    fuzzy_searcher.open(join_path(context.project_root, "src"))

    test.equal(#requests, 0)
    test.equal(core.fuzzy_searcher_active_view:is_path_search(), false)
  end)

  test.it("matches Project files behind an explicit current-directory prefix", function(context)
    local file = join_path(context.project_root, "src", "main.lua")
    write_file(file)
    helpers.set_file_cache_for_test({ assert(helpers.file_display_item(file)) })

    fuzzy_searcher.open("./")
    local picker = core.fuzzy_searcher_active_view

    test.ok(wait_until(function()
      for _, result in ipairs(picker.results or {}) do
        if result.file and common.path_equals(helpers.fullpath(result), file) then return true end
      end
    end), "expected ./ to preserve Project file results")
    test.ok(common.path_equals(picker.results[1].abs_path, context.project_root))
  end)

  test.it("keeps a Project directory prefix and search terms in Project File Search", function(context)
    local requests = {}
    http.get = function(_, params) requests[#requests+1] = params end
    helpers.set_everything_state("available")

    fuzzy_searcher.open(join_path(context.project_root, "src") .. " needle")

    test.equal(#requests, 0)
    test.equal(core.fuzzy_searcher_active_view:is_path_search(), false)

    core.fuzzy_searcher_active_view:close()
    fuzzy_searcher.open(context.project_root .. " needle")

    test.equal(#requests, 0)
    test.equal(core.fuzzy_searcher_active_view:is_path_search(), false)
  end)

  test.it("starts scoped Path Search for an absolute path outside the Project", function(context)
    local requests = {}
    http.get = function(_, params, options)
      requests[#requests+1] = { params = params, options = options }
    end
    helpers.set_everything_state("available")

    fuzzy_searcher.open(join_path(context.external_root, "needle"))

    test.equal(#requests, 1)
    test.equal(requests[1].params.search,
      'folder: ancestor:"' .. context.external_root .. '" needle')
    requests[1].options.on_done(true, nil, { totalResults = 0, results = {} })
    test.equal(#requests, 2)
    test.equal(requests[2].params.search,
      'file: ancestor:"' .. context.external_root .. '" needle')
    test.equal(core.fuzzy_searcher_active_view:is_path_search(), true)
    test.ok(core.fuzzy_searcher_active_view:list_metrics().list_w
      < core.fuzzy_searcher_active_view.size.x)
  end)

  test.it("uses the longest existing directory prefix before search terms", function(context)
    local spaced_root = join_path(context.temp_root, "outside folder")
    mkdirp(spaced_root)
    local requests = {}
    http.get = function(_, params, options)
      requests[#requests+1] = { params = params, options = options }
    end
    helpers.set_everything_state("available")

    fuzzy_searcher.open(spaced_root .. " needle")

    test.equal(#requests, 1)
    test.equal(requests[1].params.search,
      'folder: ancestor:"' .. spaced_root .. '" needle')
    requests[1].options.on_done(true, nil, { totalResults = 0, results = {} })
    test.equal(#requests, 2)
    test.equal(requests[2].params.search,
      'file: ancestor:"' .. spaced_root .. '" needle')
  end)

  test.it("expands a home-relative path before starting Path Search", function(context)
    local home = common.normalize_path(common.home_expand("~"))
    test.not_equal(home, "~")
    local name = "fuzzy-home-path-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    local home_root = join_path(home, name)
    mkdirp(home_root)
    context.home_root = home_root
    local requests = {}
    http.get = function(_, params, options)
      requests[#requests+1] = { params = params, options = options }
    end
    helpers.set_everything_state("available")

    fuzzy_searcher.open("~/" .. name .. "/needle")

    test.equal(#requests, 1)
    test.equal(requests[1].params.search,
      'folder: ancestor:"' .. home_root .. '" needle')
    requests[1].options.on_done(true, nil, { totalResults = 0, results = {} })
    test.equal(#requests, 2)
    test.equal(requests[2].params.search,
      'file: ancestor:"' .. home_root .. '" needle')
  end)

  test.it("uses bounded direct folder contents when Everything is unavailable", function(context)
    local folder = join_path(context.external_root, "alpha-folder")
    local file = join_path(context.external_root, "alpha-file.txt")
    mkdirp(folder)
    write_file(file)
    helpers.set_everything_state("unavailable")

    fuzzy_searcher.open(join_path(context.external_root, "alpha"))
    local picker = core.fuzzy_searcher_active_view
    local folder_result = result_for_path(picker.results, folder)
    local file_result = result_for_path(picker.results, file)

    test.not_nil(folder_result)
    test.equal(folder_result.is_folder, true)
    test.equal(folder_result.project, folder)
    test.not_nil(file_result)
    test.equal(file_result.is_folder, false)
    test.equal(file_result.file, file)
    test.equal(picker.results[1].kind, "create_path")
    test.equal(picker.results[2].label, "Folders")
    for index, result in ipairs(picker.results) do
      if result == file_result then picker.selected = index break end
    end
    local preview = picker:update_selected_preview()
    test.not_nil(preview)
    test.ok(common.path_equals(preview.buffer.abs_filename, file))
    local drawn, draw_error = pcall(function() picker:draw() end)
    test.ok(drawn, draw_error)
  end)

  test.it("puts an exact hidden Project path before indexed results", function(context)
    local hidden_dir = join_path(context.project_root, ".hidden")
    local hidden_file = join_path(hidden_dir, "exact.txt")
    mkdirp(hidden_dir)
    write_file(hidden_file)
    helpers.set_everything_state("unavailable")

    fuzzy_searcher.open(".hidden/exact.txt")
    local result = core.fuzzy_searcher_active_view.results[1]

    test.not_nil(result)
    test.equal(result.exact_path, true)
    test.ok(common.path_equals(result.abs_path, hidden_file))
  end)

  test.it("creates and opens an explicit missing relative file path", function(context)
    local path = join_path(context.project_root, "new", "deep", "created.txt")
    local opened_path, opened_options
    core.open_file = function(file, options)
      opened_path, opened_options = file, options
      return { buffer = { set_selection = function() end } }
    end
    helpers.set_everything_state("unavailable")

    fuzzy_searcher.open("./new/deep/created.txt")
    local picker = core.fuzzy_searcher_active_view
    test.equal(picker.results[1].kind, "create_path")
    local drawn, draw_error = pcall(function() picker:draw() end)
    test.ok(drawn, draw_error)
    picker:confirm()

    local info = system.get_file_info(path)
    test.not_nil(info)
    test.equal(info.type, "file")
    test.ok(common.path_equals(opened_path, path))
    test.equal(opened_options.placement, "current")
  end)

  test.it("creates an explicit folder path and refreshes it as exact", function(context)
    local path = join_path(context.project_root, "new", "folder")
    helpers.set_everything_state("unavailable")

    fuzzy_searcher.open("./new/folder/")
    local picker = core.fuzzy_searcher_active_view
    test.equal(picker.results[1].kind, "create_path")
    picker:confirm()

    local info = system.get_file_info(path)
    test.not_nil(info)
    test.equal(info.type, "dir")
    test.equal(core.fuzzy_searcher_active_view, picker)
    test.equal(picker.results[1].exact_path, true)
    test.ok(common.path_equals(picker.results[1].abs_path, path))
  end)

  test.it("does not offer creation for a missing bare name", function(context)
    helpers.set_everything_state("unavailable")

    fuzzy_searcher.open("missing.txt")

    for _, result in ipairs(core.fuzzy_searcher_active_view.results) do
      test.not_equal(result.kind, "create_path")
    end
  end)

  test.it("marks matching recent Projects before ordinary folders", function(context)
    local recent = join_path(context.external_root, "needle-project")
    mkdirp(recent)
    core.recent_projects = { recent }
    helpers.set_everything_state("unavailable")

    fuzzy_searcher.open("@needle")
    local picker = core.fuzzy_searcher_active_view
    local result = result_for_path(picker.results, recent)

    test.not_nil(result)
    test.equal(result.kind, "project")
    test.equal(result.path_search, true)
  end)
end)
