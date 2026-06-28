local test = require "core.test"
local command = require "core.command"

require "plugins.scale"

test.describe("editor zoom commands", function()
  test.it("uses editor zoom command names", function()
    test.ok(command.is_valid("editor:zoom-in"))
    test.ok(command.is_valid("editor:zoom-out"))
    test.ok(command.is_valid("editor:zoom-reset"))

    test.not_ok(command.is_valid("scale:increase"))
    test.not_ok(command.is_valid("scale:decrease"))
    test.not_ok(command.is_valid("scale:reset"))
  end)
end)
