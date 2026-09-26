local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local wrapping = require "core.linewrapping"
local workers = require "core.worker_pool"
local test = require "core.test"

local function ready(view)
  local instance = test.not_nil(model.peek(view.buffer))
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then coroutine.yield(0.001) end
  end
  test.equal(instance.status, "ready", instance.reason)
  wrapping.complete_async_reconstruction(view)
end

local function make_view(context, source, wrapped)
  local buffer = Buffer("heading-geometry.md", nil, true)
  buffer:insert(1, 1, source .. "\nplain\n")
  local view = Editor(buffer)
  context.views[#context.views + 1] = view
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 500, 800
  view:set_wrapping_enabled(wrapped)
  core.active_view = view
  markdown.live_render.refresh_view(view)
  ready(view)
  return view, buffer
end

local function visible_text(view)
  local parts = {}
  for _, fragment in ipairs(test.not_nil(view:get_line_render(1)).fragments) do
    if not fragment.hidden then parts[#parts + 1] = fragment.text or "" end
  end
  return table.concat(parts)
end

test.describe("Markdown heading geometry", function()
  test.before_each(function(context)
    context.active, context.live = core.active_view, config.markdown_live_editor
    context.transitions = config.transitions
    context.views = {}
    config.markdown_live_editor, config.transitions = true, false
  end)

  test.after_each(function(context)
    for _, view in ipairs(context.views) do
      view.discard_buffer_on_close = true
      view:on_close()
    end
    core.active_view, config.markdown_live_editor = context.active, context.live
    config.transitions = context.transitions
  end)

  test.it("uses equal text spacing across all wrapped heading rows", function(context)
    local view, buffer = make_view(context, "# " .. string.rep("Heading words ", 24), true)
    buffer:set_selection(2, 1)
    ready(view)
    local count = view:get_visual_row_count_for_line(1)
    test.ok(count >= 4, "the heading must span at least four visual rows")
    local previous_y, spacing
    for row = 1, count do
      local col = view:get_visual_row_bounds_for_line(1, row)
      local y = view:get_position_highlight_geometry(1, col, false)
      if previous_y then
        spacing = spacing or y - previous_y
        test.equal(y - previous_y, spacing, "wrapped row " .. row .. " adds a block gap")
      end
      previous_y = y
    end
  end)

  test.it("reveals the heading and edited bold span without revealing sibling spans", function(context)
    local view, buffer = make_view(context, "# Head **bold** and *other*", false)
    buffer:set_selection(1, 11)
    test.equal(visible_text(view), "# Head **bold** and other")
    view:on_text_input("x")
    local pending = visible_text(view)
    test.equal(pending, "# Head **bxold** and other")
    ready(view)
    test.equal(visible_text(view), pending, "publication must not hide or reveal more markers")
  end)

  for _, wrapped in ipairs { false, true } do
    test.it("aligns selection past heading text with its content row (wrapped=" .. tostring(wrapped) .. ")", function(context)
      local view, buffer = make_view(context, "# Selected heading", wrapped)
      buffer:set_selection(1, 1, 2, 2)
      ready(view)
      local color = view:get_selection_background_color()
      local rects = {}
      local draw_rect = renderer.draw_rect
      renderer.draw_rect = function(x, y, w, h, c)
        if c == color then rects[#rects + 1] = { x = x, y = y, w = w, h = h } end
        return draw_rect(x, y, w, h, c)
      end
      renderer.begin_frame(core.window)
      local ok, err = pcall(function()
        local x, y = view:get_line_screen_position(1)
        view:draw_line_body(1, x, y)
      end)
      renderer.end_frame()
      renderer.draw_rect = draw_rect
      if not ok then error(err, 0) end
      test.ok(#rects >= 2, "selection must cover heading text and the remaining row")
      local y, height = view:get_position_highlight_geometry(1, 1, false)
      for _, rect in ipairs(rects) do
        test.equal(rect.y, y, "selection must exclude the heading's leading gap")
        test.equal(rect.h, height, "selection must use one content height across the row")
      end
    end)
  end
end)
