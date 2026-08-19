local core = require "core"
local common = require "core.common"
local panes = require "core.panes"
local pane_layout = require "core.pane_layout"
local RootPanel = require "core.rootpanel"
local View = require "core.view"
local test = require "core.test"
local autocomplete = require "plugins.autocomplete"
local command = require "core.command"
local Widget = require "widget"

local FakeView = View:extend()

function FakeView:new(name, height)
  FakeView.super.new(self)
  self.name = name
  self.height = height
  self.updates = 0
  self.draws = 0
  self.presses = 0
  self.releases = 0
  self.moves = 0
  self.leaves = 0
  self.drops = 0
  self.focus_losses = 0
  self.keys = 0
end

function FakeView:get_name() return self.name end
function FakeView:update()
  self.updates = self.updates + 1
  if self.height then self.size.y = self.height end
end
function FakeView:draw() self.draws = self.draws + 1 end
function FakeView:on_mouse_pressed()
  self.presses = self.presses + 1
  return true
end
function FakeView:on_mouse_released()
  self.releases = self.releases + 1
  return true
end
function FakeView:on_mouse_moved()
  self.moves = self.moves + 1
  return true
end
function FakeView:on_mouse_left()
  self.leaves = self.leaves + 1
end
function FakeView:scrollbar_overlaps_point()
  return self.scrollbar_hit == true
end
function FakeView:on_file_dropped()
  self.drops = self.drops + 1
  return self.consume_drop == true
end
function FakeView:on_focus_lost()
  self.focus_losses = self.focus_losses + 1
end
function FakeView:on_key_pressed()
  self.keys = self.keys + 1
  return true
end

local function pane_factory(name)
  return function() return FakeView(name) end
end

