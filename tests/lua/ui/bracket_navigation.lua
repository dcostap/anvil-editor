local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local command = require "core.command"
local panes = require "core.panes"
local test = require "core.test"
require "plugins.bracketmatch"
require "plugins.intellij_actions"

test.describe("enclosing bracket navigation", function()
  local old_view
  test.before_each(function()
    old_view = core.active_view
    panes.reset_for_tests()
  end)
  test.after_each(function()
    panes.reset_for_tests()
    core.active_view = old_view
  end)

  local function setup(text, col)
    local pane = panes.create { factory = function()
      local buffer = Buffer(nil, nil, true)
      buffer:insert(1, 1, text)
      return Editor(buffer)
    end }
    pane.current_view.buffer:set_selection(1, col)
    return pane.current_view.buffer
  end

  test.it("jumps to the innermost enclosing opener and Back restores the caret", function()
    local buffer = setup("{ [ abc ] }", 6)
    command.perform("editor:move_to_matching_bracket_with_history")
    test.equal(select(2, buffer:get_selection()), 3)
    test.ok(command.perform("core:navigate_back"))
    test.equal(select(2, buffer:get_selection()), 6)
  end)

  test.it("keeps the existing matching jump", function()
    local buffer = setup("{ abc }", 1)
    command.perform("editor:move_to_matching_bracket_with_history")
    test.equal(select(2, buffer:get_selection()), 7)
  end)

  test.it("does not jump into a completed or unclosed block", function()
    local buffer = setup("{} abc {", 5)
    command.perform("editor:move_to_matching_bracket_with_history")
    test.equal(select(2, buffer:get_selection()), 5)
  end)
end)
