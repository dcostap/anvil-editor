local core = require "core"
local common = require "core.common"
local command = require "core.command"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local process = require "core.process"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"
local helpers = fuzzy_searcher._test

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
    context.everything_state = helpers.everything_state()
    helpers.set_everything_state("unavailable")
    context.root = USERDIR
      .. PATHSEP .. "fuzzy-file-refresh-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.root))
    core.projects = { Project(context.root) }
    core.visited_files = {}
    system.chdir(context.root)
    project_paths.configure_workspace {}
  end)

  test.after_each(function(context)
    helpers.cancel_file_index_for_test()
    if context.original_process_start then process.start = context.original_process_start end
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    project_paths.configure_workspace {}
    project_paths.load_workspace_state(nil)
    core.projects = context.original_projects
    core.visited_files = context.original_visited_files
    helpers.set_everything_state(context.everything_state)
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    if context.root and system.get_file_info(context.root) then
      local ok, err = common.rm(context.root, true)
      test.ok(ok, err)
    end
    if context.secondary_root and system.get_file_info(context.secondary_root) then
      local ok, err = common.rm(context.secondary_root, true)
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
    test.equal(helpers.file_index_status().native, true,
      "expected filesystem candidates to remain owned by the native file index")

    picker.input:set_text("existing-file:1")
    test.ok(wait_until(function() return picker_has_path(picker, existing) end),
      "expected line-qualified file searches to query the native snapshot")
    test.equal(helpers.file_index_status().materialized, false,
      "expected line-qualified search not to materialize the entire file list in Lua")

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

  test.it("keeps the completed file snapshot searchable while a refresh is still running", function(context)
    local existing = context.root .. PATHSEP .. "existing-snapshot-file.md"
    write_file(existing)
    helpers.set_file_cache_for_test({ helpers.file_display_item(existing) })

    local fake_running = true
    local fake_started = false
    local fake_process = {
      stdout = {
        read = function()
          coroutine.yield(0.01)
          error("timeout expired")
        end,
      },
      running = function() return fake_running end,
      kill = function() fake_running = false end,
      wait = function() return fake_running and nil or 0 end,
    }
    context.original_process_start = process.start
    process.start = function()
      fake_started = true
      return fake_process
    end

    helpers.refresh_file_index_for_test()
    fuzzy_searcher.open("existing-snapshot-file")
    local picker = assert(core.fuzzy_searcher_active_view)

    test.ok(wait_until(function() return fake_started end),
      "expected the replacement filesystem scan to start")
    test.equal(helpers.file_index_status().indexing, true)
    test.ok(picker_has_path(picker, existing),
      "expected the previous completed snapshot to remain searchable during refresh")

    picker.input:set_text("missing-during-refresh")
    coroutine.yield(0.3)
    test.ok(picker.status:find("Searching", 1, true),
      "expected search feedback while the file index refresh is still running: " .. picker.status)
    test.not_ok(picker.status:find("0 matches", 1, true),
      "expected search feedback not to announce zero matches before refresh completes")
  end)

  test.it("applies ripgrep ignore files and hidden-path defaults before native ingestion", function(context)
    local marker = context.root .. PATHSEP .. "native-ignore-scan-ready.md"
    local ignored_executable = context.root .. PATHSEP .. "native-ignore-executable.exe"
    local ignored_module_dir = context.root .. PATHSEP .. "node_modules"
    local ignored_module = ignored_module_dir .. PATHSEP .. "native-ignore-module.md"
    local ignored_trash_dir = context.root .. PATHSEP .. ".Trash-old"
    local ignored_trash = ignored_trash_dir .. PATHSEP .. "native-ignore-trash.md"
    test.ok(common.mkdirp(ignored_module_dir))
    test.ok(common.mkdirp(ignored_trash_dir))
    write_file(marker)
    write_file(ignored_executable)
    write_file(ignored_module)
    write_file(ignored_trash)
    local ignore = assert(io.open(context.root .. PATHSEP .. ".ignore", "wb"))
    ignore:write("node_modules/\n*.exe\n")
    ignore:close()

    fuzzy_searcher.open("native-ignore-scan-ready")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker_has_path(picker, marker) end),
      "expected the native scanner to finish before checking ignored paths")

    for query, path in pairs({
      ["native-ignore-executable"] = ignored_executable,
      ["native-ignore-module"] = ignored_module,
      ["native-ignore-trash"] = ignored_trash,
    }) do
      picker.input:set_text(query)
      coroutine.yield(0.1)
      test.ok(not picker_has_path(picker, path), "expected ignored path to stay out of the native index: " .. path)
    end
  end)

  test.it("toggles ignored files for the current file search", function(context)
    local ignored_dir = context.root .. PATHSEP .. "ignored-search"
    local ignored_file = ignored_dir .. PATHSEP .. "toggle-ignored-result.md"
    test.ok(common.mkdirp(ignored_dir))
    write_file(ignored_file)
    local ignore = assert(io.open(context.root .. PATHSEP .. ".ignore", "wb"))
    ignore:write("ignored-search/\n")
    ignore:close()

    fuzzy_searcher.open("toggle-ignored-result")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return not helpers.file_index_status().indexing end))
    test.not_ok(picker_has_path(picker, ignored_file))

    test.ok(command.perform("fuzzy:toggle_ignored_files"))
    test.ok(wait_until(function() return picker_has_path(picker, ignored_file) end),
      "expected the ignored file after enabling the search toggle")
    test.equal(picker.include_ignored, true)
  end)

  test.it("toggles ignored files for the current text search", function(context)
    local ignored_dir = context.root .. PATHSEP .. "ignored-text-search"
    local ignored_file = ignored_dir .. PATHSEP .. "result.md"
    test.ok(common.mkdirp(ignored_dir))
    write_file(ignored_file, "UNIQUE_IGNORED_TEXT_RESULT\n")
    local ignore = assert(io.open(context.root .. PATHSEP .. ".ignore", "wb"))
    ignore:write("ignored-text-search/\n")
    ignore:close()

    fuzzy_searcher.open("#UNIQUE_IGNORED_TEXT_RESULT")
    local picker = assert(core.fuzzy_searcher_active_view)
    coroutine.yield(0.3)
    test.not_ok(picker_has_path(picker, ignored_file))

    test.ok(command.perform("fuzzy:toggle_ignored_files"))
    test.ok(wait_until(function() return picker_has_path(picker, ignored_file) end, 10),
      "expected ignored text after enabling the search toggle; status="
        .. tostring(picker.status) .. " include=" .. tostring(picker.include_ignored)
        .. " results=" .. tostring(#(picker.results or {})))
  end)

  test.it("prewarms Project files and avoids a redundant scan on the first picker open", function(context)
    local existing = context.root .. PATHSEP .. "prewarmed-project-file.md"
    write_file(existing)

    test.ok(helpers.prewarm_file_index_for_test())
    test.ok(wait_until(function()
      local status = helpers.file_index_status()
      return status.native and not status.indexing
    end), "expected Project file prewarming to complete")

    local scanner_starts = 0
    context.original_process_start = process.start
    process.start = function(...)
      scanner_starts = scanner_starts + 1
      return context.original_process_start(...)
    end
    fuzzy_searcher.open("prewarmed-project-file")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker_has_path(picker, existing) end))
    test.equal(scanner_starts, 0,
      "expected the first picker open to consume the prewarmed snapshot without rescanning")
  end)

  test.it("invalidates a prewarmed snapshot before opening files from a different Project", function(context)
    local old_file = context.root .. PATHSEP .. "old-project-file.md"
    write_file(old_file)
    test.ok(helpers.prewarm_file_index_for_test())
    test.ok(wait_until(function() return helpers.file_index_status().native end))

    context.secondary_root = context.root .. "-secondary"
    test.ok(common.mkdirp(context.secondary_root))
    local new_file = context.secondary_root .. PATHSEP .. "new-project-file.md"
    write_file(new_file)
    core.projects = { Project(context.secondary_root) }
    system.chdir(context.secondary_root)
    project_paths.configure_workspace {}

    fuzzy_searcher.open("new-project-file")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker_has_path(picker, new_file) end),
      "expected picker open to replace the stale prewarmed Project snapshot")
    test.ok(not picker_has_path(picker, old_file))
  end)
end)
