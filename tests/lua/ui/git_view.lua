local core = require "core"
local command = require "core.command"
local style = require "core.style"
local test = require "core.test"
local tool_window = require "core.tool_window"
local git_view = require "plugins.git_view"
local real_backend = require "plugins.git.backend"
require "core.poi"

local function fake_window(id)
  return { get_size = function() return 640, 480 end, id = id }
end

local function fake_root()
  local node = {
    type = "leaf",
    added = {},
    active_view = nil,
    views = {},
    add_view = function(self, view)
      self.added[#self.added + 1] = view
      self.views[#self.views + 1] = view
      self.active_view = view
    end,
    set_active_view = function(self, view)
      self.active_view = view
    end,
    remove_view = function(self, root, view)
      for i, candidate in ipairs(self.views) do
        if candidate == view then table.remove(self.views, i); break end
      end
      if self.active_view == view then self.active_view = self.views[#self.views] end
    end,
  }
  return {
    size = { x = 0, y = 0 },
    root_node = node,
    get_active_node_default = function() return node end,
    get_main_panel = function() return node end,
    update = function() end,
    draw = function() end,
  }
end

local fake_backend = {
  repo_for_path = function(path) return { root = path } end,
  build_log_args = function() return { "log" } end,
  diff_endpoint_for_commit = real_backend.diff_endpoint_for_commit,
  WORKING_TREE = real_backend.WORKING_TREE,
  EMPTY_TREE = real_backend.EMPTY_TREE,
  parse_status_z = function() return {} end,
  parse_log_page = function() return { commits = {} } end,
  changed_files = function(repo, left, right, opts, callback)
    callback({}, nil)
    return { cancel = function() end }
  end,
  file_at = function(repo, rev, relpath, opts, callback)
    callback("", nil)
    return { cancel = function() end }
  end,
  file_history = function(repo, relpath, opts, callback)
    callback({ commits = {}, has_more = false }, nil)
    return { cancel = function() end }
  end,
  selection_history = function(repo, relpath, start_line, end_line, opts, callback)
    callback({ commits = {}, has_more = false }, nil)
    return { cancel = function() end }
  end,
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
    context.original_projects = core.projects
    context.original_active_view = core.active_view
    context.original_active_window = core.active_window
    tool_window.reset_for_tests()
    context.project = { path = "C:/repo" }
  end)

  test.after_each(function(context)
    core.projects = context.original_projects
    core.active_view = context.original_active_view
    core.active_window = context.original_active_window
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

  test.test("opened Git items become real tool-window tabs", function(context)
    local tw, view = open_fake_git_view(context.project)
    local tab = {
      id = "diff-test",
      kind = "commit_diff",
      title = "Diff abc123",
      closable = true,
      changed_files = {},
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local tab_view = git_view.ensure_tab_view(tw, tab, true)

    test.not_nil(tab_view)
    test.equal(tab_view.tab_id, "diff-test")
    test.equal(view.model.active_tab, "diff-test")
    test.equal(tw.root:get_active_node_default().active_view, tab_view)
    test.equal(#tw.root:get_active_node_default().views, 2)
    test.equal(tw.hidden, false)
  end)

  test.test("file history click hit-testing matches rendered rows", function(context)
    local tw, view = open_fake_git_view(context.project)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 600
    local tab = {
      id = "history-test",
      kind = "file_history",
      title = "History: src/app.lua",
      closable = true,
      relpath = "src/app.lua",
      commits = {
        { hash = "a", short_hash = "a", subject = "First" },
        { hash = "b", short_hash = "b", subject = "Second" },
      },
      selected_commit = 1,
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local history_view = git_view.ensure_tab_view(tw, tab, true)
    history_view.position.x, history_view.position.y = 0, 0
    history_view.size.x, history_view.size.y = 800, 600
    tab.scroll = history_view:row_height()
    history_view:on_mouse_pressed("left", 10, history_view:history_commits_y() - 2, 1)
    test.equal(tab.selected_commit, 1)
    tab.scroll = 0
    history_view:on_mouse_pressed("left", 10, history_view:history_commits_y() + 1, 1)
    test.equal(tab.selected_commit, 1)
    history_view:on_mouse_pressed("left", 10, history_view:history_commits_y() + history_view:row_height() + 1, 1)
    test.equal(tab.selected_commit, 2)
    tab.has_more = true
    tab.scroll = 999999
    history_view:clamp_history_scroll(tab)
    test.ok(tab.scroll < 999999)
    test.equal(tw.hidden, false)
  end)

  test.test("selecting a history commit loads changed files for details", function(context)
    local tw, view = open_fake_git_view(context.project)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 600
    local changed_file_calls = 0
    view.model.repo = { root = "C:/repo" }
    view.model.backend = {
      WORKING_TREE = real_backend.WORKING_TREE,
      EMPTY_TREE = real_backend.EMPTY_TREE,
      diff_endpoint_for_commit = real_backend.diff_endpoint_for_commit,
      changed_files = function(repo, left, right, opts, callback)
        changed_file_calls = changed_file_calls + 1
        callback({ { status = "modified", old_path = "src/app.lua", new_path = "src/app.lua" } }, nil)
        return { cancel = function() end }
      end,
    }
    local tab = {
      id = "history-selection-test",
      kind = "file_history",
      title = "History: src/app.lua:1-1",
      closable = true,
      relpath = "src/app.lua",
      history_context = { type = "selection", start_line = 1, end_line = 1 },
      commits = {
        { hash = "a", short_hash = "a", subject = "First", parents = {} },
        { hash = "b", short_hash = "b", subject = "Second", parents = {} },
      },
      selected_commit = 1,
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local history_view = git_view.ensure_tab_view(tw, tab, true)
    history_view.position.x, history_view.position.y = 0, 0
    history_view.size.x, history_view.size.y = 800, 600
    changed_file_calls = 0

    history_view:on_mouse_pressed("left", 10, history_view:history_commits_y() + history_view:row_height() + 1, 1)

    test.equal(tab.selected_commit, 2)
    test.equal(changed_file_calls, 1)
    test.equal(tab.commits[2].changed_files[1].new_path, "src/app.lua")

    history_view:on_mouse_pressed("left", 700, history_view:history_commits_y() + 1, 1)
    test.equal(tab.selected_commit, 2)
    test.equal(changed_file_calls, 1)
  end)

  test.test("commit diff tabs can focus diff content and return to the Git list", function(context)
    local tw, view = open_fake_git_view(context.project)
    local tab = {
      id = "diff-focus",
      kind = "commit_diff",
      title = "Diff abc123",
      closable = true,
      changed_files = { { status = "modified", old_path = "a.lua", new_path = "a.lua" } },
      selected_file = 1,
      left_text = "old\n",
      right_text = "new\n",
      left_name = "a.lua",
      right_name = "a.lua",
      diff_generation = 1,
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local tab_view = git_view.ensure_tab_view(tw, tab, true)
    core.active_view = tab_view

    test.equal(command.perform("git:focus-diff-pane"), true)
    test.equal(core.active_view.git_owner_view, tab_view)
    tw:activate_root()
    test.equal(core.active_view.git_owner_view, tab_view)
    git_view.sync_tab_views(tw, false)
    test.equal(core.active_view.git_owner_view, tab_view)
    test.equal(command.perform("git:focus-list-pane"), true)
    test.equal(core.active_view.git_owner_view, tab_view)
    test.equal(core.active_view.git_pane, "file-list")
  end)

  test.it("focused Git diff DocView treats the tool window as its focused window", function(context)
    local tw, view = open_fake_git_view(context.project)
    local tab = {
      id = "diff-caret",
      kind = "commit_diff",
      title = "Diff caret",
      closable = true,
      changed_files = { { status = "modified", old_path = "a.lua", new_path = "a.lua" } },
      selected_file = 1,
      left_text = "old\n",
      right_text = "new\n",
      left_name = "a.lua",
      right_name = "a.lua",
      diff_generation = 1,
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local tab_view = git_view.ensure_tab_view(tw, tab, true)
    tab_view.position.x, tab_view.position.y = 0, 0
    tab_view.size.x, tab_view.size.y = 800, 600

    test.equal(command.perform("sidepanel:toggle-focus"), true)
    local diff = tab.diff_view
    local doc_view = diff.doc_view_a
    local original_window_has_focus = system.window_has_focus
    system.window_has_focus = function(window) return window == tw.window end
    core.active_window = tw.window
    core.active_view = doc_view
    test.equal(doc_view:active_window_has_focus(), true)
    core.active_window = core.window
    test.equal(doc_view:active_window_has_focus(), false)
    system.window_has_focus = original_window_has_focus
  end)

  test.test("pane focus cycle enters Log list and details DocViews", function(context)
    local tw, view = open_fake_git_view(context.project)
    core.active_view = view

    test.equal(command.perform("git:focus-next-pane"), true)
    test.equal(core.active_view.git_owner_view, view)
    test.equal(core.active_view.git_pane, "log-list")
    test.equal(command.perform("git:focus-next-pane"), true)
    test.equal(core.active_view.git_pane, "details")
  end)

  test.it("pane focus cycles through Git diff list and both text panes", function(context)
    local tw, view = open_fake_git_view(context.project)
    local tab = {
      id = "diff-panes",
      kind = "commit_diff",
      title = "Diff panes",
      closable = true,
      changed_files = { { status = "modified", old_path = "a.lua", new_path = "a.lua" } },
      selected_file = 1,
      left_text = "same\nold\nsame\n",
      right_text = "same\nnew\nsame\n",
      left_name = "a.lua",
      right_name = "a.lua",
      diff_generation = 1,
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local tab_view = git_view.ensure_tab_view(tw, tab, true)
    core.active_view = tab_view

    test.equal(command.perform("sidepanel:toggle-focus"), true)
    test.equal(core.active_view.git_pane, "file-list")
    test.equal(command.perform("sidepanel:toggle-focus"), true)
    local diff = tab.diff_view
    test.equal(core.active_view, diff.doc_view_a)
    diff.doc_view_a.get_points_of_interest = function()
      return { { line = 2, col = 1, line_only_navigation = true, scroll_to_line = true } }
    end
    diff.doc_view_a.doc:set_selection(1, 1)
    test.equal(command.perform("poi:next"), true)
    local line = diff.doc_view_a.doc:get_selection()
    test.equal(line, 2)

    test.equal(command.perform("sidepanel:toggle-focus"), true)
    test.equal(core.active_view, diff.doc_view_b)
    test.equal(command.perform("sidepanel:toggle-focus"), true)
    test.equal(core.active_view.git_pane, "file-list")

    test.equal(command.perform("sidepanel:toggle-focus"), true)
    test.equal(core.active_view, diff.doc_view_a)
    test.equal(command.perform("git:close-selected-tab"), true)
    test.ok(core.active_view ~= tab_view)
    test.ok(core.active_view.git_owner_view ~= tab_view)
    test.equal(command.perform("sidepanel:toggle-focus"), true)
    test.ok(core.active_view ~= tab_view)

    core.active_view = {}
    test.equal(command.perform("git:focus-next-pane"), false)
  end)

  test.test("keyboard row commands navigate and activate Git rows", function(context)
    local tw, view = open_fake_git_view(context.project)
    core.active_view = view
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 600
    view.model.repo = { root = "C:/repo" }
    view.model:log_tab().commits = {
      { hash = "a", short_hash = "a", subject = "First", parents = {} },
      { hash = "b", short_hash = "b", subject = "Second", parents = {} },
    }

    test.equal(command.perform("git:select-next-row"), true)
    test.equal(view.model:selected_commit().hash, "b")
    test.equal(command.perform("git:activate-selected-row"), true)
    test.equal(view.model:selected_tab().kind, "commit_diff")
    test.equal(#tw.root:get_active_node_default().views, 2)

    core.active_view = {}
    test.equal(command.perform("git:select-next-row"), false)
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

  test.test("saves and restores hidden Git View tool-window state", function(context)
    local tw, view = open_fake_git_view(context.project)
    local history_tab = view.model:open_file_history("src/app.lua")
    view.model.active_tab = history_tab.id
    tw:hide()

    local states = tool_window.get_project_state(context.project)
    tool_window.reset_for_tests()
    tool_window.restore_project_state(context.project, states, {
      git = {
        window = fake_window(2222),
        window_id = 2222,
        root = fake_root(),
        git_view_opts = { backend = fake_backend },
      },
    })

    local restored = tool_window.get(context.project, "git")
    test.not_nil(restored)
    test.equal(restored.hidden, true)
    test.equal(restored.git_view.model.active_tab, history_tab.id)
    test.not_nil(restored.git_view.model:find_tab(history_tab.id))
  end)

  test.test("syncing real tabs follows model tab id changes", function(context)
    local tw, view = open_fake_git_view(context.project)
    view.model.repo = { root = "C:/repo" }
    local tab = {
      id = "diff-old",
      kind = "commit_diff",
      title = "Diff old",
      closable = true,
      left = "old",
      right = real_backend.WORKING_TREE,
      changed_files = {},
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local old_view = git_view.ensure_tab_view(tw, tab, true)
    tab.id = "diff-new"
    tab.title = "Diff new"
    view.model.active_tab = "diff-new"

    git_view.sync_tab_views(tw, true)

    test.equal(tw.git_tab_views["diff-old"], nil)
    test.not_nil(tw.git_tab_views["diff-new"])
    test.ok(tw.git_tab_views["diff-new"] ~= old_view)
    test.equal(tw.root:get_active_node_default().active_view.tab_id, "diff-new")
  end)

  test.test("restoring over an existing Git View applies saved hidden state", function(context)
    local tw, view = open_fake_git_view(context.project)
    local old_tab = view.model:open_file_history("old.lua")
    git_view.ensure_tab_view(tw, old_tab, true)
    test.equal(#tw.root:get_active_node_default().views, 2)
    tool_window.restore_project_state(context.project, {
      {
        kind = "git",
        hidden = true,
        model = {
          repo = { root = "C:/repo" },
          active_tab = "log",
          tabs = { { id = "log", kind = "log", selected_commit = 1 } },
        },
      },
    })
    test.equal(tw.hidden, true)
    test.equal(view.model.active_tab, "log")
    test.equal(view.model:find_tab("history\0file\0C:/repo\0old.lua"), nil)
    test.equal(tw.git_tab_views[old_tab.id], nil)
    test.equal(#tw.root:get_active_node_default().views, 1)
  end)

  test.test("commands refresh a hidden restored Git View before using it", function(context)
    local log_calls = 0
    local backend = {
      repo_for_path = function(path) return { root = path } end,
      build_log_args = function() return { "log" } end,
      parse_status_z = function() return {} end,
      parse_log_page = function() return {
        commits = { { hash = "abc123", short_hash = "abc123", subject = "Initial", parents = {} } },
        has_more = false,
      } end,
      diff_endpoint_for_commit = require("plugins.git.backend").diff_endpoint_for_commit,
      WORKING_TREE = require("plugins.git.backend").WORKING_TREE,
      EMPTY_TREE = require("plugins.git.backend").EMPTY_TREE,
      changed_files = function(repo, left, right, opts, callback)
        callback({ { status = "modified", old_path = "src/app.lua", new_path = "src/app.lua" } }, nil)
        return { cancel = function() end }
      end,
      file_at = function(repo, rev, relpath, opts, callback)
        callback("", nil)
        return { cancel = function() end }
      end,
      run_git = function(repo, args, opts, callback)
        if args[1] == "status" then
          callback({ code = 0, stdout = "" }, nil)
        else
          log_calls = log_calls + 1
          callback({ code = 0, stdout = "" }, nil)
        end
        return { cancel = function() end }
      end,
    }
    tool_window.restore_project_state(context.project, {
      {
        kind = "git",
        hidden = true,
        model = {
          repo = { root = "C:/repo" },
          active_tab = "log",
          tabs = { { id = "log", kind = "log", selected_commit = 1, selected_commit_hash = "abc123" } },
        },
      },
    }, {
      git = {
        window = fake_window(3333),
        window_id = 3333,
        root = fake_root(),
        git_view_opts = { backend = backend },
      },
    })
    local restored = tool_window.get(context.project, "git")
    test.equal(restored.git_view.refresh_started, nil)
    test.equal(log_calls, 0)

    core.projects = { context.project }
    core.active_view = restored.git_view
    command.perform("git:open-selected-commit-diff")

    test.equal(log_calls, 1)
    test.equal(restored.git_view.model:selected_tab().kind, "commit_diff")
  end)

  test.test("close command closes the focused real Git tab", function(context)
    local tw, view = open_fake_git_view(context.project)
    local tab = {
      id = "diff-close",
      kind = "commit_diff",
      title = "Diff close",
      closable = true,
      changed_files = {},
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local tab_view = git_view.ensure_tab_view(tw, tab, true)
    core.projects = { context.project }
    core.active_view = tab_view

    test.equal(command.perform("git:close-selected-tab"), true)
    test.equal(view.model:find_tab(tab.id), nil)
    test.equal(tw.git_tab_views[tab.id], nil)
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
    test.not_nil(command.map["git:show-file-history"])
    test.not_nil(command.map["git:show-selection-history"])
    test.not_nil(command.map["git:open-selected-historical-document"])
    test.not_nil(command.map["git:close-selected-tab"])
    test.not_nil(command.map["git:select-next-row"])
    test.not_nil(command.map["git:select-previous-row"])
    test.not_nil(command.map["git:activate-selected-row"])
    test.not_nil(command.map["git:focus-diff-pane"])
    test.not_nil(command.map["git:focus-list-pane"])
  end)
end)
