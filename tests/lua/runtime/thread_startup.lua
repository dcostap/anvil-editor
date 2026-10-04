local test = require "core.test"

test.describe("Worker startup", function()
  test.it("starts workers with strict globals and no embedded runtime", function()
    local globals = _G
    local previous_meta = getmetatable(globals)
    local previous_datadir = rawget(globals, "EMBEDDED_DATADIR")
    rawset(globals, "EMBEDDED_DATADIR", nil)
    setmetatable(globals, {
      __index = function(_, name)
        error("cannot get undefined variable: " .. name, 2)
      end,
    })

    local ok, worker, err = pcall(thread.create, "runtime-path-worker", function()
      return 7
    end)

    setmetatable(globals, previous_meta)
    rawset(globals, "EMBEDDED_DATADIR", previous_datadir)
    test.ok(ok, worker)
    test.not_nil(worker, err)
    test.equal(worker:wait(), 7)
  end)
end)
