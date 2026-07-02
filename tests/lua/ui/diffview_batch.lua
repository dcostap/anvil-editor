local core = require "core"
local command = require "core.command"
local config = require "core.config"
local test = require "core.test"
local diffview = require "plugins.diffview"
local Doc = require "core.doc"
local DocView = require "core.docview"

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function wait_until(predicate, timeout, message)
  local deadline = system.get_time() + (timeout or 1)
  while not predicate() do
    if system.get_time() >= deadline then
      test.fail(message or "timed out waiting for condition", 2)
    end
    coroutine.yield(0.01)
  end
end

local function text(doc)
  return table.concat(doc.lines)
end

test.describe("DiffView batch behavior", function()
  test.before_each(function(context)
    context.original_active_view = core.active_view
  end)

  test.after_each(function(context)
    core.active_view = context.original_active_view
    if context.restore_diff_folding_config then context.restore_diff_folding_config() end
    for _, view in ipairs(context.diffviews or {}) do
      view.doc_view_a.doc:on_close()
      view.doc_view_b.doc:on_close()
    end
  end)

  test.it("uses Text Diff View wording for arbitrary text comparisons", function(context)
    local view = track(context, "diffviews", diffview.string_to_string(
      "left",
      "right",
      "left",
      "right",
      true
    ))
    test.equal(view:get_name(), "Text Diff View")
  end)

  test.it("folds long unchanged regions and toggles them from diff DocViews", function(context)
    local old_context = config.plugins.diffview.fold_context_lines
    local old_min = config.plugins.diffview.fold_min_lines
    local old_default = config.plugins.diffview.fold_unchanged_by_default
    config.plugins.diffview.fold_context_lines = 1
    config.plugins.diffview.fold_min_lines = 3
    config.plugins.diffview.fold_unchanged_by_default = true
    context.restore_diff_folding_config = function()
      config.plugins.diffview.fold_context_lines = old_context
      config.plugins.diffview.fold_min_lines = old_min
      config.plugins.diffview.fold_unchanged_by_default = old_default
    end

    local left, right = {}, {}
    for i = 1, 14 do left[i], right[i] = "same " .. i, "same " .. i end
    left[7], right[7] = "old", "new"
    local view = track(context, "diffviews", diffview.string_to_string(
      table.concat(left, "\n"),
      table.concat(right, "\n"),
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    test.ok(#view.diff_folds_a > 0)
    test.ok(#view.diff_folds_b > 0)
    test.ok(view.diff_folds_a[1].core_fold ~= nil, "expected diff folds to be backed by core DocView folds")
    test.equal(view.doc_view_a:get_collapsed_fold_at_line(view.diff_folds_a[1].hidden_start), view.diff_folds_a[1].core_fold)
    local folded_size = view.doc_view_a:get_scrollable_size()
    core.active_view = view.doc_view_a
    test.equal(command.perform("diff-view:toggle-folding"), true)
    test.equal(#view.diff_folds_a, 0)
    test.ok(view.doc_view_a:get_scrollable_size() > folded_size)
    core.active_view = view
    test.equal(command.perform("diff-view:toggle-folding"), true)
    test.ok(#view.diff_folds_a > 0)
  end)

  test.it("uses core folding for caret movement and scroll synchronization", function(context)
    local old_context = config.plugins.diffview.fold_context_lines
    local old_min = config.plugins.diffview.fold_min_lines
    config.plugins.diffview.fold_context_lines = 1
    config.plugins.diffview.fold_min_lines = 3
    context.restore_diff_folding_config = function()
      config.plugins.diffview.fold_context_lines = old_context
      config.plugins.diffview.fold_min_lines = old_min
    end

    local left, right = {}, {}
    for i = 1, 14 do left[i], right[i] = "same " .. i, "same " .. i end
    left[7], right[7] = "old", "new"
    local view = track(context, "diffviews", diffview.string_to_string(
      table.concat(left, "\n"),
      table.concat(right, "\n"),
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    local fold = view.diff_folds_a[1]
    test.not_nil(fold)
    view.doc_view_a.doc:set_selection(fold.hidden_start + 1, 1)
    local line = view.doc_view_a.doc:get_selection()
    test.equal(line, fold.hidden_start + 1)

    core.active_view = view.doc_view_a
    view.doc_view_a.doc:set_selection(fold.hidden_start, 1)
    test.equal(command.perform("doc:move-to-next-line"), true)
    line = view.doc_view_a.doc:get_selection()
    test.equal(line, fold.hidden_end + 1)
    test.equal(view.doc_view_b.doc:get_selection(), fold.hidden_end + 1)
    local _, y1 = view.doc_view_a:get_line_screen_position(line, 1)
    test.equal(command.perform("doc:move-to-next-line"), true)
    line = view.doc_view_a.doc:get_selection()
    test.equal(line, fold.hidden_end + 2)
    local _, y2 = view.doc_view_a:get_line_screen_position(line, 1)
    test.ok(y2 > y1)

    view.doc_view_a.position.y, view.doc_view_a.size.y = 0, 80
    view.doc_view_b.position.y, view.doc_view_b.size.y = 0, 80
    view.doc_view_a:scroll_to_make_visible(7, 1, true)
    test.equal(view.doc_view_b.scroll.to.y, view.doc_view_a.scroll.to.y)
  end)

  test.it("expands folded regions when clicking their widget line", function(context)
    local old_context = config.plugins.diffview.fold_context_lines
    local old_min = config.plugins.diffview.fold_min_lines
    local old_default = config.plugins.diffview.fold_unchanged_by_default
    config.plugins.diffview.fold_context_lines = 1
    config.plugins.diffview.fold_min_lines = 3
    config.plugins.diffview.fold_unchanged_by_default = true
    context.restore_diff_folding_config = function()
      config.plugins.diffview.fold_context_lines = old_context
      config.plugins.diffview.fold_min_lines = old_min
      config.plugins.diffview.fold_unchanged_by_default = old_default
    end

    local left, right = {}, {}
    for i = 1, 14 do left[i], right[i] = "same " .. i, "same " .. i end
    left[7], right[7] = "old", "new"
    local view = track(context, "diffviews", diffview.string_to_string(
      table.concat(left, "\n"),
      table.concat(right, "\n"),
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    local fold = view.diff_folds_a[1]
    test.not_nil(fold)
    local fold_count = #view.diff_folds_a
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 400
    view:update()
    local x, y = view.doc_view_a:get_line_screen_position(fold.hidden_start, 1)

    test.equal(view:on_mouse_pressed("left", x + 1, y + 1, 1), true)
    test.equal(#view.diff_folds_a, fold_count - 1)
    test.equal(#view.diff_folds_b, fold_count - 1)
    for _, remaining in ipairs(view.diff_folds_a) do
      test.ok(remaining.index ~= fold.index)
    end
    for _, remaining in ipairs(view.diff_folds_b) do
      test.ok(remaining.index ~= fold.index)
    end
  end)

  test.it("draws curved divider connectors and opposite-side gap markers", function(context)
    local view = track(context, "diffviews", diffview.string_to_string(
      "aa\nbb",
      "aa\ninserted\nbb",
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 400
    view:update()
    test.equal(view.doc_view_a:get_scrollable_line_count(), view.doc_view_b:get_scrollable_line_count())
    test.equal(view.doc_view_a:get_scrollable_line_count(), 3)

    local old_draw_poly = renderer.draw_poly
    local old_draw_rect = renderer.draw_rect
    local old_push_clip_rect = core.push_clip_rect
    local old_pop_clip_rect = core.pop_clip_rect
    local old_draw_text = renderer.draw_text
    local polygons = {}
    local markers = {}
    local arrows = {}
    renderer.draw_poly = function(points, color)
      polygons[#polygons + 1] = { points = points, color = color }
    end
    renderer.draw_rect = function(x, y, w, h, color)
      markers[#markers + 1] = { x = x, y = y, w = w, h = h, color = color }
    end
    renderer.draw_text = function(font, text, x, y, color)
      if text == ">" or text == "<" then arrows[#arrows + 1] = { text = text, x = x, y = y, color = color } end
      return x
    end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    local ok, err = pcall(function() view:draw_divider_changes() end)
    renderer.draw_poly = old_draw_poly
    renderer.draw_rect = old_draw_rect
    core.push_clip_rect = old_push_clip_rect
    core.pop_clip_rect = old_pop_clip_rect
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end

    test.ok(#polygons >= 1, "expected an inserted hunk connector in the divider")
    test.ok(#polygons[1].points > 4, "expected a curved connector, not a simple rectangle")
    test.ok(#markers >= 1, "expected a thin gap marker on the side without inserted lines")
    test.ok(markers[1].h <= math.max(1, SCALE) + 0.01, "expected a thin marker line")
    test.ok(#arrows >= 1, "expected visible divider sync arrows")
  end)

  test.it("keeps folded panes synchronized around insert-only hunks", function(context)
    local old_context = config.plugins.diffview.fold_context_lines
    local old_min = config.plugins.diffview.fold_min_lines
    config.plugins.diffview.fold_context_lines = 2
    config.plugins.diffview.fold_min_lines = 3
    context.restore_diff_folding_config = function()
      config.plugins.diffview.fold_context_lines = old_context
      config.plugins.diffview.fold_min_lines = old_min
    end

    local left, right = {}, { "inserted" }
    for i = 1, 20 do
      left[#left + 1] = "same " .. i
      right[#right + 1] = "same " .. i
    end
    local view = track(context, "diffviews", diffview.string_to_string(
      table.concat(left, "\n"),
      table.concat(right, "\n"),
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    test.equal(#view.diff_folds_a, #view.diff_folds_b)
    test.equal(view.diff_folds_a[1].hidden_count, view.diff_folds_b[1].hidden_count)
    test.equal(view.doc_view_a:get_scrollable_size(), view.doc_view_b:get_scrollable_size())
  end)

  test.it("wraps diff change navigation across file boundaries", function(context)
    local view = track(context, "diffviews", diffview.string_to_string(
      "aa\nleft-one\nbb\nleft-two\ncc",
      "aa\nbb\ncc",
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    local left = view.doc_view_a
    core.set_active_view(left)
    left.doc:set_selection(4, 1)
    test.ok(command.perform("diff-view:next-change"))
    test.equal(left.doc:get_selection(), 2)
    test.ok(command.perform("diff-view:prev-change"))
    test.equal(left.doc:get_selection(), 4)
  end)

  test.it("uses providers and listeners without replacing child DocView or Doc methods", function(context)
    local view = track(context, "diffviews", diffview.string_to_string(
      "aa\nleft\nbb",
      "aa\nright\nbb",
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    test.equal(rawget(view.doc_view_a, "draw_line_text"), nil)
    test.equal(rawget(view.doc_view_a, "scroll_to_line"), nil)
    test.equal(rawget(view.doc_view_a, "scroll_to_make_visible"), nil)
    test.equal(view.doc_view_a.doc.set_selection, Doc.set_selection)
    test.equal(view.doc_view_a.doc.raw_insert, Doc.raw_insert)
    test.equal(view.doc_view_a.doc.raw_remove, Doc.raw_remove)
    test.ok(view.doc_view_a.decoration_providers["diff-view"] ~= nil)
    test.ok(view.doc_view_a.poi_providers["diff-view"] ~= nil)
  end)

  test.it("syncing an inserted hunk into the other side emits one document change", function(context)
    local view = track(context, "diffviews", diffview.string_to_string(
      "aa\ninserted\nbb",
      "aa\nbb",
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    local target = view.doc_view_b.doc
    local changes = 0
    function target:on_text_change()
      changes = changes + 1
    end

    view:sync(2, 1, true)

    test.equal(text(target), "aa\ninserted\nbb\n")
    test.equal(changes, 1)
  end)
end)
