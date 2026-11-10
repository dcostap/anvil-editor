local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local command = require "core.command"
local keymap = require "core.keymap"
local panes = require "core.panes"
local test = require "core.test"
local dialog = require "core.ui.dialog"
local layout = require "core.ui.layout"
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
  local clicks = {}
  local field = TextField({ text = options.text or "", on_submit = options.on_submit })
  local first = Button({ label = "First", on_click = function() table.insert(clicks, "first") end })
  local second = Button({ label = "Second", on_click = function() table.insert(clicks, "second") end })
  local instance = dialog.Dialog({ title = "Test Dialog", body = layout.Column { field, layout.Row { first, second } } })
  instance.clicks, instance.field, instance.first, instance.second = clicks, field, first, second
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

test.describe("Dialog with a layout body", function()
  local Checkbox = require "core.ui.checkbox"
  local RadioGroup = require "core.ui.radio_group"
  local Switch = require "core.ui.switch"
  local Select = require "core.ui.select"
  local ChoiceCards = require "core.ui.choice_cards"
  local saved

  test.before_each(function()
    panes.reset_for_tests()
    saved = { core.root_panel.size.x, core.root_panel.size.y }
    core.root_panel.size.x, core.root_panel.size.y = 1000, 700
  end)

  test.after_each(function()
    local open = dialog.current()
    if open then open:close() end
    for _ = 1, 3 do dialog.update() end
    panes.reset_for_tests()
    core.root_panel.size.x, core.root_panel.size.y = saved[1], saved[2]
  end)

  local function inside_card(instance, control)
    local r = instance.rect
    return control.y >= r.y and control.y + control.h <= r.y + r.h
  end

  test.it("places its body and footer, and moves focus through them in layout order", function()
    open_editor("behind")
    local name, switch = TextField {}, Switch {}
    local cancel, save = Button { label = "Cancel" }, Button { label = "Save", kind = "primary" }
    local instance = dialog.Dialog {
      title = "Layout",
      body = layout.Column { layout.Field { title = "Name", stacked = true, control = name },
        layout.Field { title = "Enabled", control = switch } },
      footer = layout.Row { justify = "end", cancel, save },
    }
    instance:open()
    dialog.update()

    test.equal(instance.focused, name)
    test.ok(name.y < switch.y and switch.y < save.y)
    test.ok(cancel.x < save.x)
    test.ok(inside_card(instance, save))
    test.equal(instance.body_scroll:max_scroll(), 0, "a body that fits does not scroll")
    local order = {}
    for _ = 1, 4 do
      command.perform("dialog:focus_next")
      order[#order + 1] = instance.focused
    end
    test.same(order, { switch, cancel, save, name })
  end)

  test.it("scrolls its body to show the focused control when the Window is short", function()
    open_editor("behind")
    core.root_panel.size.y = 320
    local body = layout.Column {}
    for i = 1, 12 do body.children[i] = TextField { text = "Field " .. i } end
    local instance = dialog.Dialog { title = "Long", body = body }
    instance:open()
    dialog.update()
    local last = body.children[12]
    test.ok(not inside_card(instance, last))

    instance:focus(last)
    for _ = 1, 3 do dialog.update() end
    test.ok(inside_card(instance, last))

    -- A control that scrolled out of the card takes no click.
    local first = body.children[1]
    test.is_nil(instance:control_at(first.x + 4, first.y + first.h / 2))
  end)

  test.it("flips and moves its choice controls with clicks, Enter and line moves", function()
    open_editor("behind")
    local switch = Switch { value = false }
    local box = Checkbox { label = "Some", value = "mixed" }
    local refused = Switch { value = true, on_change = function() return false end }
    local radio = RadioGroup { value = "a", options = {
      { value = "a", label = "A" }, { value = "b", label = "B", enabled = false }, { value = "c", label = "C" },
    } }
    local instance = dialog.Dialog { title = "Choices", body = layout.Column { switch, box, refused, radio } }
    instance:open()
    dialog.update()

    click(center(switch))
    test.equal(switch.value, true)
    instance:focus(box)
    test.ok(command.perform("dialog:confirm"))
    test.equal(box.value, true)
    click(center(refused))
    test.equal(refused.value, true)
    instance:focus(radio)
    test.ok(instance:perform("move_to_next_line"))
    test.equal(radio.value, "c")

    local cards = ChoiceCards { value = "sql", options = {
      { value = "sql", label = "SQL Server" }, { value = "pg", label = "PostgreSQL", enabled = false },
      { value = "machine", label = "Machine" },
    } }
    instance:set_body(layout.Column { cards })
    dialog.update()
    instance:focus(cards)
    test.ok(instance:perform("move_to_next_char"))
    test.equal(cards.value, "machine", "a move skips a disabled card")
    local first = cards.rects[1]
    click(first.x + first.w / 2, first.y + first.h / 2)
    test.equal(cards.value, "sql")
  end)

  local function select_options()
    return {
      { value = "dev", label = "Development" }, { value = "staging", label = "Staging" },
      { value = "prod", label = "Production", enabled = false }, { value = "demo", label = "Demo" },
    }
  end

  test.it("chooses from a Select's list with keys, typed letters and clicks, and keeps the Dialog open", function()
    open_editor("behind")
    local changes = {}
    local select = Select { value = "dev", options = select_options(),
      on_change = function(value) changes[#changes + 1] = value end }
    local other = Button { label = "Other" }
    local instance = dialog.Dialog { title = "Select", body = layout.Column { select, other } }
    instance:open(select)
    dialog.update()

    test.ok(command.perform("dialog:confirm"))
    test.not_nil(select.overlay, "Enter opens the list")
    test.ok(instance:perform("move_to_next_line"))
    test.ok(command.perform("dialog:confirm"))
    test.equal(select.value, "staging")
    test.is_nil(select.overlay)

    instance:on_modal_text_input("d")
    dialog.update()
    test.ok(command.perform("dialog:confirm"))
    test.equal(select.value, "demo", "a typed letter highlights the next option with it")

    test.ok(command.perform("dialog:confirm"))
    test.ok(command.perform("dialog:close"))
    test.is_nil(select.overlay)
    test.equal(dialog.current(), instance, "Escape closes the list, not the Dialog")

    click(center(select))
    dialog.update()
    local menu = test.not_nil(select.overlay)
    local row_h = (menu.h - 2 * layout.px(4)) / 4
    click(menu.x + menu.w / 2, menu.y + layout.px(4) + row_h * 2.5)
    test.equal(select.value, "demo", "a click on a disabled option chooses nothing")
    click(menu.x + menu.w / 2, menu.y + layout.px(4) + row_h * 0.5)
    test.equal(select.value, "dev")
    test.is_nil(select.overlay)
    test.same(changes, { "staging", "demo", "dev" })

    click(center(select))
    dialog.update()
    click(center(other))
    test.is_nil(select.overlay)
    test.same(other.pressed, false)
    test.equal(dialog.current(), instance, "a press outside the list only closes the list")
  end)

  test.it("keeps a Select's list inside the Root Panel", function()
    open_editor("behind")
    core.root_panel.size.y = 420
    local options = {}
    for i = 1, 20 do options[i] = { value = i, label = "Option " .. i } end
    local select = Select { value = 20, options = options }
    local instance = dialog.Dialog { title = "Low", body = layout.Column { layout.Spacer { height = 200 }, select } }
    instance:open(select)
    dialog.update()
    test.ok(command.perform("dialog:confirm"))
    dialog.update()
    local menu = test.not_nil(select.overlay)
    local root = core.root_panel
    test.ok(menu.y >= root.position.y and menu.y + menu.h <= root.position.y + root.size.y)
    test.ok(menu.y + menu.h <= select.y, "the list opens above when more space is there")
    test.equal(menu:index_at(menu.x + menu.w / 2, menu.y + menu.h - layout.px(8)), 20,
      "the chosen option scrolls into view")
  end)

  test.it("shows a control's tooltip after the pointer rests on it, and hides it on a press", function()
    open_editor("behind")
    local delay = dialog.TOOLTIP_DELAY
    local button = Button { icon = require("core.ui").icons.delete, tooltip = "Remove" }
    local instance = dialog.Dialog { title = "Tips", body = layout.Column { button } }
    instance:open()
    dialog.update()

    dialog.TOOLTIP_DELAY = 60
    core.on_event("mousemoved", center(button))
    dialog.update()
    test.is_nil(instance:tooltip(), "the tooltip waits for the delay")
    dialog.TOOLTIP_DELAY = 0
    dialog.update()
    test.equal(instance:tooltip(), "Remove")
    core.on_event("mousepressed", "left", center(button))
    dialog.update()
    test.is_nil(instance:tooltip())
    core.on_event("mousereleased", "left", center(button))
    dialog.update()
    test.is_nil(instance:tooltip(), "the tooltip stays hidden until the pointer leaves")
    dialog.TOOLTIP_DELAY = delay
  end)

  test.it("shows each UI Gallery page and moves through them from its page list", function()
    open_editor("behind")
    local gallery = require "plugins.ui_gallery"
    test.equal(require("core.command").get_metadata("ui_gallery:open").palette, true)
    local instance = gallery.open()
    dialog.update()
    test.equal(instance.focused, instance.nav)
    for i, page in ipairs(gallery.pages) do
      test.equal(instance.page_id, page.id)
      if page.id ~= "look" then test.ok(#instance:focusables() > 1, page.id) end
      if i < #gallery.pages then test.ok(instance:perform("move_to_next_line")) end
      dialog.update()
    end
    test.equal(instance.focused, instance.nav)
  end)

  test.it("selects text in a field with a pointer drag", function()
    open_editor("behind")
    local instance = require("plugins.ui_gallery").open("inputs")
    dialog.update()
    local field
    for _, control in ipairs(instance:focusables()) do
      if control.takes_text and control.enabled and not control.secret and control:get_text() ~= "" then
        field = control
        break
      end
    end
    field = test.not_nil(field)
    local y = field.y + field.h / 2
    core.on_event("mousepressed", "left", field.x + field.w - 2, y, 1)
    core.on_event("mousemoved", field.x + 1, y, 0, 0)
    core.on_event("mousereleased", "left", field.x + 1, y)
    test.equal(instance.focused, field)
    local first, last = field.input:selection()
    test.equal(first, 0)
    test.equal(last, #field:get_text())
  end)
end)
