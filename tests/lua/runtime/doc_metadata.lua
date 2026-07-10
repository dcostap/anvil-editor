local Doc = require "core.doc"
local test = require "core.test"

test.describe("Document metadata listeners", function()
  test.it("publishes one filename event with old and new syntax metadata", function()
    local doc = Doc("note.txt", "note.txt", true)
    local events = {}
    doc:add_metadata_listener("test", function(_, event)
      events[#events + 1] = event
    end)

    local old_syntax = doc.syntax
    doc:set_filename("note.md", "note.md")

    test.equal(#events, 1)
    test.equal(events[1].kind, "metadata")
    test.equal(events[1].reason, "set-filename")
    test.equal(events[1].filename_changed, true)
    test.equal(events[1].syntax_changed, old_syntax ~= doc.syntax)
    test.equal(events[1].old.filename, "note.txt")
    test.equal(events[1].new.filename, "note.md")
    test.equal(events[1].old.syntax, old_syntax)
    test.equal(events[1].new.syntax, doc.syntax)
  end)

  test.it("publishes direct syntax changes and supports listener removal", function()
    local doc = Doc("note.txt", "note.txt", true)
    local events = {}
    doc:add_metadata_listener("test", function(_, event)
      events[#events + 1] = event
    end)
    local markdown_syntax = require("core.syntax").get("note.md", "")

    test.equal(doc:set_syntax(markdown_syntax, "test-override"), true)
    test.equal(#events, 1)
    test.equal(events[1].reason, "test-override")
    test.equal(events[1].syntax_changed, true)
    test.equal(events[1].new.syntax, markdown_syntax)
    test.equal(doc:remove_metadata_listener("test"), true)
    test.equal(doc:set_syntax(events[1].old.syntax, "removed-listener"), true)
    test.equal(#events, 1)
  end)

  test.it("notifies metadata listeners when the Document closes", function()
    local doc = Doc("note.md", "note.md", true)
    local closed = false
    doc:add_metadata_listener("test", function(_, event)
      if event.kind == "close" then closed = true end
    end)
    doc:on_close()
    test.equal(closed, true)
    test.equal(doc.metadata_listeners, nil)
  end)
end)
