local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + (timeout or 5)
  while not predicate() and system.get_time() < deadline do coroutine.yield(0.02) end
  return predicate()
end

test.describe("Fuzzy Searcher exact grep", function()
  test.before_each(function(context)
    context.original_projects = core.projects
    context.original_cwd = system.getcwd()
    context.root = USERDIR .. PATHSEP .. "fuzzy-exact-grep-" .. system.get_process_id()
    assert(common.mkdirp(context.root))
    core.projects = { Project(context.root) }
    system.chdir(context.root)
    project_paths.configure_workspace {}
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    project_paths.configure_workspace {}
    core.projects = context.original_projects
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    if context.root and system.get_file_info(context.root) then
      common.rm(context.root, true)
    end
  end)

  test.it("returns one result for each matching line", function(context)
    local path = context.root .. PATHSEP .. "repeated.txt"
    local file = assert(io.open(path, "wb"))
    file:write("ssss\none s\n")
    file:close()

    fuzzy_searcher.open("#s")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function()
      return picker.status and picker.status:find("exact matches", 1, true)
    end), "expected exact grep to finish: " .. tostring(picker.status))

    local count = 0
    for _, result in ipairs(picker.results or {}) do
      if result.abs_path and common.path_equals(result.abs_path, path) then
        count = count + 1
      end
    end
    test.equal(count, 2)
  end)

  test.it("keeps the UI scheduler responsive during a broad search", function(context)
    local path = context.root .. PATHSEP .. "many-lines.txt"
    local file = assert(io.open(path, "wb"))
    local line = "sample search line\n"
    for _ = 1, 20000 do file:write(line) end
    file:close()

    fuzzy_searcher.open("#s")
    local started = system.get_time()
    local heartbeat
    core.add_thread(function()
      coroutine.yield(0.05)
      heartbeat = system.get_time()
    end)

    test.ok(wait_until(function() return heartbeat ~= nil end, 2),
      "expected another UI task to run during exact grep")
    test.ok(heartbeat - started < 0.3, string.format(
      "exact grep blocked the UI scheduler for %.3f seconds", heartbeat - started
    ))
  end)
end)
