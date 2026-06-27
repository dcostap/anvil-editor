local test = require "core.test"
local config = require "core.config"

local Model = require "plugins.git.model"

local real_backend = require "plugins.git.backend"

local function fake_backend(status_output, log_output)
  return {
    repo_for_path = function(path) return { root = path } end,
    build_log_args = function(opts) return { "log", tostring(opts and opts.offset or "") } end,
    parse_status_z = real_backend.parse_status_z,
    parse_log_page = real_backend.parse_log_page,
    WORKING_TREE = real_backend.WORKING_TREE,
    EMPTY_TREE = real_backend.EMPTY_TREE,
    diff_endpoint_for_commit = real_backend.diff_endpoint_for_commit,
    changed_files = function(repo, left, right, opts, callback)
      callback({ { status = "modified", old_path = "src/app.lua", new_path = "src/app.lua" } }, nil)
      return { cancel = function() end }
    end,
    file_at = function(repo, rev, relpath, opts, callback)
      callback(tostring(rev) .. ":" .. relpath, nil)
      return { cancel = function() end }
    end,
    file_history = function(repo, relpath, opts, callback)
      local stdout = table.concat({
        table.concat({"def456", "", "Ada", "ada@example.test", "1710000000", "HEAD", "History", ""}, "\0"),
        "",
      }, "\30")
      callback(real_backend.parse_log_page(stdout, { limit = opts and opts.limit or 500 }), nil)
      return { cancel = function() end }
    end,
    selection_history = function(repo, relpath, start_line, end_line, opts, callback)
      local stdout = table.concat({
        table.concat({"sel789", "", "Ada", "ada@example.test", "1710000000", "HEAD", "Selection", ""}, "\0"),
        "",
      }, "\30")
      callback(real_backend.parse_log_page(stdout, { limit = opts and opts.limit or 500 }), nil)
      return { cancel = function() end }
    end,
    run_git = function(repo, args, opts, callback)
      if args[1] == "status" then
        callback({ code = 0, stdout = status_output or "" }, nil)
      else
        callback({ code = 0, stdout = log_output or "" }, nil)
      end
      return { cancel = function() end }
    end,
  }
end

local function one_record(hash, subject)
  return table.concat({hash, "", "Ada", "ada@example.test", "1710000000", "HEAD", subject, ""}, "\0")
end

