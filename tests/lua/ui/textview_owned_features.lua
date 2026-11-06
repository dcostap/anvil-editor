local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"

test.describe("TextView owned features", function()
  test.it("does not render released features while closing a wrapped View", function()
    local buffer = Buffer()
    buffer:insert(1, 1, string.rep("wrapped words\n", 300))
    local view = TextView(buffer)
    view.size.x, view.size.y = 200, 300
    local released, rendered_after_close = false, false
    view:add_line_render_provider("remaining", {
      render_line = function()
        if released then rendered_after_close = true end
      end,
    })
    view:add_line_render_provider("owned", { render_line = function() end })
    view:add_owned_feature("owned", {
      on_release = function(_, owner)
        released = true
        owner:remove_line_render_provider("owned")
      end,
    })
    view:set_wrapping_enabled(true)
    require("core.linewrapping").complete_async_reconstruction(view)
    view:on_close()
    require("core.linewrapping").complete_async_reconstruction(view)
    buffer:on_close()
    test.equal(rendered_after_close, false, "closed Views must not request more presentation")
  end)

  test.it("round-trips optional owned feature workspace state", function()
    local buffer = Buffer("owned-state.txt", "owned-state.txt", true)
    local first = TextView(buffer)
    first:add_owned_feature("stateful", {
      value = "source",
      get_state = function(self) return { value = self.value } end,
    })
    local saved = test.not_nil(first:get_state().owned_features)
    local restored_value
    local second = TextView(buffer)
    second:add_owned_feature("stateful", {
      set_state = function(_, owner, state)
        test.equal(owner, second)
        restored_value = state.value
      end,
    })
    second:restore_owned_feature_state(saved)
    test.equal(restored_value, "source")

    local delayed_value
    local delayed = TextView(buffer)
    delayed:restore_owned_feature_state(saved)
    test.not_nil(delayed:get_state().owned_features)
    delayed:add_owned_feature("stateful", {
      set_state = function(_, _, state) delayed_value = state.value end,
    })
    test.equal(delayed_value, "source")

    local failed = TextView(buffer)
    failed:add_owned_feature("stateful", {
      get_state = function() return { value = "default" } end,
      set_state = function() error("not ready") end,
    })
    failed:restore_owned_feature_state(saved)
    test.equal(failed:get_state().owned_features.stateful.value, "source")
  end)

  test.it("releases view-local feature ownership before confirmed close", function()
    local buffer = Buffer("owned-feature.txt", "owned-feature.txt", true)
    buffer:clean()
    buffer.new_file = false
    local view = TextView(buffer)
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
