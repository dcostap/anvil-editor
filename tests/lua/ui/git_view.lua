local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local file_context = require "core.file_context"
local style = require "core.style"
local test = require "core.test"
local panes = require "core.panes"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local View = require "core.view"
local RootPanel = require "core.rootpanel"
local git_view = require "plugins.git_view"
local path_tree = require "plugins.path_tree"
local real_backend = require "plugins.git.backend"
require "core.poi"
require "plugins.intellij_actions"

local function fake_window(id)
  return { get_size = function() return 640, 480 end, id = id }
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
    git_view_opts = { backend = fake_backend },
  })
end

local function session_views(session)
  local result, seen = {}, {}
  for _, pane in ipairs(panes.ordered()) do
    for _, entry in ipairs(pane.history.entries) do
      local view = entry.view
      if view and view.git_session == session and not seen[view] then
        seen[view] = true
        result[#result + 1] = view
      end
    end
  end
  return result
end

test.describe("Git View command", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.original_projects = core.projects
    context.original_active_view = core.active_view
    context.original_active_window = core.active_window
    context.original_nag_show = core.nag_view.show
    context.original_set_clipboard = system.set_clipboard
    context.original_linewrapping_default = config.plugins.linewrapping.enable_by_default
    panes.git_sessions = {}
    context.project = { path = "C:/repo" }
  end)

  test.after_each(function(context)
    panes.reset_for_tests()
    core.projects = context.original_projects
    core.active_view = context.original_active_view
    core.active_window = context.original_active_window
    core.nag_view.show = context.original_nag_show
    system.set_clipboard = context.original_set_clipboard
    config.plugins.linewrapping.enable_by_default = context.original_linewrapping_default
    panes.git_sessions = {}
  end)

  test.test("git:open-view reuses one project Git pane session", function(context)
    local first = open_fake_git_view(context.project)
    local second = open_fake_git_view(context.project)
    test.equal(first, second)
    test.not_nil(panes.git_sessions[context.project.path])
    test.not_nil(first.git_view)
  end)

  test.test("opening a Git Pane Tab focuses the visible list TextView", function(context)
    local session, view = open_fake_git_view(context.project)
    test.equal(core.active_view.git_owner_view, view)
    test.equal(core.active_view.git_pane, "log-list")
  end)

  test.test("focus gained restores Git Log pane focus from the shell view", function(context)
    local session, view = open_fake_git_view(context.project)
    core.active_view = view
    core.active_window = core.window

    core.on_event("focusgained")

    test.equal(core.active_view.git_owner_view, view)
    test.equal(core.active_view.git_pane, "log-list")
  end)

  test.test("clicking a commit row updates selected commit details", function(context)
    local session, view = open_fake_git_view(context.project)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 600
    view.model:log_tab().commits = {
      { hash = "a", short_hash = "a", subject = "First" },
      { hash = "b", short_hash = "b", subject = "Second" },
    }
    local second_row_y = view:commit_list_y() + view:row_height()
    view:on_mouse_pressed("left", 10, second_row_y, 1)
    test.equal(view.model:selected_commit().hash, "b")
    test.equal(session.hidden, false)
  end)

  test.it("does not repeat the Git Pane Tab title inside the Git screen", function(context)
    local session, view = open_fake_git_view(context.project)
    view.position.y = 30
    test.equal(view:commit_list_y(), view.position.y + style.padding.y)
  end)

  test.test("opened Git items become Pane history Views", function(context)
    local session, view = open_fake_git_view(context.project)
    local tab = {
      id = "diff-test",
      kind = "commit_diff",
      title = "Diff abc123",
      closable = true,
      changed_files = {},
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local tab_view = git_view.ensure_tab_view(session, tab, true)

    test.not_nil(tab_view)
    test.equal(tab_view.tab_id, "diff-test")
    test.equal(view.model.active_tab, "diff-test")
    test.equal(panes.active().current_view, tab_view)
    test.equal(#session_views(session), 2)
    test.equal(session.hidden, false)
  end)

  test.test("file history click hit-testing matches rendered rows", function(context)
    local session, view = open_fake_git_view(context.project)
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
    local history_view = git_view.ensure_tab_view(session, tab, true)
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
    test.equal(session.hidden, false)
  end)

  test.it("uses the represented file as a File History Path Target", function(context)
    local session, view = open_fake_git_view(context.project)
    local tab = {
      id = "history-path-target",
      kind = "file_history",
      title = "History: src/app.lua",
      closable = true,
      relpath = "src/app.lua",
      commits = {},
      selected_commit = 1,
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local tab_view = git_view.ensure_tab_view(session, tab, true)
    tab_view:update_pane_buffers()

    local target = test.not_nil(file_context.view_path_target(tab_view:pane_view("history-list")))
    test.equal(target.path, common.normalize_path(context.project.path .. PATHSEP .. "src/app.lua"))
    test.is_nil(target.line)
  end)

  test.test("selecting a history commit loads changed files for details", function(context)
    local session, view = open_fake_git_view(context.project)
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
    local history_view = git_view.ensure_tab_view(session, tab, true)
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

  test.it("commit diff file list renders changed files as a project-relative tree", function(context)
    local session, view = open_fake_git_view(context.project)
    local tab = {
      id = "diff-tree",
      kind = "commit_diff",
      title = "Diff tree",
      closable = true,
      changed_files = {
        { status = "modified", old_path = "src/main/App.kt", new_path = "src/main/App.kt", stat = { additions = 2, deletions = 44 } },
        { status = "deleted", old_path = "README.md", new_path = "README.md", stat = { additions = 0, deletions = 5 } },
        { status = "added", old_path = "src/main/Util.kt", new_path = "src/main/Util.kt", stat = { additions = 3, deletions = 0 } },
      },
      selected_file = 3,
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local tab_view = git_view.ensure_tab_view(session, tab, true)

    tab_view:update_pane_buffers()
    local list = tab_view:pane_view("file-list")
    test.ok(list:extends(path_tree.View))
    test.equal(list.buffer.lines[1], "src/main/\n")
    test.equal(list.buffer.lines[2], "\tApp.kt\n")
    test.equal(list.buffer.lines[3], "\tUtil.kt\n")
    test.equal(list.buffer.lines[4], "README.md\n")
    test.equal(list.git_file_line_to_index[2], 1)
    test.equal(list.git_file_line_to_index[3], 3)
    test.equal(list.git_file_index_to_line[3], 3)
    test.equal(list.git_file_index_to_line[2], 4)
    test.equal(list.buffer:get_selection(), 3)
    local hint = list:get_line_hint(2)
    test.equal(hint[1].text, "+2")
    test.equal(hint[2].text, " −44")

    core.active_view = list
    list.buffer:set_selection(1, 1)
    tab_view:sync_selection_from_pane()
    test.equal(tab.selected_file, 3)
    list.buffer:set_selection(2, 1)
    tab_view:sync_selection_from_pane()
    test.equal(tab.selected_file, 1)

    list.buffer:set_selection(1, 1)
    test.equal(command.perform("git:activate_selected_row"), true)
    test.equal(list.buffer.lines[2], "README.md\n")
    test.equal(list.buffer.lines[3], nil)
    test.equal(tab.selected_file, 1)
    test.equal(command.perform("git:activate_selected_row"), true)
    test.equal(list.buffer.lines[2], "\tApp.kt\n")
    test.equal(list.buffer.lines[3], "\tUtil.kt\n")

    tab_view:select_relative(1)
    test.equal(tab.selected_file, 3)
    test.equal(list.buffer:get_selection(), 3)
    tab_view:select_relative(1)
    test.equal(tab.selected_file, 2)
    test.equal(list.buffer:get_selection(), 4)

    view.model:log_tab().commits = {
      { hash = "tree", subject = "Tree", changed_files = tab.changed_files, changed_files_loaded = true },
    }
    view.model:log_tab().selected_commit = 1
    view:update_pane_buffers()
    local details = view:pane_view("details")
    test.ok(details:extends(path_tree.View))
    test.same(details.path_tree:lines(), list.path_tree:lines())
  end)

  test.it("uses changed-file rows as Git Path Targets", function(context)
    local session, view = open_fake_git_view(context.project)
    local changed = { status = "modified", old_path = "src/App.kt", new_path = "src/App.kt" }
    local tab = {
      id = "diff-path-target",
      kind = "commit_diff",
      title = "Diff Path Target",
      closable = true,
      changed_files = { changed },
      selected_file = 1,
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local tab_view = git_view.ensure_tab_view(session, tab, true)
    tab_view:update_pane_buffers()
    local list = tab_view:pane_view("file-list")
    list.buffer:set_selection(list.path_tree:line_for_record(1), 1)

    view.model:log_tab().commits = {
      { hash = "target", subject = "Target", changed_files = { changed }, changed_files_loaded = true },
    }
    view.model:log_tab().selected_commit = 1
    view:update_pane_buffers()
    local details = view:pane_view("details")
    details.buffer:set_selection(details.path_tree_line_offset + details.path_tree:line_for_record(1), 1)

    local expected = common.normalize_path(context.project.path .. PATHSEP .. "src/App.kt")
    test.equal(test.not_nil(file_context.view_path_target(list)).path, expected)
    test.equal(test.not_nil(file_context.view_path_target(details)).path, expected)
  end)

  test.it("keeps an inactive list caret on the collapsed ancestor of its selected file", function(context)
    local session, view = open_fake_git_view(context.project)
    local tab = {
      id = "diff-collapsed-selection",
      kind = "commit_diff",
      title = "Diff collapsed selection",
      closable = true,
      changed_files = {
        { status = "modified", old_path = "README.md", new_path = "README.md" },
        { status = "modified", old_path = "src/main/App.kt", new_path = "src/main/App.kt" },
      },
      selected_file = 2,
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local tab_view = git_view.ensure_tab_view(session, tab, true)
    tab_view:update_pane_buffers()
    local list = tab_view:pane_view("file-list")
    core.active_view = list
    list.buffer:set_selection(1, 1)

    test.equal(command.perform("git:activate_selected_row"), true)
    test.equal(tab.selected_file, 2)
    test.equal(list.buffer.lines[1], "src/main/\n")
    test.equal(list.buffer.lines[2], "README.md\n")

    core.active_view = tab_view
    tab_view:update_pane_buffers()
    test.equal(list.buffer:get_selection(), 1)
  end)

  test.it("activates a changed file from Git Log details with that file preselected", function(context)
    local session, view = open_fake_git_view(context.project)
    local commit = {
      hash = "details-tree",
      subject = "Details tree",
      parents = {},
      changed_files_loaded = true,
      changed_files = {
        { status = "modified", old_path = "src/App.kt", new_path = "src/App.kt" },
        { status = "deleted", old_path = "README.md", new_path = nil },
        { status = "added", old_path = nil, new_path = "src/Util.kt" },
      },
    }
    local backend = {}
    for key, value in pairs(fake_backend) do backend[key] = value end
    backend.changed_files = function(repo, left, right, opts, callback)
      callback(commit.changed_files, nil)
      return { cancel = function() end }
    end
    view.model.backend = backend
    view.model:log_tab().commits = { commit }
    view.model:log_tab().selected_commit = 1
    view:update_pane_buffers()

    local details = view:pane_view("details")
    local folder_line = details.path_tree_line_offset + details.path_tree:line_for_path("src", "dir")
    core.active_view = details
    details.buffer:set_selection(folder_line, 1)
    test.equal(view:activate_selected_point(function() core.redraw = true end), nil)
    view:update_pane_buffers()
    test.equal(details.path_tree:is_expanded("src"), false)
    test.equal(details.path_tree:line_for_record(3), nil)
    test.equal(view:activate_selected_point(function() core.redraw = true end), nil)
    view:update_pane_buffers()
    test.equal(details.path_tree:is_expanded("src"), true)

    local line = details.path_tree_line_offset + details.path_tree:line_for_record(3)
    details.buffer:set_selection(line, 1)
    test.not_nil(details:get_point_of_interest_at(line))

    test.equal(command.perform("core:activate_point_of_interest"), true)
    local opened = view.model:selected_tab()
    test.not_nil(opened)
    test.equal(opened.kind, "commit_diff")
    test.equal(opened.selected_file_path, "src/Util.kt")
    test.equal(opened.selected_file, 3)
  end)

  test.it("invalidates embedded Path Tree layout when Git details rows are replaced", function(context)
    local session, view = open_fake_git_view(context.project)
    local long_name = string.rep("i", 260) .. ".txt"
    local commit = {
      hash = "details-layout",
      subject = "Details layout",
      parents = {},
      changed_files_loaded = true,
      changed_files = {
        { status = "modified", old_path = "a/b/" .. long_name, new_path = "a/b/" .. long_name },
      },
    }
    view.model:log_tab().commits = { commit }
    view.model:log_tab().selected_commit = 1
    view:update_pane_buffers()
    local details = view:pane_view("details")
    local line = details.path_tree_line_offset + details.path_tree:line_for_record(1)
    local before = details:get_col_x_offset(line, 100)
    local before_revision = details.buffer.text_revision

    commit.changed_files = {
      { status = "modified", old_path = "a/x.txt", new_path = "a/x.txt" },
      { status = "modified", old_path = long_name, new_path = long_name },
    }
    view:update_pane_buffers()
    local after = details:get_col_x_offset(line, 100)

    test.not_equal(before, after)
    test.ok(details.buffer.text_revision > before_revision)
  end)

  test.test("commit diff tabs can focus diff content and return to the Git list", function(context)
    local session, view = open_fake_git_view(context.project)
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
    local tab_view = git_view.ensure_tab_view(session, tab, true)
    core.active_view = tab_view

    test.equal(command.perform("git:focus_diff_pane"), true)
    test.equal(core.active_view.git_owner_view, tab_view)
    session:activate_root()
    test.equal(core.active_view.git_owner_view, tab_view)
    git_view.sync_tab_views(session, false)
    test.equal(core.active_view.git_owner_view, tab_view)
    test.equal(command.perform("git:focus_list_pane"), true)
    test.equal(core.active_view.git_owner_view, tab_view)
    test.equal(core.active_view.git_pane, "file-list")
  end)

  test.it("uses old and new paths for renamed Git Diff Sides", function(context)
    local session, view = open_fake_git_view(context.project)
    local tab = {
      id = "diff-side-path-targets",
      kind = "commit_diff",
      title = "Renamed Diff",
      closable = true,
      changed_files = {
        { status = "renamed", old_path = "src/old.lua", new_path = "src/new.lua" },
      },
      selected_file = 1,
      left_text = "old one\nold two\n",
      right_text = "new one\nnew two\n",
      left_name = "src/old.lua",
      right_name = "src/new.lua",
      diff_generation = 1,
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local tab_view = git_view.ensure_tab_view(session, tab, true)
    local diff = tab_view:ensure_diff_view(tab)
    diff.buffer_view_b:with_selection_state(function()
      diff.buffer_view_b.buffer:set_selection(2, 1)
    end)

    local left = test.not_nil(file_context.view_path_target(diff.buffer_view_a))
    local right = test.not_nil(file_context.view_path_target(diff.buffer_view_b))
    test.equal(left.path, common.normalize_path(context.project.path .. PATHSEP .. "src/old.lua"))
    test.equal(right.path, common.normalize_path(context.project.path .. PATHSEP .. "src/new.lua"))
    test.equal(left.line, 2)
    test.equal(right.line, 2)

    local copied
    system.set_clipboard = function(text) copied = text end
    core.active_view = diff.buffer_view_b
    test.ok(command.perform("editor:copy_absolute_filepath_with_line"))
    test.equal(copied, right.path .. ":2")
  end)

  test.it("focused Git diff TextView becomes the active Git pane", function(context)
    local session, view = open_fake_git_view(context.project)
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
    local tab_view = git_view.ensure_tab_view(session, tab, true)
    tab_view.position.x, tab_view.position.y = 0, 0
    tab_view.size.x, tab_view.size.y = 800, 600

    test.equal(command.perform("git:focus_diff_pane"), true)
    local diff = tab.diff_view
    local buffer_view = diff.buffer_view_a
    test.equal(core.active_view, buffer_view)
    test.equal(core.active_view.git_owner_view, tab_view)
  end)

  test.test("opening Git over a dirty Untitled requests one close confirmation", function(context)
    local buffer = Buffer(nil, nil, true)
    buffer.intellij_untitled = true
    buffer.intellij_untitled_name = "Untitled-Git-Open"
    buffer:insert(1, 1, "keep me")
    panes.create { factory = function() return Editor(buffer) end }
    local prompts = 0
    core.nag_view.show = function()
      prompts = prompts + 1
    end

    open_fake_git_view(context.project)

    test.equal(prompts, 1)
  end)

  test.it("updates an embedded commit diff before drawing", function(context)
    local session, view = open_fake_git_view(context.project)
    local tab = {
      id = "diff-update",
      kind = "commit_diff",
      title = "Diff update",
      closable = true,
      changed_files = {
        { status = "modified", old_path = "a.lua", new_path = "a.lua" },
      },
      selected_file = 1,
      left_text = "old\n",
      right_text = "new\n",
      left_name = "a.lua",
      right_name = "a.lua",
      diff_generation = 1,
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local tab_view = git_view.ensure_tab_view(session, tab, true)
    tab_view.position.x, tab_view.position.y = 0, 0
    tab_view.size.x, tab_view.size.y = 800, 600
    local diff = tab_view:ensure_diff_view(tab)
    local updates = 0
    diff.update = function() updates = updates + 1 end

    tab_view:update()

    test.equal(updates, 1)
  end)

  test.it("keeps Git Log pane TextViews unwrapped", function(context)
    config.plugins.linewrapping.enable_by_default = true
    local session, view = open_fake_git_view(context.project)
    view:update_pane_buffers()
    local list = view:pane_view("log-list")
    local details = view:pane_view("details")
    test.equal(list:is_wrapping_enabled(), false)
    test.equal(details:is_wrapping_enabled(), false)
  end)

  test.it("uses the rendered Git commit fonts for caret geometry", function(context)
    local _, view = open_fake_git_view(context.project)
    local commit = { hash = "abcdef0", short_hash = "abcdef0", subject = "Variable width subject" }
    view.model:log_tab().commits = { commit }
    view:update_pane_buffers()
    local list = view:pane_view("log-list")
    local line = list.buffer.lines[1]:gsub("\n$", "")
    local expected = style.code_font:get_width(commit.short_hash)
      + list:get_font():get_width("  " .. commit.subject)

    test.equal(list:get_col_x_offset(1, #line + 1), expected)
  end)

  test.test("Local Focus Cycle enters and wraps through Git Log targets", function(context)
    local session, view = open_fake_git_view(context.project)
    core.active_view = view

    test.equal(command.perform("pane:focus_local_next"), true)
    test.equal(core.active_view.git_owner_view, view)
    test.equal(core.active_view.git_pane, "log-list")
    test.equal(core.active_view:get_gutter_width(), 0)
    test.equal(core.active_view:draw_line_gutter(1, 0, 0, 0), core.active_view:get_line_height())
    session:activate_root()
    test.equal(core.active_view.git_pane, "log-list")
    core.active_view.buffer:set_selection(1, 2)
    session:activate_root()
    test.equal(select(2, core.active_view.buffer:get_selection()), 2)
    test.equal(command.perform("pane:focus_local_next"), true)
    test.equal(core.active_view.git_pane, "details")
    test.equal(command.perform("pane:focus_local_next"), true)
    test.equal(core.active_view.git_pane, "log-list")
    test.equal(command.perform("pane:focus_local_previous"), true)
    test.equal(core.active_view.git_pane, "details")
  end)

  test.it("flattens Git surfaces and an ordinary sibling Pane into one local cycle", function(context)
    local _, view = open_fake_git_view(context.project)
    local git_pane = panes.pane_for_view(view)
    local editor_pane = panes.split(git_pane, "right", {
      factory = function() return View() end,
      focus = false,
    })
    panes.focus(git_pane)
    view:focus_list_pane()

    test.ok(command.perform("pane:focus_local_next"))
    test.equal(core.active_view.git_pane, "details")
    test.ok(command.perform("pane:focus_local_next"))
    test.equal(panes.active(), editor_pane)
    test.equal(core.active_view, editor_pane.current_view)
    test.ok(command.perform("pane:focus_local_next"))
    test.equal(panes.active(), git_pane)
    test.equal(core.active_view.git_pane, "log-list")

    test.ok(command.perform("pane:focus_local_previous"))
    test.equal(panes.active(), editor_pane)
    test.ok(command.perform("pane:focus_local_previous"))
    test.equal(core.active_view.git_pane, "details")
    test.ok(panes.validate())
  end)

  test.it("opens and restores a Git View through Pane history", function(context)
    local session, view = git_view.open_view(context.project, {
      root = core.root_panel,
      git_view_opts = { backend = fake_backend },
    })
    local pane = panes.pane_for_view(view)
    test.not_nil(pane)
    panes.present(View(), { pane = pane })
    session:activate_root()
    test.equal(pane.current_view, view)
    test.equal(core.active_view.git_owner_view, view)
  end)

  test.it("Local Focus Cycle wraps through Git diff targets in both directions", function(context)
    local session, view = open_fake_git_view(context.project)
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
    local tab_view = git_view.ensure_tab_view(session, tab, true)
    core.active_view = tab_view

    test.equal(command.perform("pane:focus_local_next"), true)
    test.equal(core.active_view.git_pane, "file-list")
    session:activate_root()
    test.equal(core.active_view.git_pane, "file-list")
    test.equal(command.perform("pane:focus_local_next"), true)
    local diff = tab.diff_view
    test.equal(diff.request.kind, "git")
    test.equal(nil, diff.request.metadata)
    test.equal(diff.request.user_data.selected_file_path, "a.lua")
    test.equal(diff.request.user_data.source, "git")
    test.equal(diff.request.user_data.read_only_reason, "Git commit diff is read-only")
    test.equal(diff.request.editable_policy, "read-only")
    test.equal(core.active_view, diff.buffer_view_a)
    diff.buffer_view_a.get_points_of_interest = function()
      return { { line = 2, col = 1, line_only_navigation = true, scroll_to_line = true } }
    end
    diff.buffer_view_a.buffer:set_selection(1, 1)
    test.equal(command.perform("core:next_point_of_interest"), true)
    local line = diff.buffer_view_a.buffer:get_selection()
    test.equal(line, 2)

    test.equal(command.perform("pane:focus_local_next"), true)
    test.equal(core.active_view, diff.buffer_view_b)
    test.equal(command.perform("pane:focus_local_next"), true)
    test.equal(core.active_view.git_pane, "file-list")

    test.equal(command.perform("pane:focus_local_previous"), true)
    test.equal(core.active_view, diff.buffer_view_b)
    test.equal(command.perform("pane:focus_local_previous"), true)
    test.equal(core.active_view, diff.buffer_view_a)
    test.equal(command.perform("pane:focus_local_previous"), true)
    test.equal(core.active_view.git_pane, "file-list")

    test.equal(command.perform("pane:focus_local_next"), true)
    test.equal(core.active_view, diff.buffer_view_a)
    test.equal(command.perform("git:close_selected_tab"), true)
    test.ok(core.active_view ~= tab_view)
    test.ok(core.active_view.git_owner_view ~= tab_view)
    test.equal(command.perform("pane:focus_local_next"), true)
    test.ok(core.active_view ~= tab_view)

  end)

  test.test("keyboard row commands navigate and activate Git rows", function(context)
    local session, view = open_fake_git_view(context.project)
    core.active_view = view
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 600
    view.model.repo = { root = "C:/repo" }
    view.model:log_tab().commits = {
      { hash = "a", short_hash = "a", subject = "First", parents = {} },
      { hash = "b", short_hash = "b", subject = "Second", parents = {} },
    }

    test.equal(command.perform("git:select_next_row"), true)
    test.equal(view.model:selected_commit().hash, "b")
    local list = view:pane_view("log-list")
    test.equal(list.buffer:get_selection(), 2)
    test.equal(command.perform("core:activate_point_of_interest"), true)
    test.equal(view.model:selected_tab().kind, "commit_diff")
    test.equal(#session_views(session), 2)

    core.active_view = {}
    test.equal(command.perform("git:select_next_row"), false)
  end)

  test.it("does not activate a Git row while another Pane View has focus", function(context)
    local session, view = git_view.open_view(context.project, {
      root = core.root_panel,
      git_view_opts = { backend = fake_backend },
    })
    core.projects = { context.project }
    view.model:log_tab().commits = {
      { hash = "a", short_hash = "a", subject = "First", parents = {} },
    }
    local panel = View()
    panes.create { factory = function() return panel end, focus = true }

    test.equal(command.perform("git:activate_selected_row"), false)
    test.equal(view.model:selected_tab().kind, "log")
  end)

  test.test("mouse wheel scrolls a long log", function(context)
    local session, view = open_fake_git_view(context.project)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 120
    core.active_view = view
    view.model:log_tab().commits = {}
    for i = 1, 20 do
      view.model:log_tab().commits[i] = { hash = tostring(i), short_hash = tostring(i), subject = "Commit " .. i }
    end
    test.equal(view:on_mouse_wheel(0, -1), false)
    test.equal(view.scroll.to.y, 0)
    view:on_mouse_wheel(-1, 0)
    test.ok(view.scroll.to.y > 0)
    test.equal(session.hidden, false)
  end)

  test.it("scrolls the rendered Path Tree while navigating an inactive diff file list", function(context)
    local session, view = open_fake_git_view(context.project)
    local files = {}
    for index = 1, 40 do
      local path = string.format("src/file-%03d.lua", index)
      files[index] = { status = "modified", old_path = path, new_path = path }
    end
    local tab = {
      id = "diff-path-tree-scroll",
      kind = "commit_diff",
      title = "Diff Path Tree scroll",
      closable = true,
      changed_files = files,
      selected_file = 1,
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local tab_view = git_view.ensure_tab_view(session, tab, true)
    tab_view:update_pane_buffers()
    local list = tab_view:pane_view("file-list")
    list.position.x, list.position.y = 0, 0
    list.size.x, list.size.y = 240, 80
    core.active_view = tab_view

    for _ = 1, 20 do tab_view:select_relative(1) end
    test.equal(tab.selected_file, 21)
    test.ok(list.scroll.y > 0)

    local before = list.scroll.to.y
    tab.file_list_hover = true
    test.equal(tab_view:on_mouse_wheel(-1, 0), true)
    test.ok(list.scroll.to.y > before)
  end)

  test.test("saves and restores hidden Git View Pane Tab state", function(context)
    local session, view = open_fake_git_view(context.project)
    local history_tab = view.model:open_file_history("src/app.lua")
    view.model.active_tab = history_tab.id
    session:hide()

    local state = git_view.save_state(session)
    panes.git_sessions = {}
    git_view.restore_state(context.project, state, {
        window = fake_window(2222),
        window_id = 2222,
        git_view_opts = { backend = fake_backend },
    })

    local restored = panes.git_sessions[context.project.path]
    test.not_nil(restored)
    test.equal(restored.hidden, true)
    test.equal(restored.git_view.model.active_tab, history_tab.id)
    test.not_nil(restored.git_view.model:find_tab(history_tab.id))
  end)

  test.it("round-trips the selected Git tab through Pane Workspace state", function(context)
    core.projects = { context.project }
    local session, view = open_fake_git_view(context.project)
    local history_tab = view.model:open_file_history("src/app.lua")
    local history_view = git_view.ensure_tab_view(session, history_tab, true)
    local state = panes.save_workspace_state(function(candidate)
      return { module = candidate:get_module(), state = candidate:get_state() }
    end)
    test.equal(state.panes[1].view.state.tab_id, history_tab.id)

    panes.reset_for_tests()
    panes.git_sessions = {}
    test.ok(panes.restore_workspace_state(state, function(saved)
      return require(saved.module).from_state(saved.state)
    end))

    local restored = panes.active().current_view
    test.equal(restored.tab_id, history_tab.id)
    test.equal(restored.model.active_tab, history_tab.id)
    test.ok(restored ~= history_view)
    test.equal(panes.git_sessions[context.project.path].git_tab_views[history_tab.id], restored)
  end)

  test.test("syncing real tabs follows model tab id changes", function(context)
    local session, view = open_fake_git_view(context.project)
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
    local old_view = git_view.ensure_tab_view(session, tab, true)
    tab.id = "diff-new"
    tab.title = "Diff new"
    view.model.active_tab = "diff-new"

    git_view.sync_tab_views(session, true)

    test.equal(session.git_tab_views["diff-old"], nil)
    test.not_nil(session.git_tab_views["diff-new"])
    test.ok(session.git_tab_views["diff-new"] ~= old_view)
    test.equal(panes.active().current_view.tab_id, "diff-new")
  end)

  test.test("restoring over an existing Git View applies saved hidden state", function(context)
    local session, view = open_fake_git_view(context.project)
    local old_tab = view.model:open_file_history("old.lua")
    git_view.ensure_tab_view(session, old_tab, true)
    test.equal(#session_views(session), 2)
    git_view.restore_state(context.project,
      {
        kind = "git",
        hidden = true,
        model = {
          repo = { root = "C:/repo" },
          active_tab = "log",
          tabs = { { id = "log", kind = "log", selected_commit = 1 } },
        },
      })
    test.equal(session.hidden, true)
    test.equal(view.model.active_tab, "log")
    test.equal(view.model:find_tab("history\0file\0C:/repo\0old.lua"), nil)
    test.equal(session.git_tab_views[old_tab.id], nil)
    test.equal(#session_views(session), 1)
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
    git_view.restore_state(context.project,
      {
        kind = "git",
        hidden = true,
        model = {
          repo = { root = "C:/repo" },
          active_tab = "log",
          tabs = { { id = "log", kind = "log", selected_commit = 1, selected_commit_hash = "abc123" } },
        },
      }, {
        window = fake_window(3333),
        window_id = 3333,
        git_view_opts = { backend = backend },
    })
    local restored = panes.git_sessions[context.project.path]
    test.equal(restored.git_view.refresh_started, nil)
    test.equal(log_calls, 0)

    core.projects = { context.project }
    core.active_view = restored.git_view
    command.perform("git:open_selected_commit_diff")

    test.equal(log_calls, 1)
    test.equal(restored.git_view.model:selected_tab().kind, "commit_diff")
  end)

  test.test("close command closes the focused real Git tab", function(context)
    local session, view = open_fake_git_view(context.project)
    local tab = {
      id = "diff-close",
      kind = "commit_diff",
      title = "Diff close",
      closable = true,
      changed_files = {},
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local tab_view = git_view.ensure_tab_view(session, tab, true)
    core.projects = { context.project }
    core.active_view = tab_view

    test.equal(command.perform("git:close_selected_tab"), true)
    test.equal(view.model:find_tab(tab.id), nil)
    test.equal(session.git_tab_views[tab.id], nil)
    test.equal(session.hidden, false)
  end)

  test.test("closing the Git Log Pane Tab removes the owning Git session", function(context)
    local session, view = open_fake_git_view(context.project)
    local closed = false
    local pane = panes.pane_for_view(view)
    closed = panes.close_view(pane, { view = view })
    test.equal(closed, true)
    test.equal(session.hidden, true)
    test.equal(session.git_view, nil)
    test.equal(panes.git_sessions[context.project.path], nil)
  end)

  test.test("closing the Git Log Pane Tab removes sibling Git tabs and repairs focus", function(context)
    local session, view = open_fake_git_view(context.project)
    local tab = {
      id = "diff-sibling",
      kind = "commit_diff",
      title = "Diff sibling",
      closable = true,
      changed_files = {},
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local sibling = git_view.ensure_tab_view(session, tab, true)
    core.active_view = sibling
    local pane = panes.pane_for_view(view)
    panes.close_view(pane, { view = view })
    test.equal(panes.git_sessions[context.project.path], nil)
    test.equal(#session_views(session), 0)
    test.ok(core.active_view ~= sibling)
    test.ok(panes.validate())
  end)

  test.test("closing a Git Pane with sibling tabs focuses a remaining Pane", function(context)
    local session, view = open_fake_git_view(context.project)
    local tab = {
      id = "diff-close-pane",
      kind = "commit_diff",
      title = "Diff close Pane",
      closable = true,
      changed_files = {},
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    git_view.ensure_tab_view(session, tab, true)
    local git_pane = panes.pane_for_view(view)
    local remaining = panes.split(git_pane, "right", {
      factory = function() return View() end,
      focus = false,
    })
    panes.focus(git_pane)

    test.ok(command.perform("pane:close"))

    test.not_ok(panes.contains(git_pane))
    test.equal(panes.active(), remaining)
    test.equal(core.active_view, remaining.current_view)
    test.ok(panes.validate())
  end)

  test.test("command predicates tolerate zero-Pane focus", function(context)
    local old_text_input = system.text_input
    system.text_input = function() return true end
    panes.reset_for_tests()
    core.active_view = {}

    local ok = pcall(command.is_valid, "git:focus_list_pane")
    system.text_input = old_text_input
    test.equal(ok, true)
  end)

  test.test("command is registered", function()
    test.not_nil(command.map["git:open"])
    test.not_nil(command.map["git:open_selected_commit_diff"])
    test.not_nil(command.map["git:open_working_tree_diff"])
    test.not_nil(command.map["git:show_file_history"])
    test.not_nil(command.map["git:show_selection_history"])
    test.not_nil(command.map["git:open_selected_historical_buffer"])
    test.not_nil(command.map["git:close_selected_tab"])
    test.not_nil(command.map["git:select_next_row"])
    test.not_nil(command.map["git:select_previous_row"])
    test.not_nil(command.map["git:activate_selected_row"])
    test.not_nil(command.map["git:focus_diff_pane"])
    test.not_nil(command.map["git:focus_list_pane"])
  end)
end)
