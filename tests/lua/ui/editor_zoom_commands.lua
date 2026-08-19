local test = require "core.test"
local command = require "core.command"

require "plugins.scale"

test.describe("editor zoom commands", function()
  test.it("uses editor zoom command names", function()
    test.ok(command.is_valid("editor:zoom_in"))
    test.ok(command.is_valid("editor:zoom_out"))
    test.ok(command.is_valid("editor:zoom_reset"))

    test.not_ok(command.is_valid("core:zoom_in"))
    test.not_ok(command.is_valid("core:zoom_out"))
    test.not_ok(command.is_valid("core:zoom_reset"))
  end)
end)
