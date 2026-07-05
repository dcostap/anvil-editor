local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"

local project_paths_view = require "plugins.project_paths_view"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function mkdirp(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
end

local function write_file(path, text)
  local fp, err = io.open(path, "wb")
  test.not_nil(fp, err)
  fp:write(text or "")
  fp:close()
end

local function read_file(path)
  local fp, err = io.open(path, "rb")
  test.not_nil(fp, err)
  local text = fp:read("*a")
  fp:close()
  return text
end

local function setup_project(context)
  context.original_projects = core.projects
  context.original_cwd = system.getcwd()
  context.temp_root = USERDIR
    .. PATHSEP .. "project-paths-view-tests-"
    .. system.get_process_id() .. "-"
    .. math.floor(system.get_time() * 1000000)
  context.root = join_path(context.temp_root, "app")
  context.external = join_path(context.temp_root, "jdk-src")
  context.vendor = join_path(context.root, "src", "vendor", "library1")
  context.generated = join_path(context.root, "generated")
  mkdirp(context.root)
  mkdirp(context.external)
  mkdirp(context.vendor)
  mkdirp(context.generated)
  core.projects = { Project(context.root) }
  system.chdir(context.root)
  project_paths.configure_project {
    external = { { path = "../jdk-src", label = "jdk-src" } },
    vendored = { { path = "src/vendor/library1", label = "library1" } },
    excluded = { { path = "generated", label = "generated" } },
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
    project_paths.configure_project {}
    project_paths.load_workspace_state(nil)
    core.projects = context.original_projects
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.it("lists label, role, path, and storage for effective Project Path entries", function(context)
    local view = setup_project(context)
    local _, root_entry = find_row(view, common.basename(context.root))
    local _, external_entry = find_row(view, "jdk-src")
    local _, vendored_entry = find_row(view, "library1")
    local _, excluded_entry = find_row(view, "generated")

    test.not_nil(root_entry)
    test.equal(root_entry.role, "root")
    test.equal(root_entry.source, "implicit")
    test.equal(external_entry.role, "external")
    test.equal(vendored_entry.role, "vendored")
    test.equal(excluded_entry.role, "excluded")

    local text = table.concat(view.doc.lines)
    test.ok(text:find("project config", 1, true), "expected project config storage column")
    test.ok(text:find("automatic", 1, true), "expected automatic root storage")
  end)

  test.it("renames labels and changes display paths without touching files", function(context)
    local view = setup_project(context)
    local line = assert(find_row(view, "jdk-src"))
    view.doc:set_selection(line, 1)

    test.ok(view:rename_selected("jdk"))
    local display = project_paths.display_path(join_path(context.external, "String.java"))
    test.equal(display.text, "jdk" .. PATHSEP .. "String.java")
    test.ok(system.get_file_info(context.external), "external directory should remain on disk")
  end)

  test.it("changes roles and removes only Project Path Role entries", function(context)
    local view = setup_project(context)
    local line = assert(find_row(view, "library1"))
    view.doc:set_selection(line, 1)

    test.ok(view:change_selected_role("external"))
    local resolved = project_paths.resolve(context.vendor)
    test.equal(resolved.entry.role, "external")

    line = assert(find_row(view, "library1"))
    view.doc:set_selection(line, 1)
    test.ok(view:remove_selected())
    resolved = project_paths.resolve(context.vendor)
    test.equal(resolved.entry.role, "root")
    test.ok(system.get_file_info(context.vendor), "removing Project Path Role must not delete files")
  end)

  test.it("moves entries between local Workspace state and Project config state", function(context)
    local view = setup_project(context)
    local local_dir = join_path(context.temp_root, "local-lib")
    mkdirp(local_dir)
    local entry = project_paths_view.add_entry(local_dir, "external", "workspace", "local-lib")
    test.not_nil(entry)
    view:refresh()

    local line = assert(find_row(view, "local-lib"))
    view.doc:set_selection(line, 1)
    test.ok(view:change_selected_storage("project"))
    local moved = project_paths.resolve(local_dir).entry
    test.equal(moved.source, "project")

    local project_file = join_path(context.root, ".anvil_project.lua")
    local text = read_file(project_file)
    test.ok(text:find("ANVIL PROJECT PATHS BEGIN", 1, true), "expected generated project config block")
    test.ok(text:find("local%-lib") or text:find("local-lib", 1, true), "expected moved Project Path in project config")

    view:refresh()
    line = assert(find_row(view, "local-lib"))
    view.doc:set_selection(line, 1)
    test.ok(view:change_selected_storage("workspace"))
    moved = project_paths.resolve(local_dir).entry
    test.equal(moved.source, "workspace")
    text = read_file(project_file)
    test.not_ok(text:find("local%-lib") or text:find("local-lib", 1, true), "expected moved-local Project Path removed from project config")
  end)

  test.it("replaces duplicate paths across storage layers instead of leaving stale hidden entries", function(context)
    setup_project(context)
    local entry = project_paths_view.add_entry(context.external, "external", "workspace", "jdk-local")
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

  test.it("adds Project config entries through command helpers", function(context)
    setup_project(context)
    local shared = join_path(context.temp_root, "shared-src")
    mkdirp(shared)
    local entry = project_paths_view.add_entry(shared, "external", "project", "shared-src")
    test.not_nil(entry)
    test.equal(entry.source, "project")
    local text = read_file(join_path(context.root, ".anvil_project.lua"))
    test.ok(text:find("shared%-src") or text:find("shared-src", 1, true))
  end)
end)
