local config = require "core.config"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local RowTextView = require "core.rowtextview"
local style = require "core.style"
local test = require "core.test"

local LineWrapping = require "core.linewrapping"
require "plugins.selectionhighlight"

local function make_wrapped_view(text)
  local buffer = Buffer(nil, nil, true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()

  local view = TextView(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 320, 240
  view.scroll.x, view.scroll.to.x = 0, 0
  view.scroll.y, view.scroll.to.y = 0, 0
  view.wrapping_enabled = true
  LineWrapping.update_textview_breaks(view)
  return view, buffer
end

test.describe("selection highlight", function()
  test.after_each(function(context)
    if context.wrap_config then
      local cfg = config.plugins.linewrapping
      cfg.mode = context.wrap_config.mode
      cfg.width_override = context.wrap_config.width_override
      cfg.indent = context.wrap_config.indent
      cfg.wrapping_indent = context.wrap_config.wrapping_indent
      cfg.require_tokenization = context.wrap_config.require_tokenization
    end
  end)

  test.it("does not highlight matching text in unselected rows", function()
    local buffer = Buffer(nil, nil, true)
    buffer:insert(1, 1, "pane_requests.lua\npane_requests.lua\n")
    local view = RowTextView(buffer)
    view.size.x, view.size.y = 640, 240
    view:select_row(1)

    local function match_count()
      local count = 0
      local old_rect = renderer.draw_rect
      local old_text = renderer.draw_text
      local old_known_bounds = renderer.draw_text_known_bounds
      renderer.draw_rect = function(_, _, _, _, color)
        if color == style.selectionhighlight then count = count + 1 end
      end
      renderer.draw_text = function(font, text, x)
        return x + font:get_width(text)
      end
      renderer.draw_text_known_bounds = function(_, _, x, _, _, _, w)
        return x + w
      end
      local ok, err = pcall(function()
        local x, y = view:get_line_screen_position(2)
        view:draw_line_body(2, x, y)
      end)
      renderer.draw_rect = old_rect
      renderer.draw_text = old_text
      renderer.draw_text_known_bounds = old_known_bounds
      if not ok then error(err, 0) end
      return count
    end

    test.equal(match_count(), 0, "a row selection must not highlight another row's matching text")

    view:set_row_selection_mode(false)
    buffer:set_selection(1, 1, 1, 18)
    test.equal(match_count(), 1, "ordinary text selection must still highlight matching text")
  end)

  test.it("draws an additional match on its Wrapped Visual Row", function(context)
    local cfg = config.plugins.linewrapping
    context.wrap_config = {
      mode = cfg.mode,
      width_override = cfg.width_override,
      indent = cfg.indent,
      wrapping_indent = cfg.wrapping_indent,
      require_tokenization = cfg.require_tokenization,
    }
    cfg.mode = "letter"
    cfg.width_override = nil
    cfg.indent = false
    cfg.wrapping_indent = 0
    cfg.require_tokenization = false

    local view, buffer = make_wrapped_view("old xxxxx old")
    cfg.width_override = view:get_font():get_width("xxxxxxxx")
    LineWrapping.update_textview_breaks(view)
    buffer:set_selection(1, 1, 1, 4)

    local rects = {}
    local old_rect = renderer.draw_rect
    local old_text = renderer.draw_text
    local old_known_bounds = renderer.draw_text_known_bounds
    renderer.draw_rect = function(x, y, w, h, color)
      if color == style.selectionhighlight then
        rects[#rects + 1] = { x = x, y = y, w = w, h = h }
      end
    end
    renderer.draw_text = function(font, text, x)
      return x + font:get_width(text)
    end
    renderer.draw_text_known_bounds = function(_, _, x, _, _, _, w)
      return x + w
    end

    local x, y = view:get_line_screen_position(1)
    local ok, err = pcall(function()
      view:draw_line_body(1, x, y)
    end)
    renderer.draw_rect = old_rect
    renderer.draw_text = old_text
    renderer.draw_text_known_bounds = old_known_bounds
    if not ok then error(err, 0) end

    local expected_x, expected_y = view:get_line_screen_position(1, 11)
    test.equal(#rects, 1)
    test.equal(rects[1].x, expected_x)
    test.equal(rects[1].y, expected_y)
    test.ok(expected_y > y, "expected the additional match on a continuation row")
  end)
end)
