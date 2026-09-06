local GitView = require "plugins.git.view"
local renderer = require "renderer"
local renwindow = require "renwindow"
local test = require "core.test"

test.describe("Git commit rendering", function()
  test.it("reuses unchanged rendered rows and refreshes edited commit data", function()
    local view = GitView({ path = USERDIR }, { defer_refresh = true })
    local tab = view.model:log_tab()
    local commit = { hash = "abc", subject = "First", author_name = "Ada",
      commit_time = 1700000000, ref_labels = { { kind = "branch", label = "main" } } }
    tab.commits = { commit }
    view:update_pane_buffers()
    local list = view:pane_view("log-list")
    local first = list:get_line_render(1)
    local hint = list:get_line_hint(1)
    view:update_pane_buffers()
    test.equal(list:get_line_render(1), first)
    test.equal(list:get_line_hint(1), hint)

    commit.subject = "Second"
    commit.author_name = "Grace"
    commit.ref_labels[1].label = "topic"
    view:update_pane_buffers()
    test.match(list.buffer:get_utf8_line(1), "topic.*Second")
    local changed = list:get_line_render(1)
    test.ok(changed ~= first)
    test.equal(changed.fragments[#changed.fragments].text, "Second")
    test.equal(list:get_line_hint(1)[1].text, "Grace   ")
    test.equal(first.fragments[#first.fragments].text, "First")
  end)

  test.it("keeps cached commit text and hints pixel-identical", function()
    local view = GitView({ path = USERDIR }, { defer_refresh = true })
    local tab = view.model:log_tab()
    tab.commits = { {
      hash = "abc123", subject = "Packet rendering", author_name = "Ada",
      commit_time = 1700000000,
      ref_labels = { { kind = "branch", label = "main" } },
    } }
    view:update_pane_buffers()
    local list = view:pane_view("log-list")
    list.position.x, list.position.y = 0, 0
    list.size.x, list.size.y = 500, 40
    local render_line = list:get_line_render(1)
    local hint = list:get_line_hint(1)

    local function draw(window, cached)
      local display_packet = renderer.display_packet
      if not cached then
        if render_line.__git_commit_packet then
          render_line.__git_commit_packet.packet:release()
          render_line.__git_commit_packet = nil
        end
        if hint.__display_packet then hint.__display_packet.packet:release() end
        hint.__display_packet = nil
        hint.__normalized_line_hint = nil
        renderer.display_packet = nil
      end
      renderer.begin_frame(window)
      renderer.set_clip_rect(0, 0, 500, 40)
      renderer.draw_rect(0, 0, 500, 40, { 0, 0, 0, 255 })
      list:draw_line_text(1, 2, 2)
      list:draw_line_hint(1, 2, 2)
      renderer.end_frame()
      renderer.display_packet = display_packet
    end

    local cached_window = renwindow.create("cached Git row", 500, 40)
    local legacy_window = renwindow.create("legacy Git row", 500, 40)
    draw(cached_window, true)
    draw(legacy_window, false)
    for y = 0, 39 do
      for x = 0, 499 do
        test.same(
          renwindow.get_color(cached_window, x, y),
          renwindow.get_color(legacy_window, x, y)
        )
      end
    end
  end)
end)
