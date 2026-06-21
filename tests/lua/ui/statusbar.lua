local test = require "core.test"
local config = require "core.config"
local StatusBar = require "core.statusbar"

test.describe("status bar messages", function()
  local old_timeout

  test.before_each(function()
    old_timeout = config.message_timeout
    config.message_timeout = 2
  end)

  test.after_each(function()
    config.message_timeout = old_timeout
  end)

  local function shown_duration_for(text)
    local status_bar = StatusBar()
    status_bar:show_message("i", {}, text)
    return status_bar.message_timeout - status_bar.message_pulse_start
  end

  test.it("uses the configured timeout for short messages", function()
    test.equal(shown_duration_for(string.rep("a", 20)), 2)
  end)

  test.it("scales message timeout linearly by bounded text length", function()
    test.equal(shown_duration_for(string.rep("a", 60)), 5)
    test.equal(shown_duration_for(string.rep("a", 100)), 8)
    test.equal(shown_duration_for(string.rep("a", 120)), 8)
  end)
end)
