local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local NagView = require "core.nagview"
local RootPanel = require "core.rootpanel"
local test = require "core.test"

test.describe("Modal input routing", function()
  local saved
  local root
  local background_calls

  test.before_each(function()
    saved = {
      root_panel = core.root_panel,
      active_view = core.active_view,
      last_active_view = core.last_active_view,
      next_active_view = core.next_active_view,
      nag_view = core.nag_view,
      set_active_view = core.set_active_view,
      binding = keymap.map["f24"],
    }
    root = RootPanel()
    core.root_panel = root
    core.set_active_view = function(view) core.active_view = view end
    background_calls = 0
    keymap.map["f24"] = {
      function()
        background_calls = background_calls + 1
        return true
      end,
    }
  end)

  test.after_each(function()
    keymap.map["f24"] = saved.binding
    core.root_panel = saved.root_panel
    core.active_view = saved.active_view
    core.last_active_view = saved.last_active_view
    core.next_active_view = saved.next_active_view
    core.nag_view = saved.nag_view
    core.set_active_view = saved.set_active_view
  end)

  test.it("gives the top Modal Input Owner exclusive input", function()
    local first_calls, second_calls = 0, 0
    local first = {
      on_key_pressed = function()
        first_calls = first_calls + 1
        return true
      end,
    }
    local second = {
      on_key_pressed = function()
        second_calls = second_calls + 1
        return true
      end,
    }

    root:push_modal_input(first, { label = "first" })
    core.on_event("keypressed", "f24", {})
    test.equal(first_calls, 1)
    test.equal(background_calls, 0)

    root:push_modal_input(second, { label = "second" })
    core.on_event("keypressed", "f24", {})
    test.equal(first_calls, 1)
    test.equal(second_calls, 1)
    test.equal(background_calls, 0)

    root:pop_modal_input(second)
    core.on_event("keypressed", "f24", {})
    test.equal(first_calls, 2)
    test.equal(background_calls, 0)

    root:pop_modal_input(first)
    core.on_event("keypressed", "f24", {})
    test.equal(background_calls, 1)
  end)

  test.it("keeps a confirmation registered until its choice is selected", function()
    local previous = {}
    local selected
    local nag = NagView()
    core.active_view = previous
    core.last_active_view = previous
    core.nag_view = nag

    nag:show("Confirm", "Choose", {
      { text = "Continue", default_yes = true },
      { text = "Cancel", default_no = true },
    }, function(option)
      selected = option.text
    end)

    test.equal(root:modal_input_owner(), nag)
    test.ok(command.perform("core:select_next_dialog_entry"))
    test.ok(command.perform("core:select_dialog_entry"))
    test.equal(selected, "Cancel")
    test.is_nil(root:modal_input_owner())
    test.equal(core.active_view, previous)
  end)
end)
