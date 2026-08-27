local test = require "core.test"
local MouseRouter = require "core.mouse_router"
local View = require "core.view"

local function target(name)
  return {
    name = name,
    cursor = "ibeam",
    events = {},
    on_mouse_moved = function(self, x, y)
      self.events[#self.events + 1] = { "move", x, y }
      return true
    end,
    on_mouse_released = function(self, button, x, y)
      self.events[#self.events + 1] = { "release", button, x, y }
      return true
    end,
    on_mouse_left = function(self)
      self.events[#self.events + 1] = { "left" }
    end,
  }
end

test.describe("Mouse Router", function()
  test.it("keeps pointer input captured until release", function()
    local owner = { cursor = "arrow" }
    local left = target("left")
    local right = target("right")
    local router = MouseRouter(owner, function(_, x)
      return x < 50 and left or right
    end)

    router:move(10, 5, 0, 0)
    router:capture(left)
    router:move(90, 5, 80, 0)

    test.equal(router:hovered_target(), left)
    test.equal(#right.events, 0)

    local handled, released = router:release("left", 90, 5)

    test.equal(handled, true)
    test.equal(released, left)
    test.equal(router:hovered_target(), right)
    test.same(left.events[#left.events - 1], { "release", "left", 90, 5 })
    test.same(left.events[#left.events], { "left" })
    test.same(right.events[1], { "move", 90, 5 })
  end)

  test.it("uses an arrow cursor over a child scrollbar", function()
    local owner = { cursor = "ibeam" }
    local child = target("child")
    child.scrollbar_overlaps_point = function(_, x) return x >= 90 end
    local router = MouseRouter(owner, function() return child end)

    router:move(95, 5, 0, 0)

    test.equal(owner.cursor, "arrow")
  end)

  test.it("synchronizes a replacement child before routing wheel input", function()
    local owner = { cursor = "arrow" }
    local old = target("old")
    local replacement = target("replacement")
    local current = old
    local router = MouseRouter(owner, function() return current end)
    router:move(25, 15, 0, 0)

    current = replacement
    test.equal(router:wheel_target(), replacement)

    test.same(old.events[#old.events], { "left" })
    test.same(replacement.events[1], { "move", 25, 15 })
  end)

  test.it("lets a child scrollbar claim a press before child content", function()
    local owner = { cursor = "arrow" }
    local child = View()
    child.scrollable = true
    child.position.x, child.position.y = 0, 0
    child.size.x, child.size.y = 100, 100
    child.get_scrollable_size = function() return 300 end
    child:update()
    local router = MouseRouter(owner, function() return child end)
    local x, y, width, height = child.v_scrollbar:get_thumb_rect()

    local claimed, handled = router:press_scrollbar(
      router:press_target(x + width / 2, y + height / 2),
      "left", x + width / 2, y + height / 2, 1
    )

    test.equal(claimed, true)
    test.equal(handled, true)
    test.equal(router:captured_target(), child)
    test.equal(child.v_scrollbar.dragging, true)
  end)
end)
