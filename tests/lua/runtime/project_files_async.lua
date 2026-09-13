local common = require "core.common"
local project_files = require "core.project_files"
local test = require "core.test"

local function write(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

test.describe("Project file worker I/O", function()
  test.after_each(function(context)
    if context.cleanup then context.cleanup() end
  end)
  test.it("lists and reconciles files without filesystem I/O on the UI thread", function(context)
    local root = common.normalize_path(USERDIR .. PATHSEP .. "project-worker-" .. system.get_process_id())
    assert(common.mkdirp(root .. PATHSEP .. "empty"))
    local path = root .. PATHSEP .. "source.lua"
    write(path, "return 1\n")
    local get_info, list_info = system.get_file_info, system.list_dir_info
    context.cleanup = function()
      system.get_file_info, system.list_dir_info = get_info, list_info
      project_files.invalidate(root)
      common.rm(root, true)
    end
    local function guard(fn)
      return function(name, ...)
        assert(not common.path_equals(name, root) and not common.path_belongs_to(name, root),
          "Project filesystem I/O blocked the UI thread: " .. name)
        return fn(name, ...)
      end
    end
    system.get_file_info, system.list_dir_info = guard(get_info), guard(list_info)

    local files, err, directories = project_files.list(root)
    test.not_nil(files, err)
    test.equal(#files, 1)
    test.equal(#directories, 2)
    write(path, "return 2\n")
    local ok, reconcile_error, refreshed = project_files.reconcile(root, { path })
    test.ok(ok, reconcile_error)
    test.not_ok(refreshed)
    test.equal(project_files.cached(root), files)

    local added = root .. PATHSEP .. "added.lua"
    write(added, "return 3\n")
    ok, reconcile_error, refreshed = project_files.reconcile(root, { added })
    test.ok(ok, reconcile_error)
    test.ok(refreshed)
    test.ok(project_files.contains(root, added))
    assert(os.remove(path))
    ok, reconcile_error, refreshed = project_files.reconcile(root, { path })
    test.ok(ok, reconcile_error)
    test.ok(refreshed)
    test.not_ok(project_files.contains(root, path))
  end)

  test.it("finishes subscriber delivery before processing the next file batch", function(context)
    local DirWatch = require "core.dirwatch"
    local root = common.normalize_path(USERDIR .. PATHSEP .. "project-delivery-" .. system.get_process_id())
    assert(common.mkdirp(root))
    local path = root .. PATHSEP .. "source.lua"
    write(path, "return 1\n")
    assert(project_files.list(root))
    local check, pending = DirWatch.check, false
    local id, events = {}, {}
    local release, finished, overlap = false, false, false
    context.cleanup = function()
      release = true
      DirWatch.check = check
      project_files.unsubscribe(root, id)
      project_files.invalidate(root)
      common.rm(root, true)
    end
    DirWatch.check = function(_, callback)
      if pending then
        pending = false
        callback(root, path, true)
      end
      return false
    end
    project_files.subscribe(root, id, function(_, event)
      events[#events + 1] = event
      if #events == 1 then
        while not release do coroutine.yield(0) end
        finished = true
      else
        overlap = not finished
      end
    end)
    pending = true
    local deadline = system.get_time() + 5
    while #events == 0 and system.get_time() < deadline do coroutine.yield(0) end
    test.equal(#events, 1)
    assert(os.remove(path))
    pending = true
    -- Give the next batch time to arrive while the first subscriber is suspended.
    coroutine.yield(0.3)
    release = true
    while #events < 2 and system.get_time() < deadline do coroutine.yield(0) end
    test.equal(#events, 2)
    test.not_ok(overlap, "A later file batch overtook a suspended subscriber")
    test.equal(events[1].file_info[path].type, "file")
    test.equal(events[2].file_info[path], false)
    test.not_ok(project_files.contains(root, path))
  end)
end)
