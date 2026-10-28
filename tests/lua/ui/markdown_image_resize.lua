local Buffer = require "core.buffer"
local command = require "core.command"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local image_controls = require "core.markdown.image_controls"
local image_overlay = require "core.image_overlay"
local worker_pool = require "core.worker_pool"
local test = require "core.test"

local folder, view, restore
local note_count = 0

local function wait_ready(buffer)
  local instance = test.not_nil(markdown_model.peek(buffer))
  local deadline = system.get_time() + 10
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then coroutine.yield(0.001) end
  end
  test.equal(instance.status, "ready", instance.reason)
end

local function draw()
  local x, y = view:get_line_screen_position(1)
  view:draw_line_text(1, x, y)
  return test.not_nil(image_controls.layout(view, 1))
end

local function open_note(text)
  note_count = note_count + 1
  local path = folder .. PATHSEP .. "note-" .. note_count .. ".md"
  local buffer = Buffer(path, path, true)
  buffer:insert(1, 1, text)
  view = Editor(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 800, 600
  view:set_wrapping_enabled(false)
  buffer:set_selection(2, 1)
  markdown.live_render.refresh_view(view)
  wait_ready(buffer)
  return buffer
end

-- The commands of the Context Menu that opens on the image, by name.
local function image_menu()
  local layout = draw()
  local x, y = layout.image.x + 20, layout.image.y + 20
  view:on_mouse_moved(x, y, 0, 0)
  local items = {}
  for _, item in ipairs(view:context_menu(x, y)) do
    if type(item) == "table" and item.command
      and command.is_valid(item.command, table.unpack(item.args or {}))
    then
      items[item.command] = item
    end
  end
  return items
end

local function perform(item)
  return command.perform(item.command, table.unpack(item.args or {}))
end

local function corner_point(layout)
  local corner = layout.corner
  return corner.x + corner.w / 2, corner.y + corner.h / 2
end

test.describe("Markdown Live Preview image resize", function()
  test.before_each(function()
    folder = USERDIR .. PATHSEP .. "markdown-image-resize-" .. system.get_process_id()
    test.ok(system.mkdir(folder))
    local file = test.not_nil(io.open(folder .. PATHSEP .. "photo.png", "wb"))
    file:write("png")
    file:close()
    local old_load_image = canvas.load_image
    -- Tests have no window to draw in.
    local old_renderer = {}
    for _, name in ipairs({ "draw_canvas", "draw_canvas_scaled", "draw_rect", "draw_rounded_rect", "draw_text" }) do
      old_renderer[name] = renderer[name]
      renderer[name] = function() end
    end
    renderer.draw_text = function(font, text, x) return x + font:get_width(text) end
    canvas.load_image = function()
      return {
        get_size = function() return 400, 200 end,
        scaled = function(self) return self end,
      }
    end
    restore = function()
      canvas.load_image = old_load_image
      for name, fn in pairs(old_renderer) do renderer[name] = fn end
    end
  end)

  test.after_each(function()
    image_overlay.close()
    restore()
    test.ok(test.remove_tree(folder))
  end)

  test.it("drags the corner to set the width in the source", function()
    local buffer = open_note("![[photo.png]]\nnext")
    local layout = draw()
    test.equal(layout.image.w, 400)
    local x, y = corner_point(layout)
    view:on_mouse_moved(x, y, 0, 0)
    test.ok(view:on_mouse_pressed("left", x, y, 1))
    view:on_mouse_moved(layout.image.x + 250, layout.image.y + 20, 0, 0)
    test.equal(draw().image.w, 250, "the image follows the pointer during the drag")
    test.equal(buffer.lines[1], "![[photo.png]]\n", "the drag writes only when it ends")
    view:on_mouse_released("left", layout.image.x + 250, layout.image.y + 20)
    test.equal(buffer.lines[1], "![[photo.png|250]]\n")
    test.equal(markdown_model.peek(buffer).status, "pending")
    test.equal(draw().image.w, 250, "the image stays while the note is parsed again")
    wait_ready(buffer)
    test.equal(draw().image.w, 250)
  end)

  test.it("keeps the image under its shown source during a resize", function()
    local buffer = open_note("![[photo.png]]\nnext")
    buffer:set_selection(1, 1)
    local layout = draw()
    local x, y = corner_point(layout)
    view:on_mouse_moved(x, y, 0, 0)
    view:on_mouse_pressed("left", x, y, 1)
    view:on_mouse_moved(layout.image.x + 300, layout.image.y + 20, 0, 0)
    draw()
    view:on_mouse_released("left", layout.image.x + 300, layout.image.y + 20)
    test.equal(buffer.lines[1], "![[photo.png|300]]\n")
    test.equal(draw().image.w, 300)
    wait_ready(buffer)
    test.equal(draw().image.w, 300)
  end)

  test.it("double-clicks the corner to remove the width", function()
    local buffer = open_note("![Alt|120](photo.png)\nnext")
    local x, y = corner_point(draw())
    view:on_mouse_moved(x, y, 0, 0)
    view:on_mouse_pressed("left", x, y, 1)
    view:on_mouse_released("left", x, y)
    test.equal(buffer.lines[1], "![Alt|120](photo.png)\n", "a click without a drag keeps the width")
    view:on_mouse_pressed("left", x, y, 2)
    view:on_mouse_released("left", x, y)
    test.equal(buffer.lines[1], "![Alt](photo.png)\n")
  end)

  test.it("resets the size from the image's Context Menu", function()
    local buffer = open_note("![[photo.png|120]]\nnext")
    local items = image_menu()
    test.same({ buffer:get_selection() }, { 2, 1, 2, 1 }, "the caret stays")
    test.ok(perform(test.not_nil(items["markdown:reset_image_size"])))
    test.equal(buffer.lines[1], "![[photo.png]]\n")
    wait_ready(buffer)
    test.equal(image_menu()["markdown:reset_image_size"], nil, "an image without a size has nothing to reset")
  end)

  test.it("removes and copies the image from its Context Menu", function()
    local buffer = open_note("before ![[photo.png]] after\nnext")
    local copied
    local old_set_clipboard_image = system.set_clipboard_image
    system.set_clipboard_image = function(image) copied = image; return true end
    local ok, err = pcall(function()
      test.ok(perform(test.not_nil(image_menu()["markdown:copy_image"])))
      test.equal(select(1, copied:get_size()), 400)
      test.ok(perform(test.not_nil(image_menu()["markdown:remove_image"])))
    end)
    system.set_clipboard_image = old_set_clipboard_image
    if not ok then error(err, 0) end
    test.equal(buffer.lines[1], "before  after\n")
  end)

  test.it("shows zoom and edit buttons on the hovered image", function()
    local buffer = open_note("![[photo.png]]\nnext")
    local layout = draw()
    test.equal(layout.buttons, nil, "the buttons show only under the pointer")
    view:on_mouse_moved(layout.image.x + 20, layout.image.y + 20, 0, 0)
    layout = draw()
    local edit = test.not_nil(layout.buttons and layout.buttons.edit)
    view:on_mouse_pressed("left", edit.x + edit.w / 2, edit.y + edit.h / 2, 1)
    view:on_mouse_released("left", edit.x + edit.w / 2, edit.y + edit.h / 2)
    local line1, col1, line2, col2 = buffer:get_selection(true)
    test.same({ line1, col1, line2, col2 }, { 1, 4, 1, 13 }, "edit selects the image target")
    test.not_ok(image_overlay.is_open())

    buffer:set_selection(2, 1)
    layout = draw()
    view:on_mouse_moved(layout.image.x + 20, layout.image.y + 20, 0, 0)
    local zoom = test.not_nil(draw().buttons.zoom)
    view:on_mouse_pressed("left", zoom.x + zoom.w / 2, zoom.y + zoom.h / 2, 1)
    view:on_mouse_released("left", zoom.x + zoom.w / 2, zoom.y + zoom.h / 2)
    test.ok(image_overlay.is_open())
  end)
end)
