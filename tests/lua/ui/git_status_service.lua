local test = require "core.test"
local common = require "core.common"
local status = require "plugins.file_git_status"

local function fixture(options)
  options = options or {}
  local now, publications, active = 0, 0, true
  local events = {}
  local discoveries, commands = {}, {}
  local result = { kind = "modified", additions = 2, deletions = 1 }
  local backend = { is_enabled = function() return true end }
  function backend.repo_for_path_async(path, callback)
    discoveries[#discoveries+1] = { path = path, callback = callback }
    return { cancel = function() end }
  end
  function backend.run_git(repo, args, options, callback)
    commands[#commands+1] = { repo = repo, args = args, callback = callback }
    return { cancel = function() end }
  end
  local service = status.new {
    backend = backend,
    clock = function() return now end,
    root_for_path = options.root_for_path or function(path, is_directory)
      return is_directory and path or path:match("^(.*)/[^/]+$")
    end,
    marker_probe = options.marker_probe,
    use_marker_scan = options.use_marker_scan ~= nil and options.use_marker_scan or false,
    is_active = function() return active end,
    watcher_factory = function() return {
      watch = function() end, unwatch = function() end,
      check = function(_, callback)
        local pending = events
        events = {}
        for _, path in ipairs(pending) do callback("C:/repo", path) end
      end,
    } end,
    publish = function() publications = publications + 1 end,
    build_snapshot = function(payload, _, callback)
      local published = result
      callback {
        lookup = function(_, path, directory)
          if type(published) == "function" then return published(path, directory) end
          return published
        end,
        close = function() end,
      }
    end,
  }
  return service, discoveries, commands, {
    advance = function(seconds) now = now + seconds end,
    publications = function() return publications end,
    change = function(path) events[#events+1] = path end,
    set_active = function(value) active = value end,
    set_result = function(value) result = value end,
  }
end

local function marker_fixture(markers)
  return fixture {
    use_marker_scan = true,
    root_for_path = function(path, is_directory)
      path = common.normalize_path(path)
      return is_directory and path or common.dirname(path)
    end,
    marker_probe = function(path)
      for marker, exists in pairs(markers) do
        if exists and common.path_equals(path, marker) then return true end
      end
      return false
    end,
  }
end

test.describe("Shared repository Git status", function()
  test.it("shares Git queries across directories and keeps drawing reads cached", function()
    local service, discoveries, commands, clock = fixture()
    service:lookup("C:/repo/one/file.lua")
    service:lookup("C:/repo/two/file.lua")
    discoveries[1].callback({ root = "C:/repo" })
    discoveries[2].callback({ root = "C:/repo" })
    clock.advance(1)
    service:update()
    test.equal(#commands, 2, "one repository needs one status and one diff query")
    commands[1].callback({ stdout = " M one/file.lua\0" })
    commands[2].callback({ stdout = "2\t1\tone/file.lua\0" })
    for _ = 1, 100 do
      test.equal(service:lookup("C:/repo/one/file.lua").kind, "modified")
      test.equal(service:lookup("C:/repo/two/file.lua").stat.additions, 2)
      service:update()
    end
    test.equal(#commands, 2, "drawing must not submit Git queries")
    service:request("C:/repo/one/file.lua", "save")
    service:request("C:/repo/two/file.lua", "filesystem")
    clock.advance(1)
    service:update()
    test.equal(#commands, 4, "related events must share one refresh")
    commands[3].callback({ stdout = " M one/file.lua\0" })
    commands[4].callback({ stdout = "2\t1\tone/file.lua\0" })
    test.equal(clock.publications(), 1, "unchanged results must not request another redraw")
    service:close()
  end)

  test.it("shares discovery within a directory but keeps nested repositories separate", function()
    local service, discoveries, commands, clock = fixture()
    service:lookup("C:/outer/inner/one.lua")
    service:lookup("C:/outer/inner/two.lua")
    test.equal(#discoveries, 1, "files in one directory share repository discovery")
    test.equal(discoveries[1].path, "C:/outer/inner")
    discoveries[1].callback({ root = "C:/outer/inner" })
    clock.advance(1)
    service:update()
    commands[1].callback({ stdout = "" })
    commands[2].callback({ stdout = "" })

    service:lookup("C:/outer/other.lua")
    test.equal(#discoveries, 2, "a nested repository needs its own discovery")
    test.equal(discoveries[2].path, "C:/outer")
    discoveries[2].callback({ root = "C:/outer" })
    service:close()
  end)

  test.it("coalesces discovery through cached markers and invalidates new nested markers", function()
    local markers = { ["C:/outer"] = true }
    local service, discoveries, commands, clock = marker_fixture(markers)
    service:lookup("C:/outer/one/file.lua")
    service:lookup("C:/outer/two/file.lua")
    test.equal(#discoveries, 1)
    test.ok(common.path_equals(discoveries[1].path, "C:/outer"))
    discoveries[1].callback({ root = "C:/outer" })
    clock.advance(1)
    service:update()
    commands[1].callback({ stdout = "" })
    commands[2].callback({ stdout = "" })

    service:lookup("C:/outer/inner/file.lua")
    test.equal(#discoveries, 1)
    markers["C:/outer/inner"] = true
    clock.change("C:/outer/inner/.git")
    service:update()
    service:lookup("C:/outer/inner/one.lua")
    test.equal(#discoveries, 2, "a new nested marker must not use the old outer route")
    test.ok(common.path_equals(discoveries[2].path, "C:/outer/inner"))
    service:close()
  end)

  test.it("keeps published file colors when a known Git marker reports changes", function()
    local markers = { ["C:/repo"] = true }
    local service, discoveries, commands, clock = marker_fixture(markers)
    local path = "C:/repo/one/file.lua"
    service:lookup(path)
    discoveries[1].callback({ root = "C:/repo" })
    clock.advance(1)
    service:update()
    commands[1].callback({ stdout = " M one/file.lua\0" })
    commands[2].callback({ stdout = "2\t1\tone/file.lua\0" })
    test.equal(service:lookup(path).kind, "modified")

    clock.change("C:/repo/.git")
    service:update()
    local info = service:lookup(path)
    test.equal(info and info.kind, "modified", "an unchanged marker must retain published colors")
    test.equal(#discoveries, 1, "an unchanged marker must not restart repository discovery")
    clock.advance(1)
    service:update()
    test.equal(#commands, 4, "a Git metadata event must still refresh status")
    service:close()
  end)

  test.it("does not discard positive discovery routes on ordinary file writes", function()
    local markers = { ["C:/repo"] = true }
    local service, discoveries, commands, clock = marker_fixture(markers)
    service:lookup("C:/repo/one/file.lua")
    discoveries[1].callback({ root = "C:/repo" })
    clock.advance(1)
    service:update()
    commands[1].callback({ stdout = "" })
    commands[2].callback({ stdout = "" })
    service:request("C:/repo/one/file.lua", "save")
    service:lookup("C:/repo/two/file.lua")
    test.equal(#discoveries, 1)
    service:request("C:/repo", "manual-refresh")
    service:lookup("C:/repo/two/file.lua")
    test.equal(#discoveries, 2, "explicit refresh must recheck marker routing")
    service:close()
  end)

  test.it("retries cached non-Git directories after a marker appears", function()
    local markers = {}
    local service, discoveries, _, clock = marker_fixture(markers)
    local path = "C:/new-repo/file.lua"
    test.is_nil(service:lookup(path))
    markers["C:/new-repo"] = true
    test.is_nil(service:lookup(path), "a negative marker result stays bounded before retry")
    clock.advance(3)
    test.is_nil(service:lookup(path), "discovery remains pending until its callback")
    test.equal(#discoveries, 1)
    test.ok(common.path_equals(discoveries[1].path, "C:/new-repo"))
    service:close()

    markers = {}
    service, discoveries = marker_fixture(markers)
    service:lookup(path)
    markers["C:/new-repo"] = true
    service:request(nil, "focus")
    service:lookup(path)
    test.equal(#discoveries, 1, "focus clears negative marker results")
    service:close()
  end)

  test.it("notifies subscribers for unchanged output, errors, and recovery", function()
    local service, discoveries, commands, clock = fixture()
    local owner = {}
    local notifications = {}
    service:subscribe(owner, function(root, reason, err)
      notifications[#notifications + 1] = { root = root, reason = reason, err = err }
    end)
    local path = "C:/repo/file.lua"
    service:lookup(path)
    discoveries[1].callback({ root = "C:/repo" })
    clock.advance(1)
    service:update()
    commands[1].callback({ stdout = " M file.lua\0" })
    commands[2].callback({ stdout = "2\t1\tfile.lua\0" })
    test.equal(#notifications, 1)

    service:request(path, "focus")
    clock.advance(1)
    service:update()
    commands[3].callback({ stdout = " M file.lua\0" })
    commands[4].callback({ stdout = "2\t1\tfile.lua\0" })
    test.equal(#notifications, 2, "unchanged output still notifies subscribers")
    test.equal(notifications[2].reason, "focus")

    service:request(path, "filesystem")
    clock.advance(1)
    service:update()
    commands[5].callback(nil, { kind = "exit", message = "status failed" })
    local stale = service:lookup(path)
    test.equal(#notifications, 3)
    test.equal(notifications[3].err.message, "status failed")
    test.equal(stale.kind, "modified")
    test.ok(stale.stale)
    test.equal(stale.error.message, "status failed")

    service:request(path, "retry")
    clock.advance(1)
    service:update()
    clock.set_result(function() return nil end)
    commands[7].callback({ stdout = "" })
    commands[8].callback({ stdout = "" })
    test.equal(#notifications, 4)
    test.is_nil(notifications[4].err)
    test.is_nil(service:lookup(path), "recovery clears stale metadata for clean paths")
    service:unsubscribe(owner)
    service:close()
  end)

  test.it("keeps an event received during a query without cancelling that query", function()
    local service, discoveries, commands, clock = fixture()
    service:lookup("C:/repo/one/file.lua")
    discoveries[1].callback({ root = "C:/repo" })
    clock.advance(1)
    service:update()
    service:request(nil, "focus")
    commands[1].callback({ stdout = " M one/file.lua\0" })
    commands[2].callback({ stdout = "2\t1\tone/file.lua\0" })
    clock.advance(3)
    service:update()
    test.equal(#commands, 4, "a change during a query must get a later refresh")
    service:close()
  end)

  test.it("accepts refresh requests for the repository directory itself", function()
    local service, discoveries, commands, clock = fixture()
    service:lookup("C:/repo/one/file.lua")
    discoveries[1].callback({ root = "C:/repo" })
    clock.advance(1)
    service:update()
    commands[1].callback({ stdout = "" })
    commands[2].callback({ stdout = "" })
    service:request("C:/repo", "manual")
    clock.advance(1)
    service:update()
    test.equal(#commands, 4)
    service:close()
  end)

  test.it("refreshes after filesystem events and checks for missed events later", function()
    local service, discoveries, commands, clock = fixture()
    service:lookup("C:/repo/one/file.lua")
    discoveries[1].callback({ root = "C:/repo" })
    clock.advance(1)
    service:update()
    commands[1].callback({ stdout = " M one/file.lua\0" })
    commands[2].callback({ stdout = "2\t1\tone/file.lua\0" })
    clock.change("C:/repo/one/file.lua")
    service:update()
    clock.advance(1)
    service:update()
    test.equal(#commands, 4)
    commands[3].callback({ stdout = " M one/file.lua\0" })
    commands[4].callback({ stdout = "3\t1\tone/file.lua\0" })
    test.equal(clock.publications(), 2)
    clock.advance(600)
    service:update()
    clock.advance(1)
    service:update()
    test.equal(#commands, 6, "a missed event must still get a later check")
    test.equal(#discoveries, 1, "periodic checks must reuse repository discovery")
    service:close()
  end)

  test.it("stops querying repositories that are no longer used", function()
    local service, discoveries, commands, clock = fixture()
    service:lookup("C:/repo/one/file.lua")
    discoveries[1].callback({ root = "C:/repo" })
    clock.advance(1)
    service:update()
    commands[1].callback({ stdout = "" })
    commands[2].callback({ stdout = "" })
    clock.set_active(false)
    clock.advance(600)
    service:update()
    service:request(nil, "focus")
    clock.advance(600)
    service:update()
    test.equal(#commands, 2)
    test.is_nil(service:lookup("C:/repo/one/file.lua"), "released status must not survive in lookup results")
    test.equal(#discoveries, 2)
    service:close()
  end)
end)

test.describe("Shared Git lookup freshness", function()
  test.it("reuses cached discovery for repeated file lookups", function()
    local service, discoveries, commands, clock = fixture()
    local path = "C:/repo/file.lua"
    service:lookup(path)
    discoveries[1].callback({ root = "C:/repo" })
    clock.advance(1)
    service:update()
    commands[1].callback({ stdout = " M file.lua\0" })
    commands[2].callback({ stdout = "2\t1\tfile.lua\0" })
    test.equal(service:lookup(path).kind, "modified")
    test.equal(service:lookup(path).kind, "modified")
    test.equal(#discoveries, 1, "cached directory discovery must survive repeated lookups")
    service:close()
  end)

  test.it("replaces cached clean and modified results only when new status is published", function()
    local service, discoveries, commands, clock = fixture()
    local path = "C:/repo/file.lua"
    test.is_nil(service:lookup(path))
    discoveries[1].callback({ root = "C:/repo" })
    clock.set_result(nil)
    clock.advance(1)
    service:update()
    commands[1].callback({ stdout = "" })
    commands[2].callback({ stdout = "" })
    test.is_nil(service:lookup(path))
    service:request(path, "save")
    clock.advance(1)
    service:update()
    test.is_nil(service:lookup(path), "pending refresh must retain published status")
    clock.set_result({ kind = "modified", additions = 4, deletions = 2 })
    commands[3].callback({ stdout = " M file.lua\0" })
    commands[4].callback({ stdout = "4\t2\tfile.lua\0" })
    local info = service:lookup(path)
    test.equal(info.stat.additions, 4)
    info.kind, info.stat.additions = "ignored", 999
    test.equal(service:lookup(path).kind, "modified")
    test.equal(service:lookup(path).stat.additions, 4)
    clock.set_result(nil)
    service:request(path, "save")
    clock.advance(1)
    service:update()
    test.equal(service:lookup(path).kind, "modified")
    commands[5].callback({ stdout = "" })
    commands[6].callback({ stdout = "" })
    test.is_nil(service:lookup(path))
    service:close()
    test.is_nil(service:lookup(path))
  end)

  test.it("retries failed discovery and keeps file and directory lookups separate", function()
    local service, discoveries, commands, clock = fixture()
    local path = "C:/repo/item"
    test.is_nil(service:lookup(path))
    discoveries[1].callback(nil, { kind = "not-repository" })
    test.is_nil(service:lookup(path))
    clock.advance(61)
    test.is_nil(service:lookup(path))
    discoveries[2].callback({ root = "C:/repo" })
    clock.set_result(function(_, directory)
      return { kind = directory and "untracked" or "modified" }
    end)
    clock.advance(1)
    service:update()
    commands[1].callback({ stdout = "?? item\0" })
    commands[2].callback({ stdout = "" })
    for _ = 1, 2 do
      test.equal(service:lookup(path, false).kind, "modified")
      if not service:lookup(path, true) then
        discoveries[3].callback({ root = "C:/repo" })
        clock.set_result(function(_, directory)
          return { kind = directory and "untracked" or "modified" }
        end)
      end
      test.equal(service:lookup(path, true).kind, "untracked")
    end
    service:close()
  end)

  test.it("reports real discovery errors once until the retry window expires", function()
    local service, discoveries, _, clock = fixture()
    local owner, notifications = {}, 0
    service:subscribe(owner, function(_, reason, err)
      if reason == "discovery" and err then notifications = notifications + 1 end
    end)
    local path = "C:/missing/file.lua"
    test.is_nil(service:lookup(path))
    local generation = service.generation
    discoveries[1].callback(nil, { kind = "permission", message = "cannot inspect repository" })
    local info = service:lookup(path)
    test.equal(info.error.message, "cannot inspect repository")
    test.ok(service.generation > generation)
    test.equal(notifications, 1)
    test.equal(service:lookup(path).error.message, "cannot inspect repository")
    test.equal(notifications, 1, "one discovery failure must not warn on every lookup")
    clock.advance(61)
    test.is_nil(service:lookup(path))
    discoveries[2].callback(nil, { kind = "permission", message = "cannot inspect repository" })
    test.equal(notifications, 2)
    service:unsubscribe(owner)
    service:close()
  end)

  test.it("does not retain an owner through a subscription", function()
    local service = fixture()
    local weak
    local function add_subscription()
      local owner = {}
      weak = setmetatable({ value = owner }, { __mode = "v" })
      service:subscribe(owner, function() return owner end)
    end
    add_subscription()
    collectgarbage("collect")
    collectgarbage("collect")
    test.is_nil(weak.value)
    service:close()
  end)

  test.it("keeps a repository alive while its cached status is displayed", function()
    local service, discoveries, commands, clock = fixture()
    local path = "C:/repo/file.lua"
    service:lookup(path)
    discoveries[1].callback({ root = "C:/repo" })
    clock.advance(1)
    service:update()
    commands[1].callback({ stdout = " M file.lua\0" })
    commands[2].callback({ stdout = "2\t1\tfile.lua\0" })
    clock.set_active(false)
    for _ = 1, 4 do
      clock.advance(90)
      test.equal(service:lookup(path).kind, "modified")
      service:update()
    end
    test.equal(#discoveries, 1, "displayed status must not lose its repository")
    service:close()
  end)
end)
