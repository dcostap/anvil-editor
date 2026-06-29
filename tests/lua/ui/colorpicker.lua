local test = require "core.test"
local style = require "core.style"
local Widget = require "widget"
local ColorPicker = require "widget.colorpicker"

test.describe("color picker widget", function()
  local function bar_center(picker, index)
    local x = picker.selector.x + picker.selector.w * 0.5
    local y = picker.selector.y
      + style.padding.y * index
      + picker.selector.h * index
      + picker.selector.h * 0.5
    return x, y
  end

  local function new_picker()
    local parent = Widget(nil)
    parent:set_size(300, 160)
    parent:show()

    local picker = ColorPicker(parent, {0, 255, 255, 255})
    picker:set_position(0, 0)
    picker:set_size(260, 120)
    picker.selector.x = 10
    picker.selector.y = 10
    picker.selector.w = 100
    picker.selector.h = 10
    return picker
  end

  test.it("alpha bar mouse hitbox does not overlap brightness bar", function()
    local picker = new_picker()
    local x = picker.selector.x + picker.selector.w * 0.5
    local y = picker.selector.y + style.padding.y * 3 + picker.selector.h * 3 + 1

    test.ok(picker:on_mouse_pressed("left", x, y, 1))

    test.ok(picker.alpha_mouse_down)
    test.not_ok(picker.brightness_mouse_down)
  end)

  test.it("brightness bar mouse hitbox does not overlap alpha bar", function()
    local picker = new_picker()
    local x, y = bar_center(picker, 2)

    test.ok(picker:on_mouse_pressed("left", x, y, 1))

    test.ok(picker.brightness_mouse_down)
    test.not_ok(picker.alpha_mouse_down)
  end)
end)
