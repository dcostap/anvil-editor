local core = require "core"
local common = require "core.common"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local process = require "core.process"
local test = require "core.test"

require "plugins.gitdiff_highlight"
local git_status = require "plugins.file_git_status"

local function join(...)
  return table.concat({...}, PATHSEP)
end

local function run(args, cwd)
  local proc = assert(process.start(args, {
    cwd = cwd,
    stdin = process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  }))
  local code = proc:wait(process.WAIT_INFINITE, 0.01)
  return code,
    proc:read_stdout(16 * 1024 * 1024) or "",
    proc:read_stderr(1024 * 1024) or ""
end

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  assert(file:write(text))
  file:close()
end

local function remove_tree(path)
  if system.get_file_info(path) then common.rm(path, true) end
end

local function wait_until(predicate, timeout, message)
  local deadline = system.get_time() + (timeout or 8)
  while system.get_time() < deadline do
    if predicate() then return end
    coroutine.yield(0.02)
  end
  test.fail(message or "timed out waiting for Git baseline", 2)
end

local function git_point_count(view)
  local points, unavailable = view:get_points_of_interest()
  local count = 0
  for _, point in ipairs(points or {}) do
    if point.kind == "git-change" then count = count + 1 end
  end
  return count, unavailable
end

local function wait_for_git_count(view, expected, message)
  wait_until(function()
    local count, unavailable = git_point_count(view)
    return unavailable == nil and count == expected
  end, 8, message)
end

local function make_repo(context, name)
  local root = join(
    USERDIR,
    "gitdiff-baseline-" .. name .. "-" .. system.get_process_id()
      .. "-" .. math.floor(system.get_time() * 1000000)
  )
  context.root = root
  remove_tree(root)
  test.ok(common.mkdirp(root))
  local root_arg = root:gsub("\\", "/")
  test.equal(run({ "git", "-C", root_arg, "init", "-q" }), 0)
  test.equal(run({ "git", "-C", root_arg, "config", "user.email", "anvil@example.test" }), 0)
  test.equal(run({ "git", "-C", root_arg, "config", "user.name", "Anvil Test" }), 0)
  return root, root_arg
end

local function commit_file(root_arg, name, message)
  test.equal(run({ "git", "-C", root_arg, "add", name }), 0)
  test.equal(run({ "git", "-C", root_arg, "commit", "-qm", message or "commit" }), 0)
end

local function open_editor(context, path)
  local buffer = Buffer(path, path, false)
  context.buffer = buffer
  local view = Editor(buffer)
  context.view = view
  return buffer, view
end

