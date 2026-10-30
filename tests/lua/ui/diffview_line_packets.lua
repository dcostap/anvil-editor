local core = require "core"
local test = require "core.test"
local diffview = require "plugins.diffview"
local config = require "core.config"

local function wait_for_diff(view)
  local deadline = system.get_time() + 5
  while view.updater_idx do
    test.ok(system.get_time() < deadline, "Diff comparison did not finish")
    coroutine.yield(0.01)
  end
end

local function draw_line_text(side)
  local x, y = side:get_line_screen_position(1)
  local drawn = {}
  local old_draw_text = renderer.draw_text
  renderer.draw_text = function(font, text, ...)
    drawn[#drawn + 1] = text
    return old_draw_text(font, text, ...)
  end
  renderer.begin_frame(core.window)
  local ok, err = pcall(side.draw_line_text, side, 1, x, y)
  renderer.end_frame()
  renderer.draw_text = old_draw_text
  if not ok then error(err, 0) end
  return table.concat(drawn)
end

test.describe("Diff Side cached drawing", function()
  test.before_each(function(context)
    context.active = core.active_view
    context.plain_text = config.plugins.diffview.plain_text
    context.layout = config.plugins.diffview.layout
    config.plugins.diffview.plain_text = false
    context.view = diffview.string_to_string(
      "local value = 1\nretained line\n", "local value = 2\nretained line\n",
      "Before", "After", true)
    wait_for_diff(context.view)
    config.plugins.diffview.layout = "side-by-side"
    context.view.position.x, context.view.position.y = 0, 0
    context.view.size.x, context.view.size.y = 2400, 400
    for _, side in ipairs(context.view:get_surface_focus_targets()) do
      side:set_wrapping_enabled(false)
    end
    context.view:update()
  end)

  test.after_each(function(context)
    context.view:on_close()
    config.plugins.diffview.plain_text = context.plain_text
    config.plugins.diffview.layout = context.layout
    core.active_view = context.active
  end)

  test.it("replays unchanged text and replaces it after a Diff Side edit", function(context)
    local left, right = context.view.buffer_view_a, context.view.buffer_view_b
    test.ok(draw_line_text(left):find("local value = 1", 1, true))
    test.ok(draw_line_text(right):find("local value = 2", 1, true))

    right:on_text_input("new ")
    wait_for_diff(context.view)
    test.ok(draw_line_text(right):find("new local value = 2", 1, true),
      "Diff Side kept old text after an edit")
    test.ok(draw_line_text(left):find("local value = 1", 1, true),
      "editing one Diff Side changed the other side")
  end)
end)
