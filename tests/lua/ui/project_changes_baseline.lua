local core = require "core"
local common = require "core.common"
local Editor = require "core.editor"
local Project = require "core.project"
local command = require "core.command"
local process = require "core.process"
local test = require "core.test"
local changes = require "plugins.gitdiff_highlight"

local function write(path, text)
  local file = assert(io.open(path, "wb"))
  assert(file:write(text))
  assert(file:close())
end

local function wait_until(predicate, message)
  local deadline = system.get_time() + 30
  repeat
    if predicate() then return end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.fail(message or "Changes Baseline operation timed out")
end

local function run(root, ...)
  local proc = process.start({ "git", "-C", root, ... }, {
    stdin = process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_DISCARD,
    stderr = process.REDIRECT_DISCARD,
  })
  test.equal(proc:wait(process.WAIT_INFINITE, 0.01), 0)
end

local function open(context, path)
  local buffer = core.open_buffer(path)
  context.buffers[#context.buffers + 1] = buffer
  core.active_view = Editor(buffer)
  return buffer
end

local function baseline(buffer)
  local source = changes.get_patch_source(buffer)
  return source and table.concat(source.before)
end

local function perform_project(name)
  test.ok(command.perform(name), "Project command is unavailable: " .. name)
  wait_until(function() return command.is_valid(name) end)
end

test.describe("Project Changes Baseline commands", function()
  test.before_each(function(context)
    context.projects, context.active_view = core.projects, core.active_view
    context.clipboard = system.get_clipboard()
    context.buffers = {}
    context.root = USERDIR .. PATHSEP .. "project-baseline-" .. system.get_process_id()
    test.ok(common.mkdirp(context.root))
    core.projects = { Project(context.root) }
    write(context.root .. PATHSEP .. "open.txt", "committed open\n")
    write(context.root .. PATHSEP .. "closed.txt", "committed closed\n")
    run(context.root, "init")
    run(context.root, "add", ".")
    run(context.root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
      "commit", "-m", "Initial files")
    write(context.root .. PATHSEP .. "closed.txt", "disk snapshot\r\n")
  end)

  test.after_each(function(context)
    for _, buffer in ipairs(context.buffers) do
      changes.discard_changes_baseline(buffer)
      core.buffer_registry:remove(buffer, true)
    end
    require("core.project_files").invalidate(context.root)
    core.projects, core.active_view = context.projects, context.active_view
    system.set_clipboard(context.clipboard or "")
    if context.outside_path then os.remove(context.outside_path) end
    test.ok(test.remove_tree(context.root))
  end)

  test.it("captures unsaved Buffers and unopened Project files without saving them", function(context)
    local buffer = open(context, context.root .. PATHSEP .. "open.txt")
    buffer:insert(1, 1, "unsaved ")
    perform_project("project:set_changes_baseline")
    test.equal(baseline(buffer), "unsaved committed open\n")
    test.ok(buffer:is_dirty(), "Setting a baseline saved the Buffer")
    local closed_path = context.root .. PATHSEP .. "closed.txt"
    write(closed_path, "later edit\n")
    local closed = open(context, closed_path)
    wait_until(function() return changes.is_settled(closed) and baseline(closed) ~= nil end)
    test.equal(baseline(closed), "disk snapshot\n")
    test.ok(command.perform("diff:copy_diff_patch_for_file"))
    test.contains(system.get_clipboard(), "-disk snapshot\n+later edit\n")
  end)

  test.it("clears open and unopened baselines and restores Git comparisons", function(context)
    local buffer = open(context, context.root .. PATHSEP .. "open.txt")
    buffer:insert(1, 1, "unsaved ")
    perform_project("project:set_changes_baseline")
    test.equal(baseline(buffer), "unsaved committed open\n")
    perform_project("project:clear_changes_baseline")
    wait_until(function() return changes.is_settled(buffer) end)
    test.equal(baseline(buffer), "committed open\n")
    local closed = open(context, context.root .. PATHSEP .. "closed.txt")
    wait_until(function() return changes.is_settled(closed) and baseline(closed) ~= nil end)
    test.equal(baseline(closed), "committed closed\n")
  end)

  test.it("includes a new unsaved Project file without creating it on disk", function(context)
    local path = context.root .. PATHSEP .. "new.txt"
    local buffer = open(context, path)
    buffer:insert(1, 1, "new text")
    perform_project("project:set_changes_baseline")
    test.equal(baseline(buffer), "new text\n")
    test.equal(system.get_file_info(path), nil)
  end)

  test.it("excludes unopened ignored files and Buffers outside the Project", function(context)
    local ignored_path = context.root .. PATHSEP .. "ignored.txt"
    write(context.root .. PATHSEP .. ".gitignore", "ignored.txt\n")
    write(ignored_path, "ignored before\n")
    context.outside_path = context.root .. "-outside.txt"
    write(context.outside_path, "outside before\n")
    local outside = open(context, context.outside_path)
    test.ok(command.perform("editor:set_changes_baseline"))
    outside:insert(1, 1, "changed ")

    perform_project("project:set_changes_baseline")
    test.equal(baseline(outside), "outside before\n")
    write(ignored_path, "ignored after\n")
    local ignored = open(context, ignored_path)
    wait_until(function() return changes.is_settled(ignored) and baseline(ignored) ~= nil end)
    test.equal(baseline(ignored), "ignored after\n")
  end)
end)