local function log_output(records)
  local out = {}
  for _, record in ipairs(records or { { "abc123", "Initial" } }) do
    out[#out + 1] = one_record(record[1], record[2])
  end
  out[#out + 1] = ""
  return table.concat(out, "\30")
end

test.describe("plugins.git.model", function()
  test.test("creates a permanent Log tab", function()
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend("", "") })
    local tab = model:log_tab()
    test.equal(tab.id, "log")
    test.equal(tab.kind, "log")
    test.equal(tab.closable, false)
    test.equal(model:close_selected_tab(), false)
  end)

  test.test("refreshes log with working tree row and commits", function()
    local status = table.concat({ " M src/app.lua", "" }, "\0")
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend(status, log_output()) })
    local done = false
    model:refresh_log(function() done = true end)

    test.equal(done, true)
    local commits = model:log_tab().commits
    test.equal(#commits, 2)
    test.equal(commits[1].kind, "working_tree")
    test.equal(commits[1].subject, "Working Tree")
    test.equal(commits[2].hash, "abc123")
    test.equal(commits[2].subject, "Initial")
    test.equal(model:selected_commit().kind, "working_tree")
    model:select_log_index(1)
    test.equal(model:get_state().tabs[1].selected_commit_hash, nil)
    test.equal(model:select_log_index(2).hash, "abc123")
    test.equal(model:selected_commit().subject, "Initial")
  end)

  test.test("refresh loads changed files for initially selected log commit details", function()
    local backend = fake_backend("", log_output())
    local changed_file_calls = 0
    backend.changed_files = function(repo, left, right, opts, callback)
      changed_file_calls = changed_file_calls + 1
      callback({ { status = "modified", old_path = "src/app.lua", new_path = "src/app.lua" } }, nil)
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })

    model:refresh_log()

    test.equal(changed_file_calls, 1)
    test.equal(model:selected_commit().changed_files[1].new_path, "src/app.lua")
  end)

  test.test("ignores stale refresh results and cancels older jobs", function()
    local callbacks = {}
    local cancelled = 0
    local backend = fake_backend("", "")
    backend.run_git = function(repo, args, opts, callback)
      callbacks[#callbacks + 1] = { args = args, callback = callback }
      return { cancel = function() cancelled = cancelled + 1 end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    model:refresh_log()
    test.equal(cancelled, 2)
    callbacks[1].callback({ code = 0, stdout = " M stale.lua\0" }, nil)
    callbacks[2].callback({ code = 0, stdout = log_output() }, nil)
    callbacks[3].callback({ code = 0, stdout = "" }, nil)
    callbacks[4].callback({ code = 0, stdout = log_output() }, nil)

    local commits = model:log_tab().commits
    test.equal(#commits, 1)
    test.equal(commits[1].hash, "abc123")
  end)

  test.test("opens and reuses commit diff tabs with loaded file content", function()
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend("", log_output()) })
    model:refresh_log()
    local tab = model:open_selected_commit_diff()
    local again = model:open_selected_commit_diff()

    test.equal(tab, again)
    test.equal(tab.kind, "commit_diff")
    test.equal(tab.closable, true)
    test.equal(model:selected_tab(), tab)
    test.equal(#tab.changed_files, 1)
    test.equal(tab.left_text, real_backend.EMPTY_TREE .. ":src/app.lua")
    test.equal(tab.right_text, "abc123:src/app.lua")
  end)

  test.test("apply_state invalidates in-flight file history callbacks", function()
    local callbacks = {}
    local backend = fake_backend("", log_output())
    backend.file_history = function(repo, relpath, opts, callback)
      callbacks[#callbacks + 1] = callback
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    local tab = model:open_file_history("src/app.lua")
    local queued = 0
    model:load_file_history(tab, function() queued = queued + 1 end)
    model:apply_state({ repo = { root = "C:/repo" }, active_tab = "log", tabs = { { id = "log", kind = "log" } } })
    callbacks[1](real_backend.parse_log_page(log_output(), { limit = 500 }), nil)
    test.equal(queued, 0)
    test.equal(model:selected_tab().id, "log")
  end)

  test.test("queues callbacks for in-flight file history loads", function()
    local callbacks = {}
    local backend = fake_backend("", log_output())
    backend.file_history = function(repo, relpath, opts, callback)
      callbacks[#callbacks + 1] = callback
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    local tab = model:open_file_history("src/app.lua")
    local queued = 0
    model:load_file_history(tab, function() queued = queued + 1 end)
    callbacks[1](real_backend.parse_log_page(log_output(), { limit = 500 }), nil)
    test.equal(queued, 1)
  end)

  test.test("refresh invalidates in-flight file history loads without cancelled errors", function()
    local callbacks = {}
    local backend = fake_backend("", log_output())
    backend.file_history = function(repo, relpath, opts, callback)
      callbacks[#callbacks + 1] = callback
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    local tab = model:open_file_history("src/app.lua")
    test.equal(tab.loading, true)
    model:refresh_log()
    callbacks[1](nil, { kind = "cancelled", message = "cancelled" })
    test.equal(tab.loading, true)
    test.equal(tab.error, nil)
    callbacks[2](real_backend.parse_log_page(log_output(), { limit = 500 }), nil)
    test.equal(tab.loading, false)
    test.equal(tab.commits[1].hash, "abc123")
  end)

  test.test("serializes and restores lightweight tab state", function()
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend("", log_output()) })
    model:refresh_log()
    local diff_tab = model:open_selected_commit_diff()
    model:open_file_history("src/app.lua")
    local selection_tab = model:open_selection_history("src/app.lua", 3, 7)
    selection_tab.selected_commit = 1
    diff_tab.left_text = "large content must not persist"
    diff_tab.right_text = "large content must not persist"
    model.active_tab = selection_tab.id

    local state = model:get_state()
    local restored = Model.new({ path = "C:/repo" }, { backend = fake_backend("", log_output()), state = state })

    test.equal(restored.active_tab, selection_tab.id)
    test.equal(#restored.tabs, 4)
    test.equal(restored:find_tab(diff_tab.id).left_text, nil)
    test.equal(restored:find_tab(diff_tab.id).right_text, nil)
    test.equal(restored:find_tab(selection_tab.id).history_context.type, "selection")
    test.equal(restored:find_tab(selection_tab.id).history_context.start_line, 3)
    test.equal(restored:get_state().tabs[4].selected_commit_hash, "sel789")
  end)

  test.test("restored file history keeps saved scroll through first refresh", function()
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend("", log_output()) })
    model:refresh_log()
    local tab = model:open_file_history("src/app.lua")
    tab.scroll = 77
    local restored = Model.new({ path = "C:/repo" }, { backend = fake_backend("", log_output()), state = model:get_state() })
    local restored_tab = restored:find_tab(tab.id)

    restored:refresh_log()
    test.equal(restored_tab.scroll, 77)
  end)

  test.test("restored log selection anchor survives until later page loads", function()
    local old_page_size = config.plugins.git.log_page_size
    config.plugins.git.log_page_size = 1
    local backend = fake_backend("", "")
    backend.run_git = function(repo, args, opts, callback)
      if args[1] == "status" then
        callback({ code = 0, stdout = "" }, nil)
      elseif args[2] == "1" then
        callback({ code = 0, stdout = log_output({ { "bbb222", "Second" } }) }, nil)
      else
        callback({ code = 0, stdout = log_output({ { "aaa111", "First" }, { "bbb222", "Second" } }) }, nil)
      end
      return { cancel = function() end }
    end
    local restored = Model.new({ path = "C:/repo" }, {
      backend = backend,
      state = {
        repo = { root = "C:/repo" },
        active_tab = "log",
        tabs = { { id = "log", kind = "log", selected_commit = 1, selected_commit_hash = "bbb222" } },
      },
    })

    restored:refresh_log()
    test.equal(restored:log_tab().selected_commit_hash, "bbb222")
    test.equal(restored:get_state().tabs[1].selected_commit_hash, "bbb222")
    test.equal(restored:selected_commit(), nil)
    restored:load_more_log()
    test.equal(restored:selected_commit().hash, "bbb222")
    test.equal(restored:log_tab().selected_commit_hash, "bbb222")
    config.plugins.git.log_page_size = old_page_size
  end)

  test.test("resolved log selection anchor preserves selection when newer commits appear", function()
    local backend = fake_backend("", log_output({ { "bbb222", "Second" } }))
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    model:select_log_index(1)
    backend.run_git = function(repo, args, opts, callback)
      if args[1] == "status" then
        callback({ code = 0, stdout = "" }, nil)
      else
        callback({ code = 0, stdout = log_output({ { "aaa111", "New" }, { "bbb222", "Second" } }) }, nil)
      end
      return { cancel = function() end }
    end

    model:refresh_log()
    test.equal(model:selected_commit().hash, "bbb222")
  end)

  test.test("restored log selection anchor does not override later user selection", function()
    local backend = fake_backend("", log_output({ { "aaa111", "First" }, { "bbb222", "Second" } }))
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    model:select_log_index(1)
    local restored = Model.new({ path = "C:/repo" }, { backend = backend, state = model:get_state() })

    restored:refresh_log()
    test.equal(restored:selected_commit().hash, "aaa111")
    restored:select_log_index(2)
    restored:refresh_log()
    test.equal(restored:selected_commit().hash, "bbb222")
  end)

  test.test("restored diff tabs reselect files by path after lazy reload", function()
    local backend = fake_backend("", log_output())
    backend.changed_files = function(repo, left, right, opts, callback)
      callback({
        { status = "modified", old_path = "a.lua", new_path = "a.lua" },
        { status = "modified", old_path = "b.lua", new_path = "b.lua" },
      }, nil)
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    local diff_tab = model:open_selected_commit_diff()
    model:select_diff_file(diff_tab, 2)

    backend.changed_files = function(repo, left, right, opts, callback)
      callback({
        { status = "modified", old_path = "b.lua", new_path = "b.lua" },
        { status = "modified", old_path = "a.lua", new_path = "a.lua" },
      }, nil)
      return { cancel = function() end }
    end
    local restored = Model.new({ path = "C:/repo" }, { backend = backend, state = model:get_state() })
    restored:select_tab(diff_tab.id)
    local restored_tab = restored:find_tab(diff_tab.id)
    test.equal(restored_tab.selected_file, 1)
    test.equal(restored_tab.changed_files[1].new_path, "b.lua")
  end)

  test.test("selecting a restored diff tab lazily reloads changed files", function()
    local changed_calls = 0
    local backend = fake_backend("", log_output())
    backend.changed_files = function(repo, left, right, opts, callback)
      changed_calls = changed_calls + 1
      callback({ { status = "modified", old_path = "src/app.lua", new_path = "src/app.lua" } }, nil)
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    local diff_tab = model:open_selected_commit_diff()
    local state = model:get_state()
    local restored = Model.new({ path = "C:/repo" }, { backend = backend, state = state })

    changed_calls = 0
    restored:select_tab(diff_tab.id)
    test.equal(changed_calls, 1)
    test.equal(#restored:find_tab(diff_tab.id).changed_files, 1)
  end)

  test.test("selection history loads changed files for initially selected commit details", function()
    local backend = fake_backend("", log_output())
    local changed_file_calls = 0
    backend.changed_files = function(repo, left, right, opts, callback)
      changed_file_calls = changed_file_calls + 1
      callback({ { status = "modified", old_path = "src/app.lua", new_path = "src/app.lua" } }, nil)
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    changed_file_calls = 0

    local tab = model:open_selection_history("src/app.lua", 1, 1)

    test.equal(changed_file_calls, 1)
    test.equal(tab.commits[1].changed_files[1].new_path, "src/app.lua")
  end)

  test.test("opens and reuses selection history tabs distinct from file history", function()
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend("", log_output()) })
    model:refresh_log()
    local file_tab = model:open_file_history("src/app.lua")
    local sel_tab = model:open_selection_history("src/app.lua", 3, 7)
    local again = model:open_selection_history("src/app.lua", 3, 7)

    test.equal(sel_tab, again)
    test.ok(sel_tab.id ~= file_tab.id)
    test.equal(sel_tab.history_context.type, "selection")
    test.equal(sel_tab.history_context.start_line, 3)
    test.equal(sel_tab.history_context.end_line, 7)
    test.equal(sel_tab.commits[1].hash, "sel789")
  end)

  test.test("selected commit follows active file history tab", function()
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend("", log_output()) })
    model:refresh_log()
    model:open_file_history("src/app.lua")
    test.equal(model:selected_commit().hash, "def456")
    local tab = model:open_selected_commit_diff()
    test.equal(tab.commit.hash, "def456")
  end)

  test.test("failed refresh marks Git tabs instead of reloading with nil repo", function()
    local lookups = 0
    local history_calls = 0
    local changed_calls = 0
    local backend = fake_backend(table.concat({ " M src/app.lua", "" }, "\0"), log_output())
    backend.repo_for_path = function(path)
      lookups = lookups + 1
      if lookups == 1 then return { root = path } end
      return nil, { kind = "not_in_repository", message = "not in repo" }
    end
    backend.changed_files = function(repo, left, right, opts, callback)
      changed_calls = changed_calls + 1
      callback({ { status = "modified", old_path = "src/app.lua", new_path = "src/app.lua" } }, nil)
      return { cancel = function() end }
    end
    backend.file_history = function(repo, relpath, opts, callback)
      history_calls = history_calls + 1
      callback(real_backend.parse_log_page(log_output(), { limit = 500 }), nil)
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    local history_tab = model:open_file_history("src/app.lua")
    local diff_tab = model:open_working_tree_diff()
    test.equal(history_calls, 1)
    test.equal(changed_calls, 2)
    model:refresh_log()
    test.equal(model.repo, nil)
    test.equal(history_calls, 1)
    test.equal(changed_calls, 2)
    test.equal(history_tab.error.kind, "not_in_repository")
    test.equal(diff_tab.error.kind, "not_in_repository")
  end)

  test.test("refresh reloads existing file history tabs", function()
    local history_calls = 0
    local backend = fake_backend("", log_output())
    backend.file_history = function(repo, relpath, opts, callback)
      history_calls = history_calls + 1
      local hash = history_calls == 1 and "old111" or "new222"
      local stdout = table.concat({
        table.concat({hash, "", "Ada", "ada@example.test", "1710000000", "HEAD", "History", ""}, "\0"),
        "",
      }, "\30")
      callback(real_backend.parse_log_page(stdout, { limit = opts and opts.limit or 500 }), nil)
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    local tab = model:open_file_history("src/app.lua")
    tab.scroll = 999
    test.equal(tab.commits[1].hash, "old111")
    model:refresh_log()
    test.equal(tab.commits[1].hash, "new222")
    test.equal(tab.scroll, 0)
  end)

  test.test("opens and reuses file history tabs", function()
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend("", log_output()) })
    model:refresh_log()
    local tab = model:open_file_history("src/app.lua")
    local again = model:open_file_history("src/app.lua")

    test.equal(tab, again)
    test.equal(tab.kind, "file_history")
    test.equal(tab.closable, true)
    test.equal(tab.relpath, "src/app.lua")
    test.equal(model:selected_tab(), tab)
    test.equal(#tab.commits, 1)
    test.equal(tab.commits[1].hash, "def456")
  end)

  test.test("builds selected historical document request from a commit diff tab", function()
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend("", log_output()) })
    model:refresh_log()
    model:open_selected_commit_diff()
    local request = model:selected_historical_document()
    test.equal(request.rev, "abc123")
    test.equal(request.relpath, "src/app.lua")
    test.equal(request.repo.root, "C:/repo")
  end)

  test.test("keeps Log tab non-closable while closing selected diff tab", function()
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend("", log_output()) })
    model:refresh_log()
    local tab = model:open_selected_commit_diff()
    test.equal(model:close_selected_tab(), true)
    test.equal(model:selected_tab().id, "log")
    test.equal(model:find_tab(tab.id), nil)
    test.equal(model:close_selected_tab(), false)
  end)

  test.test("ignores stale selected-file content loads", function()
    local callbacks = {}
    local backend = fake_backend("", log_output())
    backend.changed_files = function(repo, left, right, opts, callback)
      callback({
        { status = "modified", old_path = "a.lua", new_path = "a.lua" },
        { status = "modified", old_path = "b.lua", new_path = "b.lua" },
      }, nil)
      return { cancel = function() end }
    end
    backend.file_at = function(repo, rev, relpath, opts, callback)
      callbacks[#callbacks + 1] = { rev = rev, relpath = relpath, callback = callback }
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    local tab = model:open_selected_commit_diff()
    model:select_diff_file(tab, 2)

    callbacks[3].callback("left b", nil)
    callbacks[4].callback("right b", nil)
    callbacks[1].callback("left a", nil)
    callbacks[2].callback("right a", nil)

    test.equal(tab.selected_file, 2)
    test.equal(tab.left_text, "left b")
    test.equal(tab.right_text, "right b")
    test.equal(tab.left_name, "b.lua")
  end)

  test.test("normalizes CRLF before storing diff text", function()
    local status = table.concat({ " M src/app.lua", "" }, "\0")
    local backend = fake_backend(status, log_output())
    backend.file_at = function(repo, rev, relpath, opts, callback)
      callback(rev == real_backend.WORKING_TREE and "one\r\ntwo\r\n" or "one\ntwo\n", nil)
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    local tab = model:open_working_tree_diff()
    test.equal(tab.left_text, "one\ntwo\n")
    test.equal(tab.right_text, "one\ntwo\n")
  end)

  test.test("historical request from working-tree diff resolves HEAD to commit hash", function()
    local status = table.concat({ " M src/app.lua", "" }, "\0")
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend(status, log_output()) })
    model:refresh_log()
    model:open_working_tree_diff()
    local request = model:selected_historical_document()
    test.equal(request.rev, "abc123")
    test.equal(request.relpath, "src/app.lua")
  end)

  test.test("opens working tree diff from the synthetic row", function()
    local status = table.concat({ " M src/app.lua", "" }, "\0")
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend(status, log_output()) })
    model:refresh_log()
    local tab = model:open_working_tree_diff()
    test.equal(tab.left, "HEAD")
    test.equal(tab.right, real_backend.WORKING_TREE)
    test.equal(tab.changed_files[1].new_path, "src/app.lua")
    test.equal(tab.right_text, real_backend.WORKING_TREE .. ":src/app.lua")
  end)

  test.test("working tree fallback refreshes status so untracked files appear", function()
    local status_calls = 0
    local status_args
    local backend = fake_backend("", log_output())
    backend.changed_files = function(repo, left, right, opts, callback)
      callback({}, nil)
      return { cancel = function() end }
    end
    backend.run_git = function(repo, args, opts, callback)
      if args[1] == "status" then
        status_args = args
        status_calls = status_calls + 1
        local stdout = status_calls == 1 and "" or table.concat({ "?? new.lua", "" }, "\0")
        callback({ code = 0, stdout = stdout }, nil)
      else
        callback({ code = 0, stdout = log_output() }, nil)
      end
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    local tab = model:open_working_tree_diff()
    test.equal(#tab.changed_files, 1)
    test.ok(real_backend._contains_arg(status_args, "--untracked-files=all"), "diff-tab status should expand untracked directories")
    test.equal(tab.changed_files[1].kind, "untracked")
    test.equal(tab.changed_files[1].path, "new.lua")
  end)

  test.test("refresh invalidation clears stale content from in-flight commit diff loads", function()
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend("", log_output()) })
    model:refresh_log()
    local tab = model:open_selected_commit_diff()
    tab.selected_file = 1
    tab.left_text = "old left"
    tab.right_text = "old right"
    tab.loading_file = true
    model:refresh_log()
    test.equal(tab.loading_file, false)
    test.equal(tab.left_text, nil)
    test.equal(tab.right_text, nil)
  end)

  test.test("refresh callback runs once while active working-tree diff reloads", function()
    local status = table.concat({ " M src/app.lua", "" }, "\0")
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend(status, log_output()) })
    model:refresh_log()
    model:open_working_tree_diff()
    local calls = 0
    model:refresh_log(function() calls = calls + 1 end)
    test.equal(calls, 1)
  end)

  test.test("selecting a cleared diff tab reloads its selected file", function()
    local status = table.concat({ " M src/app.lua", "" }, "\0")
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend(status, log_output()) })
    model:refresh_log()
    local tab = model:open_working_tree_diff()
    model.active_tab = "log"
    model:clear_diff_content(tab)
    test.equal(tab.left_text, nil)
    model:select_tab(tab.id)
    test.equal(tab.left_text, "HEAD:src/app.lua")
    test.equal(tab.file_scroll or 0, 0)
  end)

  test.test("refresh synchronizes working tree diff tabs with clean status", function()
    local status_calls = 0
    local backend = fake_backend(table.concat({ " M src/app.lua", "" }, "\0"), log_output())
    local diff_calls = 0
    backend.changed_files = function(repo, left, right, opts, callback)
      diff_calls = diff_calls + 1
      local files = diff_calls == 1 and { { status = "modified", old_path = "src/app.lua", new_path = "src/app.lua" } } or {}
      callback(files, nil)
      return { cancel = function() end }
    end
    backend.run_git = function(repo, args, opts, callback)
      if args[1] == "status" then
        status_calls = status_calls + 1
        local stdout = status_calls == 1 and table.concat({ " M src/app.lua", "" }, "\0") or ""
        callback({ code = 0, stdout = stdout }, nil)
      else
        callback({ code = 0, stdout = log_output() }, nil)
      end
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    local tab = model:open_working_tree_diff()
    tab.file_scroll = 999
    test.not_nil(tab.left_text)
    model:refresh_log()
    test.equal(#tab.changed_files, 0)
    test.equal(tab.left_text, nil)
    test.equal(tab.right_text, nil)
    test.equal(tab.loading, false)
    test.equal(tab.loading_file, false)
    test.equal(tab.file_scroll, 0)
  end)

  test.test("clears stale diff content when a changed-file reload becomes empty", function()
    local backend = fake_backend("", log_output())
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    local tab = model:open_selected_commit_diff()
    test.not_nil(tab.left_text)
    backend.changed_files = function(repo, left, right, opts, callback)
      callback({}, nil)
      return { cancel = function() end }
    end
    model:load_changed_files(tab)
    test.equal(#tab.changed_files, 0)
    test.equal(tab.left_text, nil)
    test.equal(tab.right_text, nil)
  end)

  test.test("working tree diff tab base updates after first commit appears", function()
    local log_calls = 0
    local backend = fake_backend(table.concat({ " M src/app.lua", "" }, "\0"), "")
    backend.run_git = function(repo, args, opts, callback)
      if args[1] == "status" then
        callback({ code = 0, stdout = table.concat({ " M src/app.lua", "" }, "\0") }, nil)
      else
        log_calls = log_calls + 1
        local stdout = log_calls == 1 and "" or log_output()
        callback({ code = 0, stdout = stdout }, nil)
      end
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    local tab = model:open_working_tree_diff()
    test.equal(tab.left, real_backend.EMPTY_TREE)
    model:refresh_log()
    test.equal(tab.left, "HEAD")
    test.equal(model:find_tab(tab.id), tab)
  end)

  test.test("working tree diff filters staged-add-then-deleted records", function()
    local status = table.concat({ "AD new.lua", "" }, "\0")
    local backend = fake_backend(status, log_output())
    backend.changed_files = function(repo, left, right, opts, callback)
      callback({}, nil)
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    local tab = model:open_working_tree_diff()
    test.equal(#tab.changed_files, 0)
    test.equal(tab.left_text, nil)
  end)

  test.test("working tree diff skips untracked directory summaries", function()
    local status = table.concat({ "?? generated/", "" }, "\0")
    local backend = fake_backend(status, log_output())
    backend.changed_files = function(repo, left, right, opts, callback)
      callback({}, nil)
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    local tab = model:open_working_tree_diff()
    test.equal(#tab.changed_files, 0)
    test.equal(tab.left_text, nil)
    test.equal(tab.file_error, nil)
  end)

  test.test("uses empty tree for working tree diff in repositories without commits", function()
    local status = table.concat({ "?? new.lua", "" }, "\0")
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend(status, "") })
    model:refresh_log()
    local tab = model:open_working_tree_diff()
    test.equal(tab.left, real_backend.EMPTY_TREE)
    test.equal(tab.right, real_backend.WORKING_TREE)
  end)

  test.test("shows working tree row when log fails because repo has no commits", function()
    local backend = fake_backend(table.concat({ "?? new.lua", "" }, "\0"), "")
    backend.run_git = function(repo, args, opts, callback)
      if args[1] == "status" then
        callback({ code = 0, stdout = table.concat({ "?? new.lua", "" }, "\0") }, nil)
      else
        callback(nil, { kind = "exit", stderr = "fatal: your current branch 'main' does not have any commits yet" })
      end
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    test.equal(model:log_tab().error, nil)
    test.equal(#model:log_tab().commits, 1)
    test.equal(model:log_tab().commits[1].kind, "working_tree")
  end)

  test.test("loads more commits from the next log page", function()
    local old_git = config.plugins.git
    config.plugins.git = { log_page_size = 1 }
    local backend = fake_backend("", "")
    backend.run_git = function(repo, args, opts, callback)
      if args[1] == "status" then
        callback({ code = 0, stdout = "" }, nil)
      elseif args[2] == "1" then
        callback({ code = 0, stdout = log_output({ { "def456", "Second" } }) }, nil)
      else
        callback({ code = 0, stdout = log_output({ { "abc123", "Initial" }, { "def456", "Second" } }) }, nil)
      end
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    test.equal(#model:log_tab().commits, 1)
    test.equal(model:log_tab().has_more, true)
    test.equal(model:load_more_log(), true)
    test.equal(#model:log_tab().commits, 2)
    test.equal(model:log_tab().commits[2].hash, "def456")
    config.plugins.git = old_git
  end)
end)
