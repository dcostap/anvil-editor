local config = require "core.config"
local core = require "core"
local command = require "core.command"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local keymap = require "core.keymap"
local test = require "core.test"
local View = require "core.view"

test.describe("Fuzzy Searcher input", function()
  test.before_each(function(context)
    context.transitions = config.transitions
    context.clipboard = system.get_clipboard()
    context.cursor_clipboard = core.cursor_clipboard
    context.cursor_clipboard_whole_line = core.cursor_clipboard_whole_line
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
    if context.event_modifier_binding then
      keymap.unbind(context.event_modifier_binding, "fuzzy:close")
    end
    system.set_clipboard(context.clipboard or "")
    core.cursor_clipboard = context.cursor_clipboard
    core.cursor_clipboard_whole_line = context.cursor_clipboard_whole_line
    for key in pairs(keymap.modkeys) do keymap.modkeys[key] = nil end
    for key, value in pairs(context.modkeys) do keymap.modkeys[key] = value end
    config.transitions = context.transitions
  end)

  local function perform_prompt_command(command_name)
    keymap.add({ f24 = command_name })
    core.on_event("keypressed", "f24", {})
    keymap.unbind("f24", command_name)
  end

  test.it("puts command-opened input focus back in the query field", function()
    local source = View()
    core.set_active_view(source)

    test.ok(command.perform("fuzzy:open_files"))
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.equal(core.active_view, picker.input.textview)
    test.equal(picker.input.active, true)

    core.set_active_view(source)
    picker:update()

    test.equal(core.active_view, picker.input.textview)
    test.equal(picker.input.active, true)
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

  test.it("keeps printable key presses available for text input", function()
    fuzzy_searcher.open("")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)

    local consumed = core.on_event("keypressed", "x", {})
    core.on_event("textinput", "x")

    test.not_ok(consumed)
    test.equal(picker.input:get_text(), "x")
  end)

  test.it("uses key event modifiers when modal modifier state is stale", function(context)
    context.event_modifier_binding = "alt+f24"
    keymap.add({ [context.event_modifier_binding] = "fuzzy:close" })
    fuzzy_searcher.open("")

    test.not_ok(keymap.modkeys.alt)
    core.on_event("keypressed", "f24", { alt = true })

    test.is_nil(core.fuzzy_searcher_active_view)
  end)

  test.it("keeps multiline clipboard paste on one row and keeps the caret", function()
    fuzzy_searcher.open("")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    local clipboard_text = "C:\\Projects\\my_decomps\\aoe1_attempt3\\include\\Shape.h:29\r\n"
    system.set_clipboard(clipboard_text)
    core.cursor_clipboard = {}
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("core:paste"))
    test.equal(picker.input:get_text(), clipboard_text:gsub("[\r\n]", ""))
    test.same({ picker.input.textview.buffer:get_selection() },
      { 1, #clipboard_text - 1, 1, #clipboard_text - 1 })
    test.equal(core.active_view, picker.input.textview)
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

  test.it("fills the query from the selected result and selects the new text", function()
    fuzzy_searcher.open(">old query")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker.results = {
      { kind = "command", label = "core:open_file", command = "core:open_file" },
    }
    picker.selected = 1

    test.ok(command.perform("fuzzy:fill_prompt_from_selected"))

    local buffer = picker.input.textview.buffer
    test.equal(picker.input:get_text(), ">core:open_file")
    test.same({ buffer:get_selection() }, { 1, 2, 1, #">core:open_file" + 1 })
  end)
end)
