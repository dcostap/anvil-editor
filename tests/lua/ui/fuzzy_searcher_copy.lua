local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

local function press_copy_shortcut()
  local previous_ctrl = keymap.modkeys.ctrl
  keymap.modkeys.ctrl = true
  local handled = keymap.on_key_pressed("c")
  keymap.modkeys.ctrl = previous_ctrl
  return handled
end

test.describe("Fuzzy Searcher selected-result copy", function()
  test.before_each(function(context)
    context.previous_clipboard = system.get_clipboard()
    context.previous_cursor_clipboard = core.cursor_clipboard
    context.previous_cursor_clipboard_whole_line = core.cursor_clipboard_whole_line
    system.set_clipboard("")
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then
      core.fuzzy_searcher_active_view:close()
    end
    system.set_clipboard(context.previous_clipboard or "")
    core.cursor_clipboard = context.previous_cursor_clipboard
    core.cursor_clipboard_whole_line = context.previous_cursor_clipboard_whole_line
  end)

  test.it("copies the selected result's main text", function()
    local picker = fuzzy_searcher.open_static_results("Results", {
      { kind = "command", label = "build:run", command = "build:run" },
      { kind = "grep", file = "src/main.c", line = 4, col = 3, text = "needle content" },
      { kind = "project", label = "C:/Projects/example", project = "C:/Projects/example" },
    })
    picker.selected = 2

    test.ok(command.perform("fuzzy-searcher:copy-selected"), "expected copy command to run")

    test.equal(system.get_clipboard(), "needle content")
    test.not_nil(picker.copy_flash, "expected copy feedback state")
    test.equal(picker.copy_flash.text, "needle content")
    test.equal(picker.copy_flash.result, picker.results[2])
    local feedback_color = picker:copy_flash_color(2)
    test.ok(feedback_color and feedback_color[4] > 0, "expected visible copy feedback")
    test.same({ feedback_color[1], feedback_color[2], feedback_color[3] }, { 255, 255, 255 })
    test.ok(feedback_color[4] <= 33, "expected at least 87% transparency")
  end)

  test.it("copies a prompt text selection before the selected result", function()
    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text("alpha beta", true)
    picker.results = {
      { kind = "file", label = "src/result.lua", file = "src/result.lua" },
    }
    picker.selected = 1

    test.ok(press_copy_shortcut(), "expected copy shortcut to be handled")

    test.equal(system.get_clipboard(), "alpha beta")
    test.equal(picker.copy_flash, nil)
  end)

  test.it("copies the selected result when the prompt has no text selection", function()
    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text("query")
    picker.results = {
      { kind = "file", label = "src/result.lua", file = "src/result.lua" },
    }
    picker.selected = 1

    test.ok(press_copy_shortcut(), "expected copy shortcut to be handled")

    test.equal(system.get_clipboard(), "src/result.lua")
    test.not_nil(picker.copy_flash, "expected selected-result copy feedback")
  end)

  test.it("copies file result text as external clipboard text", function()
    core.cursor_clipboard = { full = "src/app.lua", [1] = "stale structured clipboard" }
    core.cursor_clipboard_whole_line = { true }

    local picker = fuzzy_searcher.open_static_results("Results", {
      { kind = "file", label = "src/app.lua", file = "src/app.lua" },
    })

    test.ok(command.perform("fuzzy-searcher:copy-selected"), "expected copy command to run")

    test.equal(system.get_clipboard(), "src/app.lua")
    test.same(core.cursor_clipboard, {})
    test.same(core.cursor_clipboard_whole_line, {})
    test.equal(picker.copy_flash.text, "src/app.lua")
  end)
end)
