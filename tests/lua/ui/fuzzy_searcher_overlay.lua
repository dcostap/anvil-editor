local config = require "core.config"
local core = require "core"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local test = require "core.test"

test.describe("Fuzzy Searcher attention overlay", function()
  test.before_each(function(context)
    context.transitions = config.transitions
    context.fuzzy_searcher_transition = config.disabled_transitions.fuzzy_searcher
    context.app_overlay = core.root_panel.app_overlay
    config.transitions = false
  end)

  test.after_each(function(context)
    local picker = core.fuzzy_searcher_active_view
    if picker and picker.close then pcall(function() picker:close() end) end
    core.root_panel:update_app_overlay()
    core.root_panel.app_overlay = context.app_overlay
    config.transitions = context.transitions
    config.disabled_transitions.fuzzy_searcher = context.fuzzy_searcher_transition
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

  test.it("hides editor content without hiding the wallpaper inside the popup", function()
    local root = core.root_panel
    local old_wallpaper = root.wallpaper
    local old_fps = core.fps
    local old_x, old_y = root.position.x, root.position.y
    local old_w, old_h = root.size.x, root.size.y
    root.position.x, root.position.y = 0, 0
    root.size.x, root.size.y = 800, 600
    local picker = fuzzy_searcher.open_static_results("Results", {})
    root:update()
    local window = renwindow.create("fuzzy-wallpaper-test", 800, 600)
    local sx = math.floor(picker.position.x + picker.size.x - 18)
    local sy = math.floor(picker.position.y + picker.size.y - 18)
    local function pixel(image, editor_color)
      root.wallpaper = canvas.new(8, 8, image)
      renderer.begin_frame(window)
      renderer.set_clip_rect(0, 0, 800, 600)
      root:draw_wallpaper(true)
      renderer.draw_rect(picker.position.x, picker.position.y,
        picker.size.x, picker.size.y, editor_color)
      picker:draw()
      renderer.end_frame()
      return renwindow.get_color(window, sx, sy)
    end
    local ok, err = pcall(function()
      local red = { 255, 0, 0, 255 }
      local first = pixel(red, { 0, 0, 0, 255 })
      test.same(pixel(red, { 255, 255, 255, 255 }), first)
      test.not_equal(pixel({ 0, 255, 0, 255 }, { 0, 0, 0, 255 })[1], first[1])

      config.transitions = true
      config.disabled_transitions.fuzzy_searcher = false
      core.fps = 60
      picker.open_transition_complete = false
      local start = system.get_time() - 0.005
      picker.open_transition_requested_at = start
      picker.open_transition_ready_at = start
      local scale, visible = picker:opening_transition(start + 0.005)
      test.ok(visible and scale < 1,
        "the popup must be partway through its opening animation")
      local opening = pixel(red, { 0, 0, 0, 255 })
      test.same(pixel(red, { 255, 255, 255, 255 }), opening,
        "the opening animation must not reveal the editor")
      test.not_equal(pixel({ 0, 255, 0, 255 }, { 0, 0, 0, 255 })[1], opening[1],
        "the opening animation must still show the wallpaper")
    end)
    root.wallpaper = old_wallpaper
    core.fps = old_fps
    root.position.x, root.position.y = old_x, old_y
    root.size.x, root.size.y = old_w, old_h
    picker:close()
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

  test.it("keeps the opened view focused after a double-click activation", function()
    local previous_view = core.active_view
    local picker = fuzzy_searcher.open_static_results("Results", {
      { kind = "file", label = "opened.lua", file = "opened.lua" },
    })
    local target = {}
    local metrics = picker:list_metrics()
    local x = metrics.x + 20
    local y = metrics.results_top + metrics.lh * 0.5
    picker.confirm = function()
      picker:swap_active_child(nil)
      picker.closing = true
      core.active_view = target
    end

    picker:on_mouse_pressed("left", x, y, 2)
    picker:on_mouse_released("left", x, y)

    test.equal(core.active_view, target)
    core.active_view = previous_view
  end)

end)
