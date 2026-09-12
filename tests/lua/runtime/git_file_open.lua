local test = require "core.test"
local Model = require "plugins.git.model"

test.it("opens a commit at the first file in tree order", function()
  local model = Model.new({ path = USERDIR }, { backend = {
    diff_endpoint_for_commit = function() return { left = "parent", right = "commit" } end,
    changed_files = function(_, _, _, _, callback)
      callback({
        { status = "modified", new_path = "a.txt", old_path = "a.txt" },
        { status = "modified", new_path = "src/z.txt", old_path = "src/z.txt" },
        { status = "modified", new_path = "src/b.txt", old_path = "src/b.txt" },
      })
    end,
    file_at = function(_, _, path, _, callback) callback(path .. "\n") end,
  }, status_service = {
    subscribe = function() end, unsubscribe = function() end, lookup = function() end,
  } })
  model.repo = { root = USERDIR }
  local tab = model:open_commit_diff({ hash = "commit", subject = "Change files" })
  test.equal(tab.changed_files[tab.selected_file].new_path, "src/b.txt")
  test.equal(tab.right_text, "src/b.txt\n")
  model:cancel_jobs()
end)

test.it("opens listed staged files while list queries are pending and reloads their content", function()
  local content = "staged\n"
  local finish_listing
  local model = Model.new({ path = USERDIR }, { backend = {
    INDEX = "INDEX", WORKING_TREE = "WORKING_TREE", EMPTY_TREE = "EMPTY_TREE",
    changed_files = function(_, _, _, _, callback)
      finish_listing = callback
      return { cancel = function() end }
    end,
    file_at = function(_, revision, _, _, callback)
      callback(revision == "HEAD" and "committed\n" or content)
    end,
  }, status_service = {
    subscribe = function() end, unsubscribe = function() end, lookup = function() end,
  } })
  model.repo = { root = USERDIR }
  local row = { kind = "working_tree", local_scope = "staged", subject = "Staged Changes", changed_files = {
    { status = "modified", old_path = "file.txt", new_path = "file.txt" },
  } }
  model:log_tab().commits = { row, { hash = "head" } }
  local function open()
    local completed = false
    local tab = model:open_commit_diff(row, function(_, err)
      test.equal(err, nil)
      completed = true
    end, { selected_file_path = "file.txt" })
    test.ok(completed, "Selected file opening must not wait for a file-list query")
    return tab
  end
  local tab = open()
  test.equal(tab.left_text, "committed\n")
  test.equal(tab.right_text, "staged\n")
  content = "new staged content\n"
  tab = open()
  test.equal(tab.right_text, "new staged content\n")
  local refreshed = false
  model:open_commit_diff(row, function(_, err)
    test.equal(err, nil)
    refreshed = true
  end)
  test.equal(refreshed, false)
  finish_listing({ { status = "added", new_path = "other.txt" } })
  test.ok(refreshed)
  test.equal(tab.changed_files[1].new_path, "other.txt")
  model:cancel_jobs()
end)
