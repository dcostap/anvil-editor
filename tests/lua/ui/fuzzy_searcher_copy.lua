local core = require "core"
local command = require "core.command"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

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
