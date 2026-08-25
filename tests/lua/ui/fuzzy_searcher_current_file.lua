local common = require "core.common"
local command = require "core.command"
local core = require "core"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"
local View = require "core.view"

local fuzzy_searcher = require "plugins.fuzzy_searcher"
local filetree = require "plugins.filetree"

local FileView = View:extend()
function FileView:new(path)
  FileView.super.new(self)
  self.path = path
end

local function join_path(...)
  return table.concat({ ... }, PATHSEP)
end

local function write_file(path)
  local parent = common.dirname(path)
  if not system.get_file_info(parent) then assert(common.mkdirp(parent)) end
  local fp = assert(io.open(path, "wb"))
  fp:write("test\n")
  fp:close()
end

test.describe("Fuzzy Searcher current file query", function()
  test.before_each(function(context)
    context.projects = core.projects
    context.active_view = core.active_view
    context.cwd = system.getcwd()
    context.clipboard = system.get_clipboard()
    context.root = join_path(system.absolute_path("."), "fuzzy-current-file-query")
    context.external = join_path(system.absolute_path("."), "fuzzy-current-file-external")
    common.rm(context.root, true)
    common.rm(context.external, true)
    assert(common.mkdirp(context.root))
    assert(common.mkdirp(context.external))
    core.projects = { Project(context.root) }
    system.chdir(context.root)
    project_paths.configure_workspace {}
    fuzzy_searcher._test.set_everything_state("unavailable")
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    project_paths.configure_workspace {}
    core.projects = context.projects
    core.active_view = context.active_view
    system.chdir(context.cwd)
    system.set_clipboard(context.clipboard or "")
    common.rm(context.root, true)
    common.rm(context.external, true)
  end)

  local function perform_for(path)
    core.active_view = FileView(path)
    test.ok(command.perform("fuzzy:open_current_file"))
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker:update()
    return picker
  end

  test.it("uses a relative query for a Root Project file without changing the clipboard", function(context)
    local path = join_path(context.root, "src", "main.lua")
    write_file(path)
    system.set_clipboard("keep me")

    local picker = perform_for(path)

    test.equal(picker.input:get_text(), join_path("src", "main.lua"))
    test.equal(system.get_clipboard(), "keep me")
    test.ok(common.path_equals(picker.results[1].abs_path, path))
  end)

  test.it("uses the selected File Tree path", function(context)
    local path = join_path(context.root, "build", "module.obj")
    write_file(path)
    local tree = test.not_nil(filetree.new(path))
    core.active_view = tree

    test.ok(command.perform("fuzzy:open_current_file"))
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker:update()

    local query = join_path("build", "module.obj")
    test.equal(picker.input:get_text(), query)
    local line1, col1, line2, col2 = picker.input.textview.buffer:get_selection(true)
    test.same({ line1, col1, line2, col2 }, { 1, #query - #"module.obj" + 1, 1, #query + 1 })
    test.ok(common.path_equals(picker.results[1].abs_path, path))
  end)

  test.it("uses an absolute query for a Vendored Project Directory file", function(context)
    local vendor = join_path(context.root, "vendor", "library")
    local path = join_path(vendor, "src", "dependency.lua")
    write_file(path)
    project_paths.configure_workspace {
      vendored = { { path = vendor, label = "library" } },
    }

    local picker = perform_for(path)

    test.equal(picker.input:get_text(), common.normalize_path(path))
    test.not_ok(picker.path_search_active)
    test.ok(common.path_equals(picker.results[1].abs_path, path))
  end)

  test.it("uses an absolute query and Path Search for a file outside Project Search Scope", function(context)
    local path = join_path(context.external, "notes.txt")
    write_file(path)

    local picker = perform_for(path)

    test.equal(picker.input:get_text(), common.normalize_path(path))
    test.ok(picker.path_search_active)
    test.ok(common.path_equals(picker.results[1].abs_path, path))
  end)
end)
