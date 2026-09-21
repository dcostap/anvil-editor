local config = require "core.config"
local test = require "core.test"
local View = require "core.view"

local ScrollView = View:extend()

function ScrollView:new()
  ScrollView.super.new(self)
  self.scrollable = true
  self.size.x, self.size.y = 100, 100
  self.content_width, self.content_height = 1000, 1000
end

function ScrollView:get_scrollable_size()
  return self.content_height
end

function ScrollView:get_h_scrollable_size()
  return self.content_width
end

test.describe("Viewport scroll transitions", function()
  test.before_each(function(context)
    context.get_time = system.get_time
    context.transitions = config.transitions
    context.scroll_disabled = config.disabled_transitions.scroll
    context.scroll_animation_type = config.scroll_animation_type
    context.scroll_transition_duration = config.scroll_transition_duration
    context.config_fps = config.fps
    context.fps = core.fps
    context.in_live_resize_frame = core.in_live_resize_frame
    context.now = 10
    system.get_time = function() return context.now end
    config.transitions = true
    config.disabled_transitions.scroll = false
    config.scroll_animation_type = "cubic"
    config.scroll_transition_duration = 0.125
    config.fps = 60
    core.fps = 60
    core.in_live_resize_frame = false
  end)

  test.after_each(function(context)
    system.get_time = context.get_time
    config.transitions = context.transitions
    config.disabled_transitions.scroll = context.scroll_disabled
    config.scroll_animation_type = context.scroll_animation_type
    config.scroll_transition_duration = context.scroll_transition_duration
    config.fps = context.config_fps
    core.fps = context.fps
    core.in_live_resize_frame = context.in_live_resize_frame
  end)

  test.it("moves each scrollable View with a fixed cubic transition", function(context)
    local view = ScrollView()
    view.scroll.to.y = 100

    view:update()
    test.equal(view.scroll.y, 0)

    context.now = context.now + config.scroll_transition_duration / 4
    view:update()
    test.ok(view.scroll.y > 0)
    test.ok(view.scroll.y < 25)

    context.now = context.now + config.scroll_transition_duration * 3 / 4
    view:update()
    test.equal(view.scroll.y, 100)
  end)

  test.it("restarts a changed target without moving the visible position", function(context)
    local view = ScrollView()
    view.scroll.to.y = 100
    view:update()

    context.now = context.now + config.scroll_transition_duration / 2
    view:update()
    local visible = view.scroll.y
    test.ok(visible > 0 and visible < 100)

    view.scroll.to.y = 200
    view:update()
    test.equal(view.scroll.y, visible)

    context.now = context.now + config.scroll_transition_duration
    view:update()
    test.equal(view.scroll.y, 200)
  end)

  test.it("preserves forward motion when the target moves forward", function(context)
    local moving = ScrollView()
    moving.scroll.to.y = 100
    moving:update()

    context.now = context.now + config.scroll_transition_duration * 0.4
    moving:update()
    local retarget_position = moving.scroll.y
    moving.scroll.to.y = 200
    moving:update()
    test.equal(moving.scroll.y, retarget_position)

    local fresh = ScrollView()
    fresh.scroll.y = retarget_position
    fresh.scroll.to.y = 200
    fresh:update()

    context.now = context.now + config.scroll_transition_duration * 0.08
    moving:update()
    fresh:update()

    test.ok(moving.scroll.y > fresh.scroll.y)
  end)

  test.it("drops forward velocity when the target reverses", function(context)
    local view = ScrollView()
    view.scroll.to.y = 100
    view:update()

    context.now = context.now + config.scroll_transition_duration * 0.4
    view:update()
    local retarget_position = view.scroll.y
    view.scroll.to.y = 0
    view:update()

    context.now = context.now + config.scroll_transition_duration * 0.08
    view:update()
    test.ok(view.scroll.y < retarget_position)
    test.ok(view.scroll.y >= 0)
  end)

  test.it("keeps touch scrolling under direct control", function()
    local view = ScrollView()

    view:on_touch_moved(50, 50, -20, -30, 1)

    test.equal(view.scroll.x, 20)
    test.equal(view.scroll.to.x, 20)
    test.equal(view.scroll.y, 30)
    test.equal(view.scroll.to.y, 30)
  end)

  test.it("applies content-size corrections without a transition", function()
    local view = ScrollView()
    view.scroll.x, view.scroll.to.x = 900, 900
    view.scroll.y, view.scroll.to.y = 900, 900
    view.content_width, view.content_height = 200, 200

    view:update()

    test.equal(view.scroll.x, 100)
    test.equal(view.scroll.to.x, 100)
    test.equal(view.scroll.y, 100)
    test.equal(view.scroll.to.y, 100)
  end)
end)
