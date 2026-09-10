local test = require "core.test"
local Model = require "plugins.git.model"

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
