local test = require "core.test"
local status = require "plugins.file_git_status"

local function fixture()
  local now, publications, active = 0, 0, true
  local events = {}
  local discoveries, commands = {}, {}
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
    root_for_path = function(path) return path:match("^(.*)/[^/]+$") end,
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
      callback {
        lookup = function() return { kind = "modified", additions = 2, deletions = 1 } end,
        close = function() end,
      }
    end,
  }
  return service, discoveries, commands, {
    advance = function(seconds) now = now + seconds end,
    publications = function() return publications end,
    change = function(path) events[#events+1] = path end,
    set_active = function(value) active = value end,
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
    service:close()
  end)
end)
