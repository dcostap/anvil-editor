local command = require "core.command"
local style = require "core.style"
local test = require "core.test"
local tool_window = require "core.tool_window"
local git_view = require "plugins.git_view"

local function fake_window(id)
  return { get_size = function() return 640, 480 end, id = id }
end

local function fake_root()
  local node = {
    added = {},
    active_view = nil,
    views = {},
    add_view = function(self, view)
      self.added[#self.added + 1] = view
      self.views[#self.views + 1] = view
      self.active_view = view
    end,
  }
  return {
    size = { x = 0, y = 0 },
    root_node = { type = "leaf", views = {}, active_view = nil },
    get_active_node_default = function() return node end,
    get_main_panel = function() return node end,
    update = function() end,
    draw = function() end,
  }
end

local fake_backend = {
  repo_for_path = function(path) return { root = path } end,
  build_log_args = function() return { "log" } end,
  parse_status_z = function() return {} end,
  parse_log_page = function() return { commits = {} } end,
  run_git = function(repo, args, opts, callback)
    callback({ code = 0, stdout = "" }, nil)
    return { cancel = function() end }
  end,
}

local function open_fake_git_view(project)
  return git_view.open_view(project, {
    window = fake_window(1111),
    window_id = 1111,
    root = fake_root(),
    git_view_opts = { backend = fake_backend },
  })
end

test.describe("Git View command", function()
  test.before_each(function(context)
    tool_window.reset_for_tests()
    context.project = { path = "C:/repo" }
  end)

  test.after_each(function()
    tool_window.reset_for_tests()
  end)

  test.test("git:open-view reuses one project tool window", function(context)
    local first = open_fake_git_view(context.project)
    local second = open_fake_git_view(context.project)
    test.equal(first, second)
    test.not_nil(tool_window.get(context.project, "git"))
    test.not_nil(first.git_view)
  end)

  test.test("clicking a commit row updates selected commit details", function(context)
    local tw, view = open_fake_git_view(context.project)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 600
    view.model:log_tab().commits = {
      { hash = "a", short_hash = "a", subject = "First" },
      { hash = "b", short_hash = "b", subject = "Second" },
    }
    local second_row_y = view:commit_list_y() + style.font:get_height() + 2 * SCALE
    view:on_mouse_pressed("left", 10, second_row_y, 1)
    test.equal(view.model:selected_commit().hash, "b")
    test.equal(tw.hidden, false)
  end)

  test.test("clicking rendered tab labels switches active tabs", function(context)
    local tw, view = open_fake_git_view(context.project)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 600
    view.model.tabs[#view.model.tabs + 1] = {
      id = "diff-test",
      kind = "commit_diff",
      title = "Diff abc123",
      closable = true,
      changed_files = {},
    }
    local tab = view:tab_at_point(view:tab_rects(style.padding.x, style.padding.y + style.font:get_height() + style.padding.y)[2].x + 1, style.padding.y + style.font:get_height() + style.padding.y + 1)
    test.equal(tab.id, "diff-test")
    view:on_mouse_pressed("left", view:tab_rects(style.padding.x, style.padding.y + style.font:get_height() + style.padding.y)[2].x + 1, style.padding.y + style.font:get_height() + style.padding.y + 1, 1)
    test.equal(view.model.active_tab, "diff-test")
    test.equal(tw.hidden, false)
  end)

  test.test("mouse wheel scrolls a long log", function(context)
    local tw, view = open_fake_git_view(context.project)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 120
    view.model:log_tab().commits = {}
    for i = 1, 20 do
      view.model:log_tab().commits[i] = { hash = tostring(i), short_hash = tostring(i), subject = "Commit " .. i }
    end
    test.equal(view:on_mouse_wheel(0, -1), false)
    test.equal(view.scroll.to.y, 0)
    view:on_mouse_wheel(-1, 0)
    test.ok(view.scroll.to.y > 0)
    test.equal(tw.hidden, false)
  end)

  test.test("closing the Git View hides the owning tool window", function(context)
    local tw, view = open_fake_git_view(context.project)
    local closed = false
    view:try_close(function() closed = true end)
    test.equal(closed, false)
    test.equal(tw.hidden, true)
    test.equal(tw.git_view, view)
  end)

  test.test("command is registered", function()
    test.not_nil(command.map["git:open-view"])
    test.not_nil(command.map["git:open-selected-commit-diff"])
    test.not_nil(command.map["git:open-working-tree-diff"])
    test.not_nil(command.map["git:open-selected-historical-document"])
    test.not_nil(command.map["git:close-selected-tab"])
  end)
end)
