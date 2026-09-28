local core = require "core"
local command = require "core.command"
local panes = require "core.panes"
local test = require "core.test"
local git_view = require "plugins.git_view"
local backend = require "plugins.git.backend"

local fake_backend = {
  repo_for_path = function(path) return { root = path } end,
  build_log_args = function() return { "log" } end,
  diff_endpoint_for_commit = backend.diff_endpoint_for_commit,
  WORKING_TREE = backend.WORKING_TREE,
  EMPTY_TREE = backend.EMPTY_TREE,
  parse_status_z = function() return {} end,
  parse_log_page = function() return { commits = {} } end,
  changed_files = function(repo, left, right, opts, callback) callback({}, nil) end,
  file_at = function(repo, rev, relpath, opts, callback) callback("", nil) end,
  file_history = function(repo, relpath, opts, callback)
    callback({ commits = {}, has_more = false }, nil)
  end,
  selection_history = function(repo, relpath, start_line, end_line, opts, callback)
    callback({ commits = {}, has_more = false }, nil)
  end,
  run_git = function(repo, args, opts, callback)
    callback({ code = 0, stdout = "" }, nil)
  end,
}

local function open_git_view()
  local _, view = git_view.open_log({ path = "C:/repo" }, {
    window = { id = 4545, get_size = function() return 640, 480 end },
    window_id = 4545,
    git_view_opts = { backend = fake_backend },
  })
  return view
end

local function focus_side(diff, side, line)
  panes.place(function() return diff end, { placement = "current", focus = true })
  local target = side == "left" and diff.buffer_view_a or diff.buffer_view_b
  target:with_selection_state(function() target.buffer:set_selection(line, 1) end)
  core.set_active_view(target)
end

test.describe("Open historical file from Diff Side", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.active_view = core.active_view
    context.file_at = backend.file_at
    panes.git_sessions = {}
  end)

  test.after_each(function(context)
    backend.file_at = context.file_at
    panes.reset_for_tests()
    core.active_view = context.active_view
    panes.git_sessions = {}
    for i = #core.buffers, 1, -1 do
      if core.buffers[i].git_historical_key then table.remove(core.buffers, i) end
    end
  end)

  test.it("opens the committed old path after a rename, not the working-tree side", function()
    local view = open_git_view()
    local rev = string.rep("a", 40)
    local tab = {
      id = "diff-historical-rename", kind = "commit_diff", title = "Renamed file",
      left = rev, right = backend.WORKING_TREE,
      changed_files = { { status = "renamed", old_path = "src/old.lua", new_path = "src/new.lua" } },
      selected_file = 1, left_text = "old one\nold two\n", right_text = "new one\nnew two\n",
      right_current_path = "src/new.lua", left_name = "src/old.lua", right_name = "src/new.lua",
      diff_generation = 1,
    }
    backend.file_at = function(repo, requested_rev, relpath, opts, callback)
      test.equal(repo, "C:/repo")
      test.equal(requested_rev, rev)
      test.equal(relpath, "src/old.lua")
      callback("old one\nold two\nold three\n", nil)
    end
    local diff = view:ensure_diff_view(tab)
    require("plugins.git.comparison").attach(diff, view, tab)
    test.equal(diff:get_state().contents[1].git_revision.rev, rev)
    focus_side(diff, "right", 2)
    test.not_ok(command.perform("diff:open_historical_file_at_caret"))
    focus_side(diff, "left", 2)

    test.ok(command.get_metadata("diff:open_historical_file_at_caret").palette)
    test.ok(command.perform("diff:open_historical_file_at_caret"))
    local historical = panes.active().current_view
    test.equal(historical.buffer.git_historical_path, "src/old.lua")
    test.equal(historical.buffer.git_historical_rev, rev)
    test.equal(table.concat(historical.buffer.lines), "old one\nold two\nold three\n")
    local line = historical:with_selection_state(function() return historical.buffer:get_selection() end)
    test.equal(line, 2)

  end)

  test.it("opens the full parent revision from a selected File History excerpt", function()
    local view = open_git_view()
    local parent_rev, rev = string.rep("b", 40), string.rep("c", 40)
    local tab = {
      id = "history-historical-selection", kind = "file_history", title = "File History",
      relpath = "src/app.lua", history_context = { type = "selection", start_line = 20, end_line = 21 },
      commits = { {
        hash = rev, parents = { parent_rev }, history_path = "src/app.lua",
        history_parent_path = "src/app.lua",
        selection_diff = {
          left_text = "old eleven\nold twelve", right_text = "new twenty\nnew twenty-one",
          left_start_line = 11, right_start_line = 20,
        },
      } },
      selected_commit = 1,
    }
    test.ok(view.model:load_history_preview(tab))
    backend.file_at = function(repo, requested_rev, relpath, opts, callback)
      test.equal(repo, "C:/repo")
      test.equal(requested_rev, parent_rev)
      test.equal(relpath, "src/app.lua")
      callback(string.rep("source line\n", 30), nil)
    end
    local diff = view:ensure_history_diff_view(tab)
    focus_side(diff, "left", 2)

    test.ok(command.perform("diff:open_historical_file_at_caret"))
    local opened = panes.active().current_view
    test.equal(opened.buffer.git_historical_rev, parent_rev)
    test.equal(#opened.buffer.lines, 30)
    local line = opened:with_selection_state(function() return opened.buffer:get_selection() end)
    test.equal(line, 12)
  end)
end)
