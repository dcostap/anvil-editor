local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"

local function make_view(text)
  local doc = Doc(nil, nil, true)
  doc:insert(1, 1, text)
  doc:clear_undo_redo()
  local view = DocView(doc)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 400, 200
  return view, doc
end

test.describe("DocView decoration providers", function()
  test.it("draws line backgrounds and inline ranges in provider order", function()
    local view = make_view("alpha\nbeta")
    local old_rect = renderer.draw_rect
    local old_text = renderer.draw_text
    local rects = {}
    renderer.draw_rect = function(x, y, w, h, color)
      rects[#rects + 1] = { x = x, y = y, w = w, h = h, color = color }
    end
    renderer.draw_text = function(font, text, x, y, color) return x + (font and font:get_width(text) or 0) end
    view:add_decoration_provider("later", {
      line_background = function(_, _, line) if line == 1 then return { 2, 2, 2, 255 } end end,
    }, { priority = 20 })
    view:add_decoration_provider("earlier", {
      line_background = function(_, _, line) if line == 1 then return { 1, 1, 1, 255 } end end,
      inline_ranges = function(_, _, line) if line == 1 then return { { col1 = 2, col2 = 4, color = { 3, 3, 3, 255 } } } end end,
    }, { priority = 10 })

    local ok, err = pcall(function() view:draw_line_body(1, 0, 0) end)
    renderer.draw_rect = old_rect
    renderer.draw_text = old_text
    if not ok then error(err, 0) end

    test.same(rects[1].color, { 1, 1, 1, 255 })
    test.same(rects[2].color, { 2, 2, 2, 255 })
    local found_inline = false
    for _, rect in ipairs(rects) do
      if rect.color[1] == 3 then found_inline = true end
    end
    test.ok(found_inline, "expected inline provider range to be drawn")
  end)

  test.it("removes decoration and POI providers", function()
    local view = make_view("alpha")
    view:add_decoration_provider("test", { line_background = function() return { 1, 1, 1, 255 } end })
    view:add_poi_provider("test", { points_of_interest = function() return { { line = 1, col = 1, kind = "test" } } end })
    local points = view:get_points_of_interest()
    test.equal(#points, 1)
    test.equal(view:remove_decoration_provider("test"), true)
    test.equal(view:remove_poi_provider("test"), true)
    test.equal(#view:decoration_provider_entries(), 0)
    points = view:get_points_of_interest()
    test.equal(#points, 0)
  end)

  test.it("notifies selection listeners for view-local selection changes", function()
    local view = make_view("alpha")
    local count = 0
    view:add_selection_listener("test", function(_, state) count = count + 1; test.equal(state.selections[1], 1) end)
    view:with_selection_state(function() view.doc:set_selection(1, 2) end)
    test.ok(count > 0, "expected selection listener to fire")
  end)

  test.it("uses visual row providers for line-height rows", function()
    local view = make_view("one\ntwo\nthree")
    local base = view:get_scrollable_line_count()
    view:add_visual_row_provider("test", { before = { [2] = 2, [3] = 2 } })
    test.equal(view:get_extra_visual_rows_before_line(2), 2)
    test.equal(view:get_scrollable_line_count(), base + 2)
    test.equal(view:remove_visual_row_provider("test"), true)
    test.equal(view:get_scrollable_line_count(), base)
  end)

  test.it("notifies fold listeners for expand and removal", function()
    local view = make_view("one\ntwo\nthree")
    local events = {}
    view:add_fold_listener("test", function(_, event, fold, reason)
      events[#events + 1] = event .. ":" .. tostring(reason)
    end)
    local fold = assert(view:add_fold_region { line1 = 1, line2 = 2 })
    view:expand_fold_region(fold, "test-expand")
    view:remove_fold_region(fold, "test-remove")
    test.same(events, { "add:add", "expand:test-expand", "remove:test-remove" })
  end)
end)
