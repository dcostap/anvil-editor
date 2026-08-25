local core = require "core"
local command = require "core.command"
local panes = require "core.panes"
local TextView = require "core.textview"
local test = require "core.test"

local function buffer_text(buffer)
  return buffer:get_text(1, 1, #buffer.lines, #buffer.lines[#buffer.lines])
end

test.describe("Read-only Text View", function()
  local set_active_view

  test.before_each(function()
    panes.reset_for_tests()
    set_active_view = core.set_active_view
    core.set_active_view = function(view) core.active_view = view end
  end)

  test.after_each(function()
    panes.reset_for_tests()
    core.set_active_view = set_active_view
  end)

  test.it("opens named generated text as a plain navigable Text View", function()
    local view = core.open_text("first\nsecond", { name = "Build Report" })

    test.ok(view:is(TextView))
    test.equal(view:get_name(), "Build Report")
    test.equal(buffer_text(view.buffer), "first\nsecond")
    test.equal(view:supports_text_input(), false)
    test.ok(command.perform("core:move_to_next_line"))
    test.equal(view.buffer:get_selection(), 2)
  end)

  test.it("blocks user edits while code can replace generated text", function()
    local view = core.open_text("stable", { name = "Status" })

    test.equal(view:on_text_input("changed"), false)
    test.ok(command.perform("core:newline"))
    test.equal(buffer_text(view.buffer), "stable")

    view.buffer:remove(1, 1, 1, #view.buffer.lines[1])
    view.buffer:insert(1, 1, "updated")
    test.equal(buffer_text(view.buffer), "updated")
  end)
end)
