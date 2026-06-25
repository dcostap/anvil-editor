local core = require "core"
local test = require "core.test"

test.describe("core.open_doc", function()
  test.before_each(function(context)
    context.original_docs = core.docs
    core.docs = {}
  end)

  test.after_each(function(context)
    core.docs = context.original_docs
  end)

  test.test("rejects filenames containing control characters", function()
    local ok, err = pcall(core.open_doc, "test.txt\r")

    test.equal(ok, false)
    test.ok(tostring(err):find("invalid filename", 1, true), tostring(err))
    test.equal(#core.docs, 0)
  end)
end)
