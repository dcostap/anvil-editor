local Scrollbar = require "core.scrollbar"
local core = require "core"
local style = require "core.style"
local test = require "core.test"

local function capture_thumb_color(scrollbar)
  local captured
  local old_draw_rounded_rect = renderer.draw_rounded_rect
  renderer.draw_rounded_rect = function(_, _, _, _, _, color)
    captured = { color[1], color[2], color[3], color[4] }
  end
  scrollbar:draw_thumb()
  renderer.draw_rounded_rect = old_draw_rounded_rect
  return captured
end

local function make_scrollbar()
  local scrollbar = Scrollbar({ direction = "v", alignment = "e" })
  scrollbar:set_size(0, 0, 100, 100, 1000)
  return scrollbar
end

test.describe("Scrollbar native window inset", function()
  local function with_native_metrics(context, metrics)
    context.old_window = core.window
    context.old_root_panel = core.root_panel
    context.old_window_mode = core.window_mode
    context.old_metrics = system.get_window_frame_metrics
    context.old_frame_active = core.render_frame_active
    context.old_frame_id = core.render_frame_id
    core.window = {}
    core.root_panel = { position = { x = 0, y = 0 }, size = { x = 100, y = 100 } }
    core.window_mode = "normal"
    system.get_window_frame_metrics = metrics
    core.render_frame_active = true
    core.render_frame_id = 900001
  end

  local function restore_native_metrics(context)
    core.render_frame_active = context.old_frame_active
    core.render_frame_id = context.old_frame_id
    core.window = context.old_window
    core.root_panel = context.old_root_panel
    core.window_mode = context.old_window_mode
    system.get_window_frame_metrics = context.old_metrics
  end

  test.it("reads native window metrics once per redraw frame", function(context)
    local border = 4
    with_native_metrics(context, function()
      border = border + 2
      return 0, 0, border
    end)

    local scrollbar = make_scrollbar()
    local first_draw = { scrollbar:get_track_rect() }
    local repeated = { scrollbar:get_track_rect() }

    core.render_frame_id = 900002
    local next_frame = { scrollbar:get_track_rect() }
    restore_native_metrics(context)

    test.same(first_draw, repeated, "one frame must reuse one window metric query")
    test.ok(next_frame[1] < first_draw[1],
      "the next redraw frame must adopt the new native border")
  end)

  test.it("rereads native window metrics outside a redraw frame", function(context)
    local border = 4
    with_native_metrics(context, function()
      border = border + 2
      return 0, 0, border
    end)
    core.render_frame_active = false
    core.render_frame_id = nil

    local scrollbar = make_scrollbar()
    local first = { scrollbar:get_track_rect() }
    local second = { scrollbar:get_track_rect() }
    restore_native_metrics(context)

    test.ok(second[1] < first[1],
      "queries outside a redraw frame must not reuse a stale border")
  end)
end)

test.describe("Scrollbar hover rendering", function()
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

    test.ok(tx + tw < core.root_panel.size.x, "expected the scrollbar to stay inside the resize border")
    test.ok(tx + tw > core.root_panel.position.x, "expected the scrollbar to retain a visible track")
    test.equal(edge_result, false)
    test.ok(track_result, "expected the inset visible scrollbar to hover normally")
    test.ok(track_hover, "expected visual hover on the inset scrollbar")
  end)
end)
