local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local ImageComparisonView = require "core.imagecomparisonview"
local overlay = require "core.image_overlay"
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

  test.it("can zoom past actual size after a fit-to-actual-size animation", function(context)
    local view = context.view
    view.size.x, view.size.y = 210, 210
    view:set_image(canvas.new(1010, 1010, { 40, 100, 180, 255 }, true), "Square image")
    view:zoom_reset()
    context.now = 1
    view:update()
    near(image_rect(view)[3], 1010)
    test.ok(view:on_mouse_wheel(1))
    context.now = 2
    view:update()
    test.ok(image_rect(view)[3] > 1010, "zoom must not stop at actual size")
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

  test.it("zooms with the wheel while a modifier key is held", function(context)
    local keymap = require "core.keymap"
    local view = context.view
    config.transitions = false
    local before = image_rect(view)[3]
    keymap.modkeys.ctrl = true
    local ok, handled = pcall(view.on_mouse_wheel, view, 1)
    keymap.modkeys.ctrl = false
    if not ok then error(handled, 0) end
    test.ok(handled)
    test.ok(image_rect(view)[3] > before)
  end)

  test.it("enlarges a small image that fits at source size when double-clicked", function(context)
    local view = context.view
    config.transitions = false
    view:set_image(canvas.new(60, 40, { 40, 100, 180, 255 }, true), "Small image")
    near(image_rect(view)[3], 60)
    view:on_mouse_pressed("left", 330, 240, 2)
    near(image_rect(view)[4], 400)
    view:on_mouse_released("left", 330, 240)
    view:on_mouse_pressed("left", 330, 240, 2)
    near(image_rect(view)[3], 60)
  end)

  test.it("keeps a fast drag moving after release, but not a drag that stopped first", function(context)
    local view = context.view
    config.transitions = false
    view:zoom_reset()
    config.transitions = true
    local function drag(pause, dx)
      view:on_mouse_pressed("left", 300, 200, 1)
      for _ = 1, 3 do
        context.now = context.now + 0.01
        view:on_mouse_moved(300, 200, dx, 0)
      end
      context.now = context.now + pause
      view:on_mouse_released("left", 300, 200)
      local released = image_rect(view)[1]
      context.now = context.now + 0.02
      view:update()
      return released, image_rect(view)[1]
    end
    local released, later = drag(0, -10)
    test.ok(later < released, "a released fast drag keeps moving")
    for _ = 1, 200 do
      context.now = context.now + 0.02
      view:update()
    end
    local settled = image_rect(view)[1]
    context.now = context.now + 1
    view:update()
    near(image_rect(view)[1], settled)
    released, later = drag(0.5, 10)
    near(later, released)
  end)

  test.it("closes the Image Overlay on a backdrop click, but not on the image, the controls or a drag", function(context)
    config.transitions = false
    test.ok(overlay.open(context.path))
    local view = overlay.get_view()
    local function click(x, y, to_x, to_y)
      overlay.on_mouse_pressed("left", x, y, 1)
      if to_x then overlay.on_mouse_moved(to_x, to_y, to_x - x, to_y - y) end
      overlay.on_mouse_released("left", to_x or x, to_y or y)
    end
    local x, y, w, h = view:get_image_rect()
    click(x + w / 2, y + h / 2)
    test.ok(overlay.is_open())
    for _, item in ipairs(view:get_controls()) do
      if item.action == "zoom_reset" then
        click(item.x + item.w / 2, item.y + item.h / 2)
        test.ok(overlay.is_open())
        near(view.zoom_scale, 1)
      end
    end
    view:zoom_fit()
    local root = core.root_panel
    local bx, by = root.position.x + 2, root.position.y + root.size.y / 2
    test.equal(view:contains_image(bx, by), false)
    click(bx, by, bx + 100, by)
    test.ok(overlay.is_open(), "a drag from the backdrop must not close the overlay")
    click(bx, by)
    test.equal(overlay.is_open(), false)
  end)

  test.it("fits the overlay image between its top bar and its zoom controls", function(context)
    config.transitions = false
    test.ok(overlay.open(context.path))
    overlay.update()
    local view = overlay.get_view()
    local _, y, _, h = view:get_image_rect()
    local controls = test.not_nil(view:get_controls().rect)
    test.ok(y + h <= controls.y, "the fitted image must end above the zoom controls")
    for _, item in ipairs(view:get_controls()) do
      test.equal(view:contains_image(item.x + item.w / 2, item.y + item.h / 2), false)
    end
    test.ok(view:get_fit_scale() < 1)
    local root = core.root_panel
    test.ok(y > root.position.y + root.size.y * 0.02, "the top bar keeps space above the fitted image")
  end)

  test.it("keeps the overlay actions below the Title Bar", function(context)
    test.ok(overlay.open(context.path))
    local button = test.not_nil(overlay.button_rect("close"))
    local title = core.title_bar
    test.ok(title.size.y > 0)
    test.ok(button.y >= title.position.y + title.size.y, "actions must not cover Window controls")
  end)

  test.it("keeps the overlay image in place while opening and closing", function(context)
    test.ok(overlay.open(context.path))
    local view = overlay.get_view()
    local first = image_rect(view)
    context.now = 1
    overlay.update()
    test.same(image_rect(view), first)
    overlay.close()
    test.equal(overlay.is_open(), false)
    context.now = 1.05
    overlay.update()
    test.same(image_rect(view), first)
    context.now = 2
    overlay.update()
    test.same(image_rect(view), first)
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

  test.it("animates the Image Overlay through the same wheel interaction", function(context)
    test.ok(overlay.open(context.path))
    local saved, rect = {}, nil
    for _, name in ipairs({ "draw_canvas_scaled", "draw_rect", "draw_rounded_rect", "draw_text", "set_clip_rect",
      "push_transform", "pop_transform" }) do
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
      test.equal(overlay.is_open(), false)
      context.now = 2
      core.root_panel:update()
      overlay.draw()
    end)
    for name, fn in pairs(saved) do renderer[name] = fn end
    if not ok then error(err, 0) end
  end)
end)

