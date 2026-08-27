local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"

local project_paths_view = require "plugins.project_paths_view"
local panes = require "core.panes"
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
  context.original_active_view = core.active_view
  context.original_projects = core.projects
  context.original_cwd = system.getcwd()
  context.temp_root = USERDIR
    .. PATHSEP .. "project-paths-view-tests-"
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
  local view = project_paths_view.open_view()
  context.view = view
  return view
end

local function find_row(view, label)
  for line, entry in pairs(view.entries_by_line) do
    if entry.label == label then return line, entry end
  end
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

test.describe("Project Paths View", function()
  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    if core.active_view == core.global_prompt_bar then core.global_prompt_bar:exit(false) end
    if context.everything_state then fuzzy_helpers.set_everything_state(context.everything_state) end
    panes.reset_for_tests()
    project_paths.configure_workspace {}
    project_paths.load_workspace_state(nil)
    if context.save_workspace_was_stubbed then core.save_workspace = context.original_save_workspace end
    core.projects = context.original_projects
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.it("starts with line wrapping off", function(context)
    context.original_projects = core.projects
    context.original_cwd = system.getcwd()
    local old_default = config.plugins.linewrapping.enable_by_default
    config.plugins.linewrapping.enable_by_default = true
    local view = project_paths_view.view_class()
    config.plugins.linewrapping.enable_by_default = old_default

    local wrapping_enabled = view:is_wrapping_enabled()
    view:on_close()
    test.equal(wrapping_enabled, false)
  end)

  test.it("lists the label, role, and path without storage controls", function(context)
    local view = setup_project(context)
    local _, root_entry = find_row(view, common.basename(context.root))
    local _, external_entry = find_row(view, "jdk-src")
    local _, vendored_entry = find_row(view, "library1")

    test.not_nil(root_entry)
    test.equal(root_entry.role, "root")
    test.equal(root_entry.source, "implicit")
    test.equal(external_entry.role, "external")
    test.equal(vendored_entry.role, "vendored")

    local text = table.concat(view.buffer.lines)
    test.not_ok(text:find("Storage", 1, true))
    test.not_ok(view.change_selected_storage)
    test.is_nil(command.map["project_paths:add_external_directory_local"])
    test.is_nil(command.map["project_paths:add_external_directory_to_project_config"])
  end)

  test.it("moves the caret through Project Path rows with Text View navigation", function(context)
    local view = setup_project(context)
    local line = test.not_nil(find_row(view, common.basename(context.root)))
    view.buffer:set_selection(line, 1)

    test.ok(command.perform("core:move_to_next_line"))
    test.equal(view.buffer:get_selection(), line + 1)
    test.ok(command.perform("core:move_to_previous_line"))
    test.equal(view.buffer:get_selection(), line)
  end)

  test.it("renames labels and changes display paths without touching files", function(context)
    local view = setup_project(context)
    local line = assert(find_row(view, "jdk-src"))
    view.buffer:set_selection(line, 1)

    test.ok(view:rename_selected("jdk"))
    local display = project_paths.display_path(join_path(context.external, "String.java"))
    test.equal(display.text, "jdk" .. PATHSEP .. "String.java")
    test.ok(system.get_file_info(context.external), "external directory should remain on disk")
  end)

  test.it("changes roles and removes only Project Path Role entries", function(context)
    local view = setup_project(context)
    local line = assert(find_row(view, "library1"))
    view.buffer:set_selection(line, 1)

    test.ok(view:change_selected_role("external"))
    local resolved = project_paths.resolve(context.vendor)
    test.equal(resolved.entry.role, "external")

    line = assert(find_row(view, "library1"))
    view.buffer:set_selection(line, 1)
    test.ok(view:remove_selected())
    resolved = project_paths.resolve(context.vendor)
    test.equal(resolved.entry.role, "root")
    test.ok(system.get_file_info(context.vendor), "removing Project Path Role must not delete files")
  end)

  test.it("replaces a matching Project Path without leaving a duplicate", function(context)
    setup_project(context)
    local entry = project_paths_view.add_entry(context.external, "external", "jdk-local")
    test.not_nil(entry)
    local matches = 0
    for _, candidate in ipairs(project_paths.entries({ include_root = false })) do
      if common.path_equals(candidate.path, context.external) then
        matches = matches + 1
        test.equal(candidate.source, "workspace")
        test.equal(candidate.label, "jdk-local")
      end
    end
    test.equal(matches, 1)
  end)

  test.it("saves local-only Project Path changes immediately", function(context)
    setup_project(context)
    context.original_save_workspace = core.save_workspace
    context.save_workspace_was_stubbed = true
    local save_count = 0
    core.save_workspace = function() save_count = save_count + 1 end
    local local_dir = join_path(context.temp_root, "instant-local-lib")
    mkdirp(local_dir)

    local entry = project_paths_view.add_entry(local_dir, "external", "instant-local-lib")
    test.not_nil(entry)
    test.equal(entry.source, "workspace")
    test.equal(save_count, 1)
  end)

  test.it("adds an External Project Directory through the folder File Picker and label prompt", function(context)
    setup_project(context)
    context.everything_state = fuzzy_helpers.everything_state()
    fuzzy_helpers.set_everything_state("unavailable")
    local selected_path = join_path(context.temp_root, "selected-external")
    mkdirp(selected_path)

    test.ok(command.perform("project_paths:add_external_directory"))
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.equal(picker.file_picker.select, "folder")
    set_picker_query(picker, context.temp_root .. PATHSEP)
    local selected_index
    for index, result in ipairs(picker.results) do
      if common.path_equals(result_path(result), selected_path) then selected_index = index; break end
    end
    picker.selected = test.not_nil(selected_index)
    picker:confirm(false)

    test.equal(core.active_view, core.global_prompt_bar)
    test.equal(core.global_prompt_bar:get_text(), "selected-external")
    core.global_prompt_bar:set_text("Selected Sources")
    core.global_prompt_bar:submit()

    local resolved = test.not_nil(project_paths.resolve(selected_path))
    test.equal(resolved.entry.role, "external")
    test.equal(resolved.entry.label, "Selected Sources")
  end)

  test.it("lists and immediately removes External and Vendored Project Directories", function(context)
    setup_project(context)

    test.ok(command.perform("project_paths:remove_directory"))
    local prompt_bar = core.global_prompt_bar
    test.equal(core.active_view, prompt_bar)
    local roles = {}
    for _, suggestion in ipairs(prompt_bar.suggestions) do
      roles[suggestion.role] = true
    end
    test.ok(roles.external)
    test.ok(roles.vendored)
    test.equal(#prompt_bar.suggestions, 2)

    prompt_bar:set_text("library1")
    prompt_bar:submit()

    test.equal(project_paths.resolve(context.vendor).entry.role, "root")
    test.equal(project_paths.resolve(context.external).entry.role, "external")
    test.ok(system.get_file_info(context.vendor), "removing the Project Path must not delete its directory")
  end)
end)
