local core = require "core"
local command = require "core.command"
local config = require "core.config"
local test = require "core.test"
local diffview = require "plugins.diffview"

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
    local folded_size = view.doc_view_a:get_scrollable_size()
    core.active_view = view.doc_view_a
    test.equal(command.perform("diff-view:toggle-folding"), true)
    test.equal(#view.diff_folds_a, 0)
    test.ok(view.doc_view_a:get_scrollable_size() > folded_size)
    core.active_view = view
    test.equal(command.perform("diff-view:toggle-folding"), true)
    test.ok(#view.diff_folds_a > 0)
  end)

  test.it("skips caret and scroll synchronization over collapsed regions", function(context)
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
    test.ok(line == fold.hidden_start or line == fold.hidden_end + 1)
    view.doc_view_a.doc:set_selection(fold.hidden_start, 20)
    local col
    line, col = view.doc_view_a.doc:get_selection()
    test.equal(line, fold.hidden_start)
    test.equal(col, 1)

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
