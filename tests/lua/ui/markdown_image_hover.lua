local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local worker_pool = require "core.worker_pool"
local test = require "core.test"

test.describe("Markdown Live Preview image hover", function()
  test.it("highlights the attachment link and image when either is hovered", function()
    local image_path = USERDIR .. PATHSEP .. "markdown-image-hover-" .. system.get_process_id() .. ".png"
    local file = test.not_nil(io.open(image_path, "wb"))
    file:write("png")
    file:close()
    local filename = image_path:match("[^/\\]+$")
    local old_load_image = canvas.load_image
    local old_draw_canvas = renderer.draw_canvas
    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    canvas.load_image = function()
      return {
        get_size = function() return 80, 40 end,
        scaled = function(self) return self end,
      }
    end
    renderer.draw_canvas = function() end
    renderer.draw_text = function(font, text, x) return x + font:get_width(text) end

    local ok, err = pcall(function()
      for _, prefix in ipairs({ "", "before " }) do
        local buffer = Buffer(image_path .. ".md", image_path .. prefix .. ".md", true)
        buffer:insert(1, 1, prefix .. "![[" .. filename .. "]]\nnext")
        local view = Editor(buffer)
        view.position.x, view.position.y = 0, 0
        view.size.x, view.size.y = 500, 200
        view:set_wrapping_enabled(false)
        buffer:set_selection(2, 1)
        markdown.live_render.refresh_view(view)
        local instance = test.not_nil(markdown_model.peek(buffer))
        local deadline = system.get_time() + 5
        while instance.status ~= "ready" and system.get_time() < deadline do
          local pool = worker_pool.current_system()
          if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
          if instance.status ~= "ready" then system.sleep(0.001) end
        end
        test.equal(instance.status, "ready", instance.reason)
        local row = test.not_nil(test.not_nil(view:get_line_render(1)).position_rows)[1]
        local x, y = view:get_line_screen_position(1)
        local image_y = y + row.height
        local function draw_feedback()
          local link, image = 0, 0
          renderer.draw_rect = function(_, top, _, height)
            if top + height / 2 < image_y then link = link + 1
            else image = image + 1 end
          end
          view:draw_line_text(1, x, y)
          return link, image
        end

        local link_x = x + (prefix == "" and 10 or 55)
        local link_y = y + 10
        local image_x = x + 10
        local image_hover_y = image_y + 10
        view:on_mouse_left()
        local base_link, base_image = draw_feedback()
        view:on_mouse_moved(link_x, link_y, 0, 0)
        local link_on_link, image_on_link = draw_feedback()
        test.ok(link_on_link > base_link)
        test.ok(image_on_link > base_image, "hovering the link must highlight the image")

        view:on_mouse_moved(image_x, image_hover_y, 0, 0)
        local link_on_image, image_on_image = draw_feedback()
        test.ok(image_on_image > base_image)
        test.ok(link_on_image > base_link, "hovering the image must highlight the link")
        view:on_mouse_left()
        local cleared_link, cleared_image = draw_feedback()
        test.equal(cleared_link, base_link)
        test.equal(cleared_image, base_image)
      end
    end)
    canvas.load_image = old_load_image
    renderer.draw_canvas = old_draw_canvas
    renderer.draw_rect = old_draw_rect
    renderer.draw_text = old_draw_text
    os.remove(image_path)
    if not ok then error(err, 0) end
  end)
end)
