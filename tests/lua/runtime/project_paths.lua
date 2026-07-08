local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function mkdirp(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
end

test.describe("Project path roles", function()
  test.before_each(function(context)
    context.original_projects = core.projects
    context.original_cwd = system.getcwd()
    context.temp_root = USERDIR
      .. PATHSEP .. "project-paths-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)

    context.root = join_path(context.temp_root, "app")
    context.external = join_path(context.temp_root, "jdk-src")
    mkdirp(join_path(context.root, "src", "vendor", "library1", "foo"))
    mkdirp(join_path(context.root, "generated"))
    mkdirp(join_path(context.external, "java", "lang"))
    core.projects = { Project(context.root) }
    system.chdir(context.root)

    context.project_paths = project_paths
    context.project_paths.configure_project {}
    context.project_paths.load_workspace_state(nil)
  end)

  test.after_each(function(context)
    if context.original_get_file_info then
      system.get_file_info = context.original_get_file_info
      context.original_get_file_info = nil
    end
    if context.project_paths then
      context.project_paths.configure_project {}
      context.project_paths.load_workspace_state(nil)
    end
    core.projects = context.original_projects
    if context.original_cwd then
      pcall(system.chdir, context.original_cwd)
    end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.test("root project entry is implicit", function(context)
    local entries = context.project_paths.entries()

    test.equal(entries[1].role, "root")
    test.equal(entries[1].source, "implicit")
    test.ok(common.path_equals(entries[1].path, context.root))
    test.equal(entries[1].searchable, true)
  end)

  test.test("effective entries are cached until project paths change", function(context)
    local root_stat_calls = 0
    context.original_get_file_info = system.get_file_info
    system.get_file_info = function(path)
      if common.path_equals(path, context.root) then
        root_stat_calls = root_stat_calls + 1
      end
      return context.original_get_file_info(path)
    end

    context.project_paths.configure_project {}
    for _ = 1, 5 do
      context.project_paths.entries()
      context.project_paths.resolve(join_path(context.root, "src", "main.lua"))
      context.project_paths.display_path(join_path(context.root, "src", "main.lua"))
      context.project_paths.is_excluded(join_path(context.root, "src", "main.lua"), "files")
      context.project_paths.search_roots("files")
    end

    test.equal(root_stat_calls, 1)

    context.project_paths.configure_project {
      external = {
        { path = "../jdk-src", label = "jdk-src" },
      },
    }

    test.equal(root_stat_calls, 2)
  end)

  test.test("project config entries normalize paths and resolve relative paths against the root project", function(context)
    context.project_paths.configure_project {
      external = {
        { path = "../jdk-src", label = "jdk-src" },
      },
      vendored = {
        { path = "src/vendor/library1", label = "library1" },
      },
    }

    local external = context.project_paths.resolve(join_path(context.external, "java", "lang", "String.java"))
    test.equal(external.entry.role, "external")
    test.equal(external.entry.label, "jdk-src")
    test.equal(external.relpath, join_path("java", "lang", "String.java"))

    local vendored = context.project_paths.resolve(join_path(context.root, "src", "vendor", "library1", "foo", "Baz.java"))
    test.equal(vendored.entry.role, "vendored")
    test.equal(vendored.entry.label, "library1")
    test.equal(vendored.relpath, join_path("foo", "Baz.java"))
  end)

  test.test("duplicate labels are disambiguated in effective order", function(context)
    context.project_paths.configure_project {
      external = {
        { path = "../jdk-src", label = "src" },
      },
      vendored = {
        { path = "src/vendor/library1", label = "src" },
      },
    }

    local labels = {}
    for _, entry in ipairs(context.project_paths.entries()) do
      labels[#labels + 1] = entry.label
    end

    test.same(labels, { common.basename(context.root), "src", "src-2" })
  end)

  test.test("longest matching project path role wins", function(context)
    context.project_paths.configure_project {
      vendored = {
        { path = "src/vendor", label = "vendor" },
        { path = "src/vendor/library1", label = "library1" },
      },
    }

    local resolved = context.project_paths.resolve(join_path(context.root, "src", "vendor", "library1", "foo", "Baz.java"))

    test.equal(resolved.entry.label, "library1")
    test.equal(resolved.relpath, join_path("foo", "Baz.java"))
  end)

  test.test("excluded project paths suppress kind-specific capabilities while remaining browsable", function(context)
    context.project_paths.configure_project {
      excluded = {
        { path = "generated", label = "generated" },
      },
    }

    local filename = join_path(context.root, "generated", "Output.java")
    local resolved = context.project_paths.resolve(filename)

    test.equal(resolved.entry.role, "excluded")
    test.equal(resolved.flags.browsable, true)
    test.equal(resolved.flags.searchable, false)
    test.equal(context.project_paths.is_excluded(filename, "files"), true)
    test.equal(context.project_paths.is_excluded(filename, "symbols"), true)
  end)

  test.test("display path metadata and reverse resolution use role labels", function(context)
    context.project_paths.configure_project {
      external = {
        { path = "../jdk-src", label = "jdk-src" },
      },
      vendored = {
        { path = "src/vendor/library1", label = "library1" },
      },
    }

    local external_abs = join_path(context.external, "java", "lang", "String.java")
    local external_display = context.project_paths.display_path(external_abs)
    test.equal(external_display.text, "jdk-src" .. PATHSEP .. "java" .. PATHSEP .. "lang" .. PATHSEP .. "String.java")
    test.equal(external_display.root_label, "jdk-src")
    test.equal(external_display.root_role, "external")
    test.same(external_display.prefix_span, { 1, #"jdk-src" })
    test.ok(common.path_equals(context.project_paths.absolute_path(external_display.text), external_abs))

    local vendored_abs = join_path(context.root, "src", "vendor", "library1", "foo", "Baz.java")
    local vendored_display = context.project_paths.display_path(vendored_abs)
    test.equal(vendored_display.text, "library1" .. PATHSEP .. "foo" .. PATHSEP .. "Baz.java")
    test.equal(vendored_display.root_role, "vendored")
    test.ok(common.path_equals(context.project_paths.absolute_path(vendored_display.text), vendored_abs))
  end)

  test.test("reconfiguring project entries removes stale project-sourced entries", function(context)
    context.project_paths.configure_project {
      external = {
        { path = "../jdk-src", label = "jdk-src" },
      },
      excluded = {
        { path = "generated", label = "generated" },
      },
    }
    test.equal(context.project_paths.resolve(join_path(context.external, "java", "lang", "String.java")).entry.role, "external")
    test.equal(context.project_paths.is_excluded(join_path(context.root, "generated", "Output.java"), "files"), true)

    context.project_paths.configure_project {}

    test.is_nil(context.project_paths.resolve(join_path(context.external, "java", "lang", "String.java")))
    test.equal(context.project_paths.is_excluded(join_path(context.root, "generated", "Output.java"), "files"), false)
  end)

  test.test("failed project config transactions restore the previous project path entries", function(context)
    context.project_paths.configure_project {
      external = {
        { path = "../jdk-src", label = "jdk-src" },
      },
    }
    context.project_paths.begin_project_config_load()
    context.project_paths.configure_project {
      vendored = {
        { path = "src/vendor/library1", label = "library1" },
      },
    }

    context.project_paths.rollback_project_config_load()

    test.equal(context.project_paths.resolve(join_path(context.external, "java", "lang", "String.java")).entry.role, "external")
    test.equal(context.project_paths.resolve(join_path(context.root, "src", "vendor", "library1", "foo", "Baz.java")).entry.role, "root")
  end)

  test.test("workspace state imports legacy directories as local external project directories", function(context)
    context.project_paths.load_workspace_state(nil, { "../jdk-src" })

    local resolved = context.project_paths.resolve(join_path(context.external, "java", "lang", "String.java"))

    test.equal(resolved.entry.role, "external")
    test.equal(resolved.entry.source, "workspace")
    test.equal(resolved.entry.label, "jdk-src")
  end)

  test.test("explicit workspace labels win over matching open Project entries", function(context)
    context.project_paths.load_workspace_state {
      entries = {
        { path = context.external, label = "Java Sources", role = "external" },
      },
    }
    core.projects[#core.projects + 1] = Project(context.external)

    local resolved = context.project_paths.resolve(join_path(context.external, "java", "lang", "String.java"))

    test.equal(resolved.entry.role, "external")
    test.equal(resolved.entry.source, "workspace")
    test.equal(resolved.entry.label, "Java Sources")
  end)

  test.test("workspace state round-trips local project path entries", function(context)
    context.project_paths.add_external({ path = context.external, label = "jdk-src" }, { source = "workspace" })
    context.project_paths.add_excluded_path({ path = "generated", label = "generated" }, { source = "workspace" })

    local state = context.project_paths.save_workspace_state()
    context.project_paths.load_workspace_state(nil)
    test.is_nil(context.project_paths.resolve(join_path(context.external, "java", "lang", "String.java")))

    context.project_paths.load_workspace_state(state)
    test.equal(context.project_paths.resolve(join_path(context.external, "java", "lang", "String.java")).entry.role, "external")
    test.equal(context.project_paths.is_excluded(join_path(context.root, "generated", "Output.java"), "files"), true)
  end)
end)