test.describe("Image Overlay actions", function()
  test.before_each(function(context)
    context.root = USERDIR .. PATHSEP .. "image-overlay-actions-" .. system.get_process_id()
    test.ok(common.mkdirp(context.root))
    context.path = context.root .. PATHSEP .. "photo.png"
    test.ok(canvas.new(40, 30, { 200, 20, 20, 255 }, true):save_image(context.path))
    context.transitions = config.transitions
    config.transitions = false
    context.saved = {}
    for _, name in ipairs({ "set_clipboard_image", "show_in_folder", "open_in_system" }) do
      context.saved[name] = system[name]
    end
    context.calls = {}
    system.set_clipboard_image = function(image) context.calls.clipboard = image; return true end
    system.show_in_folder = function(path) context.calls.folder = path; return true end
    system.open_in_system = function(path) context.calls.opened = path; return true end
  end)

  test.after_each(function(context)
    overlay.close()
    for name, fn in pairs(context.saved) do system[name] = fn end
    config.transitions = context.transitions
    test.ok(test.remove_tree(context.root))
    if context.calls.opened and context.calls.opened ~= context.path then os.remove(context.calls.opened) end
  end)

  test.it("copies the image and shows a file in its folder", function(context)
    test.ok(overlay.open(context.path))
    test.ok(overlay.perform("copy"))
    test.equal(context.calls.clipboard, overlay.get_view().image)
    test.ok(overlay.perform("show_in_folder"))
    test.equal(context.calls.folder, context.path)
    test.ok(overlay.perform("open_external"))
    test.equal(context.calls.opened, context.path)
    test.ok(overlay.is_open())
  end)

  test.it("opens an image without a file through a temporary PNG", function(context)
    test.ok(overlay.open_image(canvas.new(20, 10, { 0, 200, 0, 255 }, true), { label = "Terminal image" }))
    test.equal(overlay.perform("show_in_folder"), false)
    test.equal(overlay.perform("open_in_pane"), false)
    test.ok(overlay.perform("open_external"))
    local opened = test.not_nil(context.calls.opened)
    local image = test.not_nil(canvas.load_image(opened))
    test.same({ image:get_size() }, { 20, 10 })
  end)

  test.it("saves a file copy for the same extension and encodes other formats", function(context)
    test.ok(overlay.open(context.path))
    local copy = context.root .. PATHSEP .. "copy.png"
    test.ok(overlay.save_to(copy))
    local function read(path)
      local file = test.not_nil(io.open(path, "rb"))
      local data = file:read("*a")
      file:close()
      return data
    end
    test.equal(read(copy), read(context.path))
    local jpeg = context.root .. PATHSEP .. "copy.jpg"
    test.ok(overlay.save_to(jpeg))
    test.same({ test.not_nil(canvas.load_image(jpeg)):get_size() }, { 40, 30 })
    test.equal(overlay.save_to(context.root .. PATHSEP .. "copy.txt"), false)
  end)

  test.it("opens the image file in a Pane and closes the overlay", function(context)
    local old_open_file = core.open_file
    local opened
    core.open_file = function(path) opened = path; return true end
    local ok, err = pcall(function()
      test.ok(overlay.open(context.path))
      test.ok(overlay.perform("open_in_pane"))
      test.equal(opened, context.path)
      test.equal(overlay.is_open(), false)
    end)
    core.open_file = old_open_file
    if not ok then error(err, 0) end
  end)
end)

