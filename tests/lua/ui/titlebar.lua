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
end)
