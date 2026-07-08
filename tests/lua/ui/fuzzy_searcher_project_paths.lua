local core = require "core"
local common = require "core.common"
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

test.describe("Fuzzy Searcher Project Path Roles", function()
  test.before_each(function(context)
    context.original_projects = core.projects
    context.original_visited_files = core.visited_files
    context.original_cwd = system.getcwd()
    context.temp_root = USERDIR
      .. PATHSEP .. "fuzzy-project-paths-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.root = join_path(context.temp_root, "app")
    context.external = join_path(context.temp_root, "jdk-src")
    mkdirp(join_path(context.root, "src", "vendor", "library1", "foo"))
    mkdirp(join_path(context.root, "generated"))
    mkdirp(join_path(context.external, "java", "lang"))
    core.projects = { Project(context.root) }
    core.visited_files = {}
    system.chdir(context.root)
    project_paths.configure_project {
      external = {
        { path = "../jdk-src", label = "Java Sources" },
      },
      vendored = {
        { path = "src/vendor/library1", label = "library1" },
      },
      excluded = {
        { path = "generated", label = "generated" },
      },
    }
  end)

  test.after_each(function(context)
    project_paths.configure_project {}
    project_paths.load_workspace_state(nil)
    core.projects = context.original_projects
    core.visited_files = context.original_visited_files
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.it("renders external and vendored files with role labels and keeps absolute activation paths", function(context)
    local external_file = join_path(context.external, "java", "lang", "String.java")
    local vendored_file = join_path(context.root, "src", "vendor", "library1", "foo", "Baz.java")
    write_file(external_file)
    write_file(vendored_file)

    local external_item = helpers.file_display_item(external_file)
    local vendored_item = helpers.file_display_item(vendored_file)
    local rows = helpers.file_search_rows("String", { external_item, vendored_item }, nil, 20)
    local external_row = rows[1]

    test.equal(external_row.file, "Java Sources" .. PATHSEP .. "java" .. PATHSEP .. "lang" .. PATHSEP .. "String.java")
    test.equal(external_row.root_label, "Java Sources")
    test.equal(external_row.root_role, "external")
    test.same(external_row.prefix_span, { 1, #"Java Sources" })
    test.ok(common.path_equals(helpers.fullpath(external_row), external_file))

    rows = helpers.file_search_rows("Baz", { external_item, vendored_item }, nil, 20)
    local vendored_row = rows[1]
    test.equal(vendored_row.file, "library1" .. PATHSEP .. "foo" .. PATHSEP .. "Baz.java")
    test.equal(vendored_row.root_role, "vendored")
    test.same(vendored_row.prefix_span, { 1, #"library1" })
    test.ok(common.path_equals(helpers.fullpath(vendored_row), vendored_file))
  end)

  test.it("disambiguates identical display paths without losing activation paths", function(context)
    local root_collision = join_path(context.root, "jdk-src", "Foo.java")
    mkdirp(join_path(context.root, "jdk-src"))
    local external_collision = join_path(context.external, "Foo.java")
    write_file(root_collision)
    write_file(external_collision)

    local root_item = helpers.file_display_item(root_collision)
    local external_item = helpers.file_display_item(external_collision)

    test.not_equal(root_item, external_item)
    test.ok(common.path_equals(helpers.fullpath(root_item), root_collision))
    test.ok(common.path_equals(helpers.fullpath(external_item), external_collision))
  end)

  test.it("prefers Root Project files over matching External Project Directory files", function(context)
    local root_file = join_path(context.root, "String.java")
    local external_file = join_path(context.external, "String.java")
    write_file(root_file)
    write_file(external_file)

    local root_item = helpers.file_display_item(root_file)
    local external_item = helpers.file_display_item(external_file)
    local rows = helpers.file_search_rows("String", { external_item, root_item }, nil, 20)

    test.ok(common.path_equals(helpers.fullpath(rows[1]), root_file), "expected Root Project file to rank first")
    test.ok(common.path_equals(helpers.fullpath(rows[2]), external_file), "expected External Project Directory file to remain visible")
  end)

  test.it("builds grep scope and display metadata from activation paths, not role labels", function(context)
    local external_file = join_path(context.external, "java", "lang", "String.java")
    local vendored_file = join_path(context.root, "src", "vendor", "library1", "foo", "Baz.java")
    write_file(external_file, "NEEDLE\n")
    write_file(vendored_file, "NEEDLE\n")
    local external_item = helpers.file_display_item(external_file)
    local vendored_item = helpers.file_display_item(vendored_file)
    helpers.set_file_cache_for_test({ external_item, vendored_item })

    local scope = helpers.build_scope("String", nil, 20)
    test.ok(common.path_equals(scope[1], external_file), "expected grep scope to use external absolute path")

    local result = helpers.decorate_grep_result({ file = "java/lang/String.java", line = 1, col = 1, text = "NEEDLE" }, context.external)
    test.equal(result.file, external_item)
    test.same(result.prefix_span, { 1, #"Java Sources" })
    test.ok(common.path_equals(result.abs_path, external_file))

    result = helpers.decorate_grep_result({ file = common.relative_path(context.root, vendored_file), line = 1, col = 1, text = "NEEDLE" }, context.root)
    test.equal(result.file, vendored_item)
    test.ok(common.path_equals(result.abs_path, vendored_file))
  end)

  test.it("omits excluded Project Paths from recent file rows", function(context)
    local excluded_file = join_path(context.root, "generated", "Output.java")
    write_file(excluded_file)
    core.visited_files = { excluded_file }

    local recents = helpers.recent_files()

    test.equal(#recents, 0)
  end)
end)
