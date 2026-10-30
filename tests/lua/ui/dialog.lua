local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local command = require "core.command"
local keymap = require "core.keymap"
local panes = require "core.panes"
local test = require "core.test"
local dialog = require "core.ui.dialog"
local Button = require "core.ui.button"
local TextField = require "core.ui.text_field"

local function open_editor(text)
  local buffer = Buffer()
  buffer:insert(1, 1, text)
  buffer:set_selection(1, 1)
  local pane = panes.create { factory = function() return Editor(buffer) end }
  panes.focus(pane)
  core.root_panel:update()
  return pane.current_view
end

-- A Dialog with a text field and two buttons.
local function open_dialog(options)
  options = options or {}
  local instance = dialog.Dialog({ title = "Test Dialog" })
  instance.clicks = {}
  instance.field = instance:add(TextField({ text = options.text or "", on_submit = options.on_submit }))
  instance.first = instance:add(Button({ label = "First", on_click = function() table.insert(instance.clicks, "first") end }))
  instance.second = instance:add(Button({ label = "Second", on_click = function() table.insert(instance.clicks, "second") end }))
  function instance:layout_content(x, y, w)
    self.field:set_rect(x, y, w, 30)
    self.first:set_rect(x, y + 40, 100, 30)
    self.second:set_rect(x + 110, y + 40, 100, 30)
    return 70
  end
  instance:open()
  dialog.update()
  return instance
end

-- A key event as SDL reports it, for a binding such as "ctrl+backspace".
local function press(binding)
  local parts = {}
  for part in binding:gmatch("[^+]+") do parts[#parts + 1] = part end
  local key = table.remove(parts)
  local event = { modifiers = 0, ctrl = false, shift = false, alt = false, altgr = false, super = false, gui = false }
  for _, mod in ipairs(parts) do event[mod] = true end
  local result = core.on_event("keypressed", key, event)
  core.on_event("keyreleased", key, event)
  return result
end

-- Type text as a key press without modifiers and its text event.
local function type_text(text)
  for char in text:gmatch(".") do
    local handled = press(char)
    if not handled then core.on_event("textinput", char) end
  end
end

local function click(x, y)
  core.on_event("mousepressed", "left", x, y, 1)
  core.on_event("mousereleased", "left", x, y)
end

local function center(control)
  return control.x + control.w / 2, control.y + control.h / 2
end

test.describe("Dialog", function()
  local saved

  test.before_each(function()
    panes.reset_for_tests()
    saved = { size = { core.root_panel.size.x, core.root_panel.size.y } }
    core.root_panel.size.x, core.root_panel.size.y = 1000, 700
  end)

  test.after_each(function()
    local open = dialog.current()
    if open then open:close() end
    for _ = 1, 3 do dialog.update() end
    panes.reset_for_tests()
    core.root_panel.size.x, core.root_panel.size.y = saved.size[1], saved.size[2]
  end)

  test.it("takes typed text in its focused field, not in the Editor behind it", function()
    local view = open_editor("behind")
    local instance = open_dialog()
    test.equal(instance.focused, instance.field)

    type_text("ab")

    test.equal(instance.field:get_text(), "ab")
    test.equal(view.buffer:get_text(1, 1, 1, math.huge), "behind")
  end)

  test.it("edits its field with the user's bindings for the editor's line commands", function()
    open_editor("behind")
    local instance = open_dialog({ text = "one two" })
    instance.field.input:set_caret(#"one two")
    local binding = keymap.get_binding("core:delete_to_previous_word_start")
    test.not_nil(binding)

    test.ok(press(binding))

    test.equal(instance.field:get_text(), "one ")
  end)

  test.it("moves focus through its controls and activates the focused one", function()
    open_editor("behind")
    local instance = open_dialog()

    test.ok(command.perform("dialog:focus_next"))
    test.equal(instance.focused, instance.first)
    test.ok(command.perform("dialog:focus_next"))
    test.equal(instance.focused, instance.second)
    test.ok(command.perform("dialog:confirm"))
    test.same(instance.clicks, { "second" })
    test.ok(command.perform("dialog:focus_next"))
    test.equal(instance.focused, instance.field)
    test.ok(command.perform("dialog:focus_previous"))
    test.equal(instance.focused, instance.second)
  end)

  test.it("cancels a field edit first, then closes and gives focus back", function()
    local view = open_editor("behind")
    local instance = open_dialog({ text = "kept" })
    test.equal(core.active_view, instance)
    type_text("x")
    test.equal(instance.field:get_text(), "x")

    test.ok(command.perform("dialog:close"))
    test.equal(instance.field:get_text(), "kept")
    test.equal(dialog.current(), instance)

    test.ok(command.perform("dialog:close"))
    test.is_nil(dialog.current())
    test.equal(core.active_view, view)
  end)

  test.it("submits its field on Enter and keeps a refused text with its message", function()
    open_editor("behind")
    local submitted = {}
    local instance = open_dialog({
      text = "old",
      on_submit = function(text)
        if text:find("/", 1, true) then return false, "No slashes" end
        submitted[#submitted + 1] = text
      end,
    })

    type_text("a/b")
    test.ok(command.perform("dialog:confirm"))
    test.equal(instance.field:get_text(), "a/b")
    test.equal(instance.field.error, "No slashes")
    test.same(submitted, {})

    instance.field:set_text("old")
    instance.field:select_all()
    type_text("new")
    test.ok(command.perform("dialog:confirm"))
    test.same(submitted, { "new" })
    test.is_nil(instance.field.error)
  end)

  test.it("puts back the accepted text when focus leaves a refused field", function()
    open_editor("behind")
    local instance = open_dialog({ text = "old", on_submit = function() return false, "Refused" end })
    type_text("bad")

    test.ok(command.perform("dialog:focus_next"))

    test.equal(instance.field:get_text(), "old")
    test.is_nil(instance.field.error)
  end)

  test.it("clicks its buttons and keeps clicks away from the Editor behind it", function()
    local view = open_editor("behind")
    local instance = open_dialog()
    local before = { view.buffer:get_selection() }

    click(center(instance.first))

    test.same(instance.clicks, { "first" })
    test.equal(instance.focused, instance.first)
    test.same({ view.buffer:get_selection() }, before)
    test.equal(dialog.current(), instance)
  end)

  test.it("closes on a press beside the card and with its close button", function()
    open_editor("behind")
    local instance = open_dialog()
    click(instance.rect.x + instance.rect.w + 20, instance.rect.y + instance.rect.h + 20)
    test.is_nil(dialog.current())

    instance = open_dialog()
    click(center(instance.close_button))
    test.is_nil(dialog.current())
  end)

  test.it("submits a field edit when it closes", function()
    open_editor("behind")
    local submitted
    local instance = open_dialog({ text = "old", on_submit = function(text) submitted = text end })
    type_text("new")

    instance:close()

    test.equal(submitted, "new")
  end)
end)
