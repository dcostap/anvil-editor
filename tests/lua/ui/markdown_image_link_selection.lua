local Buffer = require "core.buffer"
local command = require "core.command"
local core = require "core"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local image_overlay = require "core.image_overlay"
local style = require "core.style"
local worker_pool = require "core.worker_pool"
local test = require "core.test"

local folder, view, restore, previous_view
local note_count = 0
local tints = 0

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

local function open_note(text)
  note_count = note_count + 1
  local path = folder .. PATHSEP .. "note-" .. note_count .. ".md"
  local buffer = Buffer(path, path, true)
  buffer:insert(1, 1, text)
  view = Editor(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 800, 600
  view:set_wrapping_enabled(false)
  core.active_view = view
  buffer:set_selection(2, 1)
  markdown.live_render.refresh_view(view)
  wait_ready(buffer)
  return buffer
end

local function draw()
  tints = 0
  local x, y = view:get_line_screen_position(1)
  view:draw_line_text(1, x, y)
  return tints
end

-- A press goes to the view first, and then to the mouse command, as in the
-- editor's event loop.
local function press(x, y)
  if not view:on_mouse_pressed("left", x, y, 1) then
    command.perform("core:set_cursor", x, y)
  end
end

local function click(x, y)
  press(x, y)
  view:on_mouse_released("left", x, y)
end

-- The screen point of `col` on line 1, inside its row.
local function point(col)
  local x, y = view:get_line_screen_position(1, col)
  return x + 1, y + 5
end

local function selection(buffer)
  local line1, col1, line2, col2 = buffer:get_selection(true)
  return { line1, col1, line2, col2 }
end

test.describe("Markdown Live Preview image link selection", function()
  test.before_each(function()
    previous_view = core.active_view
    folder = USERDIR .. PATHSEP .. "markdown-image-link-selection-" .. system.get_process_id()
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
    renderer.draw_rect = function(_, _, _, _, color)
      if color == style.markdown_live_image_selection then tints = tints + 1 end
    end
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
    core.active_view = previous_view
    test.ok(test.remove_tree(folder))
  end)

  test.it("selects the image target when its link is clicked", function()
    for _, case in ipairs({
      { source = "![[photo.png]]", first = 4, last = 13 },
      { source = "![Alt](photo.png)", first = 8, last = 17 },
    }) do
      for _, prefix in ipairs({ "", "before " }) do
        local buffer = open_note(prefix .. case.source .. "\nnext")
        draw()
        click(point(#prefix + 3))
        test.same(selection(buffer), { 1, #prefix + case.first, 1, #prefix + case.last })
        test.not_ok(image_overlay.is_open())
      end
    end
  end)

  test.it("places the caret in a revealed image link's source on a click", function()
    for _, case in ipairs({
      { source = "![[photo.png]]", col = 8 },
      { source = "![Alt](photo.png)", col = 4 },
    }) do
      for _, prefix in ipairs({ "", "before " }) do
        local buffer = open_note(prefix .. case.source .. "\nnext")
        buffer:set_selection(1, #prefix + 5)
        draw()
        click(point(#prefix + case.col))
        test.same(selection(buffer), { 1, #prefix + case.col, 1, #prefix + case.col })
      end
    end
  end)

  test.it("selects the whole image link when a drag ends inside it", function()
    local buffer = open_note("before ![[photo.png]] after\nnext")
    draw()
    local link_x, link_y = point(10)
    press(point(1))
    view:on_mouse_moved(link_x, link_y, 0, 0)
    test.same(selection(buffer), { 1, 1, 1, 22 }, "a drag forward ends after the link")
    view:on_mouse_released("left", link_x, link_y)

    buffer:set_selection(2, 1)
    draw()
    press(point(28))
    link_x, link_y = point(10)
    view:on_mouse_moved(link_x, link_y, 0, 0)
    test.same(selection(buffer), { 1, 8, 1, 28 }, "a drag backward ends before the link")
    view:on_mouse_released("left", link_x, link_y)
  end)

  test.it("tints the image only while the selection covers its whole link", function()
    local buffer = open_note("before ![[photo.png]] after\nnext")
    buffer:set_selection(1, 5, 1, 12)
    test.equal(draw(), 0, "a selection that ends inside the link")
    buffer:set_selection(1, 12, 1, 25)
    test.equal(draw(), 0, "a selection that starts inside the link")
    buffer:set_selection(1, 11, 1, 14)
    test.equal(draw(), 0, "a selection inside the link")
    buffer:set_selection(1, 8, 1, 22)
    test.equal(draw(), 1, "a selection of the whole link")
    buffer:set_selection(1, 1, 2, 1)
    test.equal(draw(), 1, "a selection around the link")
  end)

  test.it("selects the whole link when a drag starts on its rendered name", function()
    local buffer = open_note("before ![[photo.png]] after\nnext")
    draw()
    local start_x, start_y = point(12)
    local end_x, end_y = point(28)
    press(start_x, start_y)
    view:on_mouse_moved(end_x, end_y, end_x - start_x, end_y - start_y)
    test.same(selection(buffer), { 1, 8, 1, 28 })
    view:on_mouse_released("left", end_x, end_y)

    buffer:set_selection(2, 1)
    draw()
    start_x, start_y = point(12)
    end_x, end_y = point(1)
    press(start_x, start_y)
    view:on_mouse_moved(end_x, end_y, end_x - start_x, end_y - start_y)
    test.same(selection(buffer), { 1, 1, 1, 22 })
    view:on_mouse_released("left", end_x, end_y)
  end)

  test.it("allows partial drag selections within revealed image source", function()
    local buffer = open_note("![[photo.png]]\nnext")
    buffer:set_selection(1, 5)
    draw()
    local start_x, start_y = point(5)
    local end_x, end_y = point(8)
    press(start_x, start_y)
    view:on_mouse_moved(end_x, end_y, end_x - start_x, end_y - start_y)
    view:on_mouse_released("left", end_x, end_y)
    test.same(selection(buffer), { 1, 5, 1, 8 })
    test.equal(draw(), 0)
  end)
end)
