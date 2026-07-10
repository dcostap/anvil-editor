local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"

test.describe("DocView owned features", function()
  test.it("releases view-local feature ownership before confirmed close", function()
    local doc = Doc("owned-feature.txt", "owned-feature.txt", true)
    local view = DocView(doc)
    local released, closed = false, false
    view:add_owned_feature("test", {
      on_release = function(_, owner, reason)
        test.equal(owner, view)
        test.equal(reason, "view-close")
        released = true
      end,
    })

    view:try_close(function()
      test.equal(released, true)
      closed = true
    end)
    test.equal(closed, true)
    test.equal(view:remove_owned_feature("test"), false)
  end)
end)
