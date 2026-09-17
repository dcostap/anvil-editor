local core = require "core"
local config = require "core.config"
local style = require "core.style"
local test = require "core.test"
local diffview = require "plugins.diffview"

local function open_diff(context, before, after, wrapped)
  local view = diffview.string_to_string(before, after, "Before", "After", true)
  context.views[#context.views + 1] = view
  local deadline = system.get_time() + 2
  while view.updater_idx do
    test.ok(system.get_time() < deadline, "diff computation did not finish")
    coroutine.yield(0.01)
  end
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 800, 600
  view.buffer_view_a:set_wrapping_enabled(wrapped)
  view.buffer_view_b:set_wrapping_enabled(wrapped)
  view:update()
  return view
end

-- Observe the rendered background at a point, not the number of draw calls.
local function backgrounds(side, line)
  local rects = {}
  local old_rect, old_text = renderer.draw_rect, renderer.draw_text
  local old_grid = renderer.draw_rect_grid
  local old_known_text = renderer.draw_text_known_bounds
  renderer.draw_rect_grid = function() end
  renderer.draw_text_known_bounds = function() end
  renderer.draw_rect = function(x, y, w, h, color)
    if color == style.diff_insert_background or color == style.diff_delete_background
      or color == style.diff_modify_background then
      rects[#rects + 1] = { x = x, y = y, w = w, h = h, color = color }
    end
  end
  renderer.draw_text = function(font, text, x, y, color, opts)
    return x + font:get_width(text, opts)
  end
  local ok, err = pcall(function()
    local x, y = side:get_line_screen_position(line)
    side:draw_line_body(line, x, y)
  end)
  renderer.draw_rect, renderer.draw_text = old_rect, old_text
  renderer.draw_rect_grid = old_grid
  renderer.draw_text_known_bounds = old_known_text
  if not ok then error(err, 0) end
  return function(x, y)
    local color
    for _, rect in ipairs(rects) do
      if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
        color = rect.color
      end
    end
    return color
  end
end

test.describe("Diff View indentation backgrounds", function()
  test.before_each(function(context)
    context.views = {}
    context.active_view = core.active_view
    context.plain_text = config.plugins.diffview.plain_text
    context.whitespace_mode = config.plugins.diffview.whitespace_mode
    config.plugins.diffview.plain_text = false
    config.plugins.diffview.whitespace_mode = "none"
  end)

  test.after_each(function(context)
    config.plugins.diffview.plain_text = context.plain_text
    config.plugins.diffview.whitespace_mode = context.whitespace_mode
    core.active_view = context.active_view
    for _, view in ipairs(context.views) do view:on_close() end
  end)

  test.it("separates changed indentation from retained code on every visual row", function(context)
    local body = "call(firstArgument, secondArgument, thirdArgument, fourthArgument, fifthArgument)"
    for _, indent in ipairs { "    ", "\t" } do
      for _, wrapped in ipairs { false, true } do
        for _, reverse in ipairs { false, true } do
          local before, after = "before\n" .. indent .. body .. "\nafter",
            "before\n" .. indent .. indent .. body .. "\nafter"
          if reverse then before, after = after, before end
          local view = open_diff(context, before, after, wrapped)
          local side = reverse and view.buffer_view_a or view.buffer_view_b
          local other = reverse and view.buffer_view_b or view.buffer_view_a
          local changed_color = reverse and style.diff_delete_background or style.diff_insert_background
          local font = side:get_font()
          local _, indent_size = side.buffer:get_indent_info()
          font:set_tab_size(indent_size)
          local added_width = font:get_width(indent)
          local color_at = backgrounds(side, 2)
          local rows = side:get_visual_row_count_for_line(2)
          if wrapped then test.ok(rows > 1, "fixture must wrap") end
          for row = 1, rows do
            local col = side:get_visual_row_bounds_for_line(2, row)
            local _, y = side:get_line_screen_position(2, col)
            test.same(color_at(side.position.x + added_width / 2, y + 1), changed_color)
            test.same(color_at(side.position.x + added_width + 1, y + 1), style.diff_modify_background)
          end
          local other_color_at = backgrounds(other, 2)
          local _, y = other:get_line_screen_position(2)
          test.same(other_color_at(other.position.x + 1, y + 1), style.diff_modify_background)
        end
      end
    end
  end)

  test.it("scrolls the changed indentation band with the text", function(context)
    local body = "call(" .. string.rep("argument, ", 30) .. "lastArgument)"
    local view = open_diff(context, "    " .. body, "        " .. body, false)
    local side = view.buffer_view_b
    local width = side:get_font():get_width("    ")
    side.scroll.x = width / 2
    local color_at = backgrounds(side, 1)
    local _, y = side:get_line_screen_position(1)
    test.same(color_at(side.position.x + width / 4, y + 1), style.diff_insert_background)
    test.same(color_at(side.position.x + width, y + 1), style.diff_modify_background)

    side.scroll.x = width * 2
    color_at = backgrounds(side, 1)
    test.same(color_at(side.position.x + 1, y + 1), style.diff_modify_background)
    test.same(color_at(side.position.x + side.size.x - 1, y + 1), style.diff_modify_background)
  end)
end)
