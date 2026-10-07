local Buffer = require "core.buffer"
local Editor = require "core.editor"
local test = require "core.test"

test.describe("Buffer snapshot selections", function()
  test.after_each(function(context)
    for _, view in ipairs(context.views or {}) do view:on_close() end
  end)

  test.it("keeps each Editor selection valid when it publishes replacement text", function(context)
    local buffer = Buffer("snapshot-selections.txt", "snapshot-selections.txt", true)
    buffer:insert(1, 1, "alpha\nbeta\ngamma")
    local first, second = Editor(buffer), Editor(buffer)
    context.views = { first, second }
    first:set_selection_state { selections = { 1, 5, 1, 5 }, last_selection = 1 }
    second:set_selection_state { selections = { 3, 6, 3, 6 }, last_selection = 1 }
    local published
    buffer:add_text_change_listener("snapshot-selections", {
      after_change = function()
        published = { first:get_selection_state(), second:get_selection_state() }
      end,
    })

    buffer:replace_snapshot("x\nend\n")

    test.same(published[1].selections, { 1, 2, 1, 2 })
    test.same(published[2].selections, { 2, 4, 2, 4 })
    test.equal(buffer:get_text(1, 1, math.huge, math.huge), "x\nend")
  end)
end)
