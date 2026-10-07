local core = require "core"
local common = require "core.common"
local Buffer = require "core.buffer"
local Project = require "core.project"
local storage = require "core.storage"
local test = require "core.test"

local bookmarks

test.describe("Bookmarks", function()
  test.before_each(function(context)
    context.projects = core.projects
    context.root = USERDIR .. PATHSEP .. "bookmark-project"
    test.ok(common.mkdirp(context.root))
    core.projects = { Project(context.root) }
    bookmarks = require "core.bookmarks"
    bookmarks.close_project(context.root)
    storage.clear("bookmarks", common.path_compare_key(context.root))
    context.path = context.root .. PATHSEP .. "source.txt"
    Buffer.write_text_safely(context.path, "first\ntarget\nlast\n")
    context.buffer = Buffer(context.path, context.path)
  end)

  test.after_each(function(context)
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
end)
