local Buffer = require "core.buffer"
local test = require "core.test"

test.describe("Buffer metadata listeners", function()
  test.it("publishes one filename event with old and new syntax metadata", function()
    local buffer = Buffer("note.txt", "note.txt", true)
    local events = {}
    buffer:add_metadata_listener("test", function(_, event)
      events[#events + 1] = event
    end)

    local old_syntax = buffer.syntax
    buffer:set_filename("note.md", "note.md")

    test.equal(#events, 1)
    test.equal(events[1].kind, "metadata")
    test.equal(events[1].reason, "set-filename")
    test.equal(events[1].filename_changed, true)
    test.equal(events[1].syntax_changed, old_syntax ~= buffer.syntax)
    test.equal(events[1].old.filename, "note.txt")
    test.equal(events[1].new.filename, "note.md")
    test.equal(events[1].old.syntax, old_syntax)
    test.equal(events[1].new.syntax, buffer.syntax)
  end)

  test.it("publishes direct syntax changes and supports listener removal", function()
    local buffer = Buffer("note.txt", "note.txt", true)
    local events = {}
    buffer:add_metadata_listener("test", function(_, event)
      events[#events + 1] = event
    end)
    local markdown_syntax = require("core.syntax").get("note.md", "")

    test.equal(buffer:set_syntax(markdown_syntax, "test-override"), true)
    test.equal(#events, 1)
    test.equal(events[1].reason, "test-override")
    test.equal(events[1].syntax_changed, true)
    test.equal(events[1].new.syntax, markdown_syntax)
    test.equal(buffer:remove_metadata_listener("test"), true)
    test.equal(buffer:set_syntax(events[1].old.syntax, "removed-listener"), true)
    test.equal(#events, 1)
  end)

  test.it("notifies metadata listeners when the Buffer closes", function()
    local buffer = Buffer("note.md", "note.md", true)
    local closed = false
    buffer:add_metadata_listener("test", function(_, event)
      if event.kind == "close" then closed = true end
    end)
    buffer:on_close()
    test.equal(closed, true)
    test.equal(buffer.metadata_listeners, nil)
  end)
end)
