local Buffer = require "core.buffer"
local command = require "core.command"
local core = require "core"
local RowTextView = require "core.rowtextview"
local test = require "core.test"

local function make_view()
  local buffer = Buffer()
  buffer:insert(1, 1, "one\ntwo\nthree")
  buffer:clean()
  local view = RowTextView(buffer)
  core.active_view = view
  return view, buffer
end

test.describe("Row Selection Mode", function()
  test.before_each(function(context)
    context.active_view = core.active_view
  end)

  test.after_each(function(context)
    core.active_view = context.active_view
  end)

  test.it("keeps marked rows selected during ordinary navigation", function()
    local view = make_view()
    test.same(view:get_selected_rows(), { 1 })

    test.ok(command.perform("core:toggle_row_mark"))
    command.perform("core:move_to_next_line")
    test.same(view:get_selected_rows(), { 1, 2 })

    test.ok(command.perform("core:toggle_row_mark"))
    command.perform("core:move_to_next_line")
    test.same(view:get_selected_rows(), { 1, 2, 3 })

    command.perform("core:move_to_previous_line")
    test.ok(command.perform("core:toggle_row_mark"))
    command.perform("core:move_to_next_line")
    test.same(view:get_selected_rows(), { 1, 3 })
  end)

  test.it("keeps marks while Shift extends and ordinary navigation collapses the range", function()
    local view = make_view()
    command.perform("core:toggle_row_mark")
    command.perform("core:move_to_next_line")
    command.perform("core:select_to_next_line")
    test.same(view:get_selected_rows(), { 1, 2, 3 })

    command.perform("core:move_to_previous_line")
    test.same(view:get_selected_rows(), { 1, 2 })
  end)

  test.it("blocks editing until Row Selection Mode is disabled", function()
    local view, buffer = make_view()
    local original = table.concat(buffer.lines)
    test.equal(view:on_text_input("changed"), false)
    test.equal(table.concat(buffer.lines), original)

    view:set_row_selection_mode(false)
    test.ok(view:on_text_input("changed"))
    test.not_equal(table.concat(buffer.lines), original)
  end)
end)
