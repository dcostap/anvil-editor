local core = require "core"
local test = require "core.test"
local diffview = require "plugins.diffview"
local packets = require "core.textview_line_packets"
local config = require "core.config"

local function wait_for_diff(view)
  local deadline = system.get_time() + 5
  while view.updater_idx do
    test.ok(system.get_time() < deadline, "Diff comparison did not finish")
    coroutine.yield(0.01)
  end
end

local function draw_line(side)
  local x, y = side:get_line_screen_position(1)
  renderer.begin_frame(core.window)
  local ok, err = pcall(side.draw_line_text, side, 1, x, y)
  renderer.end_frame()
  if not ok then error(err, 0) end
  return renderer.get_last_frame_stats()
end

local function packet_text(side)
  local text = {}
  for _, item in ipairs(packets.inspect_line(side, 1) or {}) do
    if item.type == "text" then text[#text + 1] = item.text end
  end
  return table.concat(text)
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
      side.__test_force_line_packets = true
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
    for _, side in ipairs { left, right } do
      draw_line(side)
      test.ok(draw_line(side).display_packet_replays > 0,
        "Diff Side did not use cached drawing")
    end
    test.ok(packet_text(left):find("local value = 1", 1, true))
    test.ok(packet_text(right):find("local value = 2", 1, true))

    right:on_text_input("new ")
    wait_for_diff(context.view)
    draw_line(right)
    test.ok(packet_text(right):find("new local value = 2", 1, true),
      "Diff Side kept old text after an edit")
    draw_line(left)
    test.ok(packet_text(left):find("local value = 1", 1, true),
      "editing one Diff Side changed the other side")
  end)
end)
