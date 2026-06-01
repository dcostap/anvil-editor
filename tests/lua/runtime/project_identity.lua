local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local test = require "core.test"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

test.describe("Project path identity", function()
  test.before_each(function(context)
    context.original_projects = core.projects
    context.original_recent_projects = core.recent_projects
    context.original_docs = core.docs
    context.original_visited_files = core.visited_files
    context.temp_root = USERDIR
      .. PATHSEP .. "project-identity-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    local ok, err = common.mkdirp(join_path(context.temp_root, "GLP4"))
    test.ok(ok, err)
  end)

  test.after_each(function(context)
    core.projects = context.original_projects
    core.recent_projects = context.original_recent_projects
    core.docs = context.original_docs
    core.visited_files = context.original_visited_files
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.test("preserves Windows UNC share roots as Project paths", function()
    if PLATFORM ~= "Windows" then return end

    test.equal(Project("\\\\server\\share").path, "\\\\server\\share")
    test.equal(Project("\\\\server\\share\\").path, "\\\\server\\share")
  end)

  test.test("deduplicates loaded Projects by Windows path identity", function(context)
    if PLATFORM ~= "Windows" then return end

    local project_path = join_path(context.temp_root, "GLP4")
    core.projects = {}

    local first = core.add_project(project_path)
    local second = core.add_project(project_path:lower())

    test.equal(#core.projects, 1)
    test.equal(second, first)
  end)

  test.test("deduplicates open docs by Windows path identity", function(context)
    if PLATFORM ~= "Windows" then return end

    local project_path = join_path(context.temp_root, "GLP4")
    local file_path = join_path(project_path, "Example.lua")
    local fp = assert(io.open(file_path, "wb"))
    fp:write("return 1\n")
    fp:close()
    core.projects = {}
    core.docs = {}
    core.add_project(project_path)

    local first = core.open_doc(file_path)
    local second = core.open_doc(file_path:lower())

    test.equal(#core.docs, 1)
    test.equal(second, first)
  end)

  test.test("deduplicates visited files by Windows path identity", function(context)
    if PLATFORM ~= "Windows" then return end

    local file_path = join_path(context.temp_root, "GLP4", "Example.lua")
    core.visited_files = {}

    core.set_visited(file_path)
    core.set_visited(file_path:lower())

    test.equal(#core.visited_files, 1)
  end)
end)
