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

  local function perform_prompt_command(command_name)
    keymap.add({ f24 = command_name })
    core.on_event("keypressed", "f24", {})
    keymap.unbind("f24", command_name)
  end

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

  test.it("keeps printable key presses available for text input", function()
    fuzzy_searcher.open("")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)

    local consumed = core.on_event("keypressed", "x", {})
    core.on_event("textinput", "x")

    test.not_ok(consumed)
    test.equal(picker.input:get_text(), "x")
  end)

  test.it("routes local selection commands to the query input", function()
    fuzzy_searcher.open("")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker.input:set_text("camelCase")
    picker.input.textview.buffer:set_selection(1, 1)

    perform_prompt_command("editor:select_next_camel_hump")

    local buffer = picker.input.textview.buffer
    local line1, column1, line2, column2 = buffer:get_selection(true)
    test.equal(buffer:get_text(line1, column1, line2, column2), "camel")
  end)
end)
