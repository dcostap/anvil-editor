local common = require "core.common"
local core = require "core"
local Project = require "core.project"
local process = require "core.process"
local test = require "core.test"
local path_tree = require "plugins.path_tree"

local function run(root, ...)
  local args = { "git", "-C", root, ... }
  local proc = process.start(args, {
    stdin = process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_DISCARD,
    stderr = process.REDIRECT_DISCARD,
  })
  test.equal(proc:wait(process.WAIT_INFINITE, 0.01), 0)
end

local function write(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

test.describe("File Git status", function()
  test.before_each(function(context)
    context.projects = core.projects
  end)
  test.after_each(function(context)
    core.projects = context.projects
  end)
  test.it("provides status and line counts without an open File Tree", function()
    local root = system.absolute_path("file-git-status-fixture")
    common.mkdirp(root)
    run(root, "init")
    core.projects = { Project(root) }
    local path = root .. PATHSEP .. "example.txt"
    write(path, "original\n")
    run(root, "add", ".")
    run(root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
      "commit", "-m", "Initial file")
    write(path, "replacement\nsecond line\n")

    local info
    local deadline = system.get_time() + 10
    repeat
      info = path_tree.git_info_for_file(path)
      if info then break end
      coroutine.yield(0.01)
    until system.get_time() >= deadline
    test.not_nil(info, "Git status must not require an open File Tree")
    test.equal(info.kind, "modified")
    test.not_nil(info.stat)
    test.equal(info.stat.additions, 2)
    test.equal(info.stat.deletions, 1)
    local tree = assert(require("plugins.filetree").new(root))
    local tree_info = tree:get_git_info_for_entry({ abs = path, type = "file" })
    test.same(tree_info, info)
    tree:on_close()

    write(path, "original\n")
    require("plugins.file_git_status"):request(path, "save")
    deadline = system.get_time() + 10
    repeat
      info = path_tree.git_info_for_file(path)
      if not info then break end
      coroutine.yield(0.01)
    until system.get_time() >= deadline
    test.is_nil(info, "restoring the saved file must clear its Git status")
  end)
end)
