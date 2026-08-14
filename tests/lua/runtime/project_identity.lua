local core = require "core"
local common = require "core.common"
local config = require "core.config"
local Project = require "core.project"
local test = require "core.test"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

test.describe("Project path identity", function()
  test.before_each(function(context)
    context.original_projects = core.projects
    context.original_recent_projects = core.recent_projects
    context.original_buffers = core.buffers
    context.original_visited_files = core.visited_files
    context.original_max_visited_files = config.max_visited_files
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
    core.buffers = context.original_buffers
    core.visited_files = context.original_visited_files
    config.max_visited_files = context.original_max_visited_files
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

  test.test("deduplicates open buffers by Windows path identity", function(context)
    if PLATFORM ~= "Windows" then return end

    local project_path = join_path(context.temp_root, "GLP4")
    local file_path = join_path(project_path, "Example.lua")
    local fp = assert(io.open(file_path, "wb"))
    fp:write("return 1\n")
    fp:close()
    core.projects = {}
    core.buffers = {}
    core.add_project(project_path)

    local first = core.open_buffer(file_path)
    local second = core.open_buffer(file_path:lower())

    test.equal(#core.buffers, 1)
    test.equal(second, first)
  end)

  test.test("deduplicates visited files by Windows path identity", function(context)
    if PLATFORM ~= "Windows" then return end

    local file_path = join_path(context.temp_root, "GLP4", "Example.lua")
    core.visited_files = {}

    core.set_visited(file_path)
    core.set_visited(file_path:lower())

    test.equal(#core.visited_files, 1)
    test.ok(common.path_equals(core.visited_files[1].path, file_path))
  end)

  test.test("keeps visited files in most-recent-first order when trimming", function(context)
    config.max_visited_files = 5
    core.visited_files = {}

    for i = 1, 10 do
      core.set_visited(join_path(context.temp_root, "recent-" .. i .. ".txt"))
    end

    test.equal(#core.visited_files, 5)
    for i, expected in ipairs({ 10, 9, 8, 7, 6 }) do
      test.ok(core.visited_files[i].path:find("recent%-" .. expected .. "%.txt$"), "unexpected recent at " .. i .. ": " .. tostring(core.visited_files[i].path))
    end
  end)

  test.test("moving an existing visited file removes stale duplicates", function(context)
    config.max_visited_files = 5
    local first = join_path(context.temp_root, "first.txt")
    local second = join_path(context.temp_root, "second.txt")
    core.visited_files = { first, second, first }

    core.set_visited(first)

    test.equal(#core.visited_files, 2)
    test.ok(common.path_equals(core.visited_files[1].path, first), "expected first path to move to front")
    test.ok(common.path_equals(core.visited_files[2].path, second), "expected second path to remain once")
  end)

  test.test("stores view and edit times without reordering a Recent File on edit", function(context)
    local first = join_path(context.temp_root, "first.txt")
    local second = join_path(context.temp_root, "second.txt")
    core.visited_files = {}

    core.set_visited(first, 100)
    core.set_visited(second, 200)
    core.set_recent_file_edited(first, 300)

    test.ok(common.path_equals(core.visited_files[1].path, second))
    test.ok(common.path_equals(core.visited_files[2].path, first))
    test.equal(core.visited_files[2].last_viewed, 100)
    test.equal(core.visited_files[2].last_edited, 300)
  end)

  test.test("updates Recent File edit metadata when its Buffer changes", function(context)
    local path = join_path(context.temp_root, "edited.txt")
    local fp = assert(io.open(path, "wb"))
    fp:write("before\n")
    fp:close()
    core.visited_files = {}

    local buffer = core.open_buffer(path)
    core.set_visited(path, 100)
    buffer:insert(1, 1, "after ")

    test.ok((core.visited_files[1].last_edited or 0) > 100)
    buffer:clean()
    for i = #core.buffers, 1, -1 do
      if core.buffers[i] == buffer then table.remove(core.buffers, i) end
    end
    buffer:on_close()
  end)
end)
