local config = require "core.config"
local core = require "core"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local test = require "core.test"

test.describe("Fuzzy Searcher attention overlay", function()
  test.before_each(function(context)
    context.transitions = config.transitions
    context.app_overlay = core.root_panel.app_overlay
    config.transitions = false
  end)

  test.after_each(function(context)
    local picker = core.fuzzy_searcher_active_view
    if picker and picker.close then pcall(function() picker:close() end) end
    core.root_panel:update_app_overlay()
    core.root_panel.app_overlay = context.app_overlay
    config.transitions = context.transitions
  end)

  test.it("dims the app while open and releases the overlay after closing", function()
    local root = core.root_panel
    local overlay_drawn = false
    local unobscured_view
    local old_draw_app_overlay = root.draw_app_overlay
    root.draw_app_overlay = function(_, _, view)
      overlay_drawn = true
      unobscured_view = view
    end

    local ok, err = pcall(function()
      local picker = fuzzy_searcher.open_static_results("Results", {})
      root:update_app_overlay()
      root:draw_active_app_overlay()

      test.ok(overlay_drawn, "expected the open picker to draw an application overlay")
      test.is_nil(unobscured_view, "the floating picker should not be excluded from the dimmer")

      picker:close()
      root:update_app_overlay()
      overlay_drawn = false
      root:draw_active_app_overlay()
      test.not_ok(overlay_drawn, "expected closing the picker to release the overlay")
    end)

    root.draw_app_overlay = old_draw_app_overlay
    if not ok then error(err, 0) end
  end)
end)
