local common = require "core.common"
local command = require "core.command"
local core = require "core"
local panes = require "core.panes"
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

local function wait_for_result(picker, path)
  local deadline = system.get_time() + 5
  repeat
    local first = picker.results[1]
    if first and first.abs_path and common.path_equals(first.abs_path, path) then return true end
    coroutine.yield(0.02)
  until system.get_time() >= deadline
  return false
end

test.describe("Fuzzy Searcher current file query", function()
  test.before_each(function(context)
    context.projects = core.projects
    context.active_view = core.active_view
    context.cwd = system.getcwd()
    context.clipboard = system.get_clipboard()
    panes.reset_for_tests()
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
    panes.reset_for_tests()
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
    test.ok(wait_for_result(picker, path))
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
    test.ok(wait_for_result(picker, path))
  end)

  test.it("uses the selected Fuzzy Searcher file instead of its source file", function(context)
    local source = join_path(context.root, "src", "source.lua")
    local selected = join_path(context.root, "lib", "selected.lua")
    write_file(source)
    write_file(selected)
    core.active_view = FileView(source)

    fuzzy_searcher.open("")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker.results = { { kind = "file", file = selected, abs_path = selected } }
    picker.selected = 1

    test.ok(command.perform("fuzzy:open_current_file"))
    test.equal(picker.input:get_text(), join_path("lib", "selected.lua"))
  end)

  test.it("keeps the source Path Target for path-aware commands", function(context)
    local path = join_path(context.root, "src", "target.lua")
    write_file(path)
    local view = View()
    function view:get_path_target()
      return { path = path, line = 37 }
    end
    core.active_view = view

    test.ok(command.perform("fuzzy:open_current_file"))
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker:update()

    test.equal(picker.source_file_path, common.normalize_path(path))
    test.equal(picker.source_file_line, 37)
    test.ok(wait_for_result(picker, path))
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
    test.ok(wait_for_result(picker, path))
  end)

  test.it("uses an absolute query and Path Search for a file outside Project Search Scope", function(context)
    local path = join_path(context.external, "notes.txt")
    write_file(path)

    local picker = perform_for(path)

    test.equal(picker.input:get_text(), common.normalize_path(path))
    test.ok(picker.path_search_active)
    test.ok(common.path_equals(picker.results[1].abs_path, path))
  end)

  test.it("opens the selected file in a File Tree", function(context)
    local source_path = join_path(context.root, "src", "source.lua")
    local selected_path = join_path(context.root, "lib", "selected.lua")
    write_file(source_path)
    write_file(selected_path)
    local source = FileView(source_path)
    local pane = panes.create { factory = function() return source end }
    core.active_view = source

    fuzzy_searcher.open("")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker.results = { { kind = "file", file = selected_path, abs_path = selected_path } }
    picker.selected = 1

    test.ok(command.perform("fuzzy:open_selected_in_filetree"))

    local tree = pane.current_view
    test.equal(tree.root_dir, common.normalize_path(context.root))
    local entry = tree:entry_for_line(tree.buffer:get_selection(true))
    test.ok(entry and common.path_equals(entry.abs, selected_path))
    test.ok(picker.closed)
  end)

  test.it("does not open a File Tree for a selected folder", function(context)
    local folder = join_path(context.root, "selected-folder")
    test.ok(common.mkdirp(folder))
    local source = FileView(join_path(context.root, "source.lua"))
    write_file(source.path)
    local pane = panes.create { factory = function() return source end }
    core.active_view = source

    fuzzy_searcher.open("")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker.results = { { kind = "folder", abs_path = folder, is_folder = true } }
    picker.selected = 1

    test.ok(command.perform("fuzzy:open_selected_in_filetree"))

    test.equal(pane.current_view, source)
    test.not_ok(picker.closed)
  end)
end)