test.describe("Git Editor baseline", function()
  test.after_each(function(context)
    if context.buffer then context.buffer:on_close() end
    if context.root then remove_tree(context.root) end
    core.redraw = true
  end)

  test.test("keeps a clean UTF-8 pathname clean", function(context)
    local root, root_arg = make_repo(context, "utf8")
    local name = "caf" .. string.char(0xc3, 0xa9) .. ".txt"
    local path = join(root, name)
    write_file(path, "one\ntwo\n")
    commit_file(root_arg, name, "UTF-8 path")

    local _, view = open_editor(context, path)
    wait_for_git_count(view, 0, "clean UTF-8 pathname did not settle")
  end)

  test.test("keeps a clean UTF-8 BOM file clean", function(context)
    local root, root_arg = make_repo(context, "bom")
    local name = "bom.txt"
    local path = join(root, name)
    write_file(path, string.char(0xef, 0xbb, 0xbf) .. "one\ntwo\n")
    commit_file(root_arg, name, "UTF-8 BOM")

    local _, view = open_editor(context, path)
    wait_for_git_count(view, 0, "clean UTF-8 BOM file did not settle")
  end)

  test.test("converts a UTF-16 baseline before checking for binary content", function(context)
    local root, root_arg = make_repo(context, "utf16")
    local name = "utf16.txt"
    local path = join(root, name)
    local utf16 = string.char(
      0xff, 0xfe,
      string.byte("o"), 0,
      string.byte("n"), 0,
      string.byte("e"), 0,
      10, 0
    )
    write_file(path, utf16)
    commit_file(root_arg, name, "UTF-16 baseline")

    local buffer, view = open_editor(context, path)
    wait_for_git_count(view, 0, "clean UTF-16 file did not settle")

    buffer:replace(function() return "changed\n" end)
    wait_until(function()
      local points, unavailable = view:get_points_of_interest()
      return unavailable == nil and points and points[1] and points[1].label == "modification"
    end, 8, "edited UTF-16 file did not produce a modification")
  end)

  test.test("keeps a clean staged rename clean", function(context)
    local root, root_arg = make_repo(context, "rename")
    local old_name, new_name = "old.txt", "new.txt"
    local old_path, new_path = join(root, old_name), join(root, new_name)
    write_file(old_path, "same\n")
    commit_file(root_arg, old_name, "rename source")
    test.equal(run({ "git", "-C", root_arg, "mv", old_name, new_name }), 0)

    local _, view = open_editor(context, new_path)
    wait_for_git_count(view, 0, "clean staged rename did not settle")
  end)

  test.test("rechecks an index path after a staged rename becomes an addition", function(context)
    local root, root_arg = make_repo(context, "rename-add")
    local old_name, new_name = "old.txt", "new.txt"
    local old_path, new_path = join(root, old_name), join(root, new_name)
    write_file(old_path, "A\n")
    commit_file(root_arg, old_name, "rename source")
    test.equal(run({ "git", "-C", root_arg, "mv", old_name, new_name }), 0)

    local buffer, view = open_editor(context, new_path)
    wait_for_git_count(view, 0, "clean staged rename did not settle")

    test.equal(run({ "git", "-C", root_arg, "restore", "--staged", old_name }), 0)
    buffer:replace(function() return "B\n" end)
    git_status:request(new_path, "rename-became-addition")
    collectgarbage("collect")

    wait_until(function()
      local points, unavailable = view:get_points_of_interest()
      return unavailable == nil and points and points[1] and points[1].label == "addition"
    end, 8, "staged rename path did not reload as an addition")
  end)

  test.test("reloads the Editor baseline after an external commit", function(context)
    local root, root_arg = make_repo(context, "refresh")
    local name = "refresh.txt"
    local path = join(root, name)
    write_file(path, "one\n")
    commit_file(root_arg, name, "first")

    local buffer, view = open_editor(context, path)
    wait_for_git_count(view, 0, "initial clean baseline did not settle")

    buffer:insert(1, 1, "changed ")
    wait_until(function()
      local count, unavailable = git_point_count(view)
      return unavailable == nil and count > 0
    end, 8, "unsaved Editor change did not produce a Git POI")
    buffer:save()
    wait_until(function()
      local count, unavailable = git_point_count(view)
      return unavailable == nil and count > 0
    end, 8, "saved Editor change did not keep its Git POI")
    test.equal(run({ "git", "-C", root_arg, "add", name }), 0)
    test.equal(run({ "git", "-C", root_arg, "commit", "-qm", "second" }), 0)

    wait_for_git_count(view, 0, "Editor baseline did not reload after external commit")
  end)

  test.test("reloads when HEAD changes but status and numstat stay the same", function(context)
    local root, root_arg = make_repo(context, "same-status")
    local name = "same-status.txt"
    local path = join(root, name)
    write_file(path, "a\n")
    commit_file(root_arg, name, "A")

    local buffer, view = open_editor(context, path)
    wait_for_git_count(view, 0, "initial baseline did not settle")

    buffer:replace(function() return "b\n" end)
    buffer:save()
    wait_until(function()
      local count, unavailable = git_point_count(view)
      return unavailable == nil and count > 0
    end, 8, "HEAD A versus worktree B did not produce a Git POI")

    test.equal(run({ "git", "-C", root_arg, "add", name }), 0)
    test.equal(run({ "git", "-C", root_arg, "commit", "-qm", "B" }), 0)
    write_file(path, "c\n")
    git_status:request(path, "same-status-head-change")
    collectgarbage("collect")

    -- The open Buffer still contains B. Only the Git baseline should change.
    wait_for_git_count(view, 0, "unchanged status bytes did not reload the new HEAD baseline")
  end)
end)
