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

test.describe("Fuzzy Searcher file refresh", function()
  test.before_each(function(context)
    context.original_projects = core.projects
    context.original_visited_files = core.visited_files
    context.original_cwd = system.getcwd()
    context.root = USERDIR
      .. PATHSEP .. "fuzzy-file-refresh-"
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
    if context.root and system.get_file_info(context.root) then
      local ok, err = common.rm(context.root, true)
      test.ok(ok, err)
    end
  end)

  test.it("refreshes external filesystem changes when the picker is reopened", function(context)
    local existing = context.root .. PATHSEP .. "existing-file.md"
    local created = context.root .. PATHSEP .. "created-externally.md"
    write_file(existing)

    fuzzy_searcher.open("existing-file")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker_has_path(picker, existing) end),
      "expected the initial project file index to become ready")

    picker.input:set_text("created-externally")
    write_file(created)

    coroutine.yield(0.5)
    test.ok(not picker_has_path(picker, created),
      "expected the open picker to keep its completed file snapshot")
    test.not_nil(system.get_file_info(created), "expected the external file fixture to remain on disk")

    picker:close()
    fuzzy_searcher.open("created-externally")
    picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker_has_path(picker, created) end),
      "expected reopening the picker to discover an externally created file")

    local nested_dir = context.root .. PATHSEP .. "new-directory" .. PATHSEP .. "nested"
    local nested = nested_dir .. PATHSEP .. "nested-external-file.md"
    test.ok(common.mkdirp(nested_dir))
    write_file(nested)
    picker:close()
    fuzzy_searcher.open("nested-external-file")
    picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker_has_path(picker, nested) end),
      "expected reopening the picker to discover a newly created directory")

    local renamed = context.root .. PATHSEP .. "renamed-externally.md"
    test.ok(os.rename(created, renamed))
    picker:close()
    fuzzy_searcher.open("renamed-externally")
    picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker_has_path(picker, renamed) end),
      "expected reopening the picker to discover an externally renamed file")

    picker.input:set_text("created-externally")
    test.ok(wait_until(function() return not picker_has_path(picker, created) end),
      "expected the old external filename to leave fuzzy file results")

    test.ok(os.remove(renamed))
    local deletion_scan_marker = context.root .. PATHSEP .. "deletion-scan-complete.md"
    write_file(deletion_scan_marker)
    picker:close()
    fuzzy_searcher.open("deletion-scan-complete")
    picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker_has_path(picker, deletion_scan_marker) end),
      "expected the deletion refresh to finish scanning")
    picker.input:set_text("renamed-externally")
    test.ok(wait_until(function() return not picker_has_path(picker, renamed) end),
      "expected reopening the picker to remove an externally deleted file")
  end)
end)
