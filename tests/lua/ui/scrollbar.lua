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

test.describe("Scrollbar hover rendering", function()
  test.it("shows thumb feedback when hovering the rendered scrollbar lane", function()
    local old_scrollbar_color = style.scrollbar
    style.scrollbar = { 10, 20, 30, 200 }

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

    test.ok(track_hover[1] > normal[1], "expected visible feedback over the rendered scrollbar lane")
    test.same(track_hover, thumb_hover)
    test.ok(dragging[4] > thumb_hover[4], "expected stronger feedback while clicking/dragging")
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
