local config = require "core.config"
local core = require "core"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local renderer = require "renderer"
local style = require "core.style"
local test = require "core.test"

local function same_color(a, b)
  return a and b
    and a[1] == b[1] and a[2] == b[2]
    and a[3] == b[3] and a[4] == b[4]
end

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
      test.equal(root:modal_input_owner(), picker)
      root:update_app_overlay()
      root:draw_active_app_overlay()

      test.ok(overlay_drawn, "expected the open picker to draw an application overlay")
      test.is_nil(unobscured_view, "the floating picker should not be excluded from the dimmer")

      picker:close()
      test.is_nil(root:modal_input_owner())
      root:update_app_overlay()
      overlay_drawn = false
      root:draw_active_app_overlay()
      test.not_ok(overlay_drawn, "expected closing the picker to release the overlay")
    end)

    root.draw_app_overlay = old_draw_app_overlay
    if not ok then error(err, 0) end
  end)

  test.it("restores a covered confirmation prompt with its choices", function()
    local root = core.root_panel
    local bar = core.global_prompt_bar
    bar:exit(true)
    local previous_view = core.active_view
    local picker
    local ok, err = pcall(function()
      bar:enter("Unsaved Changes; Confirm Close", {
        suggest = function()
          return { "Close Without Saving", "Save And Close" }
        end,
      })
      test.equal(#bar.suggestions, 2)

      picker = fuzzy_searcher.open_static_results("Commands", {})
      root:update()
      test.equal(bar.size.y, 0)
      test.equal(bar.suggestions_height, 0)
      picker:close()
      picker = nil
      root:update()

      test.equal(core.active_view, bar)
      test.equal(#bar.suggestions, 2)
      test.equal(root.app_overlay.owner, bar)
    end)

    if picker then pcall(function() picker:close() end) end
    bar:exit(true)
    if previous_view then core.set_active_view(previous_view) end
    if not ok then error(err, 0) end
  end)

  test.it("keeps hover separate from selection and activates on two clicks", function()
    local picker = fuzzy_searcher.open_static_results("Results", {
      { kind = "file", label = "first.lua", file = "first.lua" },
      { kind = "file", label = "second.lua", file = "second.lua" },
    })
    picker.selected = 1
    local metrics = picker:list_metrics()
    local x = metrics.x + 20
    local y = metrics.results_top + metrics.lh * 1.5
    local confirmations = 0
    picker.confirm = function() confirmations = confirmations + 1 end

    picker:on_mouse_moved(x, y, 0, 0)

    test.equal(picker.hovered_result, 2)
    test.equal(picker.selected, 1)
    test.equal(picker.cursor, "hand")

    picker:on_mouse_pressed("left", x, y, 1)
    picker:on_mouse_released("left", x, y)
    test.equal(picker.selected, 2)
    test.equal(confirmations, 0)

    picker:on_mouse_pressed("left", x, y, 2)
    picker:on_mouse_released("left", x, y)
    test.equal(confirmations, 1)
  end)

  test.it("keeps the hand cursor over a result after the next update", function()
    local picker = fuzzy_searcher.open_static_results("Results", {
      { kind = "file", label = "first.lua", file = "first.lua" },
    })
    picker:update()
    local metrics = picker:list_metrics()
    local x = metrics.x + 20
    local y = metrics.results_top + metrics.lh / 2
    local previous_cursor_request = core.cursor_change_req

    picker:on_mouse_moved(x, y, 0, 0)
    core.request_cursor("ibeam")
    picker:update()
    local cursor_request = core.cursor_change_req
    core.cursor_change_req = previous_cursor_request

    test.equal(picker.hovered_result, 1)
    test.equal(cursor_request, "hand")
  end)

  test.it("draws different feedback for hovered and selected results", function()
    local picker = fuzzy_searcher.open_static_results("Results", {
      { kind = "file", label = "first.lua", file = "first.lua" },
      { kind = "file", label = "second.lua", file = "second.lua" },
    })
    picker:update()
    picker.selected = 1
    picker.hovered_result = 2

    local selected_drawn = false
    local hover_drawn = false
    local original_draw_rect = renderer.draw_rect
    local original_draw_rounded_rect = renderer.draw_rounded_rect
    local original_draw_text = renderer.draw_text
    local original_draw_text_known_bounds = renderer.draw_text_known_bounds
    local original_set_clip_rect = renderer.set_clip_rect
    renderer.draw_rect = function(x, y, width, height, color)
      if same_color(color, style.fuzzy_searcher_result_selection_background) then
        selected_drawn = true
      end
      if same_color(color, style.fuzzy_searcher_result_hover_background) then
        hover_drawn = true
      end
    end
    renderer.draw_rounded_rect = function() end
    renderer.draw_text = function(font, text, x)
      return x + (font and font:get_width(text) or 0)
    end
    renderer.draw_text_known_bounds = function() end
    renderer.set_clip_rect = function() end
    local ok, err = pcall(function() picker:draw() end)
    renderer.draw_rect = original_draw_rect
    renderer.draw_rounded_rect = original_draw_rounded_rect
    renderer.draw_text = original_draw_text
    renderer.draw_text_known_bounds = original_draw_text_known_bounds
    renderer.set_clip_rect = original_set_clip_rect
    if not ok then error(err, 0) end

    test.ok(selected_drawn, "expected selected-result feedback")
    test.ok(hover_drawn, "expected hovered-result feedback")
    test.not_ok(same_color(
      style.fuzzy_searcher_result_selection_background,
      style.fuzzy_searcher_result_hover_background
    ),
      "expected hover and selection to use different feedback")
    test.ok(
      style.fuzzy_searcher_result_selection_background[4]
        > style.fuzzy_searcher_result_hover_background[4],
      "expected selection feedback to be stronger than hover feedback"
    )
  end)
end)