-- 2x2 GIF: red for 50 ms, green for 100 ms, blue for 150 ms, looping.
local THREE_FRAME_GIF_BASE64 = "R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQEBQAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQECgAAACwAAAAAAgACAIEA/wAAAAAAAAAAAAAIBgABCAQQEAAh+QQEDwAAACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7"

local function drawn_color(view)
  local old_scaled = renderer.draw_canvas_scaled
  local color
  renderer.draw_canvas_scaled = function(image)
    local r, g, b = image:get_pixels(0, 0, 1, 1):byte(1, 3)
    color = r > 200 and "red" or g > 200 and "green" or b > 200 and "blue" or "other"
  end
  local ok, err = pcall(view.draw_image, view)
  renderer.draw_canvas_scaled = old_scaled
  if not ok then error(err, 0) end
  return color
end

test.describe("Image View animations", function()
  test.before_each(function(context)
    local images = require "core.markdown.images"
    context.url = "data:image/gif;base64," .. THREE_FRAME_GIF_BASE64
    context.path = USERDIR .. PATHSEP .. "image-view-animation.gif"
    local file = test.not_nil(io.open(context.path, "wb"))
    file:write(test.not_nil(images.decode_data_image(context.url)))
    file:close()
    context.time = system.get_time
    context.background = config.images_background_mode
    context.now = 1000
    system.get_time = function() return context.now end
    config.images_background_mode = "none"
  end)

  test.after_each(function(context)
    overlay.close()
    require("core.image_animation").close_all()
    require("core.markdown.images").clear_assets()
    system.get_time = context.time
    config.images_background_mode = context.background
    os.remove(context.path)
  end)

  test.it("plays an animated GIF file", function(context)
    local view = ImageView(context.path)
    view.size.x, view.size.y = 200, 200
    view:update()
    test.equal(drawn_color(view), "red")
    context.now = context.now + 0.05
    test.equal(drawn_color(view), "green")
    context.now = context.now + 0.1
    test.equal(drawn_color(view), "blue")
  end)

  test.it("plays an embedded Markdown GIF in the image overlay", function(context)
    local images = require "core.markdown.images"
    local entry = images.get_asset(context.url)
    test.ok(overlay.open_image(entry.image, {
      label = "Embedded image", open_animation = function() return images.open_animation(entry) end,
    }))
    local view = test.not_nil(overlay.get_view())
    test.equal(drawn_color(view), "red")
    context.now = context.now + 0.05
    test.equal(drawn_color(view), "green")
  end)
end)
