local core = require "core"
local command = require "core.command"
local Editor = require "core.editor"
local test = require "core.test"
local diffview = require "plugins.diffview"

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function wait_for_diff(view)
  view:update()
  local deadline = system.get_time() + 2
  while view.updater_idx do
    test.ok(system.get_time() < deadline, "diff computation did not finish")
    coroutine.yield(0.01)
  end
end

test.describe("Diff View file reload", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    context.path = core.temp_filename(".txt")
  end)

  test.after_each(function(context)
    core.active_view = context.active_view
    if context.editor then context.editor:on_close() end
    if context.view then context.view:on_close() end
    if context.buffer then
      core.buffer_registry:remove(context.buffer)
      context.buffer:on_close()
    end
    os.remove(context.path)
  end)

  for _, side in ipairs { "left", "right" } do
    test.it("removes old markers after reloading the " .. side .. " file", function(context)
      write_file(context.path, "same\nold\nend\n")
      local contents = {
        diffview.content.text("same\nnew\nend\n"),
        diffview.content.text("same\nnew\nend\n"),
      }
      local index = side == "left" and 1 or 2
      contents[index] = diffview.content.file(context.path)
      local view = assert(diffview.open({ contents = contents, auto_reveal_first_change = false }, true))
      context.view = view
      local buffer = (index == 1 and view.buffer_view_a or view.buffer_view_b).buffer
      context.buffer = buffer
      wait_for_diff(view)
      test.ok(view:get_change_stats().total > 0)

      write_file(context.path, "same\nnew\nend\n")
      buffer:reload()
      wait_for_diff(view)
      test.equal(table.concat(buffer.lines), "same\nnew\nend\n")
      test.equal(view:get_change_stats().total, 0, "reloaded equal content must remove old change markers")
      test.same(view:diff_points_of_interest(true), {})
      test.same(view:diff_points_of_interest(false), {})
    end)
  end

  test.it("adds new markers when a shared Editor reloads changed content", function(context)
    write_file(context.path, "same\nold\nend\n")
    local buffer = core.open_buffer(context.path)
    context.buffer = buffer
    local editor = Editor(buffer)
    context.editor = editor
    local view = assert(diffview.open({
      contents = { diffview.content.text("same\nold\nend\n"), diffview.content.file(context.path) },
      auto_reveal_first_change = false,
    }, true))
    context.view = view
    wait_for_diff(view)
    test.equal(view:get_change_stats().total, 0)

    write_file(context.path, "same\nnew\nend\n")
    core.active_view = editor
    test.ok(command.perform("editor:reload"))
    wait_for_diff(view)
    test.equal(table.concat(view.buffer_view_b.buffer.lines), "same\nnew\nend\n")
    test.ok(view:get_change_stats().total > 0, "shared Editor reload must add the new change marker")
    test.equal(view:diff_points_of_interest(false)[1].line, 2)
  end)

  test.it("moves change navigation to the new changed line after file reload", function(context)
    write_file(context.path, "start\nchanged\nend\n")
    local view = assert(diffview.open({
      contents = { diffview.content.text("start\nmiddle\nend\n"), diffview.content.file(context.path) },
      auto_reveal_first_change = false,
    }, true))
    context.view = view
    context.buffer = view.buffer_view_b.buffer
    wait_for_diff(view)
    test.equal(view:diff_points_of_interest(false)[1].line, 2)

    write_file(context.path, "start\nmiddle\nchanged\n")
    context.buffer:reload()
    wait_for_diff(view)
    test.equal(table.concat(context.buffer.lines), "start\nmiddle\nchanged\n")
    test.equal(view:diff_points_of_interest(false)[1].line, 3, "reload must move navigation to the new change")
  end)
end)
