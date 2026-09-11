local core = require "core"
local config = require "core.config"
local test = require "core.test"
local diffview = require "plugins.diffview"
local style = require "core.style"

local function wait_for_diff(view)
  local deadline = system.get_time() + 10
  while view.updater_idx do
    test.ok(system.get_time() < deadline, "diff computation did not finish")
    coroutine.yield(0.01)
  end
end

local function open_diff(context, before, after)
  local view = diffview.string_to_string(before, after, "Before", "After", true)
  context.views[#context.views + 1] = view
  wait_for_diff(view)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 800, 300
  view.buffer_view_a:set_wrapping_enabled(false)
  view.buffer_view_b:set_wrapping_enabled(false)
  view:update()
  return view
end

local function capture(view, method)
  local polygons, rects, saved = {}, {}, {}
  for _, name in ipairs { "draw_poly", "draw_rect", "draw_rounded_rect", "draw_text", "set_clip_rect" } do
    saved[name] = renderer[name]
    renderer[name] = function() return 0 end
  end
  renderer.draw_poly = function(points, color)
    polygons[#polygons + 1] = { points = points, color = color }
  end
  renderer.draw_rect = function(x, y, w, h, color)
    rects[#rects + 1] = { x = x, y = y, w = w, h = h, color = color }
  end
  local ok, err = pcall(function() view[method](view) end)
  for name, fn in pairs(saved) do renderer[name] = fn end
  if not ok then error(err, 0) end
  return polygons, rects
end

local function fixture()
  local a, b = {}, {}
  for i = 1, 240 do
    a[i] = "retained line " .. i
    b[i] = i % 20 == 0 and ("replacement " .. i) or a[i]
  end
  return table.concat(a, "\n"), table.concat(b, "\n")
end

test.describe("Diff View visible decorations", function()
  test.before_each(function(context)
    context.views = {}
    context.active_view = core.active_view
    context.ignore_whitespace = config.plugins.diffview.ignore_whitespace
    context.fold_unchanged = config.plugins.diffview.fold_unchanged_by_default
    context.probe_font = style.diff_test_font
    style.diff_test_font = style.code_font:copy(style.code_font:get_size() * 1.5)
    config.plugins.diffview.ignore_whitespace = false
    config.plugins.diffview.fold_unchanged_by_default = false
  end)

  test.after_each(function(context)
    config.plugins.diffview.ignore_whitespace = context.ignore_whitespace
    config.plugins.diffview.fold_unchanged_by_default = context.fold_unchanged
    style.diff_test_font = context.probe_font
    core.active_view = context.active_view
    for _, view in ipairs(context.views) do view:on_close() end
  end)

  test.it("submits visible connectors without off-screen polygons after scrolling", function(context)
    local view = open_diff(context, fixture())
    for _, line in ipairs { 18, 118, 218 } do
      for _, side in ipairs { view.buffer_view_a, view.buffer_view_b } do
        local _, y = side:get_line_screen_position(line)
        side.scroll.y = side.scroll.y + y - side.position.y
        side.scroll.to.y = side.scroll.y
      end
      local polygons = capture(view, "draw_divider_changes")
      test.ok(#polygons > 0, "visible changes must retain their connectors")
      for _, polygon in ipairs(polygons) do
        local low, high = math.huge, -math.huge
        for _, point in ipairs(polygon.points) do
          low, high = math.min(low, point[2]), math.max(high, point[2])
        end
        test.ok(high >= view.position.y and low <= view.position.y + view.size.y,
          "fully off-screen connector reached the renderer")
      end
    end
  end)

  test.it("retains connectors that cross the viewport between independently scrolled sides", function(context)
    local view = open_diff(context, fixture())
    local left, right = view.buffer_view_a, view.buffer_view_b
    left.scroll.y = 100 * left:get_line_height()
    left.scroll.to.y = left.scroll.y
    right.scroll.y, right.scroll.to.y = 0, 0
    local polygons = capture(view, "draw_divider_changes")
    local crossing = false
    for _, polygon in ipairs(polygons) do
      local low, high = math.huge, -math.huge
      for _, point in ipairs(polygon.points) do
        low, high = math.min(low, point[2]), math.max(high, point[2])
      end
      if low <= view.position.y and high >= view.position.y + view.size.y then crossing = true end
    end
    test.ok(crossing, "connectors must survive when their endpoints straddle the viewport")
  end)

  test.it("bounds connector drawing after large pastes into a Blank Diff View", function(context)
    local view = diffview.open({
      contents = { diffview.content.blank(), diffview.content.blank() },
    }, true)
    context.views[#context.views + 1] = view
    view.position.x, view.position.y = 40, 25
    view.size.x, view.size.y = 800, 300
    local left, right = view.buffer_view_a, view.buffer_view_b
    left:set_wrapping_enabled(false)
    right:set_wrapping_enabled(false)
    local pasted = string.rep("pasted line\n", 28128)
    right:on_text_input(pasted)
    wait_for_diff(view)
    view:update()

    for _, fraction in ipairs { 0, 0.5, 1 } do
      local scroll = fraction * (right:get_scrollable_size() - right.size.y)
      for _, side in ipairs { left, right } do
        side.scroll.y, side.scroll.to.y = scroll, scroll
      end
      local polygons = capture(view, "draw_divider_changes")
      test.ok(#polygons > 0, "the large insertion must keep its visible connector")
      for _, polygon in ipairs(polygons) do
        for _, point in ipairs(polygon.points) do
          test.ok(point[2] >= view.position.y and point[2] <= view.position.y + view.size.y,
            "large paste sent an unbounded connector to the native rasterizer")
        end
      end
    end

    left:on_text_input(pasted)
    wait_for_diff(view)
    view:update()
    test.equal(table.concat(left.buffer.lines), pasted .. "\n")
    test.equal(table.concat(right.buffer.lines), pasted .. "\n")
    test.equal(#capture(view, "draw_divider_changes"), 0, "equal pasted text must have no connectors")
  end)

  local mutations = {
    { "moving and resizing", function(view)
      view.position.x, view.position.y = 40, 25
      view.size.x, view.size.y = 600, 500
      view:update()
    end },
    { "wrapping", function(view)
      view.size.x = 240
      view.buffer_view_a:set_wrapping_enabled(true)
      view.buffer_view_b:set_wrapping_enabled(true)
      view:update()
      view:update()
    end },
    { "folding", function(view) view:toggle_folding(); view:update() end },
    { "font changes", function(view)
      view.buffer_view_a.font, view.buffer_view_b.font = "diff_test_font", "diff_test_font"
      view:update()
    end },
    { "visual gap rows", function(view)
      view.buffer_view_a:add_visual_row_provider("test-gaps", { before = { [20] = 15 } })
    end },
  }

  for _, mutation in ipairs(mutations) do
    test.it("keeps warm decoration geometry correct after " .. mutation[1], function(context)
      local before, after = fixture()
      local warm = open_diff(context, before, after)
      capture(warm, "draw_divider_changes")
      local _, initial_markers = capture(warm, "draw_scrollbar")
      mutation[2](warm)

      local fresh = open_diff(context, before, after)
      mutation[2](fresh)
      local warm_polygons = capture(warm, "draw_divider_changes")
      local fresh_polygons = capture(fresh, "draw_divider_changes")
      test.same(warm_polygons, fresh_polygons)
      local _, warm_markers = capture(warm, "draw_scrollbar")
      local _, fresh_markers = capture(fresh, "draw_scrollbar")
      test.ok(#initial_markers > 0 and #warm_markers > 0, "fixture needs overview markers")
      test.same(warm_markers, fresh_markers)
    end)
  end

  test.it("replaces warm decorations after the diff changes", function(context)
    local before, after = fixture()
    local warm = open_diff(context, before, after)
    capture(warm, "draw_divider_changes")
    capture(warm, "draw_scrollbar")
    warm.buffer_view_b.buffer:insert(1, 1, "new first line\n")
    test.equal(warm.buffer_view_b.buffer.lines[1], "new first line\n")
    warm:update_diff()
    wait_for_diff(warm)
    warm:update()
    local fresh = open_diff(context, before, "new first line\n" .. after)
    for _, view in ipairs { warm, fresh } do
      for _, side in ipairs { view.buffer_view_a, view.buffer_view_b } do
        side.scroll.y, side.scroll.to.y = 0, 0
      end
    end
    local warm_polygons = capture(warm, "draw_divider_changes")
    local fresh_polygons = capture(fresh, "draw_divider_changes")
    test.ok(#warm_polygons > 0)
    test.same(warm_polygons, fresh_polygons)
    local _, warm_markers = capture(warm, "draw_scrollbar")
    local _, fresh_markers = capture(fresh, "draw_scrollbar")
    test.same(warm_markers, fresh_markers)
  end)

  test.it("uses current theme colors with warm geometry", function(context)
    local view = open_diff(context, fixture())
    capture(view, "draw_scrollbar")
    local previous = {}
    local color = { 17, 23, 41, 123 }
    for _, tag in ipairs { "modify", "insert", "delete" } do
      previous[tag] = style["diff_overview_" .. tag]
      style["diff_overview_" .. tag] = color
    end
    local ok, err = pcall(function()
      local _, markers = capture(view, "draw_scrollbar")
      test.ok(#markers > 0)
      for _, marker in ipairs(markers) do test.equal(marker.color, color) end
    end)
    for _, tag in ipairs { "modify", "insert", "delete" } do
      style["diff_overview_" .. tag] = previous[tag]
    end
    if not ok then error(err, 0) end
  end)
end)
