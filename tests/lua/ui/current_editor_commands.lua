local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local View = require "core.view"
local command = require "core.command"
local panes = require "core.panes"
local test = require "core.test"

local function editor_factory()
  return function() return Editor(Buffer()) end
end

test.describe("Current Editor command routing", function()
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

  test.it("routes text editing to the focused Pane's Current Editor", function()
    local one = panes.create { factory = editor_factory() }
    local two = panes.create { factory = editor_factory() }
    panes.focus(one)
    core.active_view = two.current_view

    test.ok(command.perform("text:newline"))
    test.equal(#one.current_view.buffer.lines, 2)
    test.equal(#two.current_view.buffer.lines, 1)
  end)

  test.it("does not route text editing to a suspended Editor", function()
    local pane = panes.create { factory = editor_factory() }
    local suspended = pane.current_view
    local current = Editor(Buffer())
    panes.present(current, { pane = pane })
    core.active_view = suspended

    test.ok(command.perform("text:newline"))
    test.equal(#current.buffer.lines, 2)
    test.equal(#suspended.buffer.lines, 1)
  end)

  test.it("routes text editing to an Editor subclass", function()
    local SpecializedEditor = Editor:extend()
    local pane = panes.create { factory = function() return SpecializedEditor(Buffer()) end }
    test.equal(core.current_editor(), pane.current_view)
    test.ok(command.perform("text:newline"))
    test.equal(#pane.current_view.buffer.lines, 2)
  end)
end)
