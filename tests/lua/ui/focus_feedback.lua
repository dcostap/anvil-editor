local test = require "core.test"
local style = require "core.style"

-- Seam: focus transitions and the feedback renderer's public bounds and lifetime.
test.describe("Focus feedback", function()
  local Feedback, old_draw, old_color, rectangles
  test.before_each(function()
    Feedback = require "core.focus_feedback"
    rectangles = {}
    old_draw, old_color = renderer.draw_rect, style.focus_feedback
    style.focus_feedback = {13, 57, 91, 120}
    renderer.draw_rect = function(x, y, w, h, color)
      rectangles[#rectangles + 1] = {x=x,y=y,w=w,h=h,alpha=color[4]}
    end
  end)
  test.after_each(function()
    if old_draw then renderer.draw_rect, style.focus_feedback = old_draw, old_color end
  end)

  test.it("marks only the new focus region and stops after the transition", function()
    local feedback = Feedback()
    local first, second = {}, {}
    feedback:update(first, 0)
    test.ok(feedback:draw(20, 40, 200, 100, 0))
    test.ok(#rectangles > 0)
    for _, rect in ipairs(rectangles) do
      test.ok(rect.x >= 20 and rect.y >= 40)
      test.ok(rect.x + rect.w <= 220 and rect.y + rect.h <= 140)
    end
    rectangles = {}
    feedback:update(first, 10)
    test.not_ok(feedback:draw(20, 40, 200, 100, 10))
    test.same(rectangles, {})
    feedback:update(second, 11)
    test.ok(feedback:draw(300, 40, 200, 100, 11))
    for _, rect in ipairs(rectangles) do test.ok(rect.x >= 300) end
  end)

  test.it("clears feedback on focus loss and marks focus return", function()
    local feedback, region = Feedback(), {}
    feedback:update(region, 0)
    feedback:update(nil, 0)
    test.not_ok(feedback:draw(0, 0, 200, 100, 0))
    test.same(rectangles, {})
    feedback:update(region, 1)
    test.ok(feedback:draw(0, 0, 200, 100, 1))
  end)

  test.it("uses the current region bounds without restarting for a resize", function()
    local feedback, region = Feedback(), {}
    feedback:update(region, 0)
    test.ok(feedback:draw(0, 0, 100, 50, 0))
    rectangles = {}
    feedback:update(region, 0)
    test.ok(feedback:draw(50, 60, 80, 40, 0))
    for _, rect in ipairs(rectangles) do
      test.ok(rect.x >= 50 and rect.y >= 60)
      test.ok(rect.x + rect.w <= 130 and rect.y + rect.h <= 100)
    end
    test.not_ok(feedback:draw(0, 0, 100, 50, 10))
  end)
end)

-- Seam: actual Pane focus and Sidebar focus events, through their normal draw methods.
test.describe("Focus feedback surfaces", function()
  local core = require "core"
  local panes = require "core.panes"
  local View = require "core.view"
  local RootPanel = require "core.rootpanel"
  local SidebarView = require "core.sidebar_view"
  local saved, rectangles, clock, focused
  test.before_each(function()
    saved = {root=core.root_panel,view=core.active_view,window=core.active_window,
      nag=core.nag_view,last=core.last_active_view,next=core.next_active_view,
      time=system.get_time,focus=system.window_has_focus,draw=renderer.draw_rect,color=style.focus_feedback}
    clock, focused, rectangles = 100, true, {}
    system.get_time = function() return clock end
    system.window_has_focus = function() return focused end
    style.focus_feedback = {13, 57, 91, 120}
    renderer.draw_rect = function(x, y, w, h, color)
      if color[1] == 13 and color[2] == 57 and color[3] == 91 then
        rectangles[#rectangles + 1] = {x=x,y=y,w=w,h=h}
      end
      return saved.draw(x, y, w, h, color)
    end
    panes.reset_for_tests()
    core.root_panel = RootPanel()
    core.nag_view = require("core.nagview")()
    core.root_panel.size.x, core.root_panel.size.y = 640, 400
    core.active_window = core.window
  end)
  test.after_each(function()
    panes.reset_for_tests()
    core.root_panel, core.active_view, core.active_window = saved.root, saved.view, saved.window
    core.nag_view, core.last_active_view, core.next_active_view = saved.nag, saved.last, saved.next
    system.get_time, system.window_has_focus = saved.time, saved.focus
    renderer.draw_rect, style.focus_feedback = saved.draw, saved.color
  end)
  local function draw(fn)
    rectangles = {}
    renderer.begin_frame(core.window)
    local ok, err = pcall(fn)
    renderer.end_frame()
    if not ok then error(err, 0) end
  end
  local function inside(view)
    test.ok(#rectangles > 0, "Focus did not produce visible feedback")
    for _, rect in ipairs(rectangles) do
      test.ok(rect.x >= view.position.x and rect.y >= view.position.y)
      test.ok(rect.x + rect.w <= view.position.x + view.size.x)
      test.ok(rect.y + rect.h <= view.position.y + view.size.y)
    end
  end

  test.it("follows Pane and nested surface focus and stops when the Window loses focus", function()
    local left = panes.create {factory=function() return View() end}
    local right = panes.split(left, "right", {factory=function() return View() end})
    local root = core.root_panel
    root:update()
    draw(function() root:draw() end)
    inside(right.current_view)
    clock = clock + 10
    panes.focus(left)
    root:update()
    draw(function() root:draw() end)
    inside(left.current_view)
    local child = View()
    child.position = {x=left.current_view.position.x + 10,y=left.current_view.position.y + 10}
    child.size = {x=100,y=80}
    panes.register_focus_target(left.current_view, child)
    core.set_active_view(child)
    root:update()
    draw(function() root:draw() end)
    inside(child)
    focused = false
    root:update()
    draw(function() root:draw() end)
    test.same(rectangles, {})
  end)

  test.it("marks Sidebar entry but does not restart while browsing its rows", function()
    local sidebar = SidebarView(function() end)
    sidebar:set_model({{id=1,row_id=1,path="C:/Project",state="ready",panes={{id="a",name="main.lua"}}}})
    sidebar:on_focus(true)
    draw(function() sidebar:draw(240, 400) end)
    test.ok(#rectangles > 0)
    clock = clock + 10
    sidebar:on_key_pressed("down")
    draw(function() sidebar:draw(240, 400) end)
    test.same(rectangles, {})
    test.is_nil(sidebar:animation_delay(clock))
    sidebar:on_focus(false)
    sidebar:on_focus(true)
    draw(function() sidebar:draw(240, 400) end)
    test.ok(#rectangles > 0)
  end)

  test.it("does not highlight the content area when a confirmation takes focus", function()
    local pane = panes.create {factory=function() return View() end}
    local root = core.root_panel
    root:update()
    clock = clock + 10
    core.nag_view:show("Open Folder", "Open this folder?", {
      {text="Cancel", default_no=true},
    })
    root:update()
    test.equal(core.active_view, core.nag_view)
    draw(function() root:draw() end)
    test.same(rectangles, {}, "Confirmation must not produce content-area focus feedback")

    core.nag_view:next()
    root:update()
    test.equal(core.active_view, pane.current_view)
    draw(function() root:draw() end)
    inside(pane.current_view)
  end)
end)
