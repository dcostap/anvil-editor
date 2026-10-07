local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local RootPanel = require "core.rootpanel"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local test = require "core.test"

local function click(button)
  local x = button.position.x + button.size.x / 2
  local y = button.position.y + button.size.y / 2
  core.on_event("mousemoved", x, y, 0, 0)
  core.on_event("mousepressed", "left", x, y, 1)
  core.on_event("mousereleased", "left", x, y)
end

test.describe("Keyboard input checker", function()
  local saved, root, background_calls

  test.before_each(function()
    saved = {
      root = core.root_panel, active = core.active_view,
      set_active_view = core.set_active_view,
      binding = keymap.map.f24, clipboard = system.set_clipboard,
      quit = core.quit,
      poll_event = system.poll_event,
    }
    root = RootPanel()
    root.size.x, root.size.y = 1200, 800
    core.root_panel = root
    core.set_active_view = function(view) core.active_view = view end
    background_calls = 0
    keymap.map.f24 = { function() background_calls = background_calls + 1; return true end }
  end)

  test.after_each(function()
    local owner = root:modal_input_owner()
    if owner then owner:on_close() end
    core.root_panel, core.active_view = saved.root, saved.active
    core.set_active_view = saved.set_active_view
    keymap.map.f24 = saved.binding
    system.set_clipboard = saved.clipboard
    core.quit = saved.quit
    system.poll_event = saved.poll_event
    keymap.clear_modkeys()
  end)

  test.it("opens from its command and shows received keys, text, and composition without editing", function()
    local buffer = Buffer()
    buffer:insert(1, 1, "keep this")
    core.active_view = Editor(buffer)
    test.ok(command.perform("core:keyboard_input_checker_gui"))
    local checker = root:modal_input_owner()
    test.not_nil(checker)
    test.ok(checker:supports_text_input())
    test.not_ok(core.on_event("keypressed", "f24", {
      raw_scancode = 118, scancode = 115, keycode = 1073741939,
      modifiers = 195, ctrl = true, shift = true, ["repeat"] = true,
      timestamp = 12.5, text = "R",
    }))
    core.on_event("keyreleased", "f24", { scancode = 115 })
    core.on_event("keypressed", "escape", {})
    core.on_event("textinput", "é")
    core.on_event("textediting", "あ", 0, 1)
    local text = checker:get_log_text()
    for _, part in ipairs {
      "keypressed", "keyreleased", "f24", "escape", "raw_scancode=118",
      "scancode=115", "keycode=1073741939", "modifiers=195", "ctrl=true",
      "shift=true", "repeat=true", "timestamp=12.5", 'text="R"',
      'textinput text="é"', 'textediting text="あ" start=0 length=1',
    } do
      test.ok(text:find(part, 1, true), "missing received input: " .. part)
    end
    test.equal(background_calls, 0)
    test.equal(root:modal_input_owner(), checker)
    test.equal(buffer:get_text(1, 1, 1, 10), "keep this")
  end)

  test.it("copies and clears received input with the mouse, then restores editor input on close", function()
    local previous = core.active_view
    test.ok(command.perform("core:keyboard_input_checker_gui"))
    local checker = root:modal_input_owner()
    checker:update()
    core.on_event("keypressed", "f24", {})
    local text = checker:get_log_text()
    local copied
    system.set_clipboard = function(value) copied = value end
    click(checker.copy_button)
    test.equal(copied, text)
    click(checker.clear_button)
    test.equal(checker:get_log_text(), "")
    click(checker.close)
    test.is_nil(root:modal_input_owner())
    test.equal(core.active_view, previous)
    core.on_event("keypressed", "f24", {})
    test.equal(background_calls, 1)
  end)

  test.it("keeps native close requests from ending the editor while checking keys", function()
    local quit_requested = false
    core.quit = function() quit_requested = true end
    test.ok(command.perform("core:keyboard_input_checker_gui"))
    local checker = root:modal_input_owner()
    core.on_event("keypressed", "f4", { alt = true })
    core.on_event("windowclose")
    test.not_ok(quit_requested)
    test.equal(root:modal_input_owner(), checker)
    test.ok(checker:get_log_text():find("windowclose", 1, true))
    checker:on_close()
    core.on_event("windowclose")
    test.ok(quit_requested)
  end)

  test.it("shows text received after a mouse press in the same event batch", function()
    test.ok(command.perform("core:keyboard_input_checker_gui"))
    local checker = root:modal_input_owner()
    local events = {
      { "mousepressed", "left", 0, 0, 1 },
      { "keypressed", "a", {} },
      { "textinput", "a" },
    }
    local index = 0
    system.poll_event = function()
      index = index + 1
      return table.unpack(events[index] or {})
    end
    core.step(system.get_time(), { immediate = true })
    test.ok(checker:get_log_text():find('textinput text="a"', 1, true))
  end)
end)
