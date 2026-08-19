local test = require "core.test"
local command = require "core.command"

test.describe("toggle commands", function()
  local saved_map
  local saved_aliases
  local saved_metadata

  test.before_each(function()
    saved_map = command.map
    saved_aliases = command.aliases
    saved_metadata = command.metadata
    command.map = {}
    command.aliases = {}
    command.metadata = {}
  end)

  test.after_each(function()
    command.map = saved_map
    command.aliases = saved_aliases
    command.metadata = saved_metadata
  end)

  test.it("registers one toggle command with current boolean status", function()
    local enabled = false

    command.add_toggle("test-feature:toggle", {
      get = function() return enabled end,
      set = function(value) enabled = value end,
    })

    test.not_nil(command.map["test-feature:toggle"])
    test.is_nil(command.map["test-feature:enable"])
    test.is_nil(command.map["test-feature:disable"])
    test.equal(command.get_status_label("test-feature:toggle"), "[Currently: OFF]")

    command.perform("test-feature:toggle")
    test.ok(enabled)
    test.equal(command.get_status_label("test-feature:toggle"), "[Currently: ON]")
  end)

  test.it("allows callers to force toggle state with a boolean argument", function()
    local enabled = false

    command.add_toggle("test-feature:toggle", {
      get = function() return enabled end,
      set = function(value) enabled = value end,
    })

    command.perform("test-feature:toggle", true)
    test.ok(enabled)

    command.perform("test-feature:toggle", false)
    test.not_ok(enabled)
  end)

  test.it("preserves predicate context when callers force toggle state", function()
    local enabled = false
    local seen_context

    command.add_toggle("test-feature:toggle", {
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

    command.perform("test-feature:toggle")
    test.ok(enabled)
    test.equal(seen_context, "context")

    command.perform("test-feature:toggle", false)
    test.not_ok(enabled)
    test.equal(seen_context, "context")
  end)

  test.it("keeps palette metadata when command behavior is wrapped", function()
    command.add(nil, { ["test-feature:open"] = function() end })
    command.set_metadata("test-feature:open", {
      title = "Open Test Feature",
      supports_placement = true,
    })
    command.add(nil, { ["test-feature:open"] = function() end })

    test.equal(command.get_metadata("test-feature:open").title, "Open Test Feature")
    test.ok(command.get_metadata("test-feature:open").supports_placement)
  end)

  test.it("limits invocation context to one command execution", function()
    local observed
    command.add(nil, {
      ["test-feature:open"] = function()
        observed = command.get_invocation_context()
      end,
    })
    local context = { placement = "split" }

    command.perform_with_context("test-feature:open", context)

    test.equal(observed, context)
    test.is_nil(command.get_invocation_context())
  end)
end)
