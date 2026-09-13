local common = require "core.common"
local test = require "core.test"
local system = require "system"
local symbol_index = require "core.treesitter.symbol_index"
local DirWatch = require "core.dirwatch"

local root
local check
local function write(name, text)
  local file = assert(io.open(root .. PATHSEP .. name, "wb"))
  file:write(text)
  file:close()
end

local function ready(predicate)
  local deadline = system.get_time() + 10
  repeat
    local status = symbol_index.status(root)
    if status.status == "ready" and (not predicate or predicate()) then return status end
    test.ok(status.status ~= "failed", status.reason)
    coroutine.yield(0.03)
  until system.get_time() >= deadline
  test.fail("Project index did not become ready")
end

local function count(name, limit)
  local symbols, reason, status = symbol_index.workspace_symbols(name, {
    root = root, limit = limit or 20, refresh_after_seconds = 0,
  })
  test.equal(status, "fresh", reason)
  return #symbols
end

test.describe("Project file watcher scope", function()
  test.before_each(function()
    symbol_index.reset_for_tests()
    -- Supply watcher events explicitly instead of using OS event timing.
    check = DirWatch.check
    DirWatch.check = function() return false end
    root = USERDIR .. PATHSEP .. "watch-files-" .. system.get_process_id()
      .. "-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(root))
  end)

  test.after_each(function(context)
    if context.cleanup then context.cleanup() end
    symbol_index.reset_for_tests()
    DirWatch.check = check
    if root then common.rm(root, true) end
  end)

  test.it("updates a file batch without UI filesystem checks", function(context)
    local paths = {}
    for i = 1, 320 do
      write("File" .. i .. ".kt", "class BeforeBatch" .. i .. "\n")
      paths[i] = root .. PATHSEP .. "File" .. i .. ".kt"
    end
    write("Unreported.kt", "class Untouched\n")
    symbol_index.start_project_indexing({ root = root, reason = "test", refresh_after_seconds = 0 })
    ready()
    for i = 1, 320 do write("File" .. i .. ".kt", "class AfterBatch" .. i .. "\n") end
    write("Unreported.kt", "class MustNotAppear\n")
    local get_info = system.get_file_info
    context.cleanup = function() system.get_file_info = get_info end
    system.get_file_info = function(path, ...)
      assert(not common.path_equals(path, root) and not common.path_belongs_to(path, root),
        "Project subscriber performed filesystem I/O on the UI thread: " .. path)
      return get_info(path, ...)
    end
    local max_resume_ms, result = 0, nil
    local caller = coroutine.create(function()
      result = symbol_index.mark_watch_paths_dirty(root, paths, "test-worker-batch")
    end)
    repeat
      local started = system.get_time()
      local ok, err = coroutine.resume(caller)
      max_resume_ms = math.max(max_resume_ms, (system.get_time() - started) * 1000)
      test.ok(ok, err)
      coroutine.yield(0)
    until coroutine.status(caller) == "dead"
    test.ok(result)
    ready(function() return count("AfterBatch", 400) == 320 end)
    test.equal(count("BeforeBatch", 400), 0)
    test.equal(count("Untouched"), 1)
    test.equal(count("MustNotAppear"), 0)
    core.log_quiet("Watcher stress: 320 changed files; longest caller resume %.3f ms", max_resume_ms)
  end)

  test.it("saves a Buffer from the main loop while scheduling its index update", function()
    require "core.treesitter"
    local Buffer = require "core.buffer"
    local pool = require("core.worker_pool").system()
    write("Saved.kt", "class BeforeSave\n")
    symbol_index.start_project_indexing({ root = root, reason = "test", refresh_after_seconds = 0 })
    ready()
    local path = root .. PATHSEP .. "Saved.kt"
    local buffer = Buffer(path, path, true)
    buffer:insert(1, 1, "class AfterSave\n")
    local done, saved, save_error, yieldable
    assert(pool:submit {
      kind = "worker_pool_test", payload = { op = "echo" },
      on_complete = function()
        yieldable = coroutine.isyieldable()
        saved, save_error = pcall(buffer.save, buffer)
        done = true
      end,
    })
    local deadline = system.get_time() + 5
    while not done and system.get_time() < deadline do coroutine.yield(0) end
    test.ok(done)
    test.not_ok(yieldable, "The save must run from the main-loop callback")
    test.ok(saved, save_error)
    symbol_index.clear_open_buffer(buffer, "test-save")
    ready(function() return count("AfterSave") == 1 end)
    test.equal(count("BeforeSave"), 0)
  end)

  test.it("a file event updates that file without consuming unreported sibling changes", function()
    write("Changed.kt", "class BeforeChange\n")
    write("Sibling.kt", "class BeforeSibling\n")
    symbol_index.start_project_indexing({ root = root, reason = "test", refresh_after_seconds = 0 })
    ready()
    test.equal(count("BeforeSibling"), 1)

    write("Changed.kt", "class AfterChange\n")
    write("Sibling.kt", "class AfterSibling\n")
    write("Added.kt", "class AddedFile\n")
    test.ok(symbol_index.mark_watch_paths_dirty(root, {
      [root .. PATHSEP .. "Changed.kt"] = true,
      [root .. PATHSEP .. "Added.kt"] = true,
    }, "test-file-event"))
    ready(function() return count("AfterChange") == 1 and count("AddedFile") == 1 end)
    test.equal(count("AfterChange"), 1)
    test.equal(count("BeforeChange"), 0)
    test.equal(count("AddedFile"), 1)
    test.equal(count("BeforeSibling"), 1)
    test.equal(count("AfterSibling"), 0)

    test.ok(symbol_index.mark_watch_paths_dirty(root, {
      [root .. PATHSEP .. "Sibling.kt"] = true,
    }, "test-sibling-event"))
    ready()
    test.equal(count("AfterSibling"), 1)
    test.equal(count("BeforeSibling"), 0)
    test.equal(count("AfterChange"), 1)
  end)

  test.it("a mixed batch refreshes a directory and a separate file", function()
    test.ok(common.mkdirp(root .. PATHSEP .. "nested"))
    write("nested/Inside.kt", "class BeforeInside\n")
    write("Outside.kt", "class BeforeOutside\n")
    write("Sibling.kt", "class BeforeSibling\n")
    symbol_index.start_project_indexing({ root = root, reason = "test", refresh_after_seconds = 0 })
    ready()

    write("nested/Inside.kt", "class AfterInside\n")
    write("Outside.kt", "class AfterOutside\n")
    write("Sibling.kt", "class AfterSibling\n")
    test.ok(symbol_index.mark_watch_paths_dirty(root, {
      [root .. PATHSEP .. "nested"] = true,
      [root .. PATHSEP .. "nested" .. PATHSEP .. "Inside.kt"] = true,
      [root .. PATHSEP .. "Outside.kt"] = true,
    }, "test-mixed-event"))
    ready(function() return count("AfterInside") == 1 and count("AfterOutside") == 1 end)
    test.equal(count("AfterInside"), 1)
    test.equal(count("BeforeInside"), 0)
    test.equal(count("AfterOutside"), 1)
    test.equal(count("BeforeOutside"), 0)
    test.equal(count("BeforeSibling"), 1)
    test.equal(count("AfterSibling"), 0)
  end)
end)
