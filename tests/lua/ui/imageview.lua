local core = require "core"
local config = require "core.config"
local command = require "core.command"
local ImageComparisonView = require "core.imagecomparisonview"
local overlay = require "core.markdown.image_overlay"
local ImageView = require "core.imageview"
local test = require "core.test"

local function near(actual, expected)
  test.ok(math.abs(actual - expected) < 0.01,
    string.format("expected %.4f, got %.4f", expected, actual))
end

-- Observe image placement at the renderer boundary, without an OS window.
local function image_rect(view)
  local old_draw, old_scaled = renderer.draw_canvas, renderer.draw_canvas_scaled
  local rect
  renderer.draw_canvas = function(image, x, y)
    local w, h = image:get_size()
    rect = { x, y, w, h }
  end
  renderer.draw_canvas_scaled = function(_, x, y, w, h)
    rect = { x, y, w, h }
  end
  local ok, err = pcall(view.draw_image, view)
  renderer.draw_canvas, renderer.draw_canvas_scaled = old_draw, old_scaled
  if not ok then error(err, 0) end
  return test.not_nil(rect)
end

test.describe("Image View interaction", function()
  test.before_each(function(context)
    context.path = USERDIR .. PATHSEP .. "image-view-interaction.png"
    test.ok(canvas.new(1200, 800, { 40, 100, 180, 255 }, true):save_image(context.path))
    context.time = system.get_time
    context.transitions = config.transitions
    context.background = config.images_background_mode
    context.active_view = core.active_view
    context.now = 0
    system.get_time = function() return context.now end
    config.transitions = true
    config.images_background_mode = "none"
    context.view = ImageView(context.path)
    context.view.position.x, context.view.position.y = 30, 40
    context.view.size.x, context.view.size.y = 600, 400
    context.view:update()
  end)

  test.after_each(function(context)
    overlay.close()
    system.get_time = context.time
    config.transitions = context.transitions
    config.images_background_mode = context.background
    core.active_view = context.active_view
    os.remove(context.path)
  end)

  test.it("animates wheel zoom while keeping the pointed image pixel in place", function(context)
    local view = context.view
    local before = image_rect(view)
    local mx, my = 270, 200
    view:on_mouse_moved(mx, my, 0, 0)
    test.ok(view:on_mouse_wheel(1))
    view:update()
    local start = image_rect(view)
    near(start[3], before[3])

    context.now = 0.05
    view:update()
    local during = image_rect(view)
    context.now = 1
    view:update()
    local after = image_rect(view)
    test.ok(during[3] > before[3] and during[3] < after[3], "expected an intermediate image size")
    for _, rect in ipairs({ during, after }) do
      near((mx - rect[1]) / rect[3], (mx - before[1]) / before[3])
      near((my - rect[2]) / rect[4], (my - before[2]) / before[4])
    end
  end)

  test.it("fits the image through the command without a resize", function(context)
    local view = context.view
    config.transitions = false
    view:zoom_reset()
    core.active_view = view
    test.ok(command.perform("image:auto_fit"))
    view:update()
    local rect = image_rect(view)
    near(rect[3], 600)
    near(rect[4], 400)
  end)

  test.it("pans directly, clamps image edges, and stops when the pointer leaves", function(context)
    local view = context.view
    config.transitions = false
    view:zoom_reset()
    local before = image_rect(view)
    view:on_mouse_pressed("left", 250, 200, 1)
    view:on_mouse_moved(270, 230, 20, 30)
    local moved = image_rect(view)
    near(moved[1], before[1] + 20)
    near(moved[2], before[2] + 30)
    view:on_mouse_moved(10000, 10000, 10000, 10000)
    local clamped = image_rect(view)
    near(clamped[1], view.position.x)
    near(clamped[2], view.position.y)
    view:on_mouse_left()
    view:on_mouse_moved(200, 200, -100, -100)
    test.same(image_rect(view), clamped)
    view:on_mouse_pressed("right", 200, 200, 1)
    view:on_mouse_moved(100, 100, -100, -100)
    test.same(image_rect(view), clamped)
  end)

  test.it("switches between actual size and fit with a double click", function(context)
    local view = context.view
    config.transitions = false
    view:on_mouse_pressed("left", 270, 200, 2)
    near(image_rect(view)[3], 1200)
    view:on_mouse_released("left", 270, 200)
    view:on_mouse_pressed("left", 270, 200, 2)
    near(image_rect(view)[3], 600)
    view.size.x, view.size.y = 300, 200
    view:update()
    near(image_rect(view)[3], 300)
  end)

  test.it("continues zoom from the displayed image when another wheel event arrives", function(context)
    local view = context.view
    view:on_mouse_moved(270, 200, 0, 0)
    view:on_mouse_wheel(1)
    context.now = 0.05
    view:update()
    local before = image_rect(view)
    view:on_mouse_wheel(1)
    test.same(image_rect(view), before)
    context.now = 1
    view:update()
    test.ok(image_rect(view)[3] > before[3])
    config.transitions = false
    view:on_mouse_wheel(-100)
    near(image_rect(view)[3], 600)
    view:on_mouse_wheel(-100)
    near(image_rect(view)[3], 600)
    test.equal(view:on_mouse_wheel(0), false)
  end)

  test.it("restores the requested zoom and pan without sharing saved state", function(context)
    local view = context.view
    view:on_mouse_moved(270, 200, 0, 0)
    view:on_mouse_wheel(2)
    local state = view:get_state()
    local restored = test.not_nil(ImageView.from_state(state))
    restored.position.x, restored.position.y = view.position.x, view.position.y
    restored.size.x, restored.size.y = view.size.x, view.size.y
    restored:update()
    context.now = 1
    view:update()
    test.same(image_rect(restored), image_rect(view))
    local saved_x = state.scroll.x
    restored:on_mouse_pressed("left", 270, 200, 1)
    restored:on_mouse_moved(280, 200, 10, 0)
    test.equal(state.scroll.x, saved_x)
  end)

  test.it("uses source dimensions for actual size even with a very wide image", function(context)
    local view = context.view
    config.transitions = false
    view:set_image(canvas.new(20000, 20, { 40, 100, 180, 255 }, true), "Wide image")
    view:zoom_reset()
    local rect = image_rect(view)
    near(rect[3], 20000)
    near(rect[4], 20)
    test.ok(rect[1] <= view.position.x and rect[1] + rect[3] >= view.position.x + view.size.x)
  end)

  test.it("runs the visible fit and actual-size controls", function(context)
    local view = context.view
    config.transitions = false
    for _, action in ipairs({ "zoom_reset", "zoom_fit" }) do
      local clicked = false
      for _, item in ipairs(view:get_controls()) do
        if item.action == action then
          view:on_mouse_pressed("left", item.x + item.w / 2, item.y + item.h / 2, 1)
          view:on_mouse_released("left", item.x + item.w / 2, item.y + item.h / 2)
          clicked = true
          break
        end
      end
      test.ok(clicked)
      near(image_rect(view)[3], action == "zoom_reset" and 1200 or 600)
    end
  end)

  test.it("closes the Markdown overlay only when the click is outside the image and controls", function(context)
    config.transitions = false
    test.ok(overlay.open(context.path))
    local view = overlay.get_view()
    local x, y, w, h = view:get_image_rect()
    overlay.on_mouse_pressed("left", x + w / 2, y + h / 2, 1)
    overlay.on_mouse_released("left", x + w / 2, y + h / 2)
    test.ok(overlay.visible())
    for _, item in ipairs(view:get_controls()) do
      if item.action == "zoom_reset" then
        overlay.on_mouse_pressed("left", item.x + item.w / 2, item.y + item.h / 2, 1)
        test.ok(overlay.visible())
        near(view.zoom_scale, 1)
      end
    end
    overlay.on_mouse_pressed("left", core.root_panel.position.x, core.root_panel.position.y, 1)
    test.equal(overlay.visible(), false)
  end)

  test.it("keeps image comparisons aligned throughout zoom", function(context)
    local view = ImageComparisonView { left_path = context.path, right_path = context.path }
    view.size.x, view.size.y = 1000, 500
    view:update()
    local left, right = view.left_view, view.right_view
    local mx, my = left.position.x + left.size.x / 2, left.position.y + left.size.y / 2
    view:on_mouse_moved(mx, my, 0, 0)
    test.ok(view:on_mouse_wheel(1))
    for _, time in ipairs({ 0.05, 0.1, 1 }) do
      context.now = time
      view:update()
      local a, b = image_rect(left), image_rect(right)
      near(a[3], b[3])
      near(a[1] - left.position.x, b[1] - right.position.x)
    end
  end)

  test.it("animates the Markdown image overlay through the same wheel interaction", function(context)
    test.ok(overlay.open(context.path))
    local saved, rect = {}, nil
    for _, name in ipairs({ "draw_canvas_scaled", "draw_rect", "draw_rounded_rect", "draw_text", "set_clip_rect" }) do
      saved[name] = renderer[name]
      renderer[name] = function() return 0 end
    end
    renderer.draw_canvas_scaled = function(_, x, y, w, h) rect = { x, y, w, h } end
    local ok, err = pcall(function()
      overlay.draw()
      local before = test.not_nil(rect)
      local x, y = before[1] + before[3] / 2, before[2] + before[4] / 2
      overlay.on_mouse_moved(x, y, 0, 0)
      overlay.on_mouse_wheel(1, 0)
      overlay.draw()
      near(rect[3], before[3])
      context.now = 1
      core.root_panel:update()
      overlay.draw()
      test.ok(rect[3] > before[3])
      overlay.close()
      test.equal(overlay.visible(), false)
    end)
    for name, fn in pairs(saved) do renderer[name] = fn end
    if not ok then error(err, 0) end
  end)
end)
