local command = require "core.command"
local test = require "core.test"

test.describe("paused Language Server commands", function()
  test.test("does not register Language Server commands", function()
    local names = {
      "editor:next_diagnostic",
      "editor:previous_diagnostic",
      "editor:restart_language_server",
      "editor:show_buffer_diagnostics",
      "editor:show_hover",
      "editor:show_language_server_status",
      "editor:show_signature_help",
      "editor:start_language_server",
      "editor:toggle_language_server",
    }
    for _, name in ipairs(names) do
      test.is_nil(command.map[name], name)
    end
  end)
end)
