local Scrollbar = require "core.scrollbar"
local core = require "core"
local style = require "core.style"
local test = require "core.test"

local function capture_thumb_color(scrollbar)
  local captured
  local old_draw_rect = renderer.draw_rect
  renderer.draw_rect = function(_, _, _, _, color)
    captured = { color[1], color[2], color[3], color[4] }
  end
  scrollbar:draw_thumb()
  renderer.draw_rect = old_draw_rect
  return captured
end

local function make_scrollbar()
  local scrollbar = Scrollbar({ direction = "v", alignment = "e" })
  scrollbar:set_size(0, 0, 100, 100, 1000)
  return scrollbar
end

local function with_style_snapshot(fn)
  local snapshot = {}
  for k, v in pairs(style) do snapshot[k] = v end
  local ok, err = xpcall(fn, debug.traceback)
  for k in pairs(style) do style[k] = nil end
  for k, v in pairs(snapshot) do style[k] = v end
  if not ok then error(err, 0) end
end

test.describe("Scrollbar hover rendering", function()
  test.it("shows thumb feedback when hovering the rendered scrollbar lane", function()
    local old_scrollbar_color = style.scrollbar
    local old_scrollbar_hover = style.scrollbar_hover
    local old_scrollbar_active = style.scrollbar_active
    style.scrollbar = { 10, 20, 30, 200 }
    style.scrollbar_hover = { 50, 60, 70, 200 }
    style.scrollbar_active = { 90, 100, 110, 200 }

    local scrollbar = make_scrollbar()
    local normal = capture_thumb_color(scrollbar)

    local tx, ty, tw, th = scrollbar:get_track_rect()
    scrollbar:on_mouse_moved(tx + tw / 2, ty + th - 1, 0, 0)
    local track_hover = capture_thumb_color(scrollbar)

    local _, thumb_y, _, thumb_h = scrollbar:get_thumb_rect()
    scrollbar:on_mouse_moved(tx + tw / 2, thumb_y + thumb_h / 2, 0, 0)
    local thumb_hover = capture_thumb_color(scrollbar)

    scrollbar.dragging = true
    local dragging = capture_thumb_color(scrollbar)

    style.scrollbar = old_scrollbar_color
    style.scrollbar_hover = old_scrollbar_hover
    style.scrollbar_active = old_scrollbar_active

    test.ok(track_hover[1] > normal[1], "expected visible color feedback over the rendered scrollbar lane")
    test.ok(track_hover[4] > normal[4], "expected visible opacity feedback over the rendered scrollbar lane")
    test.same(track_hover, thumb_hover)
    test.ok(dragging[1] > thumb_hover[1], "expected stronger color feedback while clicking/dragging")
    test.ok(dragging[4] > thumb_hover[4], "expected stronger opacity feedback while clicking/dragging")
  end)

  test.it("keeps light theme hover and pressed states distinct", function()
    with_style_snapshot(function()
      package.loaded["colors.default"] = nil
      package.loaded["colors.light"] = nil
      require "colors.default"
      require "colors.light"

      local scrollbar = make_scrollbar()
      local normal = capture_thumb_color(scrollbar)

      local tx, ty, tw, th = scrollbar:get_track_rect()
      scrollbar:on_mouse_moved(tx + tw / 2, ty + th - 1, 0, 0)
      local hover = capture_thumb_color(scrollbar)

      scrollbar.dragging = true
      local dragging = capture_thumb_color(scrollbar)

      test.ok(hover[1] < normal[1], "expected light-theme hover color to darken the thumb")
      test.ok(hover[4] > normal[4], "expected light-theme hover opacity to increase")
      test.ok(dragging[1] < hover[1], "expected light-theme pressed color to darken beyond hover")
      test.ok(dragging[4] > hover[4], "expected light-theme pressed opacity to increase beyond hover")
    end)
  end)

  test.it("does not keep hover feedback in the invisible leading hitbox padding", function()
    local old_scrollbar_color = style.scrollbar
    local old_hitbox_padding = style.scrollbar_hitbox_leading_padding
    style.scrollbar = { 10, 20, 30, 200 }
    style.scrollbar_hitbox_leading_padding = 4

    local scrollbar = make_scrollbar()
    local normal = capture_thumb_color(scrollbar)

    local tx, ty, _, th = scrollbar:get_track_rect()
    local result = scrollbar:on_mouse_moved(tx - 2, ty + th - 1, 0, 0)
    scrollbar:update()
    local hitbox_only = capture_thumb_color(scrollbar)

    style.scrollbar = old_scrollbar_color
    style.scrollbar_hitbox_leading_padding = old_hitbox_padding

    test.ok(result, "expected the padded hitbox to remain interactive")
    test.same(normal, hitbox_only)
  end)

  test.it("insets the visible outer-edge scrollbar outside the native resize border", function()
    local old_window = core.window
    local old_root_panel = core.root_panel
    local old_window_mode = core.window_mode
    local old_get_window_frame_metrics = system.get_window_frame_metrics

    core.window = {}
    core.root_panel = { position = { x = 0, y = 0 }, size = { x = 100, y = 100 } }
    core.window_mode = "normal"
    system.get_window_frame_metrics = function() return 0, 0, 12 end

    local scrollbar = make_scrollbar()
    local tx, ty, tw, th = scrollbar:get_track_rect()
    local edge_result = scrollbar:on_mouse_moved(99, ty + th - 1, 0, 0)
    local track_result = scrollbar:on_mouse_moved(tx + tw / 2, ty + th - 1, 0, 0)
    local track_hover = scrollbar.hovering.visual_track

    core.window = old_window
    core.root_panel = old_root_panel
    core.window_mode = old_window_mode
    system.get_window_frame_metrics = old_get_window_frame_metrics

    test.equal(tx + tw, 84)
    test.equal(edge_result, false)
    test.ok(track_result, "expected the inset visible scrollbar to hover normally")
    test.ok(track_hover, "expected visual hover on the inset scrollbar")
  end)
end)
