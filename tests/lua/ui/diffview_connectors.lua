local core = require "core"
local config = require "core.config"
local style = require "core.style"
local test = require "core.test"
local diffview = require "plugins.diffview"

local function open_diff(context, before, after)
  local view = diffview.string_to_string(before, after, "Before", "After", true)
  context.views[#context.views + 1] = view
  local deadline = system.get_time() + 2
  while view.updater_idx do
    test.ok(system.get_time() < deadline, "diff computation did not finish")
    coroutine.yield(0.01)
  end
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 800, 600
  view.buffer_view_a:set_wrapping_enabled(false)
  view.buffer_view_b:set_wrapping_enabled(false)
  view:update()
  return view
end

local function render_changes(view)
  local rects, polygons = {}, {}
  local old_rect, old_poly = renderer.draw_rect, renderer.draw_poly
  local old_clip, old_text = renderer.set_clip_rect, renderer.draw_text
  renderer.set_clip_rect = function() end
  renderer.draw_text = function(font, text, x, y, color, opts)
    return x + font:get_width(text, opts)
  end
  renderer.draw_rect = function(x, y, w, h, color)
    rects[#rects + 1] = { x = x, y = y, w = w, h = h, color = color }
  end
  renderer.draw_poly = function(points, color)
    polygons[#polygons + 1] = { points = points, color = color }
  end
  local ok, err = pcall(function() view:draw_divider_changes() end)
  renderer.draw_rect, renderer.draw_poly = old_rect, old_poly
  renderer.set_clip_rect, renderer.draw_text = old_clip, old_text
  if not ok then error(err, 0) end
  return rects, polygons
end

test.describe("Diff View one-sided change positions", function()
  test.before_each(function(context)
    context.views = {}
    context.active_view = core.active_view
    context.ignore_whitespace = config.plugins.diffview.ignore_whitespace
    config.plugins.diffview.ignore_whitespace = false
  end)

  test.after_each(function(context)
    config.plugins.diffview.ignore_whitespace = context.ignore_whitespace
    core.active_view = context.active_view
    for _, view in ipairs(context.views) do view:on_close() end
  end)

  for _, reverse in ipairs { false, true } do
    for _, at_end in ipairs { false, true } do
      test.it((reverse and "deletion" or "insertion")
        .. " points to the opposite boundary " .. (at_end and "at EOF" or "before retained text"), function(context)
        local before = "start\nanchor\ntail"
        local after = at_end and "start\nfirst\nsecond\nanchor\ntail\nadded"
          or "start\nfirst\nsecond\nanchor\nadded\ntail"
        if reverse then before, after = after, before end
        local view = open_diff(context, before, after)
        local opposite = reverse and view.buffer_view_b or view.buffer_view_a
        local changed = reverse and view.buffer_view_a or view.buffer_view_b
        local _, expected_y = opposite:get_line_screen_position(3)
        if at_end then expected_y = expected_y + opposite:get_line_height() end
        local _, changed_y = changed:get_line_screen_position(at_end and 6 or 5)
        test.ok(math.abs(expected_y - changed_y) > 1, "fixture must have different side offsets")

        local rects, polygons = render_changes(view)
        local marker_color = reverse and style.diff_marker_delete or style.diff_marker_insert
        local background = reverse and style.diff_delete_background or style.diff_insert_background
        local marker_found, connector_found = false, false
        for _, rect in ipairs(rects) do
          if rect.color and rect.color[1] == marker_color[1]
            and rect.color[2] == marker_color[2] and rect.color[3] == marker_color[3]
            and rect.x == opposite.position.x + opposite:get_gutter_width()
            and math.abs(rect.y + rect.h / 2 - expected_y) < 0.01 then
            marker_found = true
          end
        end
        local edge_x = reverse and opposite.position.x or opposite.position.x + opposite.size.x
        for _, polygon in ipairs(polygons) do
          if polygon.color == background then
            for _, point in ipairs(polygon.points) do
              if math.abs(point[1] - edge_x) < 0.01 and math.abs(point[2] - expected_y) < 0.01 then
                connector_found = true
              end
            end
          end
        end
        test.ok(marker_found, "missing marker at the opposite text boundary")
        test.ok(connector_found, "missing connector at the opposite text boundary")
      end)
    end
  end
end)
