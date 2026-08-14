local Buffer = require "core.buffer"
local test = require "core.test"

test.describe("Buffer text change listeners", function()
  test.it("fires once around apply_edits transactions", function()
    local buffer = Buffer(nil, nil, true)
    local events = {}
    buffer:add_text_change_listener("test", {
      before_change = function(_, change) events[#events + 1] = "before:" .. change.kind end,
      after_change = function(_, change) events[#events + 1] = "after:" .. change.kind end,
    })
    buffer:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "hello" } }, { type = "insert" })
    test.same(events, { "before:apply_edits", "after:apply_edits" })
  end)

  test.it("covers undo and redo text changes", function()
    local buffer = Buffer(nil, nil, true)
    buffer:insert(1, 1, "hello")
    local after = 0
    buffer:add_text_change_listener("test", {
      after_change = function(_, change)
        if change.type == "undo" or change.type == "redo" then after = after + 1 end
      end,
    })
    buffer:undo()
    buffer:redo()
    test.equal(after, 2)
  end)

  test.it("covers direct raw mutations", function()
    local buffer = Buffer(nil, nil, true)
    local after = 0
    buffer:add_text_change_listener("test", {
      after_change = function(_, change)
        if change.kind == "raw_insert" or change.kind == "raw_remove" then after = after + 1 end
      end,
    })
    buffer:raw_insert(1, 1, "hello", buffer.undo_stack, system.get_time())
    buffer:raw_remove(1, 1, 1, 3, buffer.undo_stack, system.get_time())
    test.equal(after, 2)
  end)

  test.it("can remove listeners", function()
    local buffer = Buffer(nil, nil, true)
    local count = 0
    buffer:add_text_change_listener("test", function() count = count + 1 end)
    test.equal(buffer:remove_text_change_listener("test"), true)
    buffer:insert(1, 1, "hello")
    test.equal(count, 0)
  end)
end)