test.describe("Root Panel Pane presentation", function()
  local saved
  local root

  test.before_each(function()
    autocomplete.close()
    Widget.destroy_floating_widgets()
    if command.is_valid("root:pick-color-cancel") then command.perform("root:pick-color-cancel") end
    panes.reset_for_tests()
    saved = {
      root_panel = core.root_panel,
      title_bar = core.title_bar,
      nag_view = core.nag_view,
      global_prompt_bar = core.global_prompt_bar,
      status_bar = core.status_bar,
      active_view = core.active_view,
      set_active_view = core.set_active_view,
      open_file = core.open_file,
      add_project = core.add_project,
      open_project_in_new_window = core.open_project_in_new_window,
      draw_rect = renderer.draw_rect,
      set_cursor = system.set_cursor,
      cursor_change_req = core.cursor_change_req,
      redraw = core.redraw,
      app_overlay = core.app_overlay,
    }
    core.title_bar = FakeView("title", 10)
    core.nag_view = FakeView("nag", 5)
    core.nag_view.show_height = 5
    core.global_prompt_bar = FakeView("prompt", 7)
    core.status_bar = FakeView("status", 8)
    core.app_overlay = nil
    root = RootPanel()
    root.size.x, root.size.y = 300, 200
    core.root_panel = root
    core.set_active_view = function(view) core.active_view = view end
    renderer.draw_rect = function() end
    core.cursor_change_req = nil
  end)

  test.after_each(function()
    autocomplete.close()
    panes.reset_for_tests()
    renderer.draw_rect = saved.draw_rect
    system.set_cursor = saved.set_cursor
    saved.draw_rect = nil
    saved.set_cursor = nil
    for key, value in pairs(saved) do core[key] = value end
  end)

  test.it("keeps shell Views outside the Pane layout", function()
    local one = panes.create { factory = pane_factory("one") }
    local two = panes.split(one, "right", { factory = pane_factory("two") })
    root:update()

    test.equal(core.title_bar.position.y, 0)
    test.equal(core.nag_view.position.y, 10)
    test.equal(one.position.y, 15)
    test.equal(one.size.y, 170)
    test.equal(two.position.x, 150)
    test.equal(core.global_prompt_bar.position.y, 185)
    test.equal(core.status_bar.position.y, 192)
  end)

  test.it("lays out only the visible Pane Group", function()
    local one = panes.create { factory = pane_factory("one") }
    panes.split(one, "right", { factory = pane_factory("two") })
    local three = panes.create { factory = pane_factory("three") }
    root:update()

    test.same(root:pane_views(), { three.current_view })
    test.equal(three.size.x, 300)
    panes.focus(one)
    root:update()
    test.equal(#root:pane_views(), 2)
  end)

  test.it("renders the shell with zero Panes", function()
    root:update()
    test.same(root:pane_views(), {})
    test.equal(root.content_rect.h, 170)
  end)

  test.it("runs deferred draws queued by another deferred draw", function()
    local sequence = {}
    root:defer_draw(function()
      sequence[#sequence + 1] = "outer"
      root:defer_draw(function() sequence[#sequence + 1] = "nested" end)
    end)

    root:draw()

    test.same(sequence, { "outer", "nested" })
  end)

  test.it("routes pointer events to the hit-tested Pane owner", function()
    local one = panes.create { factory = pane_factory("one") }
    local two = panes.split(one, "right", { factory = pane_factory("two") })
    root:update()
    local one_rect = pane_layout.find(one.group.root, one).rect
    local two_rect = pane_layout.find(two.group.root, two).rect
    root:on_mouse_pressed("left", one_rect.x + one_rect.w / 2, one_rect.y + one_rect.h / 2, 1)
    test.equal(one.current_view.presses, 1)
    test.equal(panes.active(), one)
    root:on_mouse_pressed("left", two_rect.x + two_rect.w / 2, two_rect.y + two_rect.h / 2, 1)
    test.equal(two.current_view.presses, 1)
    test.equal(panes.active(), two)
  end)

  test.it("keeps a pointer drag with the pressed Pane View", function()
    local one = panes.create { factory = pane_factory("one") }
    local two = panes.split(one, "right", { factory = pane_factory("two") })
    root:update()
    local one_rect = pane_layout.find(one.group.root, one).rect
    local two_rect = pane_layout.find(two.group.root, two).rect

    root:on_mouse_pressed("left", one_rect.x + 20, one_rect.y + 20, 1)
    root:on_mouse_moved(two_rect.x + 20, two_rect.y + 20, 10, 0)
    root:on_mouse_released("left", two_rect.x + 20, two_rect.y + 20)

    test.equal(one.current_view.moves, 1)
    test.equal(one.current_view.releases, 1)
    test.equal(two.current_view.releases, 0)
    test.is_nil(root.grab)
  end)

  test.it("clears hover state when the pointer enters another Pane View", function()
    local one = panes.create { factory = pane_factory("one") }
    local two = panes.split(one, "right", { factory = pane_factory("two") })
    root:update()
    local one_rect = pane_layout.find(one.group.root, one).rect
    local two_rect = pane_layout.find(two.group.root, two).rect

    root:on_mouse_moved(one_rect.x + 20, one_rect.y + 20, 0, 0)
    root:on_mouse_moved(two_rect.x + 20, two_rect.y + 20, 10, 0)

    test.equal(one.current_view.leaves, 1)
    test.equal(two.current_view.moves, 1)
  end)

  test.it("clears hover state when another Pane Group replaces the hovered View", function()
    local one = panes.create { factory = pane_factory("one") }
    local two = panes.create { factory = pane_factory("two") }
    panes.focus(one)
    root:update()
    root:on_mouse_moved(one.position.x + 20, one.position.y + 20, 0, 0)

    panes.focus(two)
    root:update()

    test.equal(one.current_view.leaves, 1)
    test.equal(two.current_view.moves, 1)
  end)

  test.it("applies the hovered View cursor to the system pointer", function()
    local pane = panes.create { factory = pane_factory("editor") }
    root:update()
    pane.current_view.cursor = "ibeam"
    local applied
    system.set_cursor = function(cursor) applied = cursor end

    root:on_mouse_moved(
      pane.position.x + 20, pane.position.y + 20, 0, 0
    )
    root:draw()

    test.equal(applied, "ibeam")
    test.is_nil(core.cursor_change_req)
  end)

  test.it("uses the arrow pointer over a Pane scrollbar", function()
    local pane = panes.create { factory = pane_factory("editor") }
    root:update()
    pane.current_view.cursor = "ibeam"
    pane.current_view.scrollbar_hit = true

    root:on_mouse_moved(
      pane.position.x + 20, pane.position.y + 20, 0, 0
    )

    test.equal(core.cursor_change_req, "arrow")
  end)

  test.it("lets a Pane scrollbar own presses near a divider", function()
    local one = panes.create { factory = pane_factory("one") }
    panes.split(one, "right", { factory = pane_factory("two") })
    root:update()
    local rect = one.group.root.rect
    local divider_x = rect.x + rect.w * one.group.root.ratio
    one.current_view.scrollbar_hit = true

    test.ok(root:on_mouse_pressed("left", divider_x - 1, rect.y + 20, 1))
    test.is_nil(root.dragged_divider)
    test.equal(one.current_view.presses, 1)
  end)

  test.it("routes keyboard events through a registered focus target", function()
    local one = panes.create { factory = pane_factory("one") }
    local child = FakeView("child")
    panes.register_focus_target(one.current_view, child)
    core.active_view = child
    root:update()
    test.ok(root:contains_view(child))
    test.ok(root:on_key_pressed("a"))
    test.equal(child.keys, 1)
  end)

  test.it("redraws and notifies the focus target when the window loses focus", function()
    local pane = panes.create { factory = pane_factory("editor") }
    core.active_view = pane.current_view
    core.redraw = false

    root:on_focus_lost()

    test.equal(pane.current_view.focus_losses, 1)
    test.equal(core.redraw, true)
  end)

  test.it("lets the Pane View consume a dropped file before fallback opening", function()
    local pane = panes.create { factory = pane_factory("editor") }
    root:update()
    pane.current_view.consume_drop = true
    local fallback_calls = 0
    core.open_file = function() fallback_calls = fallback_calls + 1 end

    local consumed = root:on_file_dropped(
      "attachment.png", pane.position.x + 20, pane.position.y + 20
    )

    test.equal(consumed, true)
    test.equal(pane.current_view.drops, 1)
    test.equal(fallback_calls, 0)
  end)

  test.it("does not send a shell-area file drop to the active Pane View", function()
    local pane = panes.create { factory = pane_factory("editor") }
    root:update()
    pane.current_view.consume_drop = true
    local fallback_calls = 0
    core.open_file = function() fallback_calls = fallback_calls + 1; return true end

    test.equal(root:on_file_dropped("ordinary.txt", 20, 2), true)
    test.equal(pane.current_view.drops, 0)
    test.equal(fallback_calls, 1)
  end)

  test.it("offers Project actions for a dropped directory", function()
    local fallback_calls = 0
    local added
    local choices, choose
    core.open_file = function() fallback_calls = fallback_calls + 1 end
    core.add_project = function(path) added = path end
    core.nag_view.show = function(_, _, _, options, callback)
      choices, choose = options, callback
    end

    test.equal(root:on_file_dropped(USERDIR, 20, 20), true)
    test.equal(fallback_calls, 0)
    test.not_nil(choices)
    choose(choices[1])
    test.ok(common.path_equals(added, USERDIR))
  end)

  test.it("resizes the hit-tested divider", function()
    local one = panes.create { factory = pane_factory("one") }
    panes.split(one, "right", { factory = pane_factory("two") })
    root:update()
    local rect = one.group.root.rect
    local divider_x = rect.x + rect.w * one.group.root.ratio
    local target_x = rect.x + rect.w * 0.25
    core.active_view = one.current_view
    test.not_nil(pane_layout.divider_at(one.group.root, divider_x, rect.y + 20, 3))
    test.ok(root:on_mouse_pressed("left", divider_x, rect.y + 20, 1))
    test.not_nil(root.dragged_divider)
    root:on_mouse_moved(target_x, rect.y + 20, target_x - divider_x, 0)
    test.ok(one.group.root.ratio < 0.3)
    root:on_mouse_released("left", target_x, rect.y + 20)
    test.is_nil(root.dragged_divider)
  end)
end)
