local core = require "core"
local test = require "core.test"

test.describe("core.open_buffer", function()
  test.before_each(function(context)
    context.original_buffers = core.buffers
    core.buffers = {}
  end)

  test.after_each(function(context)
    core.buffers = context.original_buffers
  end)

  test.test("rejects filenames containing control characters", function()
    local ok, err = pcall(core.open_buffer, "test.txt\r")

    test.equal(ok, false)
    test.ok(tostring(err):find("invalid filename", 1, true), tostring(err))
    test.equal(#core.buffers, 0)
  end)
end)
