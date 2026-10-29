local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local workers = require "core.worker_pool"
local wrapping = require "core.linewrapping"
local style = require "core.style"
local test = require "core.test"

local function make_view(context, text, wrapped)
  local filename = context.root .. PATHSEP .. "selection.md"
  local buffer = Buffer(filename, filename, true)
  buffer:insert(1, 1, text)
  local view = Editor(buffer)
  context.views[#context.views + 1] = view
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 900, 600
  view:set_wrapping_enabled(wrapped)
  core.active_view = view
  buffer:set_selection(#buffer.lines, 1)
  markdown.live_render.refresh_view(view)
  local instance = test.not_nil(model.peek(buffer))
  local deadline = system.get_time() + 10
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    coroutine.yield(0.001)
  end
  test.equal(instance.status, "ready", instance.reason)
  if wrapped then wrapping.complete_async_reconstruction(view) end
  view:update()
  return view, buffer
end

local function draw_line(view, line)
  local events = {}
  local old_rect, old_text = renderer.draw_rect, renderer.draw_text
  local old_canvas, old_scaled = renderer.draw_canvas, renderer.draw_canvas_scaled
  renderer.draw_rect = function(x, y, width, height, color)
    events[#events + 1] = { kind = "rect", x = x, y = y, width = width, height = height, color = color }
  end
  renderer.draw_canvas = function(_, x, y)
    events[#events + 1] = { kind = "image", x = x, y = y, width = 80, height = 40 }
  end
  renderer.draw_canvas_scaled = function(_, x, y, width, height)
    events[#events + 1] = { kind = "image", x = x, y = y, width = width, height = height }
  end
  renderer.draw_text = function(font, text, x) return x + font:get_width(text) end
  local ok, err = pcall(view.with_selection_state, view, function()
    view:prepare_line_body_draw_cache(line, line)
    view:draw_line_body(line, 0, 0)
  end)
  renderer.draw_rect, renderer.draw_text = old_rect, old_text
  renderer.draw_canvas, renderer.draw_canvas_scaled = old_canvas, old_scaled
  if not ok then error(err, 0) end
  return events
end

local function image_is_highlighted(events)
  local image
  for _, event in ipairs(events) do
    if event.kind == "image" then image = event end
    if image and event.kind == "rect" and event.color == style.markdown_live_image_selection
      and event.x <= image.x and event.y <= image.y
      and event.x + event.width >= image.x + image.width
      and event.y + event.height >= image.y + image.height
    then return true end
  end
  test.not_nil(image, "the image must remain visible")
  return false
end

test.describe("Markdown selection backgrounds", function()
  test.before_each(function(context)
    context.active, context.live = core.active_view, config.markdown_live_editor
    context.load_image = canvas.load_image
    context.views = {}
    context.root = USERDIR .. PATHSEP .. "markdown-selection-" .. system.get_process_id()
    test.ok(system.mkdir(context.root))
    local file = test.not_nil(io.open(context.root .. PATHSEP .. "image.png", "wb"))
    file:write("image fixture")
    file:close()
    canvas.load_image = function()
      return { get_size = function() return 80, 40 end, scaled = function(self) return self end }
    end
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    for _, view in ipairs(context.views) do
      view.discard_buffer_on_close = true
      view:on_close()
    end
    canvas.load_image = context.load_image
    core.active_view, config.markdown_live_editor = context.active, context.live
    test.ok(test.remove_tree(context.root))
  end)

  for _, wrapped in ipairs({ false, true }) do
    local mode = wrapped and "wrapped" or "unwrapped"
    test.it("fills selected blank rows between list items (" .. mode .. ")", function(context)
      local view, buffer = make_view(context, "- [x] first\n\n- [ ] second\n", wrapped)
      view:begin_line_render_interaction("mouse-selection")
      buffer:set_selection(1, 1, 3, 8)
      for _, phase in ipairs({ "drag", "release" }) do
        if phase == "release" then view:end_line_render_interaction("mouse-release") end
        local filled = false
        for _, event in ipairs(draw_line(view, 2)) do
          if event.color == style.selection and event.x <= 0
            and event.x + event.width >= view.size.x then filled = true end
        end
        test.ok(filled, phase .. ": the blank row must not inherit the list indent")
      end
    end)

    test.it("keeps list content aligned when a multiline drag ends (" .. mode .. ")", function(context)
      local view, buffer = make_view(context, "- [x] first\n\n- [ ] second\n", wrapped)
      local first_x = view:get_col_x_offset(1, 7)
      local second_x = view:get_col_x_offset(3, 7)
      view:begin_line_render_interaction("mouse-selection")
      buffer:set_selection(1, 1, 3, #buffer.lines[3])
      test.equal(view:get_col_x_offset(1, 7), first_x)
      test.equal(view:get_col_x_offset(3, 7), second_x)
      view:end_line_render_interaction("mouse-release")
      test.equal(view:get_col_x_offset(1, 7), first_x, "release shifted the first item's content")
      test.equal(view:get_col_x_offset(3, 7), second_x, "release shifted the last item's content")
    end)

    test.it("highlights selected images during and after a drag (" .. mode .. ")", function(context)
      local view, buffer = make_view(context, "before\n![[image.png]]\nafter\n", wrapped)
      test.ok(not image_is_highlighted(draw_line(view, 2)), "an unselected image must not be tinted")
      view:begin_line_render_interaction("mouse-selection")
      buffer:set_selection(1, 1, 3, 3)
      test.ok(image_is_highlighted(draw_line(view, 2)), "the drag must highlight the image")
      view:end_line_render_interaction("mouse-release")
      test.ok(image_is_highlighted(draw_line(view, 2)), "release must keep the image highlighted")
      buffer:set_selection(3, 1)
      test.ok(not image_is_highlighted(draw_line(view, 2)), "clearing the selection must remove the tint")
    end)
  end
end)
