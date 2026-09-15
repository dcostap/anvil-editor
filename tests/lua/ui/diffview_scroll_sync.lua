local core = require "core"
local config = require "core.config"
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

  test.it("keeps the shorter side clamped while selecting in an unmatched final hunk", function(context)
    local left_lines, right_lines = {}, {}
    for i = 1, 80 do
      left_lines[i] = "same " .. i
      right_lines[i] = left_lines[i]
    end
    right_lines[#right_lines + 1] = "inserted final line"
    local old_fold_default = config.plugins.diffview.fold_unchanged_by_default
    config.plugins.diffview.fold_unchanged_by_default = false
    local view = diffview.open({
      contents = {
        diffview.content.text(table.concat(left_lines, "\n")),
        diffview.content.text(table.concat(right_lines, "\n")),
      },
      content_titles = { "Before", "After" },
      auto_reveal_first_change = false,
    }, true)
    config.plugins.diffview.fold_unchanged_by_default = old_fold_default
    context.view = view
    local deadline = system.get_time() + 2
    while view.updater_idx do
      test.ok(system.get_time() < deadline, "diff computation did not finish")
      coroutine.yield(0.01)
    end

    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 120
    view:update()
    local left, right = view.buffer_view_a, view.buffer_view_b
    local left_max = math.max(0, left:get_scrollable_size() - left.size.y)
    local right_max = math.max(0, right:get_scrollable_size() - right.size.y)
    test.ok(right_max > left_max, "the final hunk must extend beyond the shorter side")
    left.scroll.y, left.scroll.to.y = left_max, left_max
    right.scroll.y, right.scroll.to.y = right_max, right_max

    core.set_active_view(right)
    right.buffer:set_selection(#right_lines, 1)
    view:update()

    test.ok(left.scroll.y <= left_max, "selection must not overscroll the shorter side")
    test.ok(left.scroll.to.y <= left_max, "selection must not overscroll the shorter side target")
  end)
end)
