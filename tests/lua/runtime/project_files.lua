local common = require "core.common"
local test = require "core.test"

local function join(...)
  return table.concat({...}, PATHSEP)
end

local function write(path, text)
  local fp = assert(io.open(path, "wb"))
  fp:write(text or "")
  fp:close()
end

local function names(files)
  local out = {}
  for _, file in ipairs(files) do out[file.relative:gsub("\\", "/")] = true end
  return out
end

test.describe("Project files", function()
  test.it("uses ripgrep defaults and can include ignored files", function(context)
    local project_files = require "core.project_files"
    local root = join(USERDIR, "project-files-" .. system.get_process_id())
    assert(common.mkdirp(join(root, ".git")))
    assert(common.mkdirp(join(root, "build")))
    assert(common.mkdirp(join(root, "from-ignore")))
    assert(common.mkdirp(join(root, "from-rgignore")))
    write(join(root, ".gitignore"), "build/\n")
    write(join(root, ".ignore"), "from-ignore/\n")
    write(join(root, ".rgignore"), "from-rgignore/\n")
    write(join(root, "visible.txt"), "visible")
    write(join(root, "build", "ignored.txt"), "ignored")
    write(join(root, "from-ignore", "ignored.txt"), "ignored")
    write(join(root, "from-rgignore", "ignored.txt"), "ignored")
    write(join(root, ".hidden.txt"), "hidden")
    context.cleanup = function()
      project_files.invalidate(root)
      common.rm(root, true)
    end

    local default = names(assert(project_files.list(root, { refresh = true })))
    test.ok(default["visible.txt"], "default files: " .. table.concat((function()
      local out = {}; for name in pairs(default) do out[#out + 1] = name end; return out
    end)(), ", "))
    test.not_ok(default["build/ignored.txt"])
    test.not_ok(default["from-ignore/ignored.txt"])
    test.not_ok(default["from-rgignore/ignored.txt"])
    test.not_ok(default[".hidden.txt"])

    local unrestricted = names(assert(project_files.list(root, {
      refresh = true,
      include_ignored = true,
    })))
    test.ok(unrestricted["visible.txt"])
    test.ok(unrestricted["build/ignored.txt"])
    test.ok(unrestricted["from-ignore/ignored.txt"])
    test.ok(unrestricted["from-rgignore/ignored.txt"])
    test.not_ok(unrestricted[".hidden.txt"])
  end)

  test.it("requires a Git repository before applying gitignore files", function(context)
    local project_files = require "core.project_files"
    local root = join(os.getenv("TEMP") or USERDIR,
      "anvil-project-files-no-git-" .. system.get_process_id())
    assert(common.mkdirp(join(root, "build")))
    assert(common.mkdirp(join(root, "ignored")))
    write(join(root, ".gitignore"), "build/\n")
    write(join(root, ".ignore"), "ignored/\n")
    write(join(root, "build", "visible-without-git.txt"), "visible")
    write(join(root, "ignored", "hidden-by-ignore.txt"), "ignored")
    context.cleanup = function()
      project_files.invalidate(root)
      common.rm(root, true)
    end

    local listed = names(assert(project_files.list(root, { refresh = true })))
    test.ok(listed["build/visible-without-git.txt"])
    test.not_ok(listed["ignored/hidden-by-ignore.txt"])
  end)

  test.it("reconciles content changes without rebuilding Project membership", function(context)
    local project_files = require "core.project_files"
    local root = join(USERDIR, "project-files-reconcile-" .. system.get_process_id())
    assert(common.mkdirp(join(root, ".git")))
    assert(common.mkdirp(join(root, "build")))
    write(join(root, ".gitignore"), "build/\n")
    local existing = join(root, "existing.lua")
    write(existing, "return 1\n")
    context.cleanup = function()
      project_files.invalidate(root)
      common.rm(root, true)
    end

    local before = assert(project_files.list(root, { refresh = true }))
    local generation = project_files.watch_status(root).generation
    write(existing, "return 2\n")
    local reconciled, reconcile_error, refreshed = project_files.reconcile(root, {
      [existing] = { precise = true },
    })

    test.ok(reconciled, reconcile_error)
    test.not_ok(refreshed)
    test.equal(project_files.cached(root), before)
    test.equal(project_files.watch_status(root).generation, generation)

    local ignored = join(root, "build", "generated.lua")
    write(ignored, "return 3\n")
    reconciled, reconcile_error, refreshed = project_files.reconcile(root, {
      [ignored] = { precise = true },
    })
    test.ok(reconciled, reconcile_error)
    test.not_ok(refreshed)
    test.equal(project_files.contains(root, ignored, "file"), false)
  end)

  test.it("refreshes membership once for a new file in a searchable directory", function(context)
    local project_files = require "core.project_files"
    local root = join(USERDIR, "project-files-new-file-" .. system.get_process_id())
    assert(common.mkdirp(root))
    write(join(root, "existing.lua"), "return 1\n")
    context.cleanup = function()
      project_files.invalidate(root)
      common.rm(root, true)
    end
    assert(project_files.list(root, { refresh = true }))
    local added = join(root, "added.lua")
    write(added, "return 2\n")

    local reconciled, reconcile_error, refreshed = project_files.reconcile(root, {
      [added] = { precise = true },
    })

    test.ok(reconciled, reconcile_error)
    test.ok(refreshed)
    test.equal(project_files.contains(root, added, "file"), true)
  end)

  test.it("shares one watcher between Project consumers", function(context)
    local project_files = require "core.project_files"
    local root = join(USERDIR, "project-files-watchers-" .. system.get_process_id())
    assert(common.mkdirp(root))
    local first, second = {}, {}
    context.cleanup = function()
      project_files.unsubscribe(root, first)
      project_files.unsubscribe(root, second)
      project_files.invalidate(root)
      common.rm(root, true)
    end

    project_files.subscribe(root, first, function() end)
    project_files.subscribe(root, second, function() end)
    local status = project_files.watch_status(root)
    test.ok(status.running)
    test.equal(status.subscribers, 2)

    project_files.unsubscribe(root, first)
    status = project_files.watch_status(root)
    test.ok(status.running)
    test.equal(status.subscribers, 1)
    project_files.unsubscribe(root, second)
    test.not_ok(project_files.watch_status(root).running)
  end)

  test.it("yields while building membership for a large Project", function(context)
    local project_files = require "core.project_files"
    local root = join(USERDIR, "project-files-cooperative-" .. system.get_process_id())
    assert(common.mkdirp(root))
    for i = 1, 2000 do write(join(root, string.format("file-%04d.lua", i)), "return 1\n") end
    context.cleanup = function()
      project_files.invalidate(root)
      common.rm(root, true)
    end
    local indexing_beats = 0
    local running = true
    core.add_thread(function()
      while running do
        if project_files.watch_status(root).phase == "indexing" then
          indexing_beats = indexing_beats + 1
        end
        coroutine.yield(0)
      end
    end)

    local listed = assert(project_files.list(root, { refresh = true }))
    running = false

    test.equal(#listed, 2000)
    test.ok(indexing_beats > 0, "Project membership build blocked the scheduler")
  end)
end)
