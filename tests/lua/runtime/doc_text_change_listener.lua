local Doc = require "core.doc"
local test = require "core.test"

test.describe("Doc text change listeners", function()
  test.it("fires once around apply_edits transactions", function()
    local doc = Doc(nil, nil, true)
    local events = {}
    doc:add_text_change_listener("test", {
      before_change = function(_, change) events[#events + 1] = "before:" .. change.kind end,
      after_change = function(_, change) events[#events + 1] = "after:" .. change.kind end,
    })
    doc:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "hello" } }, { type = "insert" })
    test.same(events, { "before:apply_edits", "after:apply_edits" })
  end)

  test.it("covers undo and redo text changes", function()
    local doc = Doc(nil, nil, true)
    doc:insert(1, 1, "hello")
    local after = 0
    doc:add_text_change_listener("test", {
      after_change = function(_, change)
        if change.type == "undo" or change.type == "redo" then after = after + 1 end
      end,
    })
    doc:undo()
    doc:redo()
    test.equal(after, 2)
  end)

  test.it("covers direct raw mutations", function()
    local doc = Doc(nil, nil, true)
    local after = 0
    doc:add_text_change_listener("test", {
      after_change = function(_, change)
        if change.kind == "raw_insert" or change.kind == "raw_remove" then after = after + 1 end
      end,
    })
    doc:raw_insert(1, 1, "hello", doc.undo_stack, system.get_time())
    doc:raw_remove(1, 1, 1, 3, doc.undo_stack, system.get_time())
    test.equal(after, 2)
  end)

  test.it("can remove listeners", function()
    local doc = Doc(nil, nil, true)
    local count = 0
    doc:add_text_change_listener("test", function() count = count + 1 end)
    test.equal(doc:remove_text_change_listener("test"), true)
    doc:insert(1, 1, "hello")
    test.equal(count, 0)
  end)
end)
