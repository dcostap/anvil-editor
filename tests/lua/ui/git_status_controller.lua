local test = require "core.test"
local git_status = require "plugins.git.status_controller"

local function make_controller()
  local now = 10
  local commands, publications = {}, {}
  local backend = { is_enabled = function() return true end }
  function backend.run_git(repo, args, opts, callback)
    local job = { cancelled = false }
    function job:cancel() self.cancelled = true end
    commands[#commands+1] = { args = args, opts = opts, callback = callback, job = job }
    return job
  end
  local controller = git_status.new {
    backend = backend,
    repository = { root = "C:/repo" },
    clock = function() return now end,
    build_snapshot = function(payload, _, callback)
      local snapshot = {}
      function snapshot:lookup(path)
        if path == "src/app.lua" then return { kind = "modified", additions = 2, deletions = 1 } end
      end
      function snapshot:close() end
      callback(snapshot)
    end,
    publish = function(snapshot) publications[#publications+1] = snapshot end,
  }
  return controller, commands, publications, function(seconds) now = now + seconds end
end

local function complete(commands, offset)
  commands[offset + 1].callback({ stdout = " M src/app.lua\0" })
  commands[offset + 2].callback({ stdout = "2\t1\tsrc/app.lua\0" })
end

test.describe("Repository Git status controller", function()
  test.it("keeps the published snapshot when Git reports no changes", function()
    local controller, commands, publications, advance = make_controller()
    controller:request("initial")
    controller:update()
    complete(commands, 0)
    local generation = controller:status().published_generation
    advance(3)
    controller:request("focus")
    controller:update()
    complete(commands, 2)
    test.equal(#publications, 1, "unchanged Git output must not publish another snapshot")
    test.equal(controller:status().published_generation, generation)
    test.not_ok(controller:status().active)
    controller:close()
  end)

  test.it("publishes status and line counts together", function()
    local controller, commands, publications = make_controller()
    controller:request("initial")
    controller:update()
    test.equal(#commands, 2)
    commands[1].callback({ stdout = " M src/app.lua\0" })
    test.equal(#publications, 0)
    commands[2].callback({ stdout = "2\t1\tsrc/app.lua\0" })
    test.equal(#publications, 1)
    local info = controller:lookup("C:/repo/src/app.lua", false)
    test.equal(info.kind, "modified")
    test.equal(info.additions, 2)
    test.equal(info.deletions, 1)
    controller:close()
  end)

  test.it("cancels work on close and rejects its late result", function()
    local controller, commands, publications = make_controller()
    controller:request("initial")
    controller:update()
    controller:close()
    test.ok(commands[1].job.cancelled)
    test.ok(commands[2].job.cancelled)
    complete(commands, 0)
    test.equal(#publications, 0)
  end)

  test.it("preserves the last valid snapshot after failure and remains retryable", function()
    local controller, commands, publications, advance = make_controller()
    controller:request("initial")
    controller:update()
    complete(commands, 0)
    advance(3)
    controller:request("failure")
    controller:update()
    commands[3].callback(nil, { kind = "exit", message = "failed" })
    test.equal(#publications, 1)
    test.equal(controller:lookup("C:/repo/src/app.lua", false).kind, "modified")
    test.not_ok(controller:status().active)
    advance(3)
    controller:request("retry")
    controller:update()
    test.equal(#commands, 6)
    complete(commands, 4)
    test.not_ok(controller:status().active)
    controller:close()
  end)
end)
