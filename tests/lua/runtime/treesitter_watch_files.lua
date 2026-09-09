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

local function count(name)
  local symbols, reason, status = symbol_index.workspace_symbols(name, {
    root = root, limit = 20, refresh_after_seconds = 0,
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

  test.after_each(function()
    symbol_index.reset_for_tests()
    DirWatch.check = check
    if root then common.rm(root, true) end
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
