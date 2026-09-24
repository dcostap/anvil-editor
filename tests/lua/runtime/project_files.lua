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

local function directory_names(root, directories)
  root = common.normalize_path(root)
  local out = {}
  for _, path in ipairs(directories or {}) do
    local relative = common.relative_path(root, path):gsub("\\", "/")
    out[relative] = true
  end
  return out
end

local function windows_extended_file(path, create)
  local ffi = require "ffi"
  ffi.cdef[[
    typedef void *HANDLE;
    HANDLE CreateFileW(const wchar_t *name, unsigned long access,
      unsigned long share, void *security, unsigned long creation,
      unsigned long attributes, HANDLE template_file);
    int CloseHandle(HANDLE handle);
    int DeleteFileW(const wchar_t *name);
    int MultiByteToWideChar(unsigned int code_page, unsigned long flags,
      const char *input, int input_size, wchar_t *output, int output_size);
  ]]
  local kernel32 = ffi.load("kernel32")
  local extended = [[\\?\]] .. common.normalize_path(path):gsub("/", "\\")
  local length = kernel32.MultiByteToWideChar(65001, 0, extended, #extended, nil, 0)
  local wide = ffi.new("wchar_t[?]", length + 1)
  assert(kernel32.MultiByteToWideChar(65001, 0, extended, #extended, wide, length) == length)
  if create then
    local handle = kernel32.CreateFileW(wide, 0, 7, nil, 2, 0x80, nil)
    assert(handle ~= ffi.cast("HANDLE", -1))
    assert(kernel32.CloseHandle(handle) ~= 0)
  else
    assert(kernel32.DeleteFileW(wide) ~= 0)
  end
end

test.describe("Project files", function()
  test.it("finishes a listing while its first caller is suspended", function(context)
    local project_files = require "core.project_files"
    local root = join(USERDIR, "project-files-suspended-" .. system.get_process_id())
    assert(common.mkdirp(root))
    write(join(root, "visible.lua"), "return true\n")
    context.cleanup = function()
      project_files.invalidate(root)
      common.rm(root, true)
    end
    local result
    local caller = coroutine.create(function() result = assert(project_files.list(root)) end)
    test.ok(coroutine.resume(caller))
    local deadline = system.get_time() + 3
    while not project_files.cached(root) and system.get_time() < deadline do coroutine.yield(0.01) end

    test.not_nil(project_files.cached(root), "The shared scan stopped with its first caller")
    while coroutine.status(caller) ~= "dead" do
      test.ok(coroutine.resume(caller))
      coroutine.yield(0)
    end
    test.same(names(result), { ["visible.lua"] = true })
  end)

  for _, scope in ipairs { "root", "all", "refresh" } do
    test.it("keeps a shared scan through " .. scope .. " cache invalidation", function(context)
      local project_files = require "core.project_files"
      local process = require "core.process"
      local root = join(USERDIR, "project-files-shared-" .. scope .. "-" .. system.get_process_id())
      assert(common.mkdirp(join(root, "empty")))
      write(join(root, "visible.lua"), "return true\n")
      if scope == "refresh" then
        assert(project_files.list(root))
        write(join(root, "added.lua"), "return false\n")
      end
      local start = process.start
      local started, release = false, false
      local first, second
      context.cleanup = function()
        release = true
        process.start = start
        project_files.invalidate(root)
        common.rm(root, true)
      end
      process.start = function(args, opts)
        if opts and common.path_equals(opts.cwd, root) then
          started = true
          while not release do coroutine.yield(0) end
        end
        return start(args, opts)
      end
      core.add_thread(function() first = { project_files.list(root, { refresh = true }) } end)
      local deadline = system.get_time() + 5
      while not started and system.get_time() < deadline do coroutine.yield(0) end
      test.ok(started, "Project listing did not start")
      project_files.invalidate(scope ~= "all" and root or nil)
      core.add_thread(function() second = { project_files.list(root) } end)
      release = true
      while (not first or not second) and system.get_time() < deadline do coroutine.yield(0) end
      test.not_nil(first)
      test.not_nil(second)
      local expected = { ["visible.lua"] = true }
      if scope == "refresh" then expected["added.lua"] = true end
      test.same(names(assert(first[1], first[2])), expected)
      test.same(directory_names(root, first[3]), { ["."] = true, empty = true })
      test.equal(second[1], first[1], "Consumers must receive the same completed snapshot")
      test.equal(second[3], first[3])
      test.equal(project_files.cached(root), first[1])
    end)
  end

  test.it("skips Windows device-name files that normal filesystem APIs cannot open", function(context)
    test.skip_if(PLATFORM ~= "Windows", "Windows device names are platform-specific")
    local project_files = require "core.project_files"
    local root = join(USERDIR, "project-files-device-name-" .. system.get_process_id())
    assert(common.mkdirp(root))
    write(join(root, "visible.lua"), "return true\n")
    local reserved = join(root, "NUL")
    windows_extended_file(reserved, true)
    context.cleanup = function()
      project_files.invalidate(root)
      windows_extended_file(reserved, false)
      common.rm(root, true)
    end

    local listed, err = project_files.list(root, { refresh = true })
    local found = names(assert(listed, err))
    test.ok(found["visible.lua"])
    test.not_ok(found["NUL"])
  end)

  test.it("uses ripgrep defaults and can include ignored files", function(context)
    local project_files = require "core.project_files"
    local root = join(USERDIR, "project-files-" .. system.get_process_id())
    assert(common.mkdirp(join(root, ".git")))
    assert(common.mkdirp(join(root, "build")))
    assert(common.mkdirp(join(root, "build", "deep")))
    assert(common.mkdirp(join(root, "empty", "nested")))
    assert(common.mkdirp(join(root, "from-ignore")))
    assert(common.mkdirp(join(root, "from-rgignore")))
    assert(common.mkdirp(join(root, ".hidden-folder", "nested")))
    write(join(root, ".gitignore"), "build/\n")
    write(join(root, ".ignore"), "from-ignore/\n")
    write(join(root, ".rgignore"), "from-rgignore/\n")
    write(join(root, "visible.txt"), "visible")
    write(join(root, "build", "deep", "ignored.txt"), "ignored")
    write(join(root, "from-ignore", "ignored.txt"), "ignored")
    write(join(root, "from-rgignore", "ignored.txt"), "ignored")
    write(join(root, ".hidden.txt"), "hidden")
    context.cleanup = function()
      project_files.invalidate(root)
      common.rm(root, true)
    end

    local listed, _, listed_directories = project_files.list(root, { refresh = true })
    local default = names(assert(listed))
    test.ok(default["visible.txt"], "default files: " .. table.concat((function()
      local out = {}; for name in pairs(default) do out[#out + 1] = name end; return out
    end)(), ", "))
    test.not_ok(default["build/deep/ignored.txt"])
    test.not_ok(default["from-ignore/ignored.txt"])
    test.not_ok(default["from-rgignore/ignored.txt"])
    test.not_ok(default[".hidden.txt"])

    local directories = directory_names(root, listed_directories)
    test.ok(directories["empty"])
    test.ok(directories["empty/nested"])
    test.ok(directories["build"])
    test.not_ok(directories["build/deep"])
    test.ok(directories["from-ignore"])
    test.ok(directories["from-rgignore"])
    test.not_ok(directories[".hidden-folder"])

    local unrestricted = names(assert(project_files.list(root, {
      refresh = true,
      include_ignored = true,
    })))
    test.ok(unrestricted["visible.txt"])
    test.ok(unrestricted["build/deep/ignored.txt"])
    test.ok(unrestricted["from-ignore/ignored.txt"])
    test.ok(unrestricted["from-rgignore/ignored.txt"])
    test.not_ok(unrestricted[".hidden.txt"])
    local unrestricted_directories = directory_names(root, project_files.directories(root, {
      include_ignored = true,
    }))
    test.ok(unrestricted_directories["build/deep"])
  end)

  test.it("lists a directory junction without traversing its target", function(context)
    test.skip_if(PLATFORM ~= "Windows", "This fixture uses a Windows junction")
    local project_files = require "core.project_files"
    local process = require "core.process"
    local root = common.normalize_path(join(USERDIR, "project-files-junction-" .. system.get_process_id()))
    local target = root .. "-target"
    local link = join(root, "linked")
    assert(common.mkdirp(root))
    assert(common.mkdirp(join(target, "nested")))
    write(join(target, "nested", "outside.lua"), "return true\n")
    context.cleanup = function()
      project_files.invalidate(root)
      if system.get_file_info(link) then assert(system.rmdir(link)) end
      common.rm(root, true)
      common.rm(target, true)
    end
    local proc = assert(process.start({ "cmd.exe", "/d", "/c", "mklink", "/J", link, target }, {
      stdout = process.REDIRECT_DISCARD, stderr = process.REDIRECT_DISCARD,
    }))
    while proc:running() do coroutine.yield(0.01) end
    test.equal(proc:wait(process.WAIT_DEADLINE), 0)

    local files, err, directories = project_files.list(root)

    test.not_nil(files, err)
    test.same(names(files), {})
    test.same(directory_names(root, directories), { ["."] = true, linked = true })
    test.not_ok(project_files.contains(root, link, "dir"))
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

  test.it("refreshes folder results for a new empty folder", function(context)
    local project_files = require "core.project_files"
    local root = join(USERDIR, "project-folders-new-empty-" .. system.get_process_id())
    assert(common.mkdirp(root))
    write(join(root, "existing.lua"), "return 1\n")
    context.cleanup = function()
      project_files.invalidate(root)
      common.rm(root, true)
    end
    assert(project_files.list(root, { refresh = true }))
    local added = join(root, "empty")
    assert(common.mkdirp(added))

    local reconciled, reconcile_error, refreshed = project_files.reconcile(root, {
      [added] = { precise = true },
    })

    test.ok(reconciled, reconcile_error)
    test.ok(refreshed)
    local directories = directory_names(root, project_files.directories(root))
    test.ok(directories.empty)
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
    project_files.invalidate()
    status = project_files.watch_status(root)
    test.not_ok(status.running, "Global invalidation must release watches for removed roots")
    test.equal(status.subscribers, 1)
    test.not_nil(project_files.list(root))
    test.ok(project_files.watch_status(root).running, "Listing must restore the retained subscription")
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
    local partial_snapshot = false
    local running = true
    core.add_thread(function()
      while running do
        if project_files.watch_status(root).phase == "indexing" then
          indexing_beats = indexing_beats + 1
          partial_snapshot = partial_snapshot or project_files.cached(root) ~= nil
        end
        coroutine.yield(0)
      end
    end)

    local listed = assert(project_files.list(root, { refresh = true }))
    running = false

    test.equal(#listed, 2000)
    test.ok(indexing_beats > 0, "Project membership build blocked the scheduler")
    test.not_ok(partial_snapshot, "Project listing must not publish incomplete membership")
  end)
end)
