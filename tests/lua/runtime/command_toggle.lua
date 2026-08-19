local test = require "core.test"
local command = require "core.command"

test.describe("toggle commands", function()
  local saved_map

  test.before_each(function()
    saved_map = command.map
    command.map = {}
  end)

  test.after_each(function()
    command.map = saved_map
  end)

  test.it("registers one toggle command with current boolean status", function()
    local enabled = false

    command.add_toggle("test_feature:toggle", {
      get = function() return enabled end,
      set = function(value) enabled = value end,
    })

    test.not_nil(command.map["test_feature:toggle"])
    test.is_nil(command.map["test_feature:enable"])
    test.is_nil(command.map["test_feature:disable"])
    test.equal(command.get_status_label("test_feature:toggle"), "[Currently: OFF]")

    command.perform("test_feature:toggle")
    test.ok(enabled)
    test.equal(command.get_status_label("test_feature:toggle"), "[Currently: ON]")
  end)

  test.it("allows callers to force toggle state with a boolean argument", function()
    local enabled = false

    command.add_toggle("test_feature:toggle", {
      get = function() return enabled end,
      set = function(value) enabled = value end,
    })

    command.perform("test_feature:toggle", true)
    test.ok(enabled)

    command.perform("test_feature:toggle", false)
    test.not_ok(enabled)
  end)

  test.it("preserves predicate context when callers force toggle state", function()
    local enabled = false
    local seen_context

    command.add_toggle("test_feature:toggle", {
      predicate = function(...)
        return true, "context", ...
      end,
      get = function(context)
        seen_context = context
        return enabled
      end,
      set = function(value, context)
        enabled = value
        seen_context = context
      end,
    })

    command.perform("test_feature:toggle")
    test.ok(enabled)
    test.equal(seen_context, "context")

    command.perform("test_feature:toggle", false)
    test.not_ok(enabled)
    test.equal(seen_context, "context")
  end)

  test.it("keeps palette metadata when command behavior is wrapped", function()
    command.add(nil, {
      ["test_feature:open"] = command.palette(function() end, {
        keywords = { "feature probe" },
        supports_placement = true,
      }),
    })
    command.add(nil, { ["test_feature:open"] = function() end })

    test.same({ "feature probe" }, command.get_metadata("test_feature:open").keywords)
    test.ok(command.get_metadata("test_feature:open").supports_placement)
    test.ok(command.get_metadata("test_feature:open").palette)
  end)

  test.it("rejects palette titles and descriptions", function()
    local ok = pcall(function()
      command.add(nil, {
        ["test_feature:open"] = command.palette(function() end, {
          title = "Open Test Feature",
        }),
      })
    end)
    test.not_ok(ok)
  end)

  test.it("limits invocation context to one command execution", function()
    local observed
    command.add(nil, {
      ["test_feature:open"] = function()
        observed = command.get_invocation_context()
      end,
    })
    local context = { placement = "split" }

    command.perform_with_context("test_feature:open", context)

    test.equal(observed, context)
    test.is_nil(command.get_invocation_context())
  end)
end)
