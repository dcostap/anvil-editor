local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

local function write_file(path, text)
  local fp = assert(io.open(path, "wb"))
  fp:write(text or "test\n")
  fp:close()
end

local function picker_has_path(picker, path)
  for _, result in ipairs(picker.results or {}) do
    if result.abs_path and common.path_equals(result.abs_path, path) then return true end
  end
  return false
end

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + (timeout or 5)
  while not predicate() and system.get_time() < deadline do coroutine.yield(0.02) end
  return predicate()
end

test.describe("Fuzzy Searcher filesystem updates", function()
  test.before_each(function(context)
    context.original_projects = core.projects
    context.original_visited_files = core.visited_files
    context.original_cwd = system.getcwd()
    context.root = USERDIR
      .. PATHSEP .. "fuzzy-filesystem-watch-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.root))
    core.projects = { Project(context.root) }
    core.visited_files = {}
    system.chdir(context.root)
    project_paths.configure_project {}
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    project_paths.configure_project {}
    project_paths.load_workspace_state(nil)
    core.projects = context.original_projects
    core.visited_files = context.original_visited_files
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    -- Let the persistent file-index service release its native watch on the
    -- temporary Project before removing that Project from disk on Windows.
    coroutine.yield(0.25)
    if context.root and system.get_file_info(context.root) then
      local ok, err = common.rm(context.root, true)
      test.ok(ok, err)
    end
  end)

  test.it("reflects externally created, renamed, and deleted files without opening them", function(context)
    local existing = context.root .. PATHSEP .. "existing-file.md"
    local created = context.root .. PATHSEP .. "created-externally.md"
    write_file(existing)

    fuzzy_searcher.open("existing-file")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker_has_path(picker, existing) end),
      "expected the initial project file index to become ready")

    picker.input:set_text("created-externally")
    write_file(created)

    test.ok(wait_until(function() return picker_has_path(picker, created) end),
      "expected an externally created file to enter fuzzy file results")

    local nested_dir = context.root .. PATHSEP .. "new-directory" .. PATHSEP .. "nested"
    local nested = nested_dir .. PATHSEP .. "nested-external-file.md"
    test.ok(common.mkdirp(nested_dir))
    write_file(nested)
    picker.input:set_text("nested-external-file")
    test.ok(wait_until(function() return picker_has_path(picker, nested) end),
      "expected a file in an externally created directory to enter fuzzy file results")

    local renamed = context.root .. PATHSEP .. "renamed-externally.md"
    test.ok(os.rename(created, renamed))
    picker.input:set_text("renamed-externally")
    test.ok(wait_until(function() return picker_has_path(picker, renamed) end),
      "expected an externally renamed file to enter fuzzy file results")

    picker.input:set_text("created-externally")
    test.ok(wait_until(function() return not picker_has_path(picker, created) end),
      "expected the old external filename to leave fuzzy file results")

    test.ok(os.remove(renamed))
    picker.input:set_text("renamed-externally")
    test.ok(wait_until(function() return not picker_has_path(picker, renamed) end),
      "expected an externally deleted file to leave fuzzy file results")
  end)
end)
