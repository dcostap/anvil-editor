local core = require "core"
local test = require "core.test"

local white = { 255, 255, 255, 255 }
local red = { 255, 0, 0, 255 }
local green = { 0, 255, 0, 255 }
local function test_window()
  return core.window
end

local function load_font()
  return renderer.font.load(
    DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "FiraSans-Regular.ttf",
    12 * SCALE,
    { ligatures = true }
  )
end

test.describe("native Display Packet", function()
  test.it("reports unavailable asynchronous frame capture without a D3D target", function()
    local ok, reason = renwindow.request_frame_capture(
      test_window(), USERDIR .. PATHSEP .. "unavailable-frame-capture.png"
    )
    test.equal(ok, false)
    test.equal(reason, "d3d11_unavailable")
  end)

  test.it("seals immutable relative commands with layer and row metadata", function()
    local font = load_font()
    local builder = renderer.display_packet.new()
    local next_x = builder:add_text(0, 1, font, "abc", 2.5, 3, white, 0, 4)
    test.ok(next_x > 2.5)
    builder:add_rect(1, 1, 1, 2, 3, 4, red)
    builder:add_rect_grid(0, 2, 4, 5, 6, 1, 2, 3, green)
    local packet = builder:seal()

    test.ok(packet:bytes() > 3)
    local commands = packet:inspect()
    test.equal(#commands, 3)
    test.same(
      { commands[1].type, commands[1].layer, commands[1].row, commands[1].text },
      { "text", 0, 1, "abc" }
    )
    test.equal(commands[1].tab_offset, 0)
    test.equal(commands[1].tab_size, 4)
    test.ok(commands[1].bounds_width > 0)
    test.same(
      { commands[2].type, commands[2].layer, commands[2].row },
      { "rect", 1, 1 }
    )
    test.same(
      { commands[3].type, commands[3].layer, commands[3].row, commands[3].count },
      { "rect_grid", 0, 2, 3 }
    )

    test.equal(pcall(function()
      builder:add_rect(0, 1, 0, 0, 1, 1, white)
    end), false)

    do
      local unsealed = renderer.display_packet.new()
      unsealed:add_rect(0, 1, 0, 0, 1, 1, white)
    end
    collectgarbage("collect")
  end)

  test.it("replays selected layers and Wrapped Visual Rows at a translated origin", function()
    local builder = renderer.display_packet.new()
    builder:add_rect(0, 1, 1, 1, 4, 4, red)
    builder:add_rect(0, 2, 10, 1, 4, 4, green)
    builder:add_rect(1, 1, 20, 1, 4, 4, white)
    local packet = builder:seal()
    local window = test_window()

    renderer.begin_frame(window)
    renderer.set_clip_rect(0, 0, 40, 24)
    renderer.draw_rect(0, 0, 40, 24, { 0, 0, 0, 255 })
    local ok = packet:draw(5, 6, 0, 2, 2)
    test.equal(ok, true)
    renderer.end_frame()
    test.equal(renderer._frame_font_ref_count(), 0)

    local stats = renderer.get_last_frame_stats()
    test.equal(stats.display_packet_replays, 1)
    test.equal(stats.display_packet_commands_replayed, 1)
    test.equal(type(stats.texture_batch_breaks), "number")
    test.equal(type(stats.quad_batches), "number")
    test.equal(type(stats.unique_batch_srvs), "number")
    test.equal(type(stats.repeated_batch_srvs), "number")
    local drawn = renwindow.get_color(window, 16, 8)
    local skipped = renwindow.get_color(window, 7, 8)
    test.ok(drawn[2] > 240 and drawn[1] < 10)
    test.ok(skipped[1] < 10 and skipped[2] < 10)

    renderer.begin_frame(window)
    renderer.set_clip_rect(0, 0, 40, 24)
    renderer.draw_rect(0, 0, 40, 24, { 0, 0, 0, 255 })
    renderer.set_clip_rect(0, 0, 10, 24)
    test.equal(packet:draw(5, 6, 0, 2, 2), true)
    renderer.end_frame()
    local clipped = renwindow.get_color(window, 16, 8)
    test.ok(clipped[1] < 10 and clipped[2] < 10,
      "expected packet commands to respect the active clip")
  end)

  test.it("pins fallback children through frame end after release and group mutation", function()
    local first = load_font()
    local second = first:copy(first:get_size())
    local group = renderer.font.group({ first, second })
    local builder = renderer.display_packet.new()
    builder:add_text(0, 1, group, "office", 0, 0, white, 0, 2)
    group[2] = nil
    second = nil
    collectgarbage("collect")
    local packet = builder:seal()

    local window = test_window()
    renderer.begin_frame(window)
    renderer.set_clip_rect(0, 0, 80, 24)
    test.equal(packet:draw(0, 0, 0, 1, 1), true)
    test.equal(renderer._frame_font_ref_count(), 2)
    packet:release()
    packet:release()
    collectgarbage("collect")
    renderer.end_frame()
    test.equal(renderer._frame_font_ref_count(), 0)
    local shaped_stats = renderer.get_last_frame_stats()
    test.ok(shaped_stats.text_render_shaped_cache_hits > 0,
      "expected packet measurement to seed shaped replay data")
    test.equal(shaped_stats.text_render_shaped_cache_misses, 0)

    test.equal(packet:bytes(), 0)
    local ok, reason = packet:draw(0, 0, 0, 1, 1)
    test.equal(ok, false)
    test.equal(reason, "released")

    local c_builder = renderer.display_packet.new()
    c_builder:add_text(0, 1, first, "c lifecycle", 0, 0, white, 0, 2)
    local c_packet = c_builder:seal()
    renderer.begin_frame_lua(window)
    test.equal(c_packet:draw(0, 0, 0, 1, 1), true)
    c_packet:release()
    collectgarbage("collect")
    renderer.end_frame_lua()
    test.equal(renderer._frame_font_ref_count(), 0)

  end)

  test.it("captures independent tab sizes for a shared Font", function()
    local font = load_font()
    local first_builder = renderer.display_packet.new()
    first_builder:add_text(0, 1, font, "\t", 0, 0, white, 0, 2)
    local first = first_builder:seal()
    local second_builder = renderer.display_packet.new()
    second_builder:add_text(0, 1, font, "\t", 0, 0, white, 0, 8)
    local second = second_builder:seal()
    test.equal(first:inspect()[1].tab_size, 2)
    test.equal(second:inspect()[1].tab_size, 8)
    first:release()
    second:release()
  end)

  test.it("rejects malformed commands and stale mutable Font geometry", function()
    local font = load_font()
    local builder = renderer.display_packet.new()
    test.equal(pcall(function()
      builder:add_rect(0, -1, 0, 0, 1, 1, white)
    end), false)
    test.equal(pcall(function()
      builder:add_rect(0, 1, 0 / 0, 0, 1, 1, white)
    end), false)
    test.equal(pcall(function()
      builder:add_rect(0, 1, 1073741823, 0, 1073741823, 1, white)
    end), false)
    builder:add_text(0, 1, font, "stale", 0, 0, white, 0, 2)
    builder:add_rect(1, 1, 0, 0, 2, 2, white)
    local packet = builder:seal()
    font:set_size(font:get_size() + 1)

    local window = test_window()
    renderer.begin_frame(window)
    local ok, reason = packet:draw(0, 0, 1, 1, 1)
    test.equal(ok, false)
    test.equal(reason, "stale_font")
    renderer.end_frame()
  end)

  test.it("abandons replayed frame resources and starts the next frame cleanly", function()
    local font = load_font()
    local builder = renderer.display_packet.new()
    builder:add_text(0, 1, font, "abandon", 0, 0, white, 0, 2)
    local packet = builder:seal()
    local window = test_window()

    renderer.begin_frame(window)
    test.equal(packet:draw(0, 0, 0, 1, 1), true)
    packet:release()
    renderer.abandon_frame()
    test.equal(renderer._frame_font_ref_count(), 0)
    collectgarbage("collect")

    renderer.begin_frame(window)
    renderer.draw_rect(0, 0, 2, 2, white)
    renderer.end_frame()
    local stats = renderer.get_last_frame_stats()
    test.equal(stats.rencache_frame_failed, false)
  end)

  test.it("aborts the complete frame when packet command-buffer allocation fails", function()
    local builder = renderer.display_packet.new()
    builder:add_rect(0, 1, 0, 0, 8, 8, red)
    local packet = builder:seal()
    local window = test_window()

    renderer.begin_frame(window)
    renderer.draw_rect(0, 0, 16, 16, { 0, 0, 0, 255 })
    renderer.end_frame()

    renderer.begin_frame(window)
    renderer.draw_rect(0, 0, 16, 16, white)
    renderer.display_packet._test_fail_next_reserve()
    local ok, reason = packet:draw(0, 0, 0, 1, 1)
    test.equal(ok, false)
    test.equal(reason, "frame_failed")
    test.equal(renderer.frame_failed(), true)
    renderer.draw_rect(0, 0, 16, 16, green)
    renderer.end_frame()

    local stats = renderer.get_last_frame_stats()
    test.equal(stats.rencache_frame_failed, true)
    test.equal(stats.display_packet_frame_allocation_failures, 1)
    local retained = renwindow.get_color(window, 2, 2)
    test.ok(retained[1] < 10 and retained[2] < 10 and retained[3] < 10,
      "expected the previously presented frame to remain visible")
  end)
end)
