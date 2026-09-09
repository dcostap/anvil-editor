local core = require "core"
local command = require "core.command"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"

require "core.commands.text"

test.describe("Align cursors", function()
  test.before_each(function(context)
    context.previous = core.active_view
    context.buffer = Buffer()
    context.view = TextView(context.buffer)
    core.set_active_view(context.view)
  end)

  test.after_each(function(context)
    if context.previous then core.set_active_view(context.previous) end
    context.buffer:on_close()
  end)

  test.it("pads cursors to the rightmost column and undoes in one step", function(context)
    local buffer, view = context.buffer, context.view
    buffer:insert(1, 1, "a=x\nlong=y\né=z")
    view:with_selection_state(function()
      buffer:set_selection_list({ 1, 2, 1, 2, 2, 5, 2, 5, 3, 3, 3, 3 }, 1)
    end)
    test.ok(command.perform("editor:align_cursors"))
    test.equal(table.concat(buffer.lines), "a   =x\nlong=y\né   =z\n")
    test.same(view:get_selection_state().selections, {
      1, 5, 1, 5, 2, 5, 2, 5, 3, 6, 3, 6,
    })
    test.ok(command.perform("core:undo"))
    test.equal(table.concat(buffer.lines), "a=x\nlong=y\né=z\n")
  end)

  test.it("counts tabs as tab stops when aligning cursors", function(context)
    local buffer, view = context.buffer, context.view
    local _, tab_size = buffer:get_indent_info()
    buffer:insert(1, 1, "\t=x\n=y")
    view:with_selection_state(function()
      buffer:set_selection_list({ 1, 2, 1, 2, 2, 1, 2, 1 }, 1)
    end)
    test.ok(command.perform("editor:align_cursors"))
    test.equal(table.concat(buffer.lines), "\t=x\n" .. string.rep(" ", tab_size) .. "=y\n")
    test.same(view:get_selection_state().selections, {
      1, 2, 1, 2, 2, tab_size + 1, 2, tab_size + 1,
    })
  end)
end)
