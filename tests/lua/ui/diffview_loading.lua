local core = require "core"
local test = require "core.test"
local diffview = require "plugins.diffview"

local function shows_loading(view)
  local draw_text = renderer.draw_text
  local saved = {}
  for _, name in ipairs {
    "draw_rect", "draw_rect_grid", "draw_rounded_rect", "draw_poly",
    "set_clip_rect", "draw_text_known_bounds",
  } do
    saved[name] = renderer[name]
    renderer[name] = function() end
  end
  local shown = false
  renderer.draw_text = function(font, text, x, y, color, opts)
    if text == "Computing differences..." then shown = true end
    return x + font:get_width(text, opts)
  end
  local ok, err = pcall(function() view:draw() end)
  renderer.draw_text = draw_text
  for name, fn in pairs(saved) do renderer[name] = fn end
  if not ok then error(err, 0) end
  return shown
end

test.describe("Diff View loading message", function()
  test.before_each(function(context)
    context.get_time = system.get_time
    context.active_view = core.active_view
  end)

  test.after_each(function(context)
    system.get_time = context.get_time
    if context.view then context.view:on_close() end
    core.active_view = context.active_view
  end)

  test.it("hides brief comparisons and shows comparisons that remain pending", function(context)
    local now = context.get_time()
    system.get_time = function() return now end
    local view = diffview.string_to_string("before\n", "after\n", "Before", "After", true)
    context.view = view
    view.size.x, view.size.y = 800, 600
    -- Do not yield: the comparison has not run yet.
    test.ok(not shows_loading(view), "a new comparison must not flash a loading message")
    now = now + 10
    view:update()
    test.ok(shows_loading(view), "a long comparison must show a loading message")

    system.get_time = context.get_time
    local deadline = system.get_time() + 2
    while view.updater_idx do
      test.ok(system.get_time() < deadline, "diff computation did not finish")
      coroutine.yield(0.01)
    end
    view:update()
    test.ok(not shows_loading(view), "a finished comparison must hide the loading message")
  end)
end)
