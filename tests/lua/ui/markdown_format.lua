local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local command = require "core.command"
local panes = require "core.panes"
local test = require "core.test"

local function open_editor(text)
  local buffer = Buffer()
  buffer:set_filename("notes.md", "notes.md")
  buffer:insert(1, 1, text)
  buffer:set_selection(1, 1)
  local pane = panes.create { factory = function() return Editor(buffer) end }
  panes.focus(pane)
  return pane.current_view
end

local function text_of(view)
  return table.concat(view.buffer.lines):gsub("\n$", "")
end

test.describe("Markdown formatting commands", function()
  local saved

  test.before_each(function()
    panes.reset_for_tests()
    saved = { set_active_view = core.set_active_view, buffer_registry = core.buffer_registry }
    core.buffer_registry = nil
    core.set_active_view = function(view) core.active_view = view end
  end)

  test.after_each(function()
    panes.reset_for_tests()
    core.set_active_view = saved.set_active_view
    core.buffer_registry = saved.buffer_registry
  end)

  test.it("toggles a heading level and keeps the caret on the same text", function()
    local view = open_editor("Title")
    view.buffer:set_selection(1, 3)
    test.ok(command.perform("markdown:heading_2"))
    test.equal(text_of(view), "## Title")
    test.same({ view.buffer:get_selection() }, { 1, 6, 1, 6 })
    command.perform("markdown:heading_1")
    test.equal(text_of(view), "# Title")
    command.perform("markdown:heading_1")
    test.equal(text_of(view), "Title")
    test.same({ view.buffer:get_selection() }, { 1, 3, 1, 3 })
  end)

  test.it("makes the selected lines a bullet list in one undo step, skipping blank lines", function()
    local view = open_editor("one\n\ntwo")
    view.buffer:set_selection(1, 1, 3, 4)
    command.perform("markdown:toggle_bullet_list")
    test.equal(text_of(view), "- one\n\n- two")
    command.perform("core:undo")
    test.equal(text_of(view), "one\n\ntwo")
    command.perform("core:redo")
    command.perform("markdown:toggle_bullet_list")
    test.equal(text_of(view), "one\n\ntwo")
  end)

  test.it("numbers a bullet list in order and keeps its indent", function()
    local view = open_editor("- one\n  - two\n- three")
    view.buffer:set_selection(1, 1, 3, 3)
    command.perform("markdown:toggle_numbered_list")
    test.equal(text_of(view), "1. one\n  2. two\n3. three")
  end)

  test.it("keeps the marks of finished tasks when the list becomes a task list", function()
    local view = open_editor("- [x] done\n- todo")
    view.buffer:set_selection(1, 1, 2, 3)
    command.perform("markdown:toggle_task_list")
    test.equal(text_of(view), "- [x] done\n- [ ] todo")
    command.perform("markdown:toggle_task_list")
    test.equal(text_of(view), "done\ntodo")
  end)

  test.it("gives an empty line the format at the caret", function()
    local view = open_editor("")
    command.perform("markdown:toggle_task_list")
    test.equal(text_of(view), "- [ ] ")
    test.same({ view.buffer:get_selection() }, { 1, 7, 1, 7 })
  end)

  test.it("quotes lines and removes the quote again", function()
    local view = open_editor("first\nsecond")
    view.buffer:set_selection(1, 1, 2, 2)
    command.perform("markdown:toggle_quote")
    test.equal(text_of(view), "> first\n> second")
    command.perform("markdown:toggle_quote")
    test.equal(text_of(view), "first\nsecond")
  end)

  test.it("makes selected text a link label and puts the caret at the address", function()
    local view = open_editor("see Anvil")
    view.buffer:set_selection(1, 5, 1, 10)
    command.perform("markdown:insert_link")
    test.equal(text_of(view), "see [Anvil]()")
    test.same({ view.buffer:get_selection() }, { 1, 13, 1, 13 })
  end)

  test.it("makes a selected address a link address and puts the caret at the label", function()
    local view = open_editor("https://example.com")
    view.buffer:set_selection(1, 1, 1, 20)
    command.perform("markdown:insert_link")
    test.equal(text_of(view), "[](https://example.com)")
    test.same({ view.buffer:get_selection() }, { 1, 2, 1, 2 })
  end)

  test.it("toggles strikethrough and inline code around the selection", function()
    local view = open_editor("old value")
    view.buffer:set_selection(1, 1, 1, 4)
    command.perform("markdown:surround_strikethrough")
    test.equal(text_of(view), "~~old~~ value")
    view.buffer:set_selection(1, 9, 1, 14)
    command.perform("markdown:surround_code")
    test.equal(text_of(view), "~~old~~ `value`")
  end)

  test.it("does not change a read-only Buffer", function()
    local view = open_editor("Title")
    view.buffer.read_only = true
    command.perform("markdown:heading_1")
    test.equal(text_of(view), "Title")
  end)
end)
