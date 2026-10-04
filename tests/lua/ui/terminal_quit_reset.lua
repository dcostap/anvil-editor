local command = require "core.command"
local storage = require "core.storage"
local test = require "core.test"
require "plugins.terminal"

test.describe("Terminal quit preference", function()
  test.it("clears a remembered answer through the reset command", function()
    local previous = storage.load("plugins.terminal", "quit_choice")
    local ok, err = pcall(function()
      storage.save("plugins.terminal", "quit_choice", "keep")
      test.ok(command.perform("terminal:reset_quit_choice"))
      test.equal(storage.load("plugins.terminal", "quit_choice"), nil)
      test.ok(command.perform("terminal:reset_quit_choice"))
    end)
    storage.clear("plugins.terminal", "quit_choice")
    if previous then storage.save("plugins.terminal", "quit_choice", previous) end
    test.ok(ok, err)
  end)
end)
