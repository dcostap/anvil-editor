local core = require "core"
local command = require "core.command"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"

local function make_view(context, source)
  local buffer = Buffer()
  buffer:insert(1, 1, source)
  buffer:set_filename("sample.md", "sample.md")
  local view = TextView(buffer)
  context.buffer = buffer
  return buffer, view
end

test.describe("Markdown task list Enter after a colon", function()
  test.before_each(function(context)
    context.previous_view = core.active_view
  end)

  test.after_each(function(context)
    if context.previous_view then core.set_active_view(context.previous_view) end
    if context.buffer then context.buffer:on_close() end
  end)

  test.it("starts a new task at the end of an item", function(context)
    local source = "- [ ] task:"
    local buffer, view = make_view(context, source)
    core.set_active_view(view)
    buffer:set_selection(1, #source + 1)

    test.ok(command.perform("core:newline"))

    test.equal(table.concat(buffer.lines), "- [ ] task:\n- [ ] \n")
    test.same(view:get_selection_state().selections, { 2, 7, 2, 7 })
  end)

  test.it("starts a new task when splitting an item after a colon", function(context)
    local source = "- [ ] task:more text"
    local buffer, view = make_view(context, source)
    core.set_active_view(view)
    buffer:set_selection(1, #"- [ ] task:" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(table.concat(buffer.lines), "- [ ] task:\n- [ ] more text\n")
    test.same(view:get_selection_state().selections, { 2, 7, 2, 7 })
  end)
end)
