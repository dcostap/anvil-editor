local core = require "core"
local test = require "core.test"
local View = require "core.view"
local diffview = require "plugins.diffview"

test.describe("Diff Side scroll synchronization", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    core.active_view = View()
  end)

  test.after_each(function(context)
    if context.view then context.view:on_close() end
    core.active_view = context.active_view
  end)

  test.it("reveals both sides together after an unfocused comparison receives its layout", function(context)
    local prefix, suffix = {}, {}
    for i = 1, 40 do prefix[i] = "unchanged " .. i end
    for i = 1, 100 do suffix[i] = "tail " .. i end
    local view = diffview.open({
      contents = {
        diffview.content.text(table.concat(prefix, "\n") .. "\nold value\n" .. table.concat(suffix, "\n")),
        diffview.content.text(table.concat(prefix, "\n") .. "\nnew value\n" .. table.concat(suffix, "\n")),
      },
      content_titles = { "Before", "After" },
    }, true)
    context.view = view
    view.buffer_view_a:set_wrapping_enabled(true)
    view.buffer_view_b:set_wrapping_enabled(true)
    local deadline = system.get_time() + 2
    while view.updater_idx do
      test.ok(system.get_time() < deadline, "diff computation did not finish")
      coroutine.yield(0.01)
    end

    -- File History updates a pending comparison before placing it in its Pane.
    view:update()
    view.size.x, view.size.y = 800, 400
    for frame = 1, 5 do
      view:update()
      local left, right = view.buffer_view_a, view.buffer_view_b
      test.equal(left.scroll.y, right.scroll.y, "visible scroll differs on frame " .. frame)
      test.equal(left.scroll.to.y, right.scroll.to.y, "scroll target differs on frame " .. frame)
      local _, left_y = left:get_line_screen_position(41)
      local _, right_y = right:get_line_screen_position(41)
      test.equal(left_y, right_y, "the first change must align before any click")
      test.ok(left_y >= left.position.y and left_y < left.position.y + left.size.y,
        "the first change must remain visible")
    end
  end)
end)
