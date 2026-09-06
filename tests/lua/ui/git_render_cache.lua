local GitView = require "plugins.git.view"
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
    test.equal(list:get_line_hint(1)[1].text, "Grace")
    test.equal(first.fragments[#first.fragments].text, "First")
  end)
end)
