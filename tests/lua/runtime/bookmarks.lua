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
end)
