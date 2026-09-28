local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local style = require "core.style"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

test.describe("Markdown link hover", function()
  test.it("fills the link highlight upward from its bottom edge", function()
    local buffer = Buffer(nil, nil, true)
    buffer:set_filename("link-hover.md", nil)
    buffer:insert(1, 1, "[Example](https://example.com)\nother")
    buffer:set_selection(2, 1)
    local view = Editor(buffer)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 500, 200
    view:set_wrapping_enabled(false)
    test.ok(markdown.live_render.refresh_view(view))
    local model = markdown_model.peek(buffer)
    local deadline = system.get_time() + 5
    while model.status ~= "ready" and system.get_time() < deadline do
      local pool = worker_pool.current_system()
      if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
      if model.status ~= "ready" then system.sleep(0.001) end
    end
    test.equal(model.status, "ready")

    local x, y = view:get_line_screen_position(1)
    x = x + 5
    y = y + style.markdown_body_font:get_height() / 2
    view:on_mouse_moved(x, y, 0, 0)
    test.not_nil(view.hovered_render_fragment)

    local old_rect, old_text = renderer.draw_rect, renderer.draw_text
    local old_known = renderer.draw_text_known_bounds
    local function highlight()
      local rects = {}
      renderer.draw_rect = function(rx, ry, width, height, color)
        if color == style.interactive_hover_background then
          rects[#rects + 1] = { y = ry, bottom = ry + height, height = height }
        end
      end
      renderer.draw_text = function(font, text, tx, _, _, opts)
        return tx + font:get_width(text, opts)
      end
      renderer.draw_text_known_bounds = function(_, _, tx, _, _, _, width)
        return tx + width
      end
      local ok, err = pcall(function()
        local line_x, line_y = view:get_line_screen_position(1)
        view:draw_line_text(1, line_x, line_y)
      end)
      renderer.draw_rect, renderer.draw_text = old_rect, old_text
      renderer.draw_text_known_bounds = old_known
      if not ok then error(err, 0) end
      return rects[1]
    end

    local first = test.not_nil(highlight())
    core.redraw = false
    view:update()
    test.ok(core.redraw, "the hover must schedule another frame")
    system.sleep(0.15)
    view:update()
    local full = test.not_nil(highlight())
    test.ok(first.height < full.height, "the highlight must grow")
    test.equal(first.bottom, full.bottom)
    view:on_mouse_left()
    test.equal(view.hovered_render_fragment, nil)
    test.equal(highlight(), nil)
  end)
end)
