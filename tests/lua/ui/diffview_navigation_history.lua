local core = require "core"
local panes = require "core.panes"
local View = require "core.view"
local diffview = require "plugins.diffview"
local test = require "core.test"

test.describe("Diff View navigation history", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    context.set_active_view = core.set_active_view
    panes.reset_for_tests()
    core.set_active_view = function(view) core.active_view = view end
  end)

  test.after_each(function(context)
    panes.reset_for_tests()
    if context.view then context.view:on_close() end
    core.set_active_view = context.set_active_view
    core.active_view = context.active_view
  end)

  for _, side in ipairs { "left", "right" } do
    test.it("returns to the " .. side .. " jump origin before older Views", function(context)
      local older = View()
      local pane = panes.create { factory = function() return older end }
      local text = string.rep("line\n", 1500)
      local view = diffview.open({
        contents = { diffview.content.text(text), diffview.content.text(text) },
        auto_reveal_first_change = false,
      }, true)
      context.view = view
      panes.present(view, { pane = pane })
      local target = side == "left" and view.buffer_view_a or view.buffer_view_b
      core.set_active_view(target)
      target:with_selection_state(function() target.buffer:set_selection(1461, 3) end)
      target.scroll.x, target.scroll.y = 10, 400
      panes.record_location(pane)
      target:with_selection_state(function() target.buffer:set_selection(1372, 2) end)
      target.scroll.x, target.scroll.y = 20, 200
      panes.record_location(pane)
      -- Scrolling alone must not add a return stop.
      target.scroll.y = 250

      test.equal(panes.back(pane), view)
      test.equal(core.active_view, target)
      test.equal(target:get_selection_state().selections[1], 1461)
      test.equal(target:get_selection_state().selections[2], 3)
      test.equal(target.scroll.to.x, 10)
      test.equal(target.scroll.to.y, 400)
      test.equal(panes.forward(pane), view)
      test.equal(core.active_view, target)
      test.equal(target:get_selection_state().selections[1], 1372)
      test.equal(target.scroll.to.y, 200)
      panes.present(older, { pane = pane })
      test.equal(panes.back(pane), view)
      test.equal(core.active_view, target)
      test.equal(target:get_selection_state().selections[1], 1372)
    end)
  end
end)
