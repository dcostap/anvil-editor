local test = require "core.test"
local common = require "core.common"
local process = require "core.process"
local backend = require "plugins.git.backend"
local Model = require "plugins.git.model"
local graph = require "plugins.git.graph"

local function wait_for(predicate)
  local deadline = system.get_time() + 15
  while not predicate() do
    test.ok(system.get_time() < deadline, "Git operation timed out")
    coroutine.yield(0.01)
  end
end

local function git(root, ...)
  local args = { backend.git_path(), "-C", root }
  for _, arg in ipairs { ... } do args[#args + 1] = arg end
  local proc = assert(process.start(args, {
    stdin = process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  }))
  local code = proc:wait(process.WAIT_INFINITE, 0.01)
  test.equal(code, 0, proc:read_stderr(65536))
end

local function write_file(root, path, text)
  local file = assert(io.open(root .. "/" .. path, "wb"))
  file:write(text)
  file:close()
end

local function refresh(model)
  local done = false
  model:refresh_log(function(_, err)
    test.equal(err, nil)
    done = true
  end)
  wait_for(function() return done end)
  return model:log_tab().commits
end

local function open_diff(model, row)
  local done = false
  local tab = model:open_commit_diff(row, function(_, err)
    test.equal(err, nil)
    done = true
  end)
  wait_for(function() return done end)
  return tab
end

test.describe("Git Log local changes", function()
  local root, model
  test.before_each(function()
    root = (USERDIR .. "/git-local-" .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)):gsub("\\", "/")
    assert(common.mkdirp(root))
    git(root, "init")
    git(root, "config", "user.email", "anvil@example.test")
    git(root, "config", "user.name", "Anvil Test")
    model = Model.new({ path = root }, { backend = backend, status_service = {
      subscribe = function() end, unsubscribe = function() end, lookup = function() end,
    } })
  end)
  test.after_each(function()
    if model then
      model:cancel_jobs()
      for _, tab in ipairs(model.tabs) do model:dispose_tab(tab) end
    end
    if PLATFORM == "Windows" then
      os.execute('attrib -R /S /D "' .. root .. '\\*" >NUL 2>NUL')
    end
    common.rm(root, true)
  end)

  test.it("compares each part of a partially staged file against its own base", function()
    write_file(root, "file.txt", "committed\n")
    git(root, "add", ".")
    git(root, "commit", "-m", "initial")
    write_file(root, "file.txt", "staged\n")
    git(root, "add", ".")
    write_file(root, "file.txt", "unstaged\n")

    local rows = refresh(model)
    test.equal(#rows, 3)
    test.equal(rows[1].subject, "Local Unstaged Changes")
    test.equal(rows[2].subject, "Local Staged Changes")
    local layout = graph.layout(rows)
    test.ok(layout[2].incoming)
    test.ok(layout[3].incoming)
    local unstaged = open_diff(model, rows[1])
    local staged = open_diff(model, rows[2])
    test.not_equal(unstaged.id, staged.id)
    test.equal(unstaged.left_text, "staged\n")
    test.equal(unstaged.right_current_path, "file.txt")
    test.equal(staged.left_text, "committed\n")
    test.equal(staged.right_text, "staged\n")

    model:select_log_index(2)
    git(root, "restore", "file.txt")
    rows = refresh(model)
    test.equal(#rows, 2)
    test.equal(model:selected_commit().subject, "Local Staged Changes")
    git(root, "reset", "HEAD", "--", "file.txt")
    rows = refresh(model)
    test.equal(rows[1].subject, "Local Unstaged Changes")
    unstaged = open_diff(model, rows[1])
    test.equal(unstaged.left_text, "committed\n")
    test.equal(unstaged.right_current_path, "file.txt")
  end)

  test.it("separates a staged rename from later edits at the new path", function()
    write_file(root, "old.txt", "original\n")
    git(root, "add", ".")
    git(root, "commit", "-m", "initial")
    git(root, "mv", "old.txt", "new.txt")
    write_file(root, "new.txt", "edited\n")
    local rows = refresh(model)
    test.equal(#rows, 3)
    test.equal(rows[1].changed_files[1].status, "modified")
    test.equal(rows[1].changed_files[1].old_path, "new.txt")
    test.equal(rows[2].changed_files[1].status, "renamed")
    local unstaged = open_diff(model, rows[1])
    local staged = open_diff(model, rows[2])
    test.equal(unstaged.left_text, "original\n")
    test.equal(unstaged.right_current_path, "new.txt")
    test.equal(staged.left_text, "original\n")
    test.equal(staged.right_text, "original\n")
  end)

  test.it("shows staged additions and untracked files before the first commit", function()
    write_file(root, "added.txt", "added\n")
    git(root, "add", "added.txt")
    write_file(root, "untracked.txt", "untracked\n")
    local rows = refresh(model)
    test.equal(#rows, 2)
    test.equal(rows[1].subject, "Local Unstaged Changes")
    test.equal(rows[1].changed_files[1].path, "untracked.txt")
    test.equal(rows[2].subject, "Local Staged Changes")
    local staged = open_diff(model, rows[2])
    test.equal(staged.left_text, "")
    test.equal(staged.right_text, "added\n")
  end)
end)
