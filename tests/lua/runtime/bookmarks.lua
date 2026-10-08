local core = require "core"
local common = require "core.common"
local Buffer = require "core.buffer"
local Project = require "core.project"
local storage = require "core.storage"
local test = require "core.test"

local bookmarks
local sequence = 0

local function write_file(path, text)
  local file = test.not_nil(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function wait_for_refresh()
  local deadline = system.get_time() + 10
  while bookmarks.is_refreshing() do
    require("core.worker_pool").system():drain { budget_ms = 10, max_messages = 100 }
    test.ok(system.get_time() < deadline, "Bookmark recovery timed out")
    coroutine.yield(0.01)
  end
end

local function refresh()
  bookmarks.refresh()
  wait_for_refresh()
end

test.describe("Bookmarks", function()
  test.before_each(function(context)
    context.projects = core.projects
    sequence = sequence + 1
    context.root = USERDIR .. PATHSEP .. "bookmark-project-" .. sequence
    test.ok(common.mkdirp(context.root))
    core.projects = { Project(context.root) }
    bookmarks = require "core.bookmarks"
    bookmarks.close_project(context.root)
    storage.clear("bookmarks", common.path_compare_key(context.root))
    context.path = context.root .. PATHSEP .. "source.txt"
    write_file(context.path, "first\ntarget\nlast\n")
    context.buffer = Buffer(context.path, context.path)
  end)

  test.after_each(function(context)
    if context.io_open then io.open = context.io_open end
    if context.buffer then context.buffer:on_close() end
    if bookmarks then bookmarks.close_project(context.root) end
    storage.clear("bookmarks", common.path_compare_key(context.root))
    core.projects = context.projects
    common.rm(context.root, true)
  end)

  test.it("retains a named bookmark and follows lines inserted above it", function(context)
    local mark = test.not_nil(bookmarks.add(context.buffer, 2, "Parser entry"))
    context.buffer:insert(1, 1, "new\n")
    local rows = bookmarks.list()
    test.equal(#rows, 1)
    test.equal(rows[1].id, mark.id)
    test.equal(rows[1].name, "Parser entry")
    test.equal(rows[1].line, 3)
    test.equal(rows[1].text, "target")
    test.equal(rows[1].status, "ready")
  end)

  for _, fixture in ipairs {
    { name = "punctuation-only neighbors", text = "{\nwork();\n}\n", line = 2 },
    { name = "repeated blocks", text = "first\ntarget\nlast\nfirst\ntarget\nlast\n", line = 2 },
  } do
    test.it("retains an unchanged saved location with " .. fixture.name, function(context)
      write_file(context.path, fixture.text)
      context.buffer:replace_snapshot(fixture.text)
      bookmarks.add(context.buffer, fixture.line, "Retained target")
      context.buffer:on_close()
      context.buffer = nil
      test.ok(bookmarks.close_project(context.root))
      refresh()
      local mark = bookmarks.list()[1]
      test.equal(mark.status, "ready")
      test.equal(mark.line, fixture.line)
      test.equal(mark.name, "Retained target")
    end)
  end

  for _, reopen in ipairs { false, true } do
    test.it("rejects a remaining block with only a common neighbor" .. (reopen and " in a reopened Buffer" or " on disk"), function(context)
      local original = "original owner\ntarget\nreturn nil\nother owner\ntarget\nreturn nil\n"
      write_file(context.path, original)
      context.buffer:replace_snapshot(original)
      bookmarks.add(context.buffer, 2, "Original target")
      context.buffer:on_close()
      context.buffer = nil
      test.ok(bookmarks.close_project(context.root))
      write_file(context.path, "other owner\ntarget\nreturn nil\n")
      if reopen then
        context.buffer = Buffer(context.path, context.path)
        bookmarks.attach(context.buffer)
        wait_for_refresh()
      else
        refresh()
      end
      local mark = bookmarks.list()[1]
      test.equal(mark.status, "location_missing")
      test.equal(bookmarks.navigation_target(mark), nil)
      test.equal(mark.name, "Original target")
    end)
  end

  test.it("uses wider context to distinguish displaced lines inside repeated braces", function(context)
    local original = "owner A\n{\ntarget\n}\nend A\nowner B\n{\ntarget\n}\nend B\n"
    write_file(context.path, original)
    context.buffer:replace_snapshot(original)
    bookmarks.add(context.buffer, 3, "Owner A target")
    context.buffer:on_close()
    context.buffer = nil
    test.ok(bookmarks.close_project(context.root))
    write_file(context.path, "prefix\n" .. original)
    refresh()
    local mark = bookmarks.list()[1]
    test.equal(mark.status, "ready")
    test.equal(mark.line, 4)
  end)

  test.it("does not recover another block when the saved block was removed externally", function(context)
    local original = "owner A\ncommon before\ntarget\ncommon after\nend A\nowner B\ncommon before\ntarget\ncommon after\nend B\n"
    write_file(context.path, original)
    context.buffer:replace_snapshot(original)
    local mark = bookmarks.add(context.buffer, 3, "Owner A")
    context.buffer:on_close()
    context.buffer = nil
    write_file(context.path, "owner B\ncommon before\ntarget\ncommon after\nend B\n")
    refresh()
    test.equal(mark.status, "location_missing")
    test.equal(bookmarks.navigation_target(mark), nil)
    test.equal(mark.name, "Owner A")
  end)

  test.it("maps a saved location through an insertion between its neighboring lines", function(context)
    bookmarks.add(context.buffer, 2, "Target")
    context.buffer:on_close()
    context.buffer = nil
    test.ok(bookmarks.close_project(context.root))
    write_file(context.path, "first\ninserted\ntarget\nlast\n")
    refresh()
    local mark = bookmarks.list()[1]
    test.equal(mark.status, "ready")
    test.equal(mark.line, 3)
    test.equal(mark.text, "target")
  end)

  test.it("uses retained file text to distinguish repeated blocks beyond nearby context", function(context)
    local body = "{\nshared before\n{\nshared before\ntarget\nshared after\n}\nshared after\n}\n"
    local original = "owner A\n" .. body .. "end A\nowner B\n" .. body .. "end B\n"
    write_file(context.path, original)
    context.buffer:replace_snapshot(original)
    bookmarks.add(context.buffer, 6, "Owner A")
    context.buffer:on_close()
    context.buffer = nil
    test.ok(bookmarks.close_project(context.root))
    write_file(context.path, "prefix\n" .. original)
    refresh()
    local mark = bookmarks.list()[1]
    test.equal(mark.status, "ready")
    test.equal(mark.line, 7)
  end)

  test.it("keeps repeated locations uncertain when one copy disappears between retained anchors", function(context)
    local original = "header\nfirst\ntarget\nlast\nfirst\ntarget\nlast\nfooter\n"
    write_file(context.path, original)
    context.buffer:replace_snapshot(original)
    bookmarks.add(context.buffer, 3, "First copy")
    bookmarks.add(context.buffer, 6, "Second copy")
    context.buffer:on_close()
    context.buffer = nil
    write_file(context.path, "header\nfirst\ntarget\nlast\nfooter\n")
    refresh()
    for _, mark in ipairs(bookmarks.list()) do test.equal(mark.status, "location_missing") end
  end)

  test.it("retains each missing location's text version when another location recovers", function(context)
    local original = "owner A\nfirst\ntarget\nlast\nend A\nowner B\nsecond target\nend B\n"
    write_file(context.path, original)
    context.buffer:replace_snapshot(original)
    bookmarks.add(context.buffer, 3, "A")
    bookmarks.add(context.buffer, 7, "B")
    context.buffer:on_close()
    context.buffer = nil
    write_file(context.path, "owner B\nsecond target\nend B\n")
    refresh()
    test.equal(bookmarks.list()[1].status, "location_missing")
    test.equal(bookmarks.list()[2].status, "ready")
    test.equal(bookmarks.list()[2].line, 2)
    test.ok(bookmarks.close_project(context.root))
    write_file(context.path, "prefix\n" .. original)
    refresh()
    local marks = bookmarks.list()
    test.equal(marks[1].status, "ready")
    test.equal(marks[1].line, 4)
    test.equal(marks[2].status, "ready")
    test.equal(marks[2].line, 8)
  end)

  test.it("blocks creation until existing file locations finish recovery", function(context)
    bookmarks.add(context.buffer, 2, "Original")
    test.ok(bookmarks.close_project(context.root))
    bookmarks.attach(context.buffer)
    local duplicate, reason = bookmarks.add(context.buffer, 2, "Duplicate")
    test.equal(duplicate, nil)
    test.ok(type(reason) == "string")
    wait_for_refresh()
    test.equal(#bookmarks.list(), 1)
    test.equal(bookmarks.add(context.buffer, 2, "Duplicate"), bookmarks.list()[1])
  end)

  test.it("blocks attachment until other target file locations finish recovery", function(context)
    local first = bookmarks.add(context.buffer, 1, "First")
    bookmarks.add(context.buffer, 2, "Second")
    test.ok(bookmarks.close_project(context.root))
    bookmarks.attach(context.buffer)
    first = bookmarks.list()[1]
    local attached, reason = bookmarks.retarget(first, context.buffer, 2)
    test.equal(attached, nil)
    test.ok(type(reason) == "string")
    wait_for_refresh()
    test.equal(first.line, 1)
    test.equal(bookmarks.retarget(first, context.buffer, 2), nil)
  end)

  test.it("requires opened text before returning a closed-file navigation target", function(context)
    local mark = bookmarks.add(context.buffer, 2, "Target")
    context.buffer:on_close()
    context.buffer = nil
    refresh()
    local info = test.not_nil(system.get_file_info(context.path))
    write_file(context.path, "first\nchange\nlast\n")
    local get_file_info = system.get_file_info
    system.get_file_info = function(path)
      if common.path_equals(path, context.path) then return info end
      return get_file_info(path)
    end
    local ok, target = pcall(bookmarks.navigation_target, mark)
    system.get_file_info = get_file_info
    test.ok(ok)
    test.equal(target, nil)
  end)

  test.it("retains valid stored Bookmarks and ignores malformed records and counters", function(context)
    bookmarks.list()
    test.ok(bookmarks.close_project(context.root))
    test.ok(storage.save("bookmarks", common.path_compare_key(context.root), {
      version = 1, next_id = "invalid",
      marks = {
        { id = "invalid", path = context.path, line = 2, text = "target", name = "Broken" },
        { id = 7, path = context.path, line = 2, text = "target", name = "Retained", before = "first", after = "last", status = "ready" },
      },
    }))
    refresh()
    local rows = bookmarks.list()
    test.equal(#rows, 1)
    test.equal(rows[1].name, "Retained")
    test.equal(rows[1].status, "ready")
    bookmarks.attach(context.buffer)
    wait_for_refresh()
    local added = test.not_nil(bookmarks.add(context.buffer, 1, "New target"))
    test.ok(added.id > rows[1].id)
  end)

  test.it("checks closed-file content even when file metadata remains unchanged", function(context)
    -- The worker's file result is the seam. Fix metadata at the file system boundary.
    local info = test.not_nil(system.get_file_info(context.path))
    write_file(context.path, "first\nchange\nlast\n")
    local get_file_info, messages = system.get_file_info, {}
    system.get_file_info = function(path)
      if common.path_equals(path, context.path) then return info end
      return get_file_info(path)
    end
    local ok, err = pcall(require("core.workers.bookmarks").run, {
      files = { {
        path = context.path,
        records = { { id = 1, line = 2, text = "target", before = { "first" }, after = { "last" }, status = "ready" } },
      } },
    }, {
      cancelled = function() return false end,
      send = function(message) messages[#messages + 1] = message; return true end,
    })
    system.get_file_info = get_file_info
    test.ok(ok, tostring(err))
    local records = test.not_nil(messages[1].payload.records, "Closed-file content was not checked")
    test.equal(records[1].status, "location_missing")
  end)

  test.it("retries a failed save without requiring another Bookmark change", function(context)
    local key = common.path_compare_key(context.root)
    local storage_dir = USERDIR .. PATHSEP .. "storage" .. PATHSEP .. "bookmarks" .. PATHSEP
    context.io_open = io.open
    local blocked, failed = true, false
    io.open = function(path, mode)
      if blocked and mode == "wb" and path:sub(1, #storage_dir) == storage_dir then
        failed = true
        return nil, "Bookmark test: storage unavailable"
      end
      return context.io_open(path, mode)
    end
    bookmarks.add(context.buffer, 2, "Retained target")
    local deadline = system.get_time() + 10
    while not failed do
      test.ok(system.get_time() < deadline, "Save did not reach the file system")
      coroutine.yield(0.01)
    end
    test.equal(storage.load("bookmarks", key), nil)
    blocked = false
    local saved
    repeat
      saved = storage.load("bookmarks", key)
      test.ok(system.get_time() < deadline, "Failed Bookmark save was not retried")
      if not saved then coroutine.yield(0.01) end
    until saved
    test.equal(saved.marks[1].name, "Retained target")
    test.equal(saved.marks[1].line, 2)
  end)

  test.it("keeps a failed save available for an explicit flush", function(context)
    local storage_dir = USERDIR .. PATHSEP .. "storage" .. PATHSEP .. "bookmarks" .. PATHSEP
    context.io_open = io.open
    io.open = function(path, mode)
      if mode == "wb" and path:sub(1, #storage_dir) == storage_dir then
        return nil, "Bookmark test: storage unavailable"
      end
      return context.io_open(path, mode)
    end
    bookmarks.add(context.buffer, 2, "Retained target")
    bookmarks.flush()
    io.open = context.io_open
    bookmarks.flush()
    local saved = test.not_nil(storage.load("bookmarks", common.path_compare_key(context.root)))
    test.equal(saved.marks[1].name, "Retained target")
  end)

  test.it("retains unsaved Bookmarks when closing the Project cannot write storage", function(context)
    local storage_dir = USERDIR .. PATHSEP .. "storage" .. PATHSEP .. "bookmarks" .. PATHSEP
    bookmarks.add(context.buffer, 2, "Retained target")
    context.io_open = io.open
    io.open = function(path, mode)
      if mode == "wb" and path:sub(1, #storage_dir) == storage_dir then
        return nil, "Bookmark test: storage unavailable"
      end
      return context.io_open(path, mode)
    end
    bookmarks.close_project(context.root)
    io.open = context.io_open
    bookmarks.flush()
    local saved = test.not_nil(storage.load("bookmarks", common.path_compare_key(context.root)))
    test.equal(saved.marks[1].name, "Retained target")
  end)

  test.it("keeps a deleted location and restores its attachment through undo and redo", function(context)
    local mark = bookmarks.add(context.buffer, 2, "Target")
    context.buffer:apply_edits({ { line1 = 2, col1 = 1, line2 = 3, col2 = 1, text = "" } }, { merge_undo = false })
    test.equal(bookmarks.list()[1].status, "location_missing")
    context.buffer:undo()
    test.equal(bookmarks.list()[1].status, "ready")
    test.equal(mark.line, 2)
    test.equal(mark.text, "target")
    context.buffer:redo()
    test.equal(bookmarks.list()[1].status, "location_missing")
  end)

  test.it("retains missing files across restarts and recovers a displaced location when the file returns", function(context)
    bookmarks.add(context.buffer, 2, "Target")
    context.buffer:on_close()
    context.buffer = nil
    bookmarks.close_project(context.root)
    test.ok(os.remove(context.path))
    refresh()
    test.equal(#bookmarks.list(), 1)
    test.equal(bookmarks.list()[1].status, "file_missing")
    write_file(context.path, "new\nfirst\ntarget\nlast\n")
    refresh()
    test.equal(bookmarks.list()[1].status, "ready")
    test.equal(bookmarks.list()[1].line, 3)
    test.equal(bookmarks.list()[1].name, "Target")
  end)

  test.it("does not attach a deleted blank-line bookmark to the next line", function(context)
    context.buffer:replace_snapshot("first\n\nlast\n")
    local mark = bookmarks.add(context.buffer, 2, "Blank")
    context.buffer:remove(2, 1, 3, 1)
    test.equal(bookmarks.list()[1].status, "location_missing")
    context.buffer:undo()
    test.equal(mark.status, "ready")
    test.equal(mark.line, 2)
  end)

  test.it("keeps a bookmark when its complete line text is edited", function(context)
    local mark = bookmarks.add(context.buffer, 2, "Target")
    context.buffer:apply_edits({ { line1 = 2, col1 = 1, line2 = 2, col2 = 7, text = "changed" } })
    test.equal(bookmarks.list()[1].status, "ready")
    test.equal(mark.line, 2)
    test.equal(mark.text, "changed")
  end)

  test.it("updates closed-file bookmarks when their directory moves", function(context)
    local mark = bookmarks.add(context.buffer, 2, "Target")
    context.buffer:on_close()
    context.buffer = nil
    bookmarks.move_path(context.root, context.root .. "-moved", "dir")
    test.equal(mark.path, context.root .. "-moved" .. PATHSEP .. "source.txt")
    test.equal(mark.name, "Target")
  end)

  test.it("recovers a location after reload without choosing between repeated matches", function(context)
    local mark = bookmarks.add(context.buffer, 2, "Target")
    context.buffer:replace_snapshot("new\nfirst\ntarget\nlast\n")
    refresh()
    test.equal(mark.status, "ready")
    test.equal(mark.line, 3)
    context.buffer:replace_snapshot("first\ntarget\nlast\nfirst\ntarget\nlast\n")
    refresh()
    test.equal(mark.status, "location_missing")
    test.equal(mark.name, "Target")
  end)

  test.it("keeps an uncertain target missing when its context changes during reload recovery", function(context)
    local mark = bookmarks.add(context.buffer, 2, "Target")
    context.buffer:replace_snapshot("new\nfirst\ntarget\nlast\n")
    context.buffer:apply_edits({
      { line1 = 2, col1 = 1, line2 = 2, col2 = 6, text = "changed first" },
    }, { merge_undo = false })
    wait_for_refresh()
    test.equal(mark.status, "location_missing")
    test.equal(mark.text, "target")
    test.equal(bookmarks.at(context.buffer, 2), nil)
    test.equal(bookmarks.navigation_target(mark), nil)

    context.buffer:undo()
    wait_for_refresh()
    test.equal(mark.status, "ready")
    test.equal(mark.text, "target")
    test.equal(mark.line, 3)
    context.buffer:redo()
    wait_for_refresh()
    test.equal(mark.status, "location_missing")
    test.equal(mark.text, "target")
  end)

  test.it("does not mark the target deleted when its old line is removed during reload recovery", function(context)
    local mark = bookmarks.add(context.buffer, 2, "Target")
    context.buffer:replace_snapshot("new\nfirst\ntarget\nlast\n")
    context.buffer:remove(2, 1, 3, 1)
    wait_for_refresh()
    test.equal(mark.status, "location_missing")
    test.equal(mark.text, "target")
    test.equal(bookmarks.at(context.buffer, 2), nil)
    context.buffer:undo()
    wait_for_refresh()
    test.equal(mark.status, "ready")
    test.equal(mark.text, "target")
    test.equal(mark.line, 3)
  end)

  test.it("keeps each Project's bookmarks separate", function(context)
    local mark = bookmarks.add(context.buffer, 2, "Target")
    local other = context.root .. "-other"
    test.ok(common.mkdirp(other))
    core.projects = { Project(other) }
    test.equal(#bookmarks.list(), 0)
    bookmarks.close_project(other)
    storage.clear("bookmarks", common.path_compare_key(other))
    common.rm(other, true)
    core.projects = { Project(context.root) }
    test.equal(bookmarks.list()[1].id, mark.id)
  end)

  test.it("uses the reopened Buffer rather than a stale disk recovery", function(context)
    bookmarks.add(context.buffer, 2, "Target")
    bookmarks.close_project(context.root)
    context.buffer:replace_snapshot("new\nfirst\ntarget\nlast\n")
    bookmarks.attach(context.buffer)
    wait_for_refresh()
    test.equal(bookmarks.list()[1].status, "ready")
    test.equal(bookmarks.list()[1].line, 3)
    test.equal(bookmarks.list()[1].text, "target")
  end)

  test.it("recovers the first line of a file with a UTF-8 byte order mark", function(context)
    bookmarks.add(context.buffer, 1, "First")
    context.buffer:on_close()
    context.buffer = nil
    bookmarks.close_project(context.root)
    write_file(context.path, "\239\187\191first\ntarget\nlast\n")
    refresh()
    test.equal(bookmarks.list()[1].status, "ready")
    test.equal(bookmarks.list()[1].line, 1)
  end)

  test.it("rechecks the disk location after closing a Buffer with unsaved edits", function(context)
    local mark = bookmarks.add(context.buffer, 2, "Target")
    context.buffer:insert(1, 1, "new\n")
    refresh()
    test.equal(mark.line, 3)
    context.buffer:on_close()
    context.buffer = nil
    refresh()
    test.equal(mark.status, "ready")
    test.equal(mark.line, 2)
    test.equal(mark.text, "target")
  end)

  test.it("keeps a deleted location missing after disk recovery, restart, and reopening", function(context)
    local mark = bookmarks.add(context.buffer, 2, "Target")
    context.buffer:insert(4, 1, "unrelated\ntarget\nother\n")
    context.buffer:remove(2, 1, 3, 1)
    test.equal(mark.status, "location_missing")
    write_file(context.path, table.concat(context.buffer.lines))
    context.buffer:on_close()
    context.buffer = nil
    refresh()
    test.equal(mark.status, "location_missing")

    bookmarks.close_project(context.root)
    refresh()
    mark = bookmarks.list()[1]
    test.equal(mark.status, "location_missing")

    -- Even identical text at the old position must not restore a known deletion.
    write_file(context.path, "first\ntarget\nlast\n")
    context.buffer = Buffer(context.path, context.path)
    bookmarks.attach(context.buffer)
    wait_for_refresh()
    test.equal(mark.status, "location_missing")
    test.equal(bookmarks.at(context.buffer, 2), nil)
    test.equal(bookmarks.navigation_target(mark), nil)

    test.ok(bookmarks.retarget(mark, context.buffer, 2))
    test.equal(mark.status, "ready")
    test.equal(bookmarks.at(context.buffer, 2), mark)
    bookmarks.close_project(context.root)
    refresh()
    test.equal(bookmarks.list()[1].status, "ready")
    test.equal(bookmarks.list()[1].line, 2)
  end)

  test.it("requires matching context before recovering an externally displaced location", function(context)
    local mark = bookmarks.add(context.buffer, 2, "Target")
    context.buffer:on_close()
    context.buffer = nil
    write_file(context.path, "unrelated\ntarget\nother\n")
    refresh()
    test.equal(mark.status, "location_missing")
    test.equal(bookmarks.navigation_target(mark), nil)

    write_file(context.path, "new\nfirst\ntarget\nlast\n")
    refresh()
    test.equal(mark.status, "ready")
    test.equal(mark.line, 3)
  end)

  for _, neighbor in ipairs {
    { name = "a closing brace", text = "}" },
    { name = "a blank line", text = "" },
  } do
    test.it("does not recover an unrelated line when only " .. neighbor.name .. " matches", function(context)
      context.buffer:replace_snapshot("old owner\ntarget\n" .. neighbor.text .. "\n")
      local mark = bookmarks.add(context.buffer, 2, "Target")
      context.buffer:on_close()
      context.buffer = nil
      write_file(context.path, "new owner\ntarget\n" .. neighbor.text .. "\n")
      refresh()
      test.equal(mark.status, "location_missing")
      test.equal(bookmarks.navigation_target(mark), nil)
      test.equal(mark.name, "Target")

      -- One matching content line remains sufficient when the other neighbor changes.
      write_file(context.path, "new\nold owner\ntarget\nchanged neighbor\n")
      refresh()
      test.equal(mark.status, "ready")
      test.equal(mark.line, 3)
    end)
  end

  test.it("recovers a unique line when its original file had no neighboring lines", function(context)
    context.buffer:replace_snapshot("target")
    local mark = bookmarks.add(context.buffer, 1, "Target")
    context.buffer:on_close()
    context.buffer = nil
    write_file(context.path, "new\ntarget\nlast\n")
    refresh()
    test.equal(mark.status, "ready")
    test.equal(mark.line, 2)
  end)

  for _, replacement in ipairs {
    { name = "part", col = 2, text = "ARGET", expected = "tARGET" },
    { name = "all", col = 1, text = "changed", expected = "changed" },
  } do
    test.it("follows a line when a batch inserts a prefix and replaces " .. replacement.name .. " of its text", function(context)
      local mark = bookmarks.add(context.buffer, 2, "Target")
      local transaction = context.buffer:apply_edits({
        { line1 = 2, col1 = 1, line2 = 2, col2 = 1, text = "new\n" },
        { line1 = 2, col1 = replacement.col, line2 = 2, col2 = 7, text = replacement.text },
      }, { merge_undo = false })
      test.ok(transaction.applied)
      test.equal(context.buffer.lines[3], replacement.expected .. "\n")
      test.equal(mark.status, "ready")
      test.equal(mark.line, 3)
      test.equal(mark.text, replacement.expected)
      test.equal(bookmarks.at(context.buffer, 3), mark)
      test.equal(bookmarks.at(context.buffer, 2), nil)

      context.buffer:undo()
      test.equal(mark.status, "ready")
      test.equal(mark.line, 2)
      test.equal(mark.text, "target")
      context.buffer:redo()
      test.equal(mark.status, "ready")
      test.equal(mark.line, 3)
      test.equal(mark.text, replacement.expected)
    end)
  end
end)
