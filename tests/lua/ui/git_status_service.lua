local test = require "core.test"
local status = require "plugins.file_git_status"
local project_paths = require "core.project_paths"

local function fixture()
  local now, publications, active = 0, 0, true
  local events = {}
  local discoveries, commands = {}, {}
  local result = { kind = "modified", additions = 2, deletions = 1 }
  local root_hint
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
    root_for_path = function(path) return root_hint or path:match("^(.*)/[^/]+$") end,
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
    set_root = function(value) root_hint = value end,
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
  test.it("resolves the repository again when Project paths change", function()
    local service, discoveries, commands, clock = fixture()
    local path = "C:/repo/file.lua"
    service:lookup(path)
    discoveries[1].callback({ root = "C:/repo" })
    clock.advance(1)
    service:update()
    commands[1].callback({ stdout = " M file.lua\0" })
    commands[2].callback({ stdout = "2\t1\tfile.lua\0" })
    test.equal(service:lookup(path).kind, "modified")
    clock.set_root("C:/")
    project_paths.invalidate("Git lookup test")
    test.is_nil(service:lookup(path), "a changed Project path needs fresh repository discovery")
    discoveries[2].callback({ root = "C:/" })
    clock.set_result({ kind = "untracked" })
    clock.advance(1)
    service:update()
    commands[3].callback({ stdout = "?? repo/file.lua\0" })
    commands[4].callback({ stdout = "" })
    test.equal(service:lookup(path).kind, "untracked")
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
      test.equal(service:lookup(path, true).kind, "untracked")
    end
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
