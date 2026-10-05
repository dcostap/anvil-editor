local test = require "core.test"
local core = require "core"
local command = require "core.command"
local settings = require "plugins.settings"
local style = require "core.style"
local RootPanel = require "core.rootpanel"

test.describe("wallpaper selection", function()
  local original
  test.before_each(function()
    original = settings.config.wallpaper or "image1"
    core.global_prompt_bar:exit(true)
  end)
  test.after_each(function()
    core.global_prompt_bar:exit(false)
    if settings.apply_wallpaper then settings.apply_wallpaper(original) end
  end)

  test.it("limits the wallpaper picker to four visible rows", function()
    local bar = core.global_prompt_bar
    local config = require "core.config"
    local old_transitions = config.transitions
    local old_max_visible_commands = config.max_visible_commands
    local visible_rows
    config.transitions = false
    config.max_visible_commands = 20
    local ok, err = pcall(function()
      test.ok(command.perform("core:select_wallpaper"))
      bar:update()
      visible_rows = bar.suggestions_height / bar:get_suggestion_line_height()
    end)
    bar:exit(true)
    config.transitions = old_transitions
    config.max_visible_commands = old_max_visible_commands
    if not ok then error(err, 0) end
    test.equal(visible_rows, 4)
  end)

  test.it("previews images and None, then restores the saved choice on cancel", function()
    test.ok(command.perform("core:select_wallpaper"))
    local bar = core.global_prompt_bar
    test.equal(#require("core.wallpapers").options(), #bar.suggestions)
    bar:set_text("image2")
    bar:update_suggestions()
    test.equal("image2", require("core.wallpapers").current())
    test.equal(original, settings.config.wallpaper or "image1")
    local root = RootPanel()
    root.size.x, root.size.y = 320, 200
    local old_rect, old_scaled = renderer.draw_rect, renderer.draw_canvas_scaled
    renderer.draw_rect = function() end
    renderer.draw_canvas_scaled = function() end
    local ok, err = pcall(function()
      root:draw_wallpaper(true)
      test.equal("image2", root.wallpaper_name)
      test.ok(root.wallpaper)
      bar:set_text("image12")
      bar:update_suggestions()
      root:draw_wallpaper(true)
      test.equal("image12", root.wallpaper_name)
      test.ok(root.wallpaper)
      for index = 13, 18 do
        local name = "image" .. index
        test.ok(settings.apply_wallpaper(name), name .. " must be selectable")
        root:draw_wallpaper(true)
        test.equal(name, root.wallpaper_name)
        test.ok(root.wallpaper)
      end
    end)
    renderer.draw_rect, renderer.draw_canvas_scaled = old_rect, old_scaled
    if not ok then error(err, 0) end
    bar:set_text("None")
    bar:update_suggestions()
    test.equal("none", require("core.wallpapers").current())
    test.equal(255, style.wallpaper_surface(style.background)[4])
    test.equal(255, style.line_highlight[4])
    bar:exit(false)
    test.equal(original, require("core.wallpapers").current())
    test.ok(style.line_highlight[4] < 255)
  end)

  test.it("finds wallpaper selection by its background image keyword", function()
    local picker = require("plugins.fuzzy_searcher").open(">select background image")
    local found = false
    for _, row in ipairs(picker.results) do
      if row.command == "core:select_wallpaper" then found = true break end
    end
    picker:close()
    test.ok(found, "the Command Palette must find the wallpaper command")
  end)

  test.it("draws the original opaque window when None is selected", function()
    test.ok(command.perform("core:select_wallpaper"))
    local bar = core.global_prompt_bar
    bar:set_text("None")
    bar:submit()
    test.equal("none", settings.config.wallpaper)
    test.equal("none", dofile(USERDIR .. "/user_settings.lua").config.wallpaper)
    local root = RootPanel()
    root.size.x, root.size.y = 320, 200
    local old_rect, old_scaled = renderer.draw_rect, renderer.draw_canvas_scaled
    local fills, images = {}, 0
    renderer.draw_rect = function(_, _, _, _, color) fills[#fills + 1] = color end
    renderer.draw_canvas_scaled = function() images = images + 1 end
    local ok, err = pcall(function()
      root:draw_wallpaper(true)
      test.equal(0, images)
      test.equal(1, #fills)
      test.equal(style.background, fills[1])
      test.equal(255, style.line_highlight[4])
      test.equal(style.background, style.wallpaper_surface(style.background))
    end)
    renderer.draw_rect, renderer.draw_canvas_scaled = old_rect, old_scaled
    if not ok then error(err, 0) end
  end)

  test.it("keeps surfaces opaque when the Color Theme changes with None selected", function()
    local theme = settings.config.theme or "dark"
    settings.apply_wallpaper("none")
    local ok, err = pcall(function()
      core.reload_module("colors.light")
      test.equal(255, style.line_highlight[4])
      test.equal(style.background, style.wallpaper_surface(style.background))
      core.reload_module("colors.dark2")
      test.equal(255, style.line_highlight[4])
      test.equal(style.background, style.wallpaper_surface(style.background))
    end)
    core.reload_module("colors." .. (theme == "dark" and "default" or theme))
    if not ok then error(err, 0) end
  end)

  test.it("removes all image pixels on the next frame after None is selected", function()
    local root = RootPanel()
    root.size.x, root.size.y = 320, 200
    local window = renwindow.create("wallpaper-none-test", 320, 200)
    local ok, err = pcall(function()
      settings.apply_wallpaper("image2")
      renderer.begin_frame(window)
      renderer.set_clip_rect(0, 0, 320, 200)
      root:draw_wallpaper(true)
      renderer.end_frame()

      settings.apply_wallpaper("none")
      renderer.begin_frame(window)
      renderer.set_clip_rect(0, 0, 320, 200)
      root:draw_wallpaper(true)
      renderer.end_frame()
      test.equal(nil, root.wallpaper)
      for _, point in ipairs({ { 10, 10 }, { 160, 100 }, { 310, 190 } }) do
        test.same(style.background,
          renwindow.get_color(window, point[1], point[2]))
      end
    end)
    if not ok then error(err, 0) end
  end)
end)
