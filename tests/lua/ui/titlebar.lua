local core = require "core"
local config = require "core.config"
local layout = require "core.pane_layout"
local panes = require "core.panes"
local pane_report = require "core.pane_report"
local recent_panes = require "core.recent_panes"
local scale = require "plugins.scale"
local style = require "core.style"
local TitleBar = require "core.titlebar"
local View = require "core.view"
local view_icons = require "core.view_icons"
local renwindow = require "renwindow"
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

-- Focuses `pane` while the Project has keyboard focus, and lets the Project observe it as a frame does.
local function focus(pane)
  panes.focus(pane)
  local has_focus = system.window_has_focus
  system.window_has_focus = function() return true end
  pane_report.publish()
  system.window_has_focus = has_focus
end

-- Tab lane scrolling eases over time, so let it finish before checking positions.
local function settle(title)
  local deadline = system.get_time() + 2
  repeat
    title:update()
    if math.abs(title.tab_scroll - title.tab_scroll_target) < 1e-8 then return end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.equal(title.tab_scroll, title.tab_scroll_target, "the Tab lane must finish scrolling")
end

test.describe("Global title bar Pane entries", function()
  local set_active_view, projects, window, window_mode, set_window_mode,
    set_window_hit_test, quit, zoom, set_clip_rect, transitions, scroll_transition, fps,
    configured_fps, live_resize, animation_rate

  test.before_each(function()
    panes.reset_for_tests()
    recent_panes.reset_for_tests()
    set_active_view = core.set_active_view
    projects = core.projects
    window = core.window
    window_mode = core.window_mode
    zoom = scale.get()
    set_window_mode = system.set_window_mode
    set_window_hit_test = system.set_window_hit_test
    quit = core.quit
    set_clip_rect = renderer.set_clip_rect
    renderer.set_clip_rect = function() end
    transitions, scroll_transition, fps = config.transitions, config.disabled_transitions.scroll, core.fps
    config.transitions, config.disabled_transitions.scroll, core.fps = true, false, 60
    configured_fps, live_resize, animation_rate = config.fps, core.in_live_resize_frame, config.animation_rate
    config.fps, core.in_live_resize_frame, config.animation_rate = 60, false, 1
    core.set_active_view = function(view) core.active_view = view end
  end)

  test.after_each(function()
    panes.reset_for_tests()
    recent_panes.reset_for_tests()
    core.set_active_view = set_active_view
    core.projects = projects
    core.window = window
    core.window_mode = window_mode
    scale.set(zoom)
    system.set_window_mode = set_window_mode
    system.set_window_hit_test = set_window_hit_test
    core.quit = quit
    renderer.set_clip_rect = set_clip_rect
    config.transitions, config.disabled_transitions.scroll, core.fps = transitions, scroll_transition, fps
    config.fps, core.in_live_resize_frame, config.animation_rate = configured_fps, live_resize, animation_rate
  end)

  test.it("keeps Tab order while numbering pending Panes FIFO", function()
    local one = panes.create { factory = factory("alpha.lua") }
    local two = panes.split(one, "right", { factory = factory("beta.lua") })
    local three = panes.create { factory = factory("settings") }
    for index, pane in ipairs {three, one} do
      pane.current_view.terminal_view = true
      pane.current_view.session_id = "title-number-" .. index
      pane.current_view.state = "running"
      pane.current_view.bell_at = os.time() - 3 + index
    end
    focus(three)
    focus(one)
    focus(two)
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local entries = title:get_pane_entries()
    test.equal(#entries, 3)
    test.equal(entries[1].label, "2 alpha.lua")
    test.equal(entries[2].label, "beta.lua")
    test.equal(entries[3].label, "1 settings")
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

  test.it("does not paint inactive Tabs specially", function()
    local one = panes.create { factory = factory("one") }
    panes.split(one, "right", { factory = factory("two") })
    panes.create { factory = factory("three") }
    panes.focus(one)
    local title = TitleBar()
    title.size.x = 900
    local old_window = core.window
    local old_get_controls = system.get_window_controls
    local old_get_content_x = system.get_window_content_x
    local test_clip = renderer.set_clip_rect
    local old_root_clip = core.clip_rect_stack[1]
    local render_window = renwindow.create("inactive-titlebar-tabs", 900, 80)
    core.window = nil
    system.get_window_controls = function() return nil end
    system.get_window_content_x = function() return 0 end
    renderer.set_clip_rect = set_clip_rect
    core.clip_rect_stack[1] = { 0, 0, 900, 80 }
    local ok, err = pcall(function()
      title:update()
      local entries = title:get_pane_entries()
      test.ok(entries[1].active)
      test.not_ok(entries[2].active)

      renderer.begin_frame(render_window)
      renderer.set_clip_rect(0, 0, 900, 80)
      local draw_ok, draw_err = pcall(title.draw, title)
      renderer.end_frame()
      test.ok(draw_ok, draw_err)

      local function tab_pixel(entry)
        local x = math.floor(entry.x + entry.w / 2)
        local y = math.floor(entry.y + entry.h - 6)
        return renwindow.get_color(render_window, x, y)
      end
      local active = tab_pixel(entries[1])
      local inactive = tab_pixel(entries[2])
      local blank_x = math.floor(entries[#entries].x + entries[#entries].w + 8)
      local blank = renwindow.get_color(render_window, blank_x, math.floor(entries[1].h - 6))
      test.not_equal(active, blank, "the active Tab has no visible background")
      test.same(inactive, blank, "an inactive Tab has a special background")
      local group_mark = renwindow.get_color(render_window,
        math.floor(entries[1].x + entries[1].w / 2), math.floor(entries[1].h - 1))
      local blank_group_mark = renwindow.get_color(render_window, blank_x, math.floor(entries[1].h - 1))
      test.not_equal(group_mark, blank_group_mark, "the visible Pane Group has no indicator")
    end)
    renderer.set_clip_rect = test_clip
    core.clip_rect_stack[1] = old_root_clip
    core.window = old_window
    system.get_window_controls = old_get_controls
    system.get_window_content_x = old_get_content_x
    renwindow.close(render_window)
    test.ok(ok, err)
  end)

  test.it("renders pending Pane numbers and names with their requested fonts", function()
    local one = panes.create { factory = factory("one") }
    one.current_view.terminal_view = true
    one.current_view.session_id = "number-font-test"
    one.current_view.state = "running"
    one.current_view.bell_at = os.time()
    focus(one)
    focus(panes.create { factory = factory("two") })
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
    test.equal(name.font, style.view_text_font)
    test.equal(number.color, style.titlebar_pane_number)
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

  test.it("closes the right-clicked Tab's Pane from its Context Menu", function()
    local context_menu = require "core.context_menu"
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local entry = title:get_pane_entries()[1]
    test.ok(title:on_mouse_pressed("right", entry.x + 2, entry.y + 2, 1))
    test.equal(panes.active(), one)
    test.ok(context_menu.choose("Close"))
    test.same(panes.ordered(), { two })
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

  test.it("scrolls hidden Tabs when a Pane drag reaches the lane edge", function()
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

    settle(title)
    test.ok(title.entries[1] == nil or title.entries[1].x < source.x)
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

  test.it("smoothly scrolls the Tab lane with fractional wheel input", function()
    local first
    for i = 1, 6 do
      local pane = panes.create { factory = factory("view-" .. i) }
      first = first or pane
    end
    panes.focus(first)
    local title = TitleBar()
    title.size.x = 420
    title:update()
    local get_time = system.get_time
    local animation_type = config.scroll_animation_type
    local duration = config.scroll_transition_duration
    local now = get_time()
    config.scroll_animation_type = "cubic"
    config.scroll_transition_duration = 1
    system.get_time = function() return now end
    local ok, err = pcall(function()
      local before = title.entries[1].x
      test.ok(title:on_mouse_wheel(-0.25, 0))
      test.equal(title.entries[1].x, before)

      -- Advance the animation clock in fixed steps instead of waiting for real time.
      title:update()
      now = now + 0.5
      title:update()
      local moving = title.entries[1].x
      test.ok(moving < before)

      now = now + 0.5
      title:update()
      test.ok(title.entries[1].x < moving)
      test.ok(title.entries[1].x + title.entries[1].w > before)
      test.is_nil(title:entry_at(before - 1, title.position.y + 2))
    end)
    system.get_time = get_time
    config.scroll_animation_type = animation_type
    config.scroll_transition_duration = duration
    test.ok(ok, err)
  end)

  test.it("keeps an overflowing edge Tab visible and clickable", function()
    local first = panes.create { factory = factory("first") }
    panes.create { factory = factory("second") }
    panes.create { factory = factory("third") }
    panes.focus(first)
    local title = TitleBar()
    title.size.x = 1200
    title:update()
    local second = title.entries[2]
    title.size.x = title.size.x - (title.caption_rects[1].x - second.x - second.w / 2)
    title:update()
    local edge = title.caption_rects[1].x
    test.not_nil(title.entries[2])
    test.ok(title.entries[2].x < edge)
    test.ok(title.entries[2].x + title.entries[2].w > edge)
    test.equal(title:entry_at(edge - 1, title.position.y + 2), 2)
    test.is_nil(title:entry_at(edge, title.position.y + 2))
  end)

  test.it("clamps horizontal scrolling and reveals the focused Tab", function()
    local first, last
    for i = 1, 6 do
      last = panes.create { factory = factory("view-" .. i) }
      first = first or last
    end
    panes.focus(first)
    local title = TitleBar()
    title.size.x = 600
    title:update()
    test.not_ok(title:on_mouse_wheel(0, 0))
    test.ok(title:on_mouse_wheel(0, -1000))
    settle(title)
    local right = title.caption_rects[1].x
    test.equal(title.entries[6].x + title.entries[6].w, right)
    panes.focus(last)
    title:update()
    panes.focus(first)
    settle(title)
    test.equal(title.entries[1].x, title.project_rect.x + title.project_rect.w)
    title:on_mouse_wheel(0, -1000)
    settle(title)
    title.size.x = 3000
    title:update()
    test.equal(title.entries[1].x, title.project_rect.x + title.project_rect.w)
    test.not_ok(title:on_mouse_wheel(-1, 0))
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

  test.it("draws a complete short Project name at fractional Zoom", function()
    core.projects = { { path = "C:\\projects\\glp4" } }
    panes.create { factory = factory("tree") }
    scale.set(1.436352296215)
    local title = TitleBar()
    title.size.x = 900
    title:update()
    local old_draw_rect = renderer.draw_rect
    local old_draw_rounded_rect = renderer.draw_rounded_rect
    local old_draw_text = renderer.draw_text
    local project_name
    renderer.draw_rect = function() end
    renderer.draw_rounded_rect = function() end
    renderer.draw_text = function(font, text, x)
      project_name = project_name or text
      return x + font:get_width(text)
    end
    local ok, err = pcall(title.draw, title)
    renderer.draw_rect = old_draw_rect
    renderer.draw_rounded_rect = old_draw_rounded_rect
    renderer.draw_text = old_draw_text

    test.ok(ok, err)
    test.equal(project_name, "glp4")
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
