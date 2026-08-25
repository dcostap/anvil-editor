local panes = require "core.panes"
local core = require "core"
local command = require "core.command"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local layout = require "core.pane_layout"
local View = require "core.view"
local test = require "core.test"

local FakeView = View:extend()

function FakeView:new(name)
  FakeView.super.new(self)
  self.name = name
end

function FakeView:get_name()
  return self.name
end

function FakeView:try_close(close)
  close()
end

local function factory(name)
  return function() return FakeView(name) end
end

local function names(values)
  local result = {}
  for _, pane in ipairs(values) do result[#result + 1] = pane.current_view:get_name() end
  return result
end

test.describe("Pane manager", function()
  local set_active_view
  local global_prompt_enter

  test.before_each(function()
    panes.reset_for_tests()
    set_active_view = core.set_active_view
    global_prompt_enter = core.global_prompt_bar.enter
    core.set_active_view = function(view) core.active_view = view end
  end)

  test.after_each(function()
    panes.reset_for_tests()
    core.set_active_view = set_active_view
    core.global_prompt_bar.enter = global_prompt_enter
  end)

  test.it("accepts zero Panes", function()
    test.equal(panes.count(), 0)
    test.same(panes.ordered(), {})
    test.is_nil(panes.active())
    test.is_nil(panes.visible_group())
    test.ok(panes.validate())
  end)

  test.it("creates Pane 1 in one group", function()
    local first = panes.create { factory = factory("one") }
    test.equal(panes.count(), 1)
    test.equal(panes.number(first), 1)
    test.equal(first.current_view:get_name(), "one")
    test.equal(panes.active(), first)
    test.equal(panes.visible_group(), first.group)
    test.same(names(panes.ordered()), { "one" })
    test.ok(panes.validate())
  end)

  test.it("appends each new Pane as a singleton group", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    test.same(names(panes.ordered()), { "one", "two" })
    test.equal(panes.number(one), 1)
    test.equal(panes.number(two), 2)
    test.not_equal(one.group, two.group)
  end)

  test.it("splits next to the source in deterministic order", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.split(one, "right", { factory = factory("two") })
    local zero = panes.split(one, "left", { factory = factory("zero") })
    test.same(names(panes.ordered()), { "zero", "one", "two" })
    test.equal(one.group, two.group)
    test.equal(one.group, zero.group)
    test.equal(panes.visible_group(), one.group)
  end)

  test.it("rebalances a Pane Group after moving a Pane", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.split(one, "right", { factory = factory("two") })
    local three = panes.split(one, "down", { factory = factory("three") })
    local group = one.group
    group.root.a.ratio = 0.2

    test.equal(panes.move(two, one, "left"), two)

    layout.update_rects(group.root, { x = 0, y = 0, w = 200, h = 100 })
    test.equal(two.size.x, 100)
    test.equal(two.size.y, 20)
    test.equal(one.size.x, 100)
    test.equal(one.size.y, 80)
    test.equal(three.size.x, 100)
    test.equal(three.size.y, 100)
  end)

  test.it("splits with an independent Editor for the same Buffer", function()
    local buffer = Buffer(nil, nil, true)
    buffer:insert(1, 1, "line one\nline two")
    local source = panes.create { factory = function() return Editor(buffer) end }
    source.current_view:set_selection_state { selections = { 2, 5, 2, 5 } }
    source.current_view.scroll.x, source.current_view.scroll.y = 12, 34

    test.ok(command.perform("core:split_pane_right_copy_view"))

    local destination = panes.active()
    local copy = destination.current_view
    test.not_equal(copy, source.current_view)
    test.equal(copy.buffer, buffer)
    test.same(copy:get_selection_state().selections, { 2, 5, 2, 5 })
    test.equal(copy.scroll.x, 12)
    test.equal(copy.scroll.y, 34)
    test.equal(panes.history_length(source), 1)
    test.equal(panes.history_length(destination), 1)
  end)

  test.it("falls back to a normal split for a View without safe duplication", function()
    local source = panes.create { factory = factory("source") }

    test.ok(command.perform("core:split_pane_down_copy_view"))

    local destination = panes.active()
    test.ok(destination.current_view:extends(Editor))
    test.equal(source.current_view:get_name(), "source")
    test.equal(panes.history_length(destination), 1)
  end)

  test.it("focuses one member while presenting its complete group", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.split(one, "right", { factory = factory("two") })
    local three = panes.create { factory = factory("three") }
    panes.focus(one)
    test.equal(panes.visible_group(), one.group)
    panes.focus(two)
    test.equal(panes.visible_group(), one.group)
    test.equal(panes.active(), two)
    panes.focus(three)
    test.equal(panes.visible_group(), three.group)
  end)

  test.it("does not leave a Pane when its Current View has no Surface Focus Targets", function()
    local one = panes.create { factory = factory("one") }
    panes.create { factory = factory("two") }
    panes.focus(one)

    test.ok(command.perform("core:focus_next_surface"))
    test.ok(command.perform("core:focus_previous_surface"))
    test.equal(panes.active(), one)
  end)

  test.it("rotates only the active Pane Group clockwise through fixed split positions", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.split(one, "right", { factory = factory("two") })
    local four = panes.split(one, "down", { factory = factory("four") })
    local three = panes.split(two, "down", { factory = factory("three") })
    local group = one.group
    local outside = panes.create { factory = factory("outside") }
    layout.update_rects(group.root, { x = 0, y = 0, w = 400, h = 400 })
    panes.focus(one)

    test.ok(command.perform("core:rotate_panes_clockwise"))

    test.equal(layout.pane_at(group.root, 100, 100).current_view:get_name(), "four")
    test.equal(layout.pane_at(group.root, 300, 100).current_view:get_name(), "one")
    test.equal(layout.pane_at(group.root, 300, 300).current_view:get_name(), "two")
    test.equal(layout.pane_at(group.root, 100, 300).current_view:get_name(), "three")
    test.equal(panes.active(), one)
    test.equal(panes.visible_group(), group)
    test.equal(outside.current_view:get_name(), "outside")
    test.not_equal(outside.group, group)
    test.ok(panes.validate())
  end)

  test.it("swaps the positions in a two-Pane Group rotation", function()
    local left = panes.create { factory = factory("left") }
    local right = panes.split(left, "right", { factory = factory("right") })
    local group = left.group
    layout.update_rects(group.root, { x = 0, y = 0, w = 400, h = 200 })
    panes.focus(left)

    test.ok(command.perform("core:rotate_panes_clockwise"))

    test.equal(layout.pane_at(group.root, 100, 100), right)
    test.equal(layout.pane_at(group.root, 300, 100), left)
    test.equal(panes.active(), left)
  end)

  test.it("moves and merges complete Pane histories through the numbered prompt", function()
    local destination = panes.create { factory = factory("X") }
    panes.present(FakeView("Y"), { pane = destination })
    panes.present(FakeView("Z"), { pane = destination })
    panes.back(destination)

    local source = panes.create { factory = factory("A") }
    panes.present(FakeView("B"), { pane = source })
    panes.present(FakeView("C"), { pane = source })
    panes.present(FakeView("D"), { pane = source })
    panes.back(source)

    local prompt
    core.global_prompt_bar.enter = function(_, label, options)
      prompt = { label = label, options = options }
    end

    test.ok(command.perform("core:move_and_merge_pane"))
    test.equal(prompt.label, "Move and Merge Pane Into")
    test.ok(prompt.options.validate("1"))
    prompt.options.submit("1")

    test.not_ok(panes.contains(source))
    test.equal(panes.count(), 1)
    test.equal(panes.active(), destination)
    test.equal(destination.current_view:get_name(), "C")
    for _, expected in ipairs { "B", "A", "Z", "Y", "X" } do
      test.not_nil(panes.back(destination))
      test.equal(destination.current_view:get_name(), expected)
    end
    for _, expected in ipairs { "Y", "Z", "A", "B", "C", "D" } do
      test.not_nil(panes.forward(destination))
      test.equal(destination.current_view:get_name(), expected)
    end
    test.ok(panes.validate())
  end)

  test.it("discards only a disposable destination placeholder during a merge", function()
    test.ok(command.perform("core:new_pane"))
    local destination = panes.active()
    local placeholder = destination.current_view
    local buffer = placeholder.buffer
    buffer:insert(1, 1, "x")
    buffer:remove(1, 1, 1, 2)
    test.ok(panes.is_disposable(destination))

    local source = panes.create { factory = factory("source") }
    test.equal(panes.move_and_merge(source, destination), destination)

    test.equal(panes.history_length(destination), 1)
    test.equal(destination.current_view:get_name(), "source")
    test.is_nil(panes.pane_for_view(placeholder))
    test.not_ok(panes.contains(source))
  end)

  test.it("keeps a disposable source entry when merging it into another Pane", function()
    local destination = panes.create { factory = factory("destination") }
    test.ok(command.perform("core:new_pane"))
    local source = panes.active()
    local untitled = source.current_view
    test.ok(panes.is_disposable(source))

    test.equal(panes.move_and_merge(source, destination), destination)

    test.equal(panes.history_length(destination), 2)
    test.equal(destination.current_view, untitled)
    test.equal(panes.back(destination):get_name(), "destination")
    test.not_ok(panes.contains(source))
  end)

  test.it("transfers retained source Views outside Navigation History", function()
    local destination = panes.create { factory = factory("destination") }
    local source = panes.create { factory = factory("source") }
    local protected = FakeView("protected")
    protected.history_protected = true
    panes.present(protected, { pane = source })
    panes.back(source)
    panes.present(FakeView("current"), { pane = source })
    test.equal(panes.history_length(source), 2)

    test.equal(panes.move_and_merge(source, destination), destination)

    local found = false
    for _, view in ipairs(panes.views(destination)) do
      if view == protected then found = true break end
    end
    test.ok(found)
    test.equal(panes.pane_for_view(protected), destination)
    test.ok(panes.validate())
  end)

  test.it("focuses Panes by current number", function()
    panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    test.equal(panes.focus_index(2), two)
    test.equal(panes.active(), two)
  end)

  test.it("renumbers after closing and permits zero Panes", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    local three = panes.create { factory = factory("three") }
    test.ok(panes.close(two))
    test.same(names(panes.ordered()), { "one", "three" })
    test.equal(panes.number(three), 2)
    test.ok(panes.close(one))
    test.ok(panes.close(three))
    test.equal(panes.count(), 0)
    test.is_nil(panes.active())
    test.is_nil(panes.visible_group())
  end)

  test.it("stays in the same Pane Group after closing its last ordered Pane", function()
    local one = panes.create { factory = factory("one") }
    local group = one.group
    local two = panes.split(one, "right", { factory = factory("two") })
    local three = panes.create { factory = factory("three") }
    panes.focus(two)

    test.ok(panes.close(two))

    test.equal(panes.active(), one)
    test.equal(panes.visible_group(), group)
    test.not_equal(panes.visible_group(), three.group)
  end)

  test.it("switches Pane Groups after closing a group sole Pane", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    panes.focus(one)

    test.ok(panes.close(one))

    test.equal(panes.active(), two)
    test.equal(panes.visible_group(), two.group)
  end)

  test.it("rejects duplicate Pane membership", function()
    local one = panes.create { factory = factory("one") }
    local group = one.group
    group.root = {
      kind = "split", axis = "x", ratio = 0.5,
      a = { kind = "pane", pane = one },
      b = { kind = "pane", pane = one },
    }
    test.not_ok(pcall(panes.validate))
  end)

  test.it("removes focus-target ownership when its View closes", function()
    local pane = panes.create { factory = factory("one") }
    local child = FakeView("child")
    panes.register_focus_target(pane.current_view, child)
    test.equal(panes.pane_for_view(child), pane)
    panes.close(pane, { force = true })
    test.is_nil(panes.pane_for_view(child))
    test.ok(panes.validate())
  end)

  test.it("clears a closed final Pane View from global focus", function()
    local pane = panes.create { factory = factory("one") }
    core.active_view = pane.current_view
    local clear_active_view = core.clear_active_view
    core.clear_active_view = function(view)
      if core.active_view == view then core.active_view = nil; return true end
      return false
    end
    panes.close(pane, { force = true })
    core.clear_active_view = clear_active_view
    test.is_nil(core.active_view)
  end)

  test.it("closes the Current View and restores the previous View", function()
    local pane = panes.create { factory = factory("one") }
    local first = pane.current_view
    local second = FakeView("two")
    function second:on_close() self.closed = (self.closed or 0) + 1 end
    panes.present(second, { pane = pane })

    test.ok(panes.close_view(pane, { force = true }))
    test.equal(pane.current_view, first)
    test.equal(panes.history_length(pane), 1)
    test.equal(second.closed, 1)
  end)
end)
