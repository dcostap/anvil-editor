local core = require "core"
local layout = require "core.pane_layout"
local panes = require "core.panes"
local style = require "core.style"
local TitleBar = require "core.titlebar"
local View = require "core.view"
local view_icons = require "core.view_icons"
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
  local set_active_view, projects, window, window_mode, set_window_mode,
    set_window_hit_test, quit

  test.before_each(function()
    panes.reset_for_tests()
    set_active_view = core.set_active_view
    projects = core.projects
    window = core.window
    window_mode = core.window_mode
    set_window_mode = system.set_window_mode
    set_window_hit_test = system.set_window_hit_test
    quit = core.quit
    core.set_active_view = function(view) core.active_view = view end
  end)

  test.after_each(function()
    panes.reset_for_tests()
    core.set_active_view = set_active_view
    core.projects = projects
    core.window = window
    core.window_mode = window_mode
    system.set_window_mode = set_window_mode
    system.set_window_hit_test = set_window_hit_test
    core.quit = quit
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

  test.it("clusters Tabs by Pane Group", function()
    local one = panes.create { factory = factory("one") }
    panes.split(one, "right", { factory = factory("two") })
    panes.create { factory = factory("three") }
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local entries = title:get_pane_entries()

    test.equal(entries[1].x + entries[1].w, entries[2].x)
    test.ok(entries[2].x + entries[2].w < entries[3].x)
  end)

  test.it("draws the visible Pane Group across its inactive Tabs", function()
    local one = panes.create { factory = factory("one") }
    panes.split(one, "right", { factory = factory("two") })
    panes.create { factory = factory("three") }
    panes.focus(one)
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local old_draw_rect = renderer.draw_rect
    local old_draw_rounded_rect = renderer.draw_rounded_rect
    local old_draw_text = renderer.draw_text
    local visible_tile = false
    local group_indicator = false
    renderer.draw_rect = function(_, _, _, _, color)
      if color == style.titlebar_group_indicator then group_indicator = true end
    end
    renderer.draw_rounded_rect = function(_, _, _, _, _, color)
      if color == style.titlebar_tab_visible then visible_tile = true end
    end
    renderer.draw_text = function() end
    local ok, err = pcall(title.draw, title)
    renderer.draw_rect = old_draw_rect
    renderer.draw_rounded_rect = old_draw_rounded_rect
    renderer.draw_text = old_draw_text

    test.ok(ok, err)
    test.not_nil(style.titlebar_tab_visible)
    test.not_nil(style.titlebar_group_indicator)
    test.ok(visible_tile)
    test.ok(group_indicator)
  end)

  test.it("renders Pane numbers and names at one size with their requested fonts", function()
    panes.create { factory = factory("one") }
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local old_draw_rect = renderer.draw_rect
    local old_draw_rounded_rect = renderer.draw_rounded_rect
    local old_draw_text = renderer.draw_text
    local number, name
    renderer.draw_rect = function() end
    renderer.draw_rounded_rect = function() end
    renderer.draw_text = function(font, text, x, y, color)
      if text == "1" then number = { font = font, color = color } end
      if text == "one" then name = { font = font, color = color } end
    end
    local ok, err = pcall(title.draw, title)
    renderer.draw_rect = old_draw_rect
    renderer.draw_rounded_rect = old_draw_rounded_rect
    renderer.draw_text = old_draw_text

    test.ok(ok, err)
    test.not_nil(number)
    test.not_nil(name)
    test.equal(number.font, style.font)
    test.equal(name.font, style.prose_font)
    test.equal(number.font:get_size(), name.font:get_size())
    test.equal(number.color, style.titlebar_pane_number)
  end)

  test.it("draws the Pane number before its View Icon and name", function()
    local pane = panes.create { factory = factory("tree") }
    pane.current_view.view_icon = { font = style.icon_font, glyph = "d" }
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local old_draw_rect = renderer.draw_rect
    local old_draw_rounded_rect = renderer.draw_rounded_rect
    local old_draw_text = renderer.draw_text
    local number_x, icon_x, name_x
    renderer.draw_rect = function() end
    renderer.draw_rounded_rect = function() end
    renderer.draw_text = function(font, text, x)
      if font == style.icon_font and text == "d" then icon_x = x end
      if text == "1" then number_x = x end
      if text == "tree" then name_x = x end
    end
    local ok, err = pcall(title.draw, title)
    renderer.draw_rect = old_draw_rect
    renderer.draw_rounded_rect = old_draw_rounded_rect
    renderer.draw_text = old_draw_text

    test.ok(ok, err)
    test.not_nil(number_x)
    test.not_nil(icon_x)
    test.not_nil(name_x)
    test.ok(number_x < icon_x)
    test.ok(icon_x < name_x)
  end)

  test.it("draws a complete short name when its Tab has room", function()
    local pane = panes.create { factory = factory("newfile.txt") }
    pane.current_view.view_icon = view_icons.file("newfile.txt")
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local old_draw_rect = renderer.draw_rect
    local old_draw_rounded_rect = renderer.draw_rounded_rect
    local old_draw_text = renderer.draw_text
    local drawn_name
    renderer.draw_rect = function() end
    renderer.draw_rounded_rect = function() end
    renderer.draw_text = function(font, text, x)
      if text:match("^newfile") then drawn_name = text end
      return x + font:get_width(text)
    end
    local ok, err = pcall(title.draw, title)
    renderer.draw_rect = old_draw_rect
    renderer.draw_rounded_rect = old_draw_rounded_rect
    renderer.draw_text = old_draw_text

    test.ok(ok, err)
    test.equal(drawn_name, "newfile.txt")
  end)

  test.it("focuses a Pane from its global entry", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local entry = title:get_pane_entries()[1]
    test.ok(title:on_mouse_pressed("left", entry.x + 2, entry.y + 2, 1))
    test.equal(panes.active(), two)
    test.ok(title:on_mouse_released("left", entry.x + 2, entry.y + 2))
    test.equal(panes.active(), one)
  end)

  test.it("uses content-sized Tabs instead of filling the title lane", function()
    panes.create { factory = factory("one") }
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local entry = title:get_pane_entries()[1]
    test.ok(entry.w < title.size.x / 2)
  end)

  test.it("uses the full Tab surface to focus its Pane", function()
    local one = panes.create { factory = factory("one") }
    panes.create { factory = factory("two") }
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local entry = title:get_pane_entries()[1]
    test.ok(title:on_mouse_pressed("left", entry.x + entry.w - 2, entry.y + 2, 1))
    title:on_mouse_released("left", entry.x + entry.w - 2, entry.y + 2)
    test.equal(panes.active(), one)
    test.equal(panes.count(), 2)
  end)

  test.it("drags a Pane to reorder leaves and rebalance the changed axis", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.split(one, "right", { factory = factory("two") })
    one.group.root.ratio = 0.35
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local source = title.entries[2]
    local target = title.entries[1]

    title:on_mouse_pressed("left", source.x + source.w / 2, source.y + 2, 1)
    title:on_mouse_moved(target.x + 2, target.y + 2, -source.w, 0)
    title:on_mouse_released("left", target.x + 2, target.y + 2)

    local ordered = panes.ordered()
    test.equal(ordered[1], two)
    test.equal(ordered[2], one)
    test.equal(one.group.root.ratio, 0.5)
  end)

  test.it("drags a hidden Pane onto a visible work-area edge", function()
    local source_pane = panes.create { factory = factory("source") }
    local target_pane = panes.create { factory = factory("target") }
    layout.update_rects(target_pane.group.root, { x = 0, y = 50, w = 200, h = 100 })
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local source = title.entries[1]

    title:on_mouse_pressed("left", source.x + source.w / 2, source.y + 2, 1)
    title:on_mouse_moved(195, 100, 100, 50)
    title:on_mouse_released("left", 195, 100)

    test.equal(source_pane.group, target_pane.group)
    local ordered = panes.ordered()
    test.equal(ordered[1], target_pane)
    test.equal(ordered[2], source_pane)
    test.equal(panes.active(), source_pane)
  end)

  test.it("swaps Panes through the work-area center target", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.split(one, "right", { factory = factory("two") })
    layout.update_rects(one.group.root, { x = 0, y = 50, w = 400, h = 100 })
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local source = title.entries[2]

    title:on_mouse_pressed("left", source.x + source.w / 2, source.y + 2, 1)
    title:on_mouse_moved(100, 100, 100 - source.x, 50)
    title:on_mouse_released("left", 100, 100)

    local ordered = panes.ordered()
    test.equal(ordered[1], two)
    test.equal(ordered[2], one)
    test.equal(panes.active(), two)
  end)

  test.it("drags a Pane to a title boundary as a singleton group", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.split(one, "right", { factory = factory("two") })
    local three = panes.create { factory = factory("three") }
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local source = title.entries[2]
    local target = title.entries[3]

    title:on_mouse_pressed("left", source.x + source.w / 2, source.y + 2, 1)
    title:on_mouse_moved(target.x + 2, target.y + 2, target.x - source.x, 0)
    title:on_mouse_released("left", target.x + 2, target.y + 2)

    local ordered = panes.ordered()
    test.equal(ordered[1], one)
    test.equal(ordered[2], two)
    test.equal(ordered[3], three)
    test.equal(#panes.groups, 3)
    test.not_equal(one.group, two.group)
  end)

  test.it("detaches a Pane at the outer Title Bar group boundary", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.split(one, "right", { factory = factory("two") })
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local source = title.entries[1]
    local last = title.entries[2]
    local boundary_x = last.x + last.w + 20

    title:on_mouse_pressed("left", source.x + source.w / 2, source.y + 2, 1)
    title:on_mouse_moved(boundary_x, source.y + 2, boundary_x - source.x, 0)
    title:on_mouse_released("left", boundary_x, source.y + 2)

    test.equal(#panes.groups, 2)
    test.not_equal(one.group, two.group)
    test.equal(panes.ordered()[2], one)
  end)

  test.it("cancels a Pane drag outside valid targets without changing focus", function()
    local source_pane = panes.create { factory = factory("source") }
    local focused = panes.create { factory = factory("focused") }
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local source = title.entries[1]

    title:on_mouse_pressed("left", source.x + source.w / 2, source.y + 2, 1)
    title:on_mouse_moved(-50, -50, -100, -100)
    title:on_mouse_released("left", -50, -50)

    test.not_equal(source_pane.group, focused.group)
    test.equal(panes.active(), focused)
    test.is_nil(title.dragged_pane)
    test.is_nil(title.drag_target)
  end)

  test.it("cancels a captured Pane drag when the window loses focus", function()
    local pane = panes.create { factory = factory("source") }
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local source = title.entries[1]

    title:on_mouse_pressed("left", source.x + 2, source.y + 2, 1)
    title:on_mouse_moved(source.x + 40, source.y + 2, 40, 0)
    title:on_focus_lost()

    test.equal(panes.active(), pane)
    test.is_nil(title.pressed_pane)
    test.is_nil(title.dragged_pane)
  end)

  test.it("pages hidden Tabs when a Pane drag reaches the lane edge", function()
    local first
    for i = 1, 7 do
      local pane = panes.create { factory = factory("long-view-name-" .. i) }
      first = first or pane
    end
    panes.focus(first)
    local title = TitleBar()
    title.size.x = 420
    title:update()
    local source = title.entries[1]
    local lane_right = title.caption_rects[1].x

    title:on_mouse_pressed("left", source.x + 2, source.y + 2, 1)
    title:on_mouse_moved(lane_right - 1, source.y + 2, lane_right - source.x, 0)

    test.ok(title.tab_offset > 1)
    test.equal(title.dragged_pane, first)
    title:on_mouse_released("left", -50, -50)
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

  test.it("keeps a long Project name out of the Tab lane", function()
    core.projects = { { path = "C:/projects/Israel Mallo Martínez - ManualSistemas" } }
    panes.create { factory = factory("notes.md") }
    local title = TitleBar()
    title.size.x = 700
    title:update()
    local old_draw_rect = renderer.draw_rect
    local old_draw_rounded_rect = renderer.draw_rounded_rect
    local old_draw_text = renderer.draw_text
    local drawn = {}
    renderer.draw_rect = function() end
    renderer.draw_rounded_rect = function() end
    renderer.draw_text = function(font, text, x, y, color)
      drawn[#drawn + 1] = { font = font, text = text, x = x, y = y, color = color }
      return x + font:get_width(text)
    end
    local ok, err = pcall(title.draw, title)
    renderer.draw_rect = old_draw_rect
    renderer.draw_rounded_rect = old_draw_rounded_rect
    renderer.draw_text = old_draw_text
    test.ok(ok, err)
    local project = drawn[1]
    test.not_nil(project)
    test.ok(project.x + project.font:get_width(project.text)
      <= title.project_rect.x + title.project_rect.w)
  end)

  test.it("runs a caption action only after release over its pressed button", function()
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local maximize = title.caption_rects[2]
    local calls = {}
    core.window = {}
    core.window_mode = "normal"
    system.set_window_mode = function(_, mode) calls[#calls + 1] = mode end

    test.ok(title:on_mouse_pressed("left", maximize.x + 2, maximize.y + 2, 1))
    test.equal(#calls, 0)
    title:on_mouse_released("left", maximize.x + 2, maximize.y + 2)
    test.same(calls, { "maximized" })
  end)

  test.it("cancels a caption action when release leaves its pressed button", function()
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local minimize = title.caption_rects[1]
    local calls = 0
    core.window = {}
    system.set_window_mode = function() calls = calls + 1 end

    title:on_mouse_pressed("left", minimize.x + 2, minimize.y + 2, 1)
    title:on_mouse_moved(minimize.x - 20, minimize.y + 2)
    title:on_mouse_released("left", minimize.x - 20, minimize.y + 2)

    test.equal(calls, 0)
  end)

  test.it("removes custom hit testing when the integrated title bar is disabled", function()
    local title = TitleBar()
    local argument_count
    core.window = {}
    system.set_window_hit_test = function(...) argument_count = select("#", ...) end

    title:configure_hit_test(false)

    test.equal(argument_count, 1)
  end)
end)
