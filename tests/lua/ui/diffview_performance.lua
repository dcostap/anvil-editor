local core = require "core"
local config = require "core.config"
local test = require "core.test"
local diffview = require "plugins.diffview"

local function wait_until(predicate, timeout, message)
  local deadline = system.get_time() + (timeout or 1)
  while not predicate() do
    if system.get_time() >= deadline then
      test.fail(message or "timed out waiting for condition", 2)
    end
    coroutine.yield(0.01)
  end
end

local function with_stubbed_divider_renderer(fn)
  local old_draw_poly = renderer.draw_poly
  local old_draw_rect = renderer.draw_rect
  local old_push_clip_rect = core.push_clip_rect
  local old_pop_clip_rect = core.pop_clip_rect
  renderer.draw_poly = function() end
  renderer.draw_rect = function() end
  core.push_clip_rect = function() end
  core.pop_clip_rect = function() end
  local ok, result = pcall(fn)
  renderer.draw_poly = old_draw_poly
  renderer.draw_rect = old_draw_rect
  core.push_clip_rect = old_push_clip_rect
  core.pop_clip_rect = old_pop_clip_rect
  if not ok then error(result, 0) end
  return result
end

test.describe("DiffView folded rendering performance", function()
  test.before_each(function(context)
    context.old_context = config.plugins.diffview.fold_context_lines
    context.old_min = config.plugins.diffview.fold_min_lines
    context.old_default = config.plugins.diffview.fold_unchanged_by_default
    context.old_line_numbers = config.show_line_numbers
    config.plugins.diffview.fold_context_lines = 1
    config.plugins.diffview.fold_min_lines = 3
    config.plugins.diffview.fold_unchanged_by_default = true
    config.show_line_numbers = false
  end)

  test.after_each(function(context)
    config.plugins.diffview.fold_context_lines = context.old_context
    config.plugins.diffview.fold_min_lines = context.old_min
    config.plugins.diffview.fold_unchanged_by_default = context.old_default
    config.show_line_numbers = context.old_line_numbers
    local view = context.view
    if view then
      local node = core.root_panel.root_node:get_node_for_view(view)
      if node then node:remove_view(core.root_panel.root_node, view) end
      view.doc_view_a.doc:on_close()
      view.doc_view_b.doc:on_close()
    end
  end)

  test.it("keeps repeated folded divider geometry interactive for a large diff", function(context)
    local left, right = {}, {}
    for line = 1, 800 do
      left[line], right[line] = "same " .. line, "same " .. line
      if line % 50 == 25 then
        left[line], right[line] = "old " .. line, "new " .. line
      end
    end

    local view = diffview.string_to_string(
      table.concat(left, "\n"),
      table.concat(right, "\n"),
      "left",
      "right",
      true
    )
    context.view = view
    wait_until(function() return view.updater_idx == nil end, 3, "expected large diff computation to finish")
    test.ok(#view.diff_folds_a >= 10, "expected enough folds to exercise folded geometry")

    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1200, 800
    view:update()

    with_stubbed_divider_renderer(function()
      view:draw_divider_changes() -- warm stable visual-row caches
      view:draw_scrollbar()
    end)
    local elapsed = with_stubbed_divider_renderer(function()
      local started = system.get_time()
      for _ = 1, 100 do
        view:draw_divider_changes()
        view:draw_scrollbar()
      end
      return system.get_time() - started
    end)

    test.ok(elapsed < 0.1, string.format(
      "expected one hundred cached diff geometry frames under 100ms, took %.1fms",
      elapsed * 1000
    ))
  end)
end)
