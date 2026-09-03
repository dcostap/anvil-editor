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
local diffview = require "plugins.diffview"
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
  return git_view.open_log(project, {
    window = fake_window(1111),
    window_id = 1111,
    git_view_opts = { backend = fake_backend },
  })
end

local function wait_until(predicate, timeout, message)
  local deadline = system.get_time() + (timeout or 1)
  while not predicate() do
    if system.get_time() >= deadline then
      test.fail(message or "timed out waiting for condition", 2)
    end
    coroutine.yield(0.01)
  end
end

local function use_fake_command_git_views(context)
  git_view.open_log = function(project, opts)
    opts = opts or {}
    opts.window = fake_window(2222)
    opts.window_id = 2222
    opts.git_view_opts = { backend = fake_backend }
    return context.original_open_log(project, opts)
  end
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

local function buffer_text(buffer)
  return table.concat(buffer.lines or {})
end

test.describe("Git View command", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.original_projects = core.projects
    context.original_active_view = core.active_view
    context.original_active_window = core.active_window
    context.original_root_panel = core.root_panel
    context.original_nag_show = core.nag_view.show
    context.original_set_clipboard = system.set_clipboard
    context.original_open_log = git_view.open_log
    context.original_linewrapping_default = config.plugins.linewrapping.enable_by_default
    context.original_scroll_context_lines = config.scroll_context_lines
    panes.git_sessions = {}
    context.project = { path = "C:/repo" }
  end)

  test.after_each(function(context)
    panes.reset_for_tests()
    core.projects = context.original_projects
    core.active_view = context.original_active_view
    core.active_window = context.original_active_window
    core.root_panel = context.original_root_panel
    core.nag_view.show = context.original_nag_show
    system.set_clipboard = context.original_set_clipboard
    git_view.open_log = context.original_open_log
    config.plugins.linewrapping.enable_by_default = context.original_linewrapping_default
    config.scroll_context_lines = context.original_scroll_context_lines
    panes.git_sessions = {}
  end)

  test.test("each Git Log open creates an independent Git session", function(context)
    local first_session, first_view = open_fake_git_view(context.project)
    local second_session, second_view = open_fake_git_view(context.project)

    test.ok(first_session ~= second_session)
    test.ok(first_view ~= second_view)
    test.ok(first_view.model ~= second_view.model)
  end)

  test.test("git:open_log creates the Git Log in the invoking Pane", function(context)
    local first_session, first_view = open_fake_git_view(context.project)
    local first_pane = panes.pane_for_view(first_view)
    local invoking_pane = panes.split(first_pane, "right", {
      factory = function() return View() end,
      focus = true,
    })
    core.projects = { context.project }
    use_fake_command_git_views(context)

    test.equal(command.perform("git:open_log"), true)

    local opened = invoking_pane.current_view
    test.equal(panes.active(), invoking_pane)
    test.ok(opened ~= first_view)
    test.ok(opened.git_session ~= first_session)
    test.equal(first_pane.current_view, first_view)
  end)

  test.it("loads a Commit Diff View created without focus", function(context)
    local session, log_view = open_fake_git_view(context.project)
    local tab = {
      id = "restored-diff-load",
      kind = "commit_diff",
      title = "Restored Diff",
      closable = true,
      left = "parent",
      right = "commit",
      changed_files = {},
      selected_file = 1,
    }
    log_view.model.tabs[#log_view.model.tabs + 1] = tab
    local calls = 0
    local old_load = log_view.model.load_view
    log_view.model.load_view = function(model, candidate, callback)
      calls = calls + 1
      return old_load(model, candidate, callback)
    end

    git_view.ensure_tab_view(session, tab, false)

    test.equal(calls, 1)
  end)

  test.it("uses a nested repository session for the current-file Diff", function(context)
    local parent_session, parent_log = open_fake_git_view(context.project)
    local target = View()
    target.get_path_target = function() return { path = "C:/repo/vendor/src/app.lua" } end
    core.active_view = target
    core.projects = { context.project }
    use_fake_command_git_views(context)
    local old_lookup = real_backend.repo_for_path_async
    real_backend.repo_for_path_async = function(path, callback)
      callback({ root = "C:/repo/vendor", relpath = "src/app.lua" }, nil)
    end

    command.perform("git:open_current_file_in_project_diff")
    real_backend.repo_for_path_async = old_lookup

    local nested_session = panes.active().current_view.git_session
    test.equal(nested_session.project_key, "C:/repo/vendor")
    test.ok(nested_session ~= parent_session)
    test.equal(parent_session.git_model.repo.root, "C:/repo")
    test.equal(parent_log.model.repo.root, "C:/repo")
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

  test.it("routes auxiliary mouse navigation before Git pointer input", function(context)
    local root = RootPanel()
    root.position.x, root.position.y = 0, 0
    root.size.x, root.size.y = 1000, 600
    core.root_panel = root

    local first = View()
    local active_pane = panes.create { factory = function() return first end }
    local second = View()
    panes.present(second, { pane = active_pane })

    local git_pane = panes.split(active_pane, "right", {
      factory = function() return View() end,
      focus = true,
    })
    local _, view = open_fake_git_view(context.project)
    local tab = view.model:log_tab()
    tab.commits = {
      { hash = "a", short_hash = "a", subject = "First", parents = {} },
    }
    tab.selected_commit = 1

    panes.focus(active_pane)
    root:update()
    local x = view.position.x + view.size.x / 2
    local y = view.position.y + view.size.y / 2
    local tab_count = #view.model.tabs

    core.on_event("mousepressed", "x", x, y, 2)
    core.on_event("mousereleased", "x", x, y)

    test.equal(panes.active(), active_pane)
    test.equal(active_pane.current_view, first)
    test.equal(git_pane.current_view, view)
    test.equal(#view.model.tabs, tab_count)

    core.on_event("mousepressed", "y", x, y, 1)
    core.on_event("mousereleased", "y", x, y)

    test.equal(panes.active(), active_pane)
    test.equal(active_pane.current_view, second)
    test.equal(git_pane.current_view, view)
    test.equal(#view.model.tabs, tab_count)
  end)

  test.it("keeps existing commits visible while the Git Log refreshes", function(context)
    local session, view = open_fake_git_view(context.project)
    local tab = view.model:log_tab()
    tab.commits = { { hash = "abc", short_hash = "abc", subject = "Existing commit" } }
    tab.loading = true

    view:update_pane_buffers()

    test.ok(view:pane_view("log-list").buffer:get_utf8_line(1):find("Existing commit", 1, true))
  end)

  test.it("shows the repository commit total instead of the loaded page size", function(context)
    local _, view = open_fake_git_view(context.project)
    local tab = view.model:log_tab()
    tab.commits = {}
    for index = 1, 500 do tab.commits[index] = { hash = tostring(index) } end
    tab.has_more = true
    tab.total_commits = 1234

    test.equal(view:log_commit_count_text(tab), "1234 commits")
  end)

  test.it("loads the next Log page when scrolling near the loaded end", function(context)
    local _, view = open_fake_git_view(context.project)
    local tab = view.model:log_tab()
    tab.commits = {}
    for index = 1, 500 do
      tab.commits[index] = { hash = tostring(index), short_hash = tostring(index), subject = "Commit" }
    end
    tab.has_more = true
    tab.next_offset = 500
    local list = view:pane_view("log-list")
    view:update_pane_buffers()
    list.size.y = 200
    list.scroll.y = 500 * view:row_height()
    list.scroll.to.y = list.scroll.y
    local calls = 0
    view.model.load_more_log = function()
      calls = calls + 1
      tab.loading_more = true
      return true
    end

    view:update()

    test.equal(calls, 1)
  end)

  test.it("loads the next File History page near its loaded end", function(context)
    local session, log_view = open_fake_git_view(context.project)
    local tab = {
      id = "history-auto-page",
      kind = "file_history",
      title = "History: src/app.lua",
      closable = true,
      relpath = "src/app.lua",
      commits = {},
      selected_commit = 1,
      has_more = true,
      next_offset = 100,
    }
    for index = 1, 100 do
      tab.commits[index] = { hash = tostring(index), short_hash = tostring(index), subject = "Revision" }
    end
    log_view.model.tabs[#log_view.model.tabs + 1] = tab
    local history_view = git_view.ensure_tab_view(session, tab, true)
    history_view:update_pane_buffers()
    local list = history_view:pane_view("history-list")
    list.size.y = 200
    list.scroll.y = 100 * history_view:row_height()
    list.scroll.to.y = list.scroll.y
    local calls = 0
    log_view.model.load_file_history = function()
      calls = calls + 1
      tab.loading = true
      return true
    end

    history_view:update()

    test.equal(calls, 1)
  end)

  test.it("keeps File History refreshes invisible when commits are already visible", function(context)
    local session, view = open_fake_git_view(context.project)
    local tab = {
      id = "history-test",
      kind = "file_history",
      title = "History: src/app.lua",
      relpath = "src/app.lua",
      commits = { { hash = "abc", short_hash = "abc", subject = "Existing revision" } },
      selected_commit = 1,
      loading = true,
      refreshing = true,
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    view.tab_id = tab.id

    view:update_pane_buffers()

    local buffer = view:pane_view("history-list").buffer
    test.ok(buffer:get_utf8_line(1):find("Existing revision", 1, true))
    test.equal((buffer:get_utf8_line(2) or ""):find("Loading", 1, true), nil)
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

  test.it("persists File History Text View scroll state", function(context)
    local session, log_view = open_fake_git_view(context.project)
    local tab = {
      id = "history-scroll-state",
      kind = "file_history",
      title = "History: src/app.lua",
      closable = true,
      relpath = "src/app.lua",
      commits = {},
      selected_commit = 1,
    }
    for index = 1, 100 do
      tab.commits[index] = { hash = tostring(index), short_hash = tostring(index), subject = "Revision" }
    end
    log_view.model.tabs[#log_view.model.tabs + 1] = tab
    local history_view = git_view.ensure_tab_view(session, tab, true)
    history_view:update_pane_buffers()
    local list = history_view:pane_view("history-list")
    list.size.y = 100
    core.active_view = list

    list.scroll.y = 250
    list.scroll.to.y = 250
    history_view:update()

    local saved
    for _, item in ipairs(log_view.model:get_state().tabs) do
      if item.id == tab.id then saved = item end
    end
    test.ok(saved.scroll > 0)
  end)

  test.it("refreshes the current Git View when application focus returns", function(context)
    local session, view = open_fake_git_view(context.project)
    local calls = 0
    view.model.refresh_log = function(_, callback)
      calls = calls + 1
      if callback then callback(view.model, nil) end
    end
    core.active_view = view:pane_view("log-list")
    core.active_window = core.window

    core.on_event("focuslost")
    core.on_event("focusgained")

    test.equal(calls, 1)
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

  test.it("opens File History from a selected Path Target", function(context)
    local session = open_fake_git_view(context.project)
    local target = View()
    target.get_path_target = function()
      return { path = "C:/repo/src/from-tree.lua" }
    end
    core.active_view = target
    use_fake_command_git_views(context)
    local old_lookup = real_backend.repo_for_path_async
    real_backend.repo_for_path_async = function(path, callback)
      callback({ root = "C:/repo", relpath = "src/from-tree.lua" }, nil)
    end

    command.perform("git:show_file_history")
    real_backend.repo_for_path_async = old_lookup

    local opened = panes.active().current_view
    local found = opened:model_tab()
    test.ok(opened.git_session ~= session)
    test.not_nil(found)
    test.equal(found.relpath, "src/from-tree.lua")
  end)

  test.it("opens Selection History from a file-backed Diff fragment", function(context)
    local session = open_fake_git_view(context.project)
    local source = Buffer("src/source.lua", "C:/repo/src/source.lua", true)
    source:insert(1, 1, "before\nselected\nafter")
    local diff = diffview.open({
      contents = {
        diffview.content.text("old"),
        diffview.content.fragment(source, 2, 1, 2, 9),
      },
    }, true)
    core.active_view = diff.buffer_view_b
    diff.buffer_view_b:with_selection_state(function()
      diff.buffer_view_b.buffer:set_selection(1, 1, 1, 5)
    end)
    use_fake_command_git_views(context)
    local old_lookup = real_backend.repo_for_path_async
    real_backend.repo_for_path_async = function(path, callback)
      callback({ root = "C:/repo", relpath = "src/source.lua" }, nil)
    end

    command.perform("git:show_selection_history")
    real_backend.repo_for_path_async = old_lookup

    local opened = panes.active().current_view
    local found = opened:model_tab()
    test.ok(opened.git_session ~= session)
    test.not_nil(found)
    test.equal(found.relpath, "src/source.lua")
    test.equal(found.history_context.start_line, 2)
    test.equal(found.history_context.end_line, 2)
    diff:dispose_integrations()
    diff:dispose_owned_buffers()
    source:on_close()
  end)

  test.test("selecting a history commit loads its embedded Diff preview", function(context)
    local session, view = open_fake_git_view(context.project)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 600
    local file_at_calls = 0
    view.model.repo = { root = "C:/repo" }
    view.model.backend = {
      WORKING_TREE = real_backend.WORKING_TREE,
      EMPTY_TREE = real_backend.EMPTY_TREE,
      diff_endpoint_for_commit = real_backend.diff_endpoint_for_commit,
      file_at = function(repo, rev, relpath, opts, callback)
        file_at_calls = file_at_calls + 1
        callback(rev .. ":" .. relpath, nil)
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
    file_at_calls = 0

    history_view:on_mouse_pressed("left", 10, history_view:history_commits_y() + history_view:row_height() + 1, 1)

    test.equal(tab.selected_commit, 2)
    test.equal(file_at_calls, 1)
    test.equal(tab.preview_right_text, "b:src/app.lua")

    local tab_count = #view.model.tabs
    history_view:on_mouse_pressed(
      "left", 10,
      history_view:history_commits_y() + history_view:row_height() + 1,
      2
    )
    test.equal(#view.model.tabs, tab_count)

    local preview = history_view:ensure_history_diff_view(tab)
    preview.position.x = math.floor(history_view.size.x * 0.34) + style.padding.x
    preview.position.y = history_view:history_commits_y()
    preview.size.x = history_view.size.x - preview.position.x
    preview.size.y = history_view.size.y - preview.position.y
    preview:update()
    local calls_before_diff_click = file_at_calls
    history_view:on_mouse_pressed("left", 700, history_view:history_commits_y() + 1, 1)
    test.equal(tab.selected_commit, 2)
    test.equal(file_at_calls, calls_before_diff_click)
    test.ok(core.active_view == tab.history_diff_view.buffer_view_a
      or core.active_view == tab.history_diff_view.buffer_view_b)
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

  test.it("keeps folder collapse state with its commit when changed-file data is shared", function(context)
    local session, view = open_fake_git_view(context.project)
    local files = {
      { status = "modified", old_path = "src/App.kt", new_path = "src/App.kt" },
      { status = "modified", old_path = "src/Util.kt", new_path = "src/Util.kt" },
    }
    local first = {
      hash = "first-shared-tree",
      subject = "First",
      changed_files = files,
      changed_files_loaded = true,
    }
    local second = {
      hash = "second-shared-tree",
      subject = "Second",
      changed_files = files,
      changed_files_loaded = true,
    }
    local log = view.model:log_tab()
    log.commits = { first, second }
    log.selected_commit = 1
    view:update_pane_buffers()

    local details = view:pane_view("details")
    local folder_line = details.path_tree_line_offset + details.path_tree:line_for_path("src", "dir")
    test.equal(view:toggle_details_tree_folder(details, folder_line), true)
    test.equal(details.path_tree:is_expanded("src"), false)

    log.selected_commit = 2
    view:update_pane_buffers()

    test.equal(details.path_tree:is_expanded("src"), true)
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
    local opened
    for _, candidate in ipairs(view.model.tabs) do
      if candidate.kind == "commit_diff" then opened = candidate end
    end
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
    git_view.ensure_tab_view(session, tab, true)
    test.equal(core.active_view.git_owner_view, tab_view)
    git_view.sync_tab_views(session)
    test.equal(core.active_view.git_owner_view, tab_view)
    test.equal(command.perform("git:focus_list_pane"), true)
    test.equal(core.active_view.git_owner_view, tab_view)
    test.equal(core.active_view.git_pane, "file-list")
  end)

  test.it("preserves Diff Side scroll when changed content replaces the viewer", function(context)
    local _, view = open_fake_git_view(context.project)
    local tab = {
      id = "diff-scroll-reload",
      kind = "commit_diff",
      title = "Diff scroll reload",
      closable = true,
      changed_files = { { status = "modified", old_path = "a.lua", new_path = "a.lua" } },
      selected_file = 1,
      left_text = "old\n",
      right_text = "new\n",
      left_name = "a.lua",
      right_name = "a.lua",
      diff_generation = 1,
    }
    local first = view:ensure_diff_view(tab)
    first.buffer_view_a.scroll.x, first.buffer_view_a.scroll.to.x = 24, 28
    first.buffer_view_a.scroll.y, first.buffer_view_a.scroll.to.y = 320, 324
    first.buffer_view_b.scroll.x, first.buffer_view_b.scroll.to.x = 12, 16
    first.buffer_view_b.scroll.y, first.buffer_view_b.scroll.to.y = 320, 324

    tab.left_text = "replaced old\n"
    tab.right_text = "replaced new\n"
    tab.diff_generation = 2
    local replacement = view:ensure_diff_view(tab)

    test.ok(replacement ~= first)
    test.same(replacement.buffer_view_a.scroll, { x = 24, y = 320, to = { x = 28, y = 324 } })
    test.same(replacement.buffer_view_b.scroll, { x = 12, y = 320, to = { x = 16, y = 324 } })
    test.equal(replacement.pending_first_change_reveal, false)
    replacement:dispose_integrations()
    replacement:dispose_owned_buffers()
  end)

  test.it("reveals the first change when another Git file opens", function(context)
    local _, view = open_fake_git_view(context.project)
    local first_file = { status = "modified", old_path = "first.lua", new_path = "first.lua" }
    local second_file = { status = "modified", old_path = "second.lua", new_path = "second.lua" }
    local tab = {
      id = "diff-file-reveal",
      kind = "commit_diff",
      title = "Diff file reveal",
      closable = true,
      changed_files = { first_file, second_file },
      selected_file = 1,
      left_text = "old\n",
      right_text = "new\n",
      left_name = "first.lua",
      right_name = "first.lua",
      diff_generation = 1,
    }
    local first = view:ensure_diff_view(tab)
    first.buffer_view_a.scroll.y, first.buffer_view_a.scroll.to.y = 320, 320
    first.buffer_view_b.scroll.y, first.buffer_view_b.scroll.to.y = 320, 320

    local prefix = {}
    for i = 1, 40 do prefix[i] = "unchanged " .. i end
    tab.selected_file = 2
    tab.selected_file_path = "second.lua"
    tab.left_text = table.concat(prefix, "\n") .. "\nold value\n"
    tab.right_text = table.concat(prefix, "\n") .. "\nnew value\n"
    tab.left_name = "second.lua"
    tab.right_name = "second.lua"
    tab.diff_generation = 2
    local replacement = view:ensure_diff_view(tab)
    replacement.position.x, replacement.position.y = 0, 0
    replacement.size.x, replacement.size.y = 800, 200
    wait_until(function() return replacement.updater_idx == nil end, 1, "expected diff computation to finish")
    replacement:update()

    test.equal(replacement.buffer_view_b.buffer:get_selection(), 41)
    test.ok(replacement.buffer_view_b.scroll.to.y > 0)
    replacement:dispose_integrations()
    replacement:dispose_owned_buffers()
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

  test.it("uses the canonical editable Buffer for a working-tree Diff Side", function(context)
    local session, view = open_fake_git_view(context.project)
    view.model.repo = { root = "C:/repo" }
    local path = common.normalize_path("C:/repo/src/app.lua")
    local buffer = Buffer("src/app.lua", path, true)
    buffer:insert(1, 1, "unsaved current")
    core.buffer_registry:register(buffer, path)
    local tab = {
      id = "working-buffer",
      kind = "commit_diff",
      title = "Working Diff",
      left = "HEAD",
      right = real_backend.WORKING_TREE,
      changed_files = { { status = "modified", old_path = "src/app.lua", new_path = "src/app.lua" } },
      selected_file = 1,
      left_text = "committed\n",
      right_text = "",
      right_current_path = "src/app.lua",
      left_name = "src/app.lua",
      right_name = "src/app.lua",
      diff_generation = 1,
    }
    local diff = view:ensure_diff_view(tab)

    test.equal(diff.buffer_view_b.buffer, buffer)
    test.equal(table.concat(diff.buffer_view_b.buffer.lines), "unsaved current\n")
    diff.buffer_view_b:on_text_input("edited ")
    test.equal(table.concat(buffer.lines), "edited unsaved current\n")
    buffer:on_close()
  end)

  test.it("uses an Image Comparison View for binary image revisions", function(context)
    local _, view = open_fake_git_view(context.project)
    view.position.y = 40
    local image_path = DATADIR .. PATHSEP .. "plugins" .. PATHSEP
      .. "editor_wallpaper" .. PATHSEP .. "wallpaper.jpg"
    local tab = {
      id = "image-comparison",
      kind = "commit_diff",
      title = "Image comparison",
      changed_files = {
        { status = "modified", old_path = "before.jpg", new_path = "after.jpg", binary = true },
      },
      selected_file = 1,
      left_name = "before.jpg",
      right_name = "after.jpg",
      non_text = { kind = "binary", message = "Binary file changed" },
      binary_paths = { left = image_path, right = image_path },
      binary_generation_value = 1,
    }

    local list, _, _, _, _, _, comparison = view:layout_diff_tab(tab, 0)

    test.equal(tostring(comparison), "ImageComparisonView")
    test.equal(list.position.y, view.position.y)
    test.equal(comparison.position.y, view.position.y)
    test.not_nil(comparison.left_view.image)
    test.not_nil(comparison.right_view.image)
    test.equal(comparison.left_title, "Before — before.jpg")
    test.equal(comparison.right_title, "After — after.jpg")
    test.equal(tab.diff_view, nil)
  end)

  test.it("continues change navigation into the next changed file on repeat", function(context)
    local session, view = open_fake_git_view(context.project)
    view.model.repo = { root = "C:/repo" }
    local tab = {
      id = "cross-file-navigation",
      kind = "commit_diff",
      title = "Diff",
      left = "parent",
      right = "commit",
      changed_files = {
        { status = "modified", old_path = "a.lua", new_path = "a.lua" },
        { status = "modified", old_path = "b.lua", new_path = "b.lua" },
      },
      selected_file = 1,
      left_text = "old\n",
      right_text = "new\n",
      left_name = "a.lua",
      right_name = "a.lua",
      diff_generation = 1,
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local diff = view:ensure_diff_view(tab)
    local boundary = diff.request.user_data.on_change_boundary
    test.equal(type(boundary), "function")

    boundary(1, diff.buffer_view_b)
    test.equal(tab.selected_file, 1)
    boundary(1, diff.buffer_view_b)
    test.equal(tab.selected_file, 2)
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

  test.it("keeps the previous Diff View visible while the next file loads", function(context)
    local session, view = open_fake_git_view(context.project)
    local tab = {
      id = "diff-loading-presentation",
      kind = "commit_diff",
      title = "Diff loading presentation",
      closable = true,
      changed_files = {
        { status = "modified", old_path = "a.lua", new_path = "a.lua" },
        { status = "modified", old_path = "b.lua", new_path = "b.lua" },
      },
      selected_file = 1,
      left_text = "old a\n",
      right_text = "new a\n",
      left_name = "a.lua",
      right_name = "a.lua",
      diff_generation = 1,
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local tab_view = git_view.ensure_tab_view(session, tab, true)
    tab_view.position.x, tab_view.position.y = 0, 0
    tab_view.size.x, tab_view.size.y = 800, 300
    tab_view:update()
    local previous = test.not_nil(tab.diff_view)

    tab.selected_file = 2
    tab.loading_file = true
    tab.file_loading_started_at = system.get_time()
    local presented = select(7, tab_view:layout_diff_tab(tab, tab_view.position.x + style.padding.x))

    test.equal(presented, previous)
    test.equal(tab_view:file_loading_indicator_visible(tab, tab.file_loading_started_at + 0.999), false)
    test.equal(tab_view:file_loading_indicator_visible(tab, tab.file_loading_started_at + 1.001), true)
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

  test.it("lays out commit graph lanes and ref indicators in Git Log rows", function(context)
    local _, view = open_fake_git_view(context.project)
    view.model:log_tab().commits = {
      {
        hash = "merge", short_hash = "merge", subject = "Merge work",
        parents = { "left", "right" },
        ref_labels = { { kind = "head", label = "main" }, { kind = "tag", label = "v1" } },
      },
      { hash = "left", short_hash = "left", subject = "Left", parents = { "base" } },
      { hash = "right", short_hash = "right", subject = "Right", parents = { "base" } },
      { hash = "base", short_hash = "base", subject = "Base", parents = {} },
    }

    view:update_pane_buffers()

    local list = view:pane_view("log-list")
    test.ok(list:get_gutter_width() > 0)
    test.equal(list.git_graph_rows.max_lanes, 2)
    test.equal(list.git_graph_rows[3].node_lane, 2)
    local line = list.buffer:get_utf8_line(1)
    local main_position = test.not_nil(line:find("main", 1, true))
    local tag_position = test.not_nil(line:find("v1", 1, true))
    local subject_position = test.not_nil(line:find("Merge work", 1, true))
    test.ok(main_position < subject_position)
    test.ok(tag_position < subject_position)
  end)

  test.it("presents Local Changes without a fake commit hash", function(context)
    local _, view = open_fake_git_view(context.project)
    view.model:log_tab().commits = {
      {
        kind = "working_tree", short_hash = "", subject = "Local Changes",
        parents = { "head" }, changed_files = { { kind = "modified", path = "src/app.lua" } },
        changed_files_loaded = true,
      },
      { hash = "head", short_hash = "head", subject = "HEAD commit", parents = {} },
    }

    view:update_pane_buffers()

    local list = view:pane_view("log-list")
    local details = view:pane_view("details")
    local details_text = table.concat(details.buffer.lines)
    test.equal(list.buffer:get_utf8_line(1), "Local Changes\n")
    test.ok(details_text:find("app.lua", 1, true))
    test.ok(not details_text:find("Hash:", 1, true))
  end)

  test.test("Local Focus Cycle enters and wraps through Git Log targets", function(context)
    local session, view = open_fake_git_view(context.project)
    core.active_view = view

    test.equal(command.perform("pane:focus_local_next"), true)
    test.equal(core.active_view.git_owner_view, view)
    test.equal(core.active_view.git_pane, "log-list")
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
    local session, view = git_view.open_log(context.project, {
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
    git_view.ensure_tab_view(session, tab, true)
    test.equal(core.active_view.git_pane, "file-list")
    test.equal(command.perform("pane:focus_local_next"), true)
    local diff = tab.diff_view
    test.equal(diff.request.kind, "git")
    test.equal(nil, diff.request.metadata)
    test.equal(diff.request.user_data.selected_file_path, "a.lua")
    test.equal(diff.request.user_data.source, "git")
    test.equal(diff.request.user_data.read_only_reason, "Historical Git content is read-only")
    test.equal(diff.request.editable_policy, "content")
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
    local opened
    for _, candidate in ipairs(view.model.tabs) do
      if candidate.kind == "commit_diff" then opened = candidate end
    end
    test.not_nil(opened)
    test.equal(#session_views(session), 2)

    core.active_view = {}
    test.equal(command.perform("git:select_next_row"), false)
  end)

  test.it("gives Git commit rows complete mouse interaction", function(context)
    local session, view = open_fake_git_view(context.project)
    view.model:log_tab().commits = {
      { hash = "a", short_hash = "a", subject = "First", parents = {} },
      { hash = "b", short_hash = "b", subject = "Second", parents = {} },
    }
    view:update_pane_buffers()
    local list = view:pane_view("log-list")
    list.position.x, list.position.y = 0, 0
    list.size.x, list.size.y = 500, 200
    list.scroll.x, list.scroll.y = 0, 0
    list.scroll.to.x, list.scroll.to.y = 0, 0
    local x, y = list:get_line_screen_position(2, 1)
    x = x + math.max(1, list:get_font():get_width("b") / 2)
    y = y + list:get_line_height() / 2
    list.buffer:set_selection(1, 1)

    view:on_mouse_moved(x, y, 0, 0)

    test.equal(list.buffer:get_selection(), 1)
    test.equal(view.cursor, "hand")
    test.equal(list.git_hovered_action_line, 2)

    test.ok(view:on_mouse_pressed("left", x, y, 1))
    test.equal(list.git_pressed_action_line, 2)
    local line1, col1, line2, col2 = list.buffer:get_selection(true)
    test.same({ line1, col1, line2, col2 }, { 2, 1, 2, #list.buffer.lines[2] })
    test.ok(view:on_mouse_released("left", x, y))
    test.is_nil(list.git_pressed_action_line)
    test.equal(#session_views(session), 1)

    local text = list.buffer:get_utf8_line(1):gsub("\n$", "")
    local text_x = select(1, list:get_line_screen_position(1, #text + 1))
    local outside_x = math.min(list.position.x + list.size.x - 2, text_x + 20)
    local outside_y = select(2, list:get_line_screen_position(1, 1)) + list:get_line_height() / 2
    local tab_count = #view.model.tabs
    view:on_mouse_moved(outside_x, outside_y, 0, 0)
    test.not_equal(view.cursor, "hand")
    test.is_nil(list.git_hovered_action_line)
    test.ok(view:on_mouse_pressed("left", outside_x, outside_y, 2))
    test.ok(view:on_mouse_released("left", outside_x, outside_y))
    test.equal(#view.model.tabs, tab_count)

    test.ok(view:on_mouse_pressed("left", x, y, 2))
    test.ok(view:on_mouse_released("left", x, y))
    test.equal(#session_views(session), 2)
  end)

  test.it("uses mouse interaction for changed-file folders", function(context)
    local session, log_view = open_fake_git_view(context.project)
    local tab = {
      id = "diff-folder-mouse",
      kind = "commit_diff",
      title = "Diff folder mouse",
      closable = true,
      changed_files = {
        { status = "modified", old_path = "src/a.lua", new_path = "src/a.lua" },
        { status = "modified", old_path = "src/b.lua", new_path = "src/b.lua" },
      },
      selected_file = 1,
    }
    log_view.model.tabs[#log_view.model.tabs + 1] = tab
    local view = git_view.ensure_tab_view(session, tab, true)
    view:update_pane_buffers()
    local list = view:pane_view("file-list")
    list.position.x, list.position.y = 0, 0
    list.size.x, list.size.y = 300, 200
    list.scroll.x, list.scroll.y = 0, 0
    list.scroll.to.x, list.scroll.to.y = 0, 0
    local folder_line = list.path_tree:line_for_path("src", "dir")
    local x, y = list:get_line_screen_position(folder_line, 1)
    x = x + math.max(1, list:get_font():get_width("s") / 2)
    y = y + list:get_line_height() / 2

    view:on_mouse_moved(x, y, 0, 0)
    test.equal(view.cursor, "hand")
    test.equal(list.git_hovered_action_line, folder_line)

    test.ok(view:on_mouse_pressed("left", x, y, 2))
    test.ok(view:on_mouse_released("left", x, y))
    test.equal(list.path_tree:is_expanded("src"), false)
  end)

  test.it("keeps the viewport fixed when an actionable row is clicked", function(context)
    config.scroll_context_lines = 3
    local _, view = open_fake_git_view(context.project)
    local log = view.model:log_tab()
    for index = 1, 20 do
      log.commits[index] = {
        hash = tostring(index), short_hash = tostring(index),
        subject = "Commit " .. index, parents = {},
      }
    end
    view:update_pane_buffers()
    local list = view:pane_view("log-list")
    local line_height = list:get_line_height()
    list.position.x, list.position.y = 0, 0
    list.size.x, list.size.y = 500, line_height * 6
    list:update()

    local target_line = 10
    local start_scroll = (target_line - 1) * line_height
    list.scroll.y, list.scroll.to.y = start_scroll, start_scroll
    local x, y = list:get_line_screen_position(target_line, 1)
    x = x + math.max(1, list:get_font():get_width("1") / 2)
    y = y + line_height / 2

    test.ok(view:on_mouse_pressed("left", x, y, 1))
    test.ok(view:on_mouse_released("left", x, y))
    list:update()

    test.equal(list.scroll.y, start_scroll)
    test.equal(list.scroll.to.y, start_scroll)
  end)

  test.it("captures every loaded Git Log item as text", function(context)
    local session, view = open_fake_git_view(context.project)
    view.model.repo = { root = "C:/repo" }
    local selected = {
      hash = "bbbbbbbb",
      short_hash = "bbbbbbbb",
      subject = "Selected commit",
      author_name = "Dario",
      author_email = "dario@example.test",
      body = "First body line\nSecond body line",
      parents = { "aaaaaaaa" },
      changed_files_loaded = true,
      changed_files = {
        { status = "modified", old_path = "src/a.lua", new_path = "src/a.lua", stat = { additions = 2, deletions = 1 } },
        { status = "added", old_path = nil, new_path = "src/deep/b.lua", stat = { additions = 4, deletions = 0 } },
      },
    }
    local log = view.model:log_tab()
    log.commits = {
      { hash = "aaaaaaaa", short_hash = "aaaaaaaa", subject = "Earlier commit", parents = {} },
      selected,
    }
    log.selected_commit = 2
    log.has_more = true
    view.model.details_tree_collapsed[selected.hash] = { src = true }
    view:update_pane_buffers()
    core.active_view = view:pane_view("log-list")

    test.ok(command.perform("core:open_text_capture"))

    local capture = panes.active().current_view
    test.ok(capture and capture.text_capture)
    test.ok(capture.buffer.read_only)
    local text = buffer_text(capture.buffer)
    test.contains(text, "Repository: C:/repo")
    test.contains(text, "Earlier commit")
    test.contains(text, "Selected commit")
    test.contains(text, "First body line")
    test.contains(text, "src/a.lua")
    test.contains(text, "src/deep/b.lua")
    test.contains(text, "More commits: yes")
  end)

  test.it("captures a Commit Diff View list and both text sides", function(context)
    local session, log_view = open_fake_git_view(context.project)
    log_view.model.repo = { root = "C:/repo" }
    local tab = {
      id = "diff-text-capture",
      kind = "commit_diff",
      title = "Diff text capture",
      closable = true,
      left = "parent-revision",
      right = "commit-revision",
      changed_files = {
        { status = "modified", old_path = "src/a.lua", new_path = "src/a.lua" },
        { status = "renamed", old_path = "old.lua", new_path = "new.lua" },
      },
      selected_file = 2,
      left_text = "old text\n",
      right_text = "new text\n",
      left_name = "parent:old.lua",
      right_name = "commit:new.lua",
      diff_generation = 1,
    }
    log_view.model.tabs[#log_view.model.tabs + 1] = tab
    local view = git_view.ensure_tab_view(session, tab, true)
    view:update()
    core.active_view = test.not_nil(tab.diff_view).buffer_view_b

    test.ok(command.perform("core:open_text_capture"))

    local text = buffer_text(panes.active().current_view.buffer)
    test.contains(text, "Diff text capture")
    test.contains(text, "parent-revision")
    test.contains(text, "commit-revision")
    test.contains(text, "src/a.lua")
    test.contains(text, "old.lua -> new.lua")
    test.contains(text, "Left: parent:old.lua")
    test.contains(text, "old text")
    test.contains(text, "Right: commit:new.lua")
    test.contains(text, "new text")
  end)

  test.it("captures every loaded File History revision and comparison", function(context)
    local session, log_view = open_fake_git_view(context.project)
    log_view.model.repo = { root = "C:/repo" }
    local tab = {
      id = "history-text-capture",
      kind = "file_history",
      title = "History: src/app.lua",
      closable = true,
      relpath = "src/app.lua",
      history_context = { type = "selection", start_line = 4, end_line = 9 },
      commits = {
        { hash = "bbbbbbbb", short_hash = "bbbbbbbb", subject = "Newest", parents = { "aaaaaaaa" } },
        { hash = "aaaaaaaa", short_hash = "aaaaaaaa", subject = "Oldest", parents = {} },
      },
      selected_commit = 1,
      has_more = true,
      preview_left_text = "before history\n",
      preview_right_text = "after history\n",
      preview_left_name = "aaaaaaaa:src/app.lua",
      preview_right_name = "bbbbbbbb:src/app.lua",
    }
    log_view.model.tabs[#log_view.model.tabs + 1] = tab
    local view = git_view.ensure_tab_view(session, tab, true)
    tab.preview_left_text = "before history\n"
    tab.preview_right_text = "after history\n"
    tab.preview_left_name = "aaaaaaaa:src/app.lua"
    tab.preview_right_name = "bbbbbbbb:src/app.lua"
    tab.preview_generation_value = (tab.preview_generation_value or 0) + 1
    view:update()
    core.active_view = test.not_nil(tab.history_diff_view).buffer_view_a

    test.ok(command.perform("core:open_text_capture"))

    local text = buffer_text(panes.active().current_view.buffer)
    test.contains(text, "Path: src/app.lua")
    test.contains(text, "Selected lines: 4-9")
    test.contains(text, "Newest")
    test.contains(text, "Oldest")
    test.contains(text, "More revisions: yes")
    test.contains(text, "before history")
    test.contains(text, "after history")
  end)

  test.it("does not activate a Git row while another Pane View has focus", function(context)
    local session, view = git_view.open_log(context.project, {
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
    test.equal(#view.model.tabs, 1)
    test.equal(view.model:log_tab().kind, "log")
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
    tab_view:on_mouse_moved(list.position.x + 1, list.position.y + 1, 0, 0)
    test.equal(tab_view:on_mouse_wheel(-1, 0), true)
    test.ok(list.scroll.to.y > before)
  end)

  test.it("lets the changed-file Path Tree scrollbar own pointer input", function(context)
    local session, view = open_fake_git_view(context.project)
    local files = {}
    for index = 1, 40 do
      local path = string.format("src/file-%03d.lua", index)
      files[index] = { status = "modified", old_path = path, new_path = path }
    end
    local tab = {
      id = "diff-path-tree-scrollbar",
      kind = "commit_diff",
      title = "Diff Path Tree scrollbar",
      closable = true,
      changed_files = files,
      selected_file = 1,
      left_text = "old\n",
      right_text = "new\n",
      left_name = "old",
      right_name = "new",
      diff_generation = 1,
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local tab_view = git_view.ensure_tab_view(session, tab, true)
    tab_view.position.x, tab_view.position.y = 0, 0
    tab_view.size.x, tab_view.size.y = 800, 120
    tab_view:update()

    local list = tab_view:pane_view("file-list")
    local x, y, width, height = list.v_scrollbar:get_thumb_rect()
    test.ok(width > 0 and height > 0)
    local selected_line = list.buffer:get_selection()
    core.active_view = test.not_nil(tab.diff_view).buffer_view_b

    test.equal(tab_view:on_mouse_pressed("left", x + width / 2, y + height / 2, 1), true)
    test.equal(list.v_scrollbar.dragging, true)
    test.equal(core.active_view, list)
    test.equal(list.buffer:get_selection(), selected_line)

    local before = list.scroll.to.y
    tab_view:on_mouse_moved(x + width / 2, y + height / 2 + 20, 0, 20)
    test.ok(list.scroll.to.y > before)
    tab_view:on_mouse_released("left", x + width / 2, y + height / 2 + 20)
    test.equal(list.v_scrollbar.dragging, false)
  end)

  test.it("routes wheel input to the hovered Diff View instead of the focused Path Tree", function(context)
    local session, view = open_fake_git_view(context.project)
    local lines = {}
    for index = 1, 40 do lines[index] = "line " .. index end
    local tab = {
      id = "diff-hover-scroll",
      kind = "commit_diff",
      title = "Diff hover scroll",
      closable = true,
      changed_files = {
        { status = "modified", old_path = "a.lua", new_path = "a.lua" },
      },
      selected_file = 1,
      left_text = table.concat(lines, "\n"),
      right_text = table.concat(lines, "\n") .. "\nadded",
      left_name = "a.lua",
      right_name = "a.lua",
      diff_generation = 1,
    }
    view.model.tabs[#view.model.tabs + 1] = tab
    local tab_view = git_view.ensure_tab_view(session, tab, true)
    tab_view.position.x, tab_view.position.y = 0, 0
    tab_view.size.x, tab_view.size.y = 800, 120
    tab_view:update()

    local list = tab_view:pane_view("file-list")
    local diff = test.not_nil(tab.diff_view)
    core.active_view = list
    tab_view:on_mouse_moved(diff.position.x + 10, diff.position.y + 10, 0, 0)

    test.equal(tab_view:on_mouse_wheel(-1, 0), true)
    test.equal(list.scroll.to.y, 0)
    test.ok(diff.buffer_view_a.scroll.to.y > 0)
    test.ok(diff.buffer_view_b.scroll.to.y > 0)
  end)

  test.test("saves and restores hidden Git View Pane Tab state", function(context)
    local session, view = open_fake_git_view(context.project)
    local history_tab = view.model:open_file_history("src/app.lua")
    session:hide()

    test.equal(view:get_state().session.hidden, true)
    local state = git_view.save_state(session)
    panes.git_sessions = {}
    local restored = git_view.restore_state(context.project, state, {
        window = fake_window(2222),
        window_id = 2222,
        git_view_opts = { backend = fake_backend },
    })

    test.not_nil(restored)
    test.equal(panes.git_sessions[state.session_key], restored)
    test.equal(restored.hidden, true)
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
    test.equal(panes.git_sessions[session.key], session)
    test.ok(panes.restore_workspace_state(state, function(saved)
      return require(saved.module).from_state(saved.state)
    end))

    local restored = panes.active().current_view
    test.equal(restored.tab_id, history_tab.id)
    test.ok(restored ~= history_view)
    test.equal(panes.git_sessions[session.key].git_tab_views[history_tab.id], restored)
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
    git_view.sync_tab_views(session)

    test.equal(session.git_tab_views["diff-old"], nil)
    test.not_nil(session.git_tab_views["diff-new"])
    test.equal(session.git_tab_views["diff-new"], old_view)
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
        session_key = session.key,
        hidden = true,
        model = {
          repo = { root = "C:/repo" },
          tabs = { { id = "log", kind = "log", selected_commit = 1 } },
        },
      })
    test.equal(session.hidden, true)
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
    local restored = git_view.restore_state(context.project,
      {
        kind = "git",
        hidden = true,
        model = {
          repo = { root = "C:/repo" },
          tabs = { { id = "log", kind = "log", selected_commit = 1, selected_commit_hash = "abc123" } },
        },
      }, {
        window = fake_window(3333),
        window_id = 3333,
        git_view_opts = { backend = backend },
    })
    test.equal(restored.git_view.refresh_started, nil)
    test.equal(log_calls, 0)

    core.projects = { context.project }
    core.active_view = restored.git_view
    command.perform("git:open_selected_commit_diff")

    test.equal(log_calls, 1)
    local opened
    for _, candidate in ipairs(restored.git_view.model.tabs) do
      if candidate.kind == "commit_diff" then opened = candidate end
    end
    test.not_nil(opened)
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

  test.test("closing the Git Log hides it while retaining project Git state", function(context)
    local session, view = open_fake_git_view(context.project)
    local closed = false
    local pane = panes.pane_for_view(view)
    closed = panes.close_view(pane, { view = view })
    test.equal(closed, true)
    test.equal(session.hidden, true)
    test.equal(session.git_view, view)
    test.equal(panes.git_sessions[session.key], session)
  end)

  test.test("closing the Git Log leaves sibling Git Views open", function(context)
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
    test.equal(panes.git_sessions[session.key], session)
    test.ok(panes.pane_for_view(sibling) ~= nil)
    test.ok(core.active_view == sibling or core.active_view.git_owner_view == sibling)
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
    test.not_nil(command.map["git:open_log"])
    test.is_nil(command.map["git:open"])
    test.not_nil(command.map["git:open_selected_commit_diff"])
    test.not_nil(command.map["git:open_working_tree_diff"])
    test.not_nil(command.map["git:show_file_history"])
    test.is_nil(command.map["git:show_history"])
    test.not_nil(command.map["git:open_current_file_in_project_diff"])
    test.is_nil(command.map["git:open_current_file_diff"])
    test.not_nil(command.map["git:copy_selected_commit_hash"])
    test.not_nil(command.map["git:copy_selected_commit_message"])
    test.not_nil(command.map["git:show_selection_history"])
    test.not_nil(command.map["git:open_selected_historical_buffer"])
    test.not_nil(command.map["git:close_selected_tab"])
    test.not_nil(command.map["git:select_next_row"])
    test.not_nil(command.map["git:select_previous_row"])
    test.not_nil(command.map["git:activate_selected_row"])
    test.not_nil(command.map["git:focus_diff_pane"])
    test.not_nil(command.map["git:focus_list_pane"])
    for _, name in ipairs {
      "git:open_log",
      "git:open_selected_commit_diff",
      "git:open_working_tree_diff",
      "git:show_file_history",
      "git:show_selection_history",
      "git:open_current_file_in_project_diff",
      "git:open_selected_historical_buffer",
    } do
      test.ok(command.get_metadata(name).opens_view, name)
    end
    test.not_ok(command.get_metadata("git:open_selected_commit_diff").palette)
    test.not_ok(command.get_metadata("git:open_selected_historical_buffer").palette)
  end)
end)
