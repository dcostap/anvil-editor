local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"
local flash = require "plugins.reload_diff_flash"

local function make_view(text)
  local buffer = Buffer(nil, nil, true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = TextView(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 400, 200
  return view, buffer
end

test.describe("reload diff flash UI", function()
  test.it("draws a flash over inserted text in the reloaded Buffer", function()
    local view, buffer = make_view("one\ntwo")
    test.ok(flash.flash(buffer, { "one\n" }, buffer.lines, { duration = 1000 }))

    local original_draw_rect = renderer.draw_rect
    local original_draw_text = renderer.draw_text
    local drawn_flash = false
    renderer.draw_rect = function(_, _, _, _, color)
      if color and color[4] and color[4] > 0 and color[4] < 255 then
        drawn_flash = true
      end
    end
    renderer.draw_text = function(font, text, x, _, _, opts)
      return x + font:get_width(text, opts)
    end
    local ok, err = pcall(function() view:draw_line_body(2, 0, 0) end)
    renderer.draw_rect = original_draw_rect
    renderer.draw_text = original_draw_text

    test.ok(ok, err)
    test.ok(drawn_flash, "inserted text did not draw its flash")
  end)
end)
