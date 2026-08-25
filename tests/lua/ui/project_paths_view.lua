local core = require "core"
local command = require "core.command"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"

local project_paths_view = require "plugins.project_paths_view"
local panes = require "core.panes"

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
  project_paths.configure_project {
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

test.describe("Project Paths View", function()
  test.after_each(function(context)
    panes.reset_for_tests()
    project_paths.configure_project {}
    project_paths.load_workspace_state(nil)
    if context.save_workspace_was_stubbed then core.save_workspace = context.original_save_workspace end
    core.projects = context.original_projects
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
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
end)
