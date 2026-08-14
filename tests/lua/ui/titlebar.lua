local core = require "core"
local panes = require "core.panes"
local TitleBar = require "core.titlebar"
local View = require "core.view"
local test = require "core.test"

local NamedView = View:extend()
function NamedView:new(name)
  NamedView.super.new(self)
  self.name = name
end
function NamedView:get_name() return self.name end

local function factory(name)
  return function() return NamedView(name) end
end

test.describe("Global title bar Pane entries", function()
  local set_active_view

  test.before_each(function()
    panes.reset_for_tests()
    set_active_view = core.set_active_view
    core.set_active_view = function(view) core.active_view = view end
  end)

  test.after_each(function()
    panes.reset_for_tests()
    core.set_active_view = set_active_view
  end)

  test.it("shows all Panes in current numeric order", function()
    local one = panes.create { factory = factory("alpha.lua") }
    panes.split(one, "right", { factory = factory("beta.lua") })
    panes.create { factory = factory("settings") }
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local entries = title:get_pane_entries()
    test.equal(#entries, 3)
    test.equal(entries[1].label, "1 alpha.lua")
    test.equal(entries[2].label, "2 beta.lua")
    test.equal(entries[3].label, "3 settings")
  end)

  test.it("marks the active Pane and its visible group", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.split(one, "right", { factory = factory("two") })
    panes.focus(one)
    local entries = TitleBar():get_pane_entries()
    test.ok(entries[1].active)
    test.ok(entries[1].visible)
    test.not_ok(entries[2].active)
    test.ok(entries[2].visible)
  end)

  test.it("focuses a Pane from its global entry", function()
    panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local entry = title:get_pane_entries()[1]
    test.ok(title:on_mouse_pressed("left", entry.x + 2, entry.y + 2, 1))
    test.not_equal(panes.active(), two)
    test.equal(panes.active().current_view:get_name(), "one")
  end)

  test.it("marks Pane Group boundaries and closes a Tab with middle-click", function()
    local one = panes.create { factory = factory("one") }
    panes.split(one, "right", { factory = factory("two") })
    panes.create { factory = factory("three") }
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local entries = title:get_pane_entries()
    test.ok(entries[1].group_start)
    test.not_ok(entries[2].group_start)
    test.ok(entries[3].group_start)
    test.ok(title:on_mouse_pressed("middle", entries[2].x + 2, entries[2].y + 2, 1))
    test.equal(panes.count(), 2)
  end)

  test.it("pages the global Tab lane with the mouse wheel", function()
    local first
    for i = 1, 6 do
      local pane = panes.create { factory = factory("view-" .. i) }
      first = first or pane
    end
    panes.focus(first)
    local title = TitleBar()
    title.size.x = 420
    title:update()
    local before = title.tab_offset
    test.ok(title:on_mouse_wheel(-1, 0))
    test.ok(title.tab_offset > before)
  end)
end)
