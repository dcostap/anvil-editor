local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local ime = require "core.ime"
local style = require "core.style"
local test = require "core.test"
local LineWrapping = require "core.linewrapping"

local function make_view(text)
  local buffer = Buffer(nil, nil, true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = TextView(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 320, 200
  view.scroll.x, view.scroll.to.x = 0, 0
  view.scroll.y, view.scroll.to.y = 0, 0
  return view, buffer
end

test.describe("Text View IME geometry", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    local wrapping = config.plugins.linewrapping
    context.wrapping = {
      mode = wrapping.mode,
      width_override = wrapping.width_override,
      indent = wrapping.indent,
      wrapping_indent = wrapping.wrapping_indent,
      require_tokenization = wrapping.require_tokenization,
    }
  end)

  test.after_each(function(context)
    core.active_view = context.active_view
    local wrapping = config.plugins.linewrapping
    if context.wrapping then
      wrapping.mode = context.wrapping.mode
      wrapping.width_override = context.wrapping.width_override
      wrapping.indent = context.wrapping.indent
      wrapping.wrapping_indent = context.wrapping.wrapping_indent
      wrapping.require_tokenization = context.wrapping.require_tokenization
    end
    if context.old_set_location then ime.set_location = context.old_set_location end
  end)

  test.it("draws composition underlines at their Buffer columns", function()
    local view = make_view("abcdefghij")
    local rects = {}
    local old_draw_rect = renderer.draw_rect
    renderer.draw_rect = function(x, y, w, h, color)
      if color == style.text then rects[#rects + 1] = { x = x, y = y, w = w, h = h } end
    end
    local ok, err = pcall(view.draw_ime_decoration, view, 1, 7, 1, 5)
    renderer.draw_rect = old_draw_rect
    if not ok then error(err, 0) end

    local expected_x = select(1, view:get_line_screen_position(1, 5))
    local expected_x2 = select(1, view:get_line_screen_position(1, 7))
    test.equal(rects[1].x, expected_x)
    test.equal(rects[1].w, expected_x2 - expected_x)
  end)

  test.it("anchors the system IME rectangle to a wrapped continuation row", function(context)
    local view, buffer = make_view(string.rep("x", 16) .. "AB")
    local wrapping = config.plugins.linewrapping
    wrapping.mode = "letter"
    wrapping.width_override = view:get_font():get_width(string.rep("x", 16))
    wrapping.indent = false
    wrapping.wrapping_indent = 0
    wrapping.require_tokenization = false
    view:set_wrapping_enabled(true)
    LineWrapping.update_textview_breaks(view)
    buffer:set_selection(1, 19, 1, 17)
    view.ime_status = true
    core.active_view = view

    local location
    context.old_set_location = ime.set_location
    ime.set_location = function(x, y, w, h) location = { x = x, y = y, w = w, h = h } end
    view:update_ime_location()

    local expected_x, expected_y = view:get_line_screen_position(1, 17)
    test.ok(expected_y > select(2, view:get_line_screen_position(1)))
    test.equal(location.x, expected_x)
    test.equal(location.y, expected_y)
  end)

  test.it("splits a composition underline across Wrapped Visual Rows", function()
    local view = make_view("xxxxxxxAB")
    local wrapping = config.plugins.linewrapping
    wrapping.mode = "letter"
    wrapping.width_override = view:get_font():get_width("xxxxxxxx")
    wrapping.indent = false
    wrapping.wrapping_indent = 0
    wrapping.require_tokenization = false
    view:set_wrapping_enabled(true)
    LineWrapping.update_textview_breaks(view)

    local rects = {}
    local old_draw_rect = renderer.draw_rect
    renderer.draw_rect = function(x, y, w, h, color)
      if color == style.text then rects[#rects + 1] = { x = x, y = y, w = w, h = h } end
    end
    local ok, err = pcall(view.draw_ime_decoration, view, 1, 10, 1, 8)
    renderer.draw_rect = old_draw_rect
    if not ok then error(err, 0) end

    test.equal(#rects, 2)
    test.ok(rects[2].y > rects[1].y)
  end)

  test.it("gives the system IME a positive first-row rect for a wrapped composition", function(context)
    local view, buffer = make_view("xxxxxxxAB")
    local wrapping = config.plugins.linewrapping
    wrapping.mode = "letter"
    wrapping.width_override = view:get_font():get_width("xxxxxxxx")
    wrapping.indent = false
    wrapping.wrapping_indent = 0
    wrapping.require_tokenization = false
    view:set_wrapping_enabled(true)
    LineWrapping.update_textview_breaks(view)
    buffer:set_selection(1, 10, 1, 8)
    view.ime_status = true
    core.active_view = view

    local location
    context.old_set_location = ime.set_location
    ime.set_location = function(x, y, w, h) location = { x = x, y = y, w = w, h = h } end
    view:update_ime_location()

    local expected_x, expected_y = view:get_line_screen_position(1, 8)
    test.equal(location.x, expected_x)
    test.equal(location.y, expected_y)
    test.ok(location.w > 0, "expected a positive first-segment IME width")
  end)
end)
