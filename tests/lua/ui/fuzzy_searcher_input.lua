local config = require "core.config"
local core = require "core"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local keymap = require "core.keymap"
local test = require "core.test"

test.describe("Fuzzy Searcher input", function()
  test.before_each(function(context)
    context.transitions = config.transitions
    context.modkeys = {}
    for key, value in pairs(keymap.modkeys) do
      context.modkeys[key] = value
      keymap.modkeys[key] = false
    end
    config.transitions = false
  end)

  test.after_each(function(context)
    local picker = core.fuzzy_searcher_active_view
    if picker and picker.close then pcall(function() picker:close() end) end
    for key in pairs(keymap.modkeys) do keymap.modkeys[key] = nil end
    for key, value in pairs(context.modkeys) do keymap.modkeys[key] = value end
    config.transitions = context.transitions
  end)

  test.it("moves the query caret with Left", function()
    fuzzy_searcher.open(">")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker.input:set_text(">copy stuff")
    picker.input.textview.buffer:set_selection(1, 12)

    core.on_event("keypressed", "left", {})

    local line, column = picker.input.textview.buffer:get_selection()
    test.equal(line, 1)
    test.equal(column, 11)
  end)
end)
