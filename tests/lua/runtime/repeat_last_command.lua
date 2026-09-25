local test = require "core.test"
local command = require "core.command"

test.describe("repeat last command", function()
  local saved_map

  test.before_each(function()
    saved_map = command.map
    command.map = {
      ["core:repeat_last_command"] = saved_map["core:repeat_last_command"],
    }
  end)

  test.after_each(function()
    command.map = saved_map
  end)

  test.it("runs the same command and arguments on each repeat", function()
    local seen = {}
    command.add(nil, {
      ["test_feature:append"] = function(value)
        seen[#seen + 1] = value
      end,
    })

    test.ok(command.perform("test_feature:append", "item"))
    test.ok(command.perform("core:repeat_last_command"))
    test.ok(command.perform("core:repeat_last_command"))

    test.same({ "item", "item", "item" }, seen)
  end)

  test.it("keeps the last valid command after an invalid command", function()
    local seen = {}
    command.add(nil, {
      ["test_feature:first"] = function() seen[#seen + 1] = "first" end,
    })
    command.add(function() return false end, {
      ["test_feature:unavailable"] = function() seen[#seen + 1] = "unavailable" end,
    })

    test.ok(command.perform("test_feature:first"))
    test.not_ok(command.perform("test_feature:unavailable"))
    test.ok(command.perform("core:repeat_last_command"))

    test.same({ "first", "first" }, seen)
  end)

  test.it("repeats a newer command after it runs", function()
    local seen = {}
    command.add(nil, {
      ["test_feature:first"] = function() seen[#seen + 1] = "first" end,
      ["test_feature:second"] = function() seen[#seen + 1] = "second" end,
    })

    test.ok(command.perform("test_feature:first"))
    test.ok(command.perform("test_feature:second"))
    test.ok(command.perform("core:repeat_last_command"))

    test.same({ "first", "second", "second" }, seen)
  end)

  test.it("repeats the outer command instead of its internal command", function()
    local seen = {}
    command.add(nil, {
      ["test_feature:inner"] = function() seen[#seen + 1] = "inner" end,
      ["test_feature:outer"] = function()
        seen[#seen + 1] = "outer"
        command.perform("test_feature:inner")
      end,
    })

    test.ok(command.perform("test_feature:outer"))
    test.ok(command.perform("core:repeat_last_command"))

    test.same({ "outer", "inner", "outer", "inner" }, seen)
  end)
end)
