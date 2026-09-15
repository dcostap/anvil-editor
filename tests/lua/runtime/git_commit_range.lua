local test = require "core.test"
local common = require "core.common"
local process = require "core.process"
local Model = require "plugins.git.model"
local backend = require "plugins.git.backend"

local function run(root, ...)
  local args = { backend.git_path(), "-C", root:gsub("\\", "/"), ... }
  local proc = process.start(args, {
    stdin = process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  local code = proc:wait(process.WAIT_INFINITE, 0.01)
  test.equal(code, 0, proc:read_stderr(1024 * 1024))
  return (proc:read_stdout(1024 * 1024) or ""):gsub("%s+$", "")
end

local function wait_for(predicate)
  local deadline = system.get_time() + 10
  while not predicate() do
    test.ok(system.get_time() < deadline, "Git range request timed out")
    coroutine.yield(0.01)
  end
end

test.describe("Commit Range Diff", function()
  test.after_each(function(context)
    if context.model then context.model:cancel_jobs() end
    if context.root then
      if PLATFORM == "Windows" then
        os.execute('attrib -R /S /D "' .. context.root .. '\\*" >NUL 2>NUL')
      end
      common.rm(context.root, true)
    end
  end)

  test.it("shows net file changes across commits, including a range from the root", function(context)
    local root = USERDIR .. PATHSEP .. "git-commit-range-" .. system.get_process_id()
    context.root = root
    test.ok(common.mkdirp(root))
    run(root, "init")
    run(root, "config", "user.name", "Anvil Test")
    run(root, "config", "user.email", "anvil@example.test")
    local function write(name, text)
      local file = assert(io.open(root .. PATHSEP .. name, "wb"))
      file:write(text)
      file:close()
    end
    local function commit(message)
      run(root, "add", "-A")
      run(root, "commit", "-m", message)
      return run(root, "rev-parse", "HEAD")
    end
    write("kept.txt", "before\n")
    local first = commit("Initial")
    write("kept.txt", "middle\n")
    write("temporary.txt", "removed by the next commit\n")
    local middle = commit("Add temporary file")
    os.remove(root .. PATHSEP .. "temporary.txt")
    write("kept.txt", "after\n")
    local newest = commit("Remove temporary file")
    local model = Model.new({ path = root }, { backend = backend, status_service = {} })
    context.model = model
    model.repo = { root = root }
    model:log_tab().commits = {
      { hash = newest, parents = { middle }, subject = "Newest" },
      { hash = middle, parents = { first }, subject = "Middle" },
      { hash = first, parents = {}, subject = "Initial" },
    }
    model:select_log_rows({ 1, 2 }, 2)
    local done, failure = false
    local diff = model:open_selected_commit_diff(nil, function(_, err) done, failure = true, err end)
    wait_for(function() return done end)
    test.equal(failure, nil)
    test.equal(diff.left, first)
    test.equal(diff.right, newest)
    test.equal(#diff.changed_files, 1)
    test.equal(diff.changed_files[1].new_path, "kept.txt")
    test.equal(diff.left_text, "before\n")
    test.equal(diff.right_text, "after\n")

    model:select_log_rows({ 1, 2, 3 }, 3)
    done = false
    diff = model:open_selected_commit_diff(nil, function(_, err) done, failure = true, err end)
    wait_for(function() return done end)
    test.equal(failure, nil)
    test.equal(diff.left, backend.EMPTY_TREE)
    test.equal(diff.right, newest)
    test.equal(diff.left_text, "")
    test.equal(diff.right_text, "after\n")
  end)

  for _, case in ipairs {
    { name = "gaps", rows = { 1, 3 }, parents = { "bbbb" } },
    { name = "mixed branch histories", rows = { 1, 2 }, parents = { "aaaa", "bbbb" } },
    { name = "local changes mixed with commits", rows = { 1, 2 }, local_scope = "staged" },
  } do
    test.it("rejects " .. case.name .. " without opening a partial diff", function()
      local model = Model.new({ path = "C:/repo" }, { status_service = {} })
      model.repo = { root = "C:/repo" }
      model:log_tab().commits = {
        { hash = not case.local_scope and "cccc" or nil, parents = case.parents,
          kind = case.local_scope and "working_tree" or "commit", local_scope = case.local_scope },
        { hash = "bbbb", parents = { "aaaa" } },
        { hash = "aaaa", parents = {} },
      }
      model:select_log_rows(case.rows, 1)
      local diff, err = model:open_selected_commit_diff()
      test.equal(diff, nil)
      test.ok(err and err.message:find("Select", 1, true))
      test.equal(#model.tabs, 1)
    end)
  end
end)
