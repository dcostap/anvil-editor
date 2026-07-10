local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"

test.describe("DocView owned features", function()
  test.it("round-trips optional owned feature workspace state", function()
    local doc = Doc("owned-state.txt", "owned-state.txt", true)
    local first = DocView(doc)
    first:add_owned_feature("stateful", {
      value = "source",
      get_state = function(self) return { value = self.value } end,
    })
    local saved = test.not_nil(first:get_state().owned_features)
    local restored_value
    local second = DocView(doc)
    second:add_owned_feature("stateful", {
      set_state = function(_, owner, state)
        test.equal(owner, second)
        restored_value = state.value
      end,
    })
    second:restore_owned_feature_state(saved)
    test.equal(restored_value, "source")

    local delayed_value
    local delayed = DocView(doc)
    delayed:restore_owned_feature_state(saved)
    test.not_nil(delayed:get_state().owned_features)
    delayed:add_owned_feature("stateful", {
      set_state = function(_, _, state) delayed_value = state.value end,
    })
    test.equal(delayed_value, "source")

    local failed = DocView(doc)
    failed:add_owned_feature("stateful", {
      get_state = function() return { value = "default" } end,
      set_state = function() error("not ready") end,
    })
    failed:restore_owned_feature_state(saved)
    test.equal(failed:get_state().owned_features.stateful.value, "source")
  end)

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
