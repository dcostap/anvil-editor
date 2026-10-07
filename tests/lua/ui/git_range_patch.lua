local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local process = require "core.process"
local panes = require "core.panes"
local test = require "core.test"
local git_view = require "plugins.git_view"
local backend = require "plugins.git.backend"

local function run(root, ...)
  local proc = process.start({ backend.git_path(), "-C", root:gsub("\\", "/"), ... }, {
    stdin = process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  test.equal(proc:wait(process.WAIT_INFINITE, 0.01), 0, proc:read_stderr(1024 * 1024))
  return (proc:read_stdout(1024 * 1024) or ""):gsub("%s+$", "")
end

local function write(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function wait_for(predicate)
  local deadline = system.get_time() + 10
  while not predicate() do
    test.ok(system.get_time() < deadline, "Copy range patch timed out")
    coroutine.yield(0.01)
  end
end

local function open_log(context)
  local root = USERDIR .. PATHSEP .. "git-range-patch-" .. system.get_process_id()
  context.root = root
  test.ok(common.mkdirp(root))
  run(root, "init")
  run(root, "config", "user.name", "Anvil Test")
  run(root, "config", "user.email", "anvil@example.test")
  run(root, "config", "core.autocrlf", "false")
  local function commit(message)
    run(root, "add", "-A")
    run(root, "commit", "-m", message)
    return run(root, "rev-parse", "HEAD")
  end
  write(root .. PATHSEP .. "kept.txt", "before\n")
  write(root .. PATHSEP .. "binary.dat", "\0before\n")
  local first = commit("Initial")
  write(root .. PATHSEP .. "kept.txt", "middle\n")
  write(root .. PATHSEP .. "temporary.txt", "temporary\n")
  local middle = commit("Middle")
  os.remove(root .. PATHSEP .. "temporary.txt")
  write(root .. PATHSEP .. "kept.txt", "after\n")
  write(root .. PATHSEP .. "binary.dat", "\0after\n")
  local newest = commit("Newest")
  local _, view = git_view.open_log({ path = root }, {
    git_view_opts = { defer_refresh = true },
  })
  context.view = view
  view.refresh_pending = nil
  view.refresh_started = true
  view.model.repo = { root = root }
  view.model:log_tab().commits = {
    { hash = newest, parents = { middle }, subject = "Newest", changed_files = {} },
    { hash = middle, parents = { first }, subject = "Middle", changed_files = {} },
    { hash = first, parents = {}, subject = "Initial", changed_files = {} },
  }
  view:update_pane_buffers()
  view:focus_list_pane()
  context.copied = "unchanged clipboard"
  system.set_clipboard = function(text) context.copied = text end
  return view, view:pane_view("log-list"), first
end

test.describe("Copy range patch", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    context.set_clipboard = system.set_clipboard
    context.warn = core.warn
    context.max_output = config.plugins.git.max_output
    panes.reset_for_tests()
  end)

  test.after_each(function(context)
    if context.view then context.view.model:cancel_jobs() end
    system.set_clipboard = context.set_clipboard
    core.warn = context.warn
    config.plugins.git.max_output = context.max_output
    panes.reset_for_tests()
    core.active_view = context.active_view
    if context.root then
      if PLATFORM == "Windows" then
        os.execute('attrib -R /S /D "' .. context.root .. '\\*" >NUL 2>NUL')
      end
      common.rm(context.root, true)
    end
  end)

  test.it("copies an applicable net patch, including binary changes", function(context)
    local _, list, first = open_log(context)
    test.ok(not command.is_valid("git:copy_range_patch"))
    list:set_selection_state({ selections = { 1, 1, 2, 1 } })
    test.ok(command.perform("git:copy_range_patch"))
    wait_for(function() return context.copied ~= "unchanged clipboard" end)
    local patch = context.copied
    test.ok(patch:find("-before\n+after\n", 1, true), patch)
    test.ok(patch:find("GIT binary patch", 1, true), patch)
    test.ok(not patch:find("middle", 1, true), patch)
    test.ok(not patch:find("temporary.txt", 1, true), patch)
    write(context.root .. PATHSEP .. "copied.patch", patch)
    run(context.root, "checkout", "--detach", first)
    run(context.root, "apply", "--check", "copied.patch")
    test.same(list:get_selected_rows(), { 1, 2 })
  end)

  test.it("copies a range that includes the root commit", function(context)
    local _, list = open_log(context)
    list:set_selection_state({ selections = { 1, 1, 3, 1 } })
    test.ok(command.perform("git:copy_range_patch"))
    wait_for(function() return context.copied ~= "unchanged clipboard" end)
    test.ok(context.copied:find("--- /dev/null\n+++ b/kept.txt", 1, true), context.copied)
    test.ok(context.copied:find("+after\n", 1, true), context.copied)
    test.ok(not context.copied:find("temporary.txt", 1, true), context.copied)
  end)

  test.it("leaves the clipboard unchanged for a selection with gaps", function(context)
    local view, list = open_log(context)
    list:set_selection_state({ selections = { 1, 1, 1, 1, 3, 1, 3, 1 }, last_selection = 2 })
    test.ok(command.perform("git:copy_range_patch"))
    test.equal(context.copied, "unchanged clipboard")
    test.equal(view.model:log_tab().selection_error.kind, "non_contiguous")
  end)

  test.it("reports an oversized patch without changing the clipboard", function(context)
    local _, list = open_log(context)
    list:set_selection_state({ selections = { 1, 1, 2, 1 } })
    config.plugins.git.max_output = 1
    local warning
    core.warn = function(format, ...)
      warning = string.format(format, ...)
    end
    test.ok(command.perform("git:copy_range_patch"))
    wait_for(function() return warning ~= nil end)
    test.ok(warning:find("Cannot copy a range patch", 1, true), warning)
    test.ok(warning:find("output too large", 1, true), warning)
    test.equal(context.copied, "unchanged clipboard")
  end)
end)
