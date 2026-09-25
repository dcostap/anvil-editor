local core = require "core"
local RootPanel = require "core.rootpanel"
local View = require "core.view"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local style = require "core.style"
local test = require "core.test"

local function near(actual, expected)
  test.ok(math.abs(actual - expected) < 0.01,
    string.format("expected %.2f, got %.2f", expected, actual))
end

test.describe("Window wallpaper", function()
  test.it("shows the wallpaper through the current line", function()
    local view = TextView(Buffer(nil, nil, true))
    view.size.x, view.size.y = 200, 100
    local old_rect = renderer.draw_rect
    local line_color
    renderer.draw_rect = function(_, _, _, _, color) line_color = color end
    local ok, err = pcall(function()
      view:draw_line_highlight(0, 10, 20)
      test.ok(line_color and line_color[4] > 0 and line_color[4] < 255,
        "the current line must not cover the image")
    end)
    renderer.draw_rect = old_rect
    if not ok then error(err, 0) end
  end)

  test.it("keeps image detail visible on very dark and light themes", function()
    local image, err = canvas.load_image(DATADIR .. "/core/assets/wallpaper.jpg")
    test.ok(image, err)
    local root = RootPanel()
    root.wallpaper = image
    root.wallpaper_name = "image1"
    root.size.x, root.size.y = 600, 400
    root.pane_views = function() return { { draw = function() end } } end
    root.shell_views = function() return {} end
    root.begin_keyboard_caret_frame = function() end
    root.draw_keyboard_caret = function() end
    root.draw_active_app_overlay = function() end
    local previous = require("plugins.settings").config.theme or "dark"
    local old_rect, old_scaled = renderer.draw_rect, renderer.draw_canvas_scaled
    local backdrop
    renderer.draw_rect = function(_, _, _, _, color) backdrop = color end
    renderer.draw_canvas_scaled = function() end
    local ok, failure = pcall(function()
      local function visibility(theme)
        core.reload_module("colors." .. theme)
        test.ok(style.line_highlight[4] < 255, "the Color Theme must let the current line show the image")
        root:draw()
        return (1 - backdrop[4] / 255) * (1 - style.wallpaper_surface_opacity)
      end
      local ordinary = visibility("default")
      local near_black = visibility("dark2")
      local bright = visibility("light")
      test.ok(near_black > ordinary, "Dark2 needs more visible image detail")
      test.ok(bright > ordinary, "a light theme needs more visible image detail")
    end)
    core.reload_module("colors." .. (previous == "dark" and "default" or previous))
    renderer.draw_rect, renderer.draw_canvas_scaled = old_rect, old_scaled
    if not ok then error(failure, 0) end
  end)

  test.it("does not brighten the image while the window has no Pane View", function()
    local root = RootPanel()
    root.wallpaper = canvas.new(200, 100, { 40, 100, 80, 255 })
    root.wallpaper_name = "image1"
    root.size.x, root.size.y = 200, 100
    root.shell_views = function() return {} end
    root.begin_keyboard_caret_frame = function() end
    root.draw_keyboard_caret = function() end
    root.draw_active_app_overlay = function() end
    local old_rect, old_scaled = renderer.draw_rect, renderer.draw_canvas_scaled
    local fills = {}
    renderer.draw_rect = function(_, _, _, _, color) fills[#fills + 1] = color end
    renderer.draw_canvas_scaled = function() end
    local ok, err = pcall(function()
      root.pane_views = function() return {} end
      root:draw()
      local empty_visibility = 1 - fills[1][4] / 255

      fills = {}
      local view = View()
      view.size.x, view.size.y = 200, 100
      view.draw = function(self) self:draw_background(style.background) end
      root.pane_views = function() return { view } end
      root:draw()
      local loaded_visibility = (1 - fills[1][4] / 255) * (1 - fills[2][4] / 255)
      test.ok(math.abs(empty_visibility - loaded_visibility) <= 1 / 255,
        "the loading frame must not show more of the image")
    end)
    renderer.draw_rect, renderer.draw_canvas_scaled = old_rect, old_scaled
    if not ok then error(err, 0) end
  end)

  test.it("lets the image show through a View without fading its foreground colors", function()
    local view = View()
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 100, 80
    local old_rect = renderer.draw_rect
    local drawn
    renderer.draw_rect = function(_, _, _, _, color) drawn = color end
    local ok, err = pcall(function()
      view:draw_background(style.background)
      test.ok(drawn[4] > 0 and drawn[4] < 255)
      test.equal(drawn[1], style.background[1])
      test.equal(drawn[2], style.background[2])
      test.equal(drawn[3], style.background[3])
      test.equal(style.text[4] or 255, 255)
    end)
    renderer.draw_rect = old_rect
    if not ok then error(err, 0) end
  end)

  test.it("fills the window behind its Views without changing the image shape", function()
    local root = RootPanel()
    root.wallpaper = canvas.new(1200, 800, { 40, 100, 80, 255 })
    root.wallpaper_name = "image1"
    root.position.x, root.position.y = 0, 0
    local draws = {}
    root.pane_views = function()
      return { { draw = function() draws[#draws + 1] = "pane" end } }
    end
    root.shell_views = function()
      return { { draw = function() draws[#draws + 1] = "shell" end } }
    end
    root.begin_keyboard_caret_frame = function() end
    root.draw_keyboard_caret = function() end
    root.draw_active_app_overlay = function() end
    local old_scaled, old_rect = renderer.draw_canvas_scaled, renderer.draw_rect
    local rectangle
    renderer.draw_canvas_scaled = function(_, x, y, w, h)
      draws[#draws + 1] = "wallpaper"
      rectangle = { x, y, w, h }
    end
    renderer.draw_rect = function(_, _, _, _, color)
      draws[#draws + 1] = "backdrop"
      test.ok(color[4] > 0 and color[4] < 255)
    end

    local ok, err = pcall(function()
      root.size.x, root.size.y = 400, 600
      root:draw()
      test.same(draws, { "wallpaper", "backdrop", "pane", "shell" })
      near(rectangle[1], -250)
      near(rectangle[2], 0)
      near(rectangle[3], 900)
      near(rectangle[4], 600)

      draws = {}
      root.size.x, root.size.y = 1600, 900
      root:draw()
      test.same(draws, { "wallpaper", "backdrop", "pane", "shell" })
      near(rectangle[1], 0)
      near(rectangle[2], -83.3333)
      near(rectangle[3], 1600)
      near(rectangle[4], 1066.6667)
    end)
    renderer.draw_canvas_scaled, renderer.draw_rect = old_scaled, old_rect
    if not ok then error(err, 0) end
  end)
end)
