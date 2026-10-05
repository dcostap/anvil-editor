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
      or color == style.diff_modify_background
      or color == style.diff_modify_inline
      or color == style.diff_insert_inline or color == style.diff_delete_inline then
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

test.describe("Diff View change backgrounds", function()
  test.before_each(function(context)
    context.views = {}
    context.active_view = core.active_view
    context.plain_text = config.plugins.diffview.plain_text
    context.whitespace_mode = config.plugins.diffview.whitespace_mode
    context.unified_width_threshold = config.plugins.diffview.unified_width_threshold
    config.plugins.diffview.unified_width_threshold = 0
    config.plugins.diffview.plain_text = false
    config.plugins.diffview.whitespace_mode = "none"
  end)

  test.after_each(function(context)
    config.plugins.diffview.plain_text = context.plain_text
    config.plugins.diffview.whitespace_mode = context.whitespace_mode
    config.plugins.diffview.unified_width_threshold = context.unified_width_threshold
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
          local changed_color = reverse and style.diff_delete_inline or style.diff_insert_inline
          local line_color = style.diff_modify_background
          local other_color = style.diff_modify_background
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
            test.same(color_at(side.position.x + added_width + 1, y + 1), line_color)
          end
          local other_color_at = backgrounds(other, 2)
          local _, y = other:get_line_screen_position(2)
          test.same(other_color_at(other.position.x + 1, y + 1), other_color)
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
    test.same(color_at(side.position.x + width / 4, y + 1), style.diff_insert_inline)
    test.same(color_at(side.position.x + width, y + 1), style.diff_modify_background)

    side.scroll.x = width * 2
    color_at = backgrounds(side, 1)
    test.same(color_at(side.position.x + 1, y + 1), style.diff_modify_background)
    test.same(color_at(side.position.x + side.size.x - 1, y + 1), style.diff_modify_background)
  end)

  test.it("distinguishes modified lines from their replaced words in both layouts", function(context)
    local view = open_diff(context, "top\nprivate const val LIMIT = 2_000\nbottom",
      "top\nprivate const val LIMIT = 1_500\nbottom", false)
    local function check(surface, line, word_color)
      local color_at = backgrounds(surface, line)
      local x, y = surface:get_line_screen_position(line, 1)
      test.same(color_at(x + 1, y + 1), style.diff_modify_background)
      x, y = surface:get_line_screen_position(line, 27)
      test.same(color_at(x + 1, y + 1), word_color)
    end
    check(view.buffer_view_a, 2, style.diff_modify_inline)
    check(view.buffer_view_b, 2, style.diff_modify_inline)

    config.plugins.diffview.unified_width_threshold = 10000
    view:update()
    local unified = view:get_focus_view()
    test.equal(unified.buffer.lines[2], "private const val LIMIT = 2_000\n")
    test.equal(unified.buffer.lines[3], "private const val LIMIT = 1_500\n")
    check(unified, 2, style.diff_modify_inline)
    check(unified, 3, style.diff_modify_inline)
  end)

  test.it("uses replacement colors for a comma changed to an arrow without recoloring pure additions", function(context)
    local before = '2 -> "${vehiculos.first()}, ${vehiculos.last()}"\n'
      .. 'else -> "${vehiculos.first()} ➜ ${vehiculos.last()} (${vehiculos.size})"'
    local after = '2 -> "${vehiculos.first()} ➜ ${vehiculos.last()}"\n'
      .. 'else -> "${vehiculos.first()} ➜ (...) ➜ ${vehiculos.last()} (${vehiculos.size})"'
    local function check(surface, line, text, expected)
      local col = surface.buffer.lines[line]:find(text, 1, true)
      test.ok(col, "fixture must contain the changed separator")
      local color_at = backgrounds(surface, line)
      local x, y = surface:get_line_screen_position(line, col)
      test.same(color_at(x + 1, y + 1), expected)
    end
    local function check_markers(surface, line, markers)
      test.ok(#markers > 0, "the retained arrow must show the insertion position")
      local color_at = backgrounds(surface, line)
      for _, marker in ipairs(markers) do
        local x, y = surface:get_line_screen_position(line, marker.col)
        test.same(color_at(x + style.caret_width / 2, y + 1), style.diff_insert_inline)
      end
    end
    for _, mode in ipairs { "none", "trim", "ignore" } do
      config.plugins.diffview.whitespace_mode = mode
      config.plugins.diffview.unified_width_threshold = 0
      local view = open_diff(context, before, after, false)
      check(view.buffer_view_a, 1, ",", style.diff_modify_inline)
      check(view.buffer_view_b, 1, "➜", style.diff_modify_inline)
      check(view.buffer_view_b, 2, "(...)", style.diff_insert_inline)
      local markers = view.diff_model:inline_markers("a", 2)
      check_markers(view.buffer_view_a, 2, markers)
      config.plugins.diffview.unified_width_threshold = 10000
      view:update()
      local unified = view:get_focus_view()
      check(unified, 1, ",", style.diff_modify_inline)
      check(unified, 3, "➜", style.diff_modify_inline)
      check(unified, 4, "(...)", style.diff_insert_inline)
      check_markers(unified, 2, markers)
    end
  end)

  test.it("shows an inline addition or deletion marker on the unchanged side in both layouts", function(context)
    for _, mode in ipairs { "none", "trim", "ignore" } do
      for _, wrapped in ipairs { false, true } do
        for _, reverse in ipairs { false, true } do
          config.plugins.diffview.whitespace_mode = mode
          config.plugins.diffview.unified_width_threshold = 0
          local prefix = wrapped and string.rep("keep ", 20) or ""
          local short, expanded = prefix .. "head tail", prefix .. "head extra tail"
          local before, after = short, expanded
          if reverse then before, after = after, before end
          local view = open_diff(context, before, after, wrapped)
          local side = reverse and view.buffer_view_b or view.buffer_view_a
          local col = #prefix + 6
          local expected = reverse and style.diff_delete_inline or style.diff_insert_inline
          local function check(surface, line)
            local color_at = backgrounds(surface, line)
            local x, y = surface:get_line_screen_position(line, col)
            test.same(color_at(x + style.caret_width / 2, y + 1), expected)
          end
          if wrapped then test.ok(side:get_visual_row_count_for_line(1) > 1, "fixture must wrap") end
          test.equal(table.concat(side.buffer.lines), short .. "\n")
          check(side, 1)
          config.plugins.diffview.unified_width_threshold = 10000
          view:update()
          check(view:get_focus_view(), reverse and 2 or 1)
        end
      end
    end
  end)

  test.it("emphasizes deleted comments and added expressions without emphasizing retained code", function(context)
    local before = "OUTER APPLY (\n    -- removed explanation\n    SELECT ISNULL(SUM(m.Unidades), 0) AS UnidadesServidas\nFROM stock"
    local after = "OUTER APPLY (\n    SELECT\n        ISNULL(SUM(m.Unidades), 0) AS UnidadesServidas,\n        MAX(m.Fecha) AS FechaUltimoServicio\nFROM stock"
    local view = open_diff(context, before, after, false)
    local function check(surface, line, col, expected)
      local color_at = backgrounds(surface, line)
      local x, y = surface:get_line_screen_position(line, col)
      test.same(color_at(x + 1, y + 1), expected)
    end
    check(view.buffer_view_a, 2, 5, style.diff_delete_inline)
    check(view.buffer_view_b, 4, 9, style.diff_insert_inline)
    check(view.buffer_view_b, 3, 9, style.diff_delete_inline)
    check(view.buffer_view_b, 3, 12, style.diff_modify_background)
    -- Text emphasis ends with the content, not at the edge of the surface.
    check(view.buffer_view_b, 4, #view.buffer_view_b.buffer.lines[4], style.diff_modify_background)

    config.plugins.diffview.unified_width_threshold = 10000
    view:update()
    local unified = view:get_focus_view()
    test.ok(unified ~= view.buffer_view_a and unified ~= view.buffer_view_b)
    local found_comment, found_expression = false, false
    for line, text in ipairs(unified.buffer.lines) do
      if text:find("-- removed explanation", 1, true) then
        found_comment = true
        check(unified, line, 5, style.diff_delete_inline)
      elseif text:find("MAX(m.Fecha)", 1, true) then
        found_expression = true
        check(unified, line, 9, style.diff_insert_inline)
      end
    end
    test.ok(found_comment and found_expression, "Unified Diff must show both changed lines")
  end)

  test.it("keeps mixed-block text emphasis across wrapped rows", function(context)
    local text = "top\n    -- " .. string.rep("removed explanation ", 12) .. "\nvalue = 1\nbottom"
    for _, reverse in ipairs { false, true } do
      local before, after = text, "top\nvalue = 2\nbottom"
      if reverse then before, after = after, before end
      local view = open_diff(context, before, after, true)
      local side = reverse and view.buffer_view_b or view.buffer_view_a
      local color = reverse and style.diff_insert_inline or style.diff_delete_inline
      local rows = side:get_visual_row_count_for_line(2)
      test.ok(rows > 1, "fixture must wrap")
      local color_at = backgrounds(side, 2)
      for row = 1, rows do
        local col = side:get_visual_row_bounds_for_line(2, row)
        local x, y = side:get_line_screen_position(2, math.max(5, col))
        test.same(color_at(x + 1, y + 1), color)
      end
    end
  end)

  test.it("fills fully added and deleted blocks uniformly in both layouts", function(context)
    local text = "top\n    added code\n\n    more code\nbottom"
    for _, reverse in ipairs { false, true } do
      for _, wrapped in ipairs { false, true } do
        config.plugins.diffview.unified_width_threshold = 0
        local before, after = text, "top\nbottom"
        if reverse then before, after = after, before end
        local view = open_diff(context, before, after, wrapped)
        local side = reverse and view.buffer_view_b or view.buffer_view_a
        local expected = reverse and style.diff_insert_background or style.diff_delete_background
        local function check(surface)
          for line = 2, 4 do
            local color_at = backgrounds(surface, line)
            for _, col in ipairs { 1, 5, #surface.buffer.lines[line] } do
              local x, y = surface:get_line_screen_position(line, col)
              test.same(color_at(x + 1, y + 1), expected)
            end
          end
        end
        check(side)
        config.plugins.diffview.unified_width_threshold = 10000
        view:update()
        local unified = view:get_focus_view()
        test.equal(unified.buffer.lines[2], "    added code\n")
        check(unified)
      end
    end
  end)
end)
