local core = require "core"
local command = require "core.command"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local panes = require "core.panes"
local test = require "core.test"
local dialog = require "core.ui.dialog"
local fuzzy_searcher = require "plugins.fuzzy_searcher"

local fuzzy_helpers = fuzzy_searcher._test

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function mkdirp(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
end

local function setup_project(context)
  context.original_projects = core.projects
  context.original_cwd = system.getcwd()
  context.original_save_workspace = core.save_workspace
  context.saves = 0
  core.save_workspace = function() context.saves = context.saves + 1 end
  context.temp_root = USERDIR
    .. PATHSEP .. "project-paths-dialog-tests-"
    .. system.get_process_id() .. "-"
    .. math.floor(system.get_time() * 1000000)
  context.root = join_path(context.temp_root, "app")
  context.external = join_path(context.temp_root, "jdk-src")
  context.vendor = join_path(context.root, "src", "vendor", "library1")
  mkdirp(context.root)
  mkdirp(context.external)
  mkdirp(context.vendor)
  core.projects = { Project(context.root) }
  system.chdir(context.root)
  project_paths.configure_workspace {
    external = { { path = "../jdk-src", label = "jdk-src" } },
    vendored = { { path = "src/vendor/library1", label = "library1" } },
  }
end

local function open_dialog()
  test.ok(command.perform("project_paths:manage"))
  local open = test.not_nil(dialog.current())
  dialog.update()
  return open
end

local function select_row(open, label)
  for index, entry in ipairs(open.list.rows) do
    if entry.label == label then
      open.list:select(index)
      return entry
    end
  end
  test.fail("no row " .. label)
end

local function type_text(open, text)
  for char in text:gmatch(".") do open:on_modal_text_input(char) end
end

local function click(control)
  local x, y = control.x + control.w / 2, control.y + control.h / 2
  core.on_event("mousepressed", "left", x, y, 1)
  core.on_event("mousereleased", "left", x, y)
end

local function set_picker_query(picker, text)
  picker.input:set_text(text)
  picker.current_query_key = nil
  picker.force_refresh = true
  picker.dirty = true
  picker:refresh(text)
end

local function result_path(result)
  return result and (result.path or result.project or result.abs_path or result.file)
end

test.describe("Project Paths Dialog", function()
  local saved_size

  test.before_each(function()
    panes.reset_for_tests()
    saved_size = { core.root_panel.size.x, core.root_panel.size.y }
    core.root_panel.size.x, core.root_panel.size.y = 1000, 700
  end)

  test.after_each(function(context)
    local open = dialog.current()
    if open then open:close() end
    for _ = 1, 3 do dialog.update() end
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    if context.everything_state then fuzzy_helpers.set_everything_state(context.everything_state) end
    panes.reset_for_tests()
    project_paths.configure_workspace {}
    project_paths.load_workspace_state(nil)
    core.root_panel.size.x, core.root_panel.size.y = saved_size[1], saved_size[2]
    if context.original_save_workspace then core.save_workspace = context.original_save_workspace end
    if context.original_projects then core.projects = context.original_projects end
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    if context.temp_root then test.ok(test.remove_tree(context.temp_root)) end
  end)

  test.it("lists the Root Project and each Project Path with its role", function(context)
    setup_project(context)
    local open = open_dialog()

    local roles = {}
    for _, entry in ipairs(open.list.rows) do roles[entry.label] = entry.role end
    test.same(roles, { [common.basename(context.root)] = "root", ["jdk-src"] = "external", library1 = "vendored" })
  end)

  test.it("renames a label without touching the folder", function(context)
    setup_project(context)
    local open = open_dialog()
    select_row(open, "jdk-src")
    test.ok(command.perform("dialog:confirm"))
    test.equal(open.focused, open.label_field)

    type_text(open, "jdk")
    test.ok(command.perform("dialog:confirm"))

    local display = project_paths.display_path(join_path(context.external, "String.java"))
    test.equal(display.text, "jdk" .. PATHSEP .. "String.java")
    test.ok(system.get_file_info(context.external), "the folder stays on disk")
    test.ok(context.saves > 0, "the change saves the Workspace")
  end)

  test.it("refuses a label with a path separator and keeps the old label", function(context)
    setup_project(context)
    local open = open_dialog()
    select_row(open, "jdk-src")
    open:focus(open.label_field)

    type_text(open, "a/b")
    test.ok(command.perform("dialog:confirm"))

    test.not_nil(open.label_field.error)
    test.equal(project_paths.resolve(context.external).entry.label, "jdk-src")
  end)

  test.it("refuses a label that another Project Path has", function(context)
    setup_project(context)
    local open = open_dialog()
    select_row(open, "jdk-src")
    open:focus(open.label_field)

    type_text(open, "library1")
    test.ok(command.perform("dialog:confirm"))

    test.not_nil(open.label_field.error)
    test.equal(project_paths.resolve(context.external).entry.label, "jdk-src")
  end)

  test.it("changes the role, and offers only Vendored inside the Root Project", function(context)
    setup_project(context)
    local open = open_dialog()

    select_row(open, "library1")
    test.not_ok(open.role_control:choose("external"))
    test.equal(project_paths.resolve(context.vendor).entry.role, "vendored")

    select_row(open, "jdk-src")
    test.ok(open.role_control:choose("vendored"))
    test.equal(project_paths.resolve(context.external).entry.role, "vendored")
  end)

  test.it("keeps the Root Project's row read-only", function(context)
    setup_project(context)
    local open = open_dialog()
    select_row(open, common.basename(context.root))

    test.not_ok(open.label_field:can_focus())
    test.not_ok(open.remove_button.enabled)
    test.not_ok(open:remove_selected())
  end)

  test.it("removes a Project Path with Remove and keeps its folder", function(context)
    setup_project(context)
    local open = open_dialog()
    select_row(open, "library1")

    click(open.remove_button)

    test.equal(project_paths.resolve(context.vendor).entry.role, "root")
    test.ok(system.get_file_info(context.vendor), "the folder stays on disk")
    for _, entry in ipairs(open.list.rows) do test.not_equal(entry.label, "library1") end
  end)

  test.it("adds a folder by path and opens it in the Dialog with its label ready", function(context)
    setup_project(context)
    local folder = join_path(context.temp_root, "sdk")
    mkdirp(folder)

    test.ok(command.perform("project_paths:add", folder))

    local entry = test.not_nil(project_paths.resolve(folder)).entry
    test.equal(entry.role, "external")
    test.equal(entry.label, "sdk")
    local open = test.not_nil(dialog.current())
    test.equal(open:selected_entry().label, "sdk")
    test.equal(open.focused, open.label_field)
    test.ok(context.saves > 0, "the change saves the Workspace")
  end)

  test.it("adds a folder inside the Root Project as Vendored", function(context)
    setup_project(context)
    local folder = join_path(context.root, "third_party")
    mkdirp(folder)

    test.ok(command.perform("project_paths:add", folder))

    test.equal(project_paths.resolve(folder).entry.role, "vendored")
  end)

  test.it("adds the folder chosen in the File Picker", function(context)
    setup_project(context)
    context.everything_state = fuzzy_helpers.everything_state()
    fuzzy_helpers.set_everything_state("unavailable")
    local folder = join_path(context.temp_root, "picked")
    mkdirp(folder)
    open_dialog()

    click(dialog.current().add_button)

    test.is_nil(dialog.current())
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.equal(picker.file_picker.select, "folder")
    set_picker_query(picker, context.temp_root .. PATHSEP)
    local index
    for i, result in ipairs(picker.results) do
      if common.path_equals(result_path(result), folder) then index = i end
    end
    picker.selected = test.not_nil(index)
    picker:confirm(false)

    test.equal(project_paths.resolve(folder).entry.role, "external")
    test.equal(test.not_nil(dialog.current()):selected_entry().label, "picked")
  end)

  test.it("changes the label of an extra open Project", function(context)
    setup_project(context)
    local other = join_path(context.temp_root, "other")
    mkdirp(other)
    core.projects[#core.projects + 1] = Project(other)
    project_paths.invalidate("test")
    local open = open_dialog()
    select_row(open, "other")
    open:focus(open.label_field)

    type_text(open, "renamed")
    test.ok(command.perform("dialog:confirm"))

    test.is_nil(open.label_field.error)
    test.equal(project_paths.resolve(join_path(other, "a.txt")).entry.label, "renamed")
  end)

  test.it("shows changes that the File Tree makes while it is open", function(context)
    setup_project(context)
    local open = open_dialog()

    require("plugins.project_paths").remove(project_paths.resolve(context.external).entry.id)
    dialog.update()

    for _, entry in ipairs(open.list.rows) do test.not_equal(entry.label, "jdk-src") end
  end)
end)
