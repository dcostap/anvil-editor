local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local wrapping = require "core.linewrapping"
local pool = require "core.worker_pool"
local scale = require "plugins.scale"
local test = require "core.test"

local identity = 0
local function make_view(text)
  identity = identity + 1
  local buffer = Buffer(nil, nil, true)
  buffer:set_filename("first-frame-zoom-" .. identity .. ".md", nil)
  buffer:insert(1, 1, text)
  local view = Editor(buffer)
  view.size.x, view.size.y = 500, 300
  view:set_wrapping_enabled(true)
  markdown.live_render.refresh_view(view)
  local instance = test.not_nil(model.peek(buffer))
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    pool.current_system():drain({ max_ms = 5, max_messages = 64 })
    system.sleep(0.001)
  end
  test.equal(instance.status, "ready", instance.reason)
  view:update()
  wrapping.complete_async_reconstruction(view)
  return view
end

local function visible_geometry(view, line)
  return view:with_selection_state(function()
    local rendered = test.not_nil(view:get_line_render(line))
    local font
    for _, fragment in ipairs(view:iter_line_render_fragments(rendered)) do
      if not fragment.hidden and fragment.text and fragment.text ~= "" then
        font = fragment.font
        break
      end
    end
    font = test.not_nil(font)
    local row = view:get_visual_row(line, 1, false)
    local _, y = view:get_line_screen_position(line, 1)
    local _, next_y = view:get_line_screen_position(line + 1, 1)
    return {
      font_size = font:get_size(), row_height = view:get_visual_row_height(row),
      rows = view:get_visual_row_count_for_line(line), line_height = next_y - y,
    }
  end)
end

local function drawn_geometry(view, first_line)
  local number = (first_line + 1) / 2
  local heading, paragraph = "Heading " .. number, "Paragraph " .. number .. " "
  local original = renderer.draw_text
  local rect, round = renderer.draw_rect, renderer.draw_rounded_rect
  local push, pop = core.push_clip_rect, core.pop_clip_rect
  local drawn = {}
  renderer.draw_text = function(font, text, x, y)
    local key = text == heading and "heading"
      or text:sub(1, #paragraph) == paragraph and "paragraph"
    if key and not drawn[key] then
      drawn[key] = { y = y, size = font:get_size(), height = font:get_height() }
    end
    return x + font:get_width(text)
  end
  renderer.draw_rect, renderer.draw_rounded_rect = function() end, function() end
  core.push_clip_rect, core.pop_clip_rect = function() end, function() end
  local ok, err = pcall(view.draw, view)
  renderer.draw_text = original
  renderer.draw_rect, renderer.draw_rounded_rect = rect, round
  core.push_clip_rect, core.pop_clip_rect = push, pop
  if not ok then error(err, 0) end
  return test.not_nil(drawn.heading), test.not_nil(drawn.paragraph)
end

test.describe("Markdown zoom first redraw", function()
  for _, first_line in ipairs { 1, 1001 } do
    test.it("updates visible fonts, heights, and wrapping without waiting at line " .. first_line, function()
      coroutine.yield(0.05)
      local old_live, old_active = config.markdown_live_editor, core.active_view
      local old_scale, old_code = scale.get(), scale.get_code()
      local views = {}
      config.markdown_live_editor = true
      local ok, err = pcall(function()
        local lines = {}
        for i = 1, 600 do
          lines[#lines + 1] = "# Heading " .. i
          lines[#lines + 1] = "Paragraph " .. i .. " with **bold words** and "
            .. string.rep("more words to wrap ", 8)
        end
        local text = table.concat(lines, "\n")
        scale.set(old_scale * 1.5)
        scale.set_code(old_code * 1.5)
        local reference = make_view(text)
        views[#views + 1] = reference
        reference:with_selection_state(function() reference.buffer:set_selection(first_line, 2) end)
        reference:invalidate_measurement_dependent_layout("reference")
        wrapping.complete_async_reconstruction(reference)
        local expected_heading = visible_geometry(reference, first_line)
        local expected_body = visible_geometry(reference, first_line + 1)
        scale.set(old_scale)
        scale.set_code(old_code)

        local view = make_view(text)
        views[#views + 1] = view
        core.set_active_view(view)
        view:with_selection_state(function() view.buffer:set_selection(first_line, 1) end)
        view:scroll_to_line(first_line, false, true)
        view:with_selection_state(function() view.buffer:set_selection(first_line, 2) end)
        view:update()
        wrapping.complete_async_reconstruction(view)
        view:get_visible_line_range()
        local baseline = {}
        for line = math.max(1, first_line - 40), first_line + 40 do
          baseline[line] = visible_geometry(view, line)
        end

        test.equal(core.active_view, view)
        scale.set(old_scale * 1.5)
        scale.set_code(old_code * 1.5)
        view:update()
        -- Do not drain workers, yield, or finish background wrapping here.
        test.same(visible_geometry(view, first_line), expected_heading,
          "the first redraw kept the old heading layout")
        test.same(visible_geometry(view, first_line + 1), expected_body,
          "the first redraw kept the old paragraph layout")
        -- Zoom keeps the viewport center fixed, not the caret. Use the next
        -- complete heading when zoom moves the first heading offscreen.
        local visible_first = view:get_visible_line_range()
        local drawn_line = math.max(first_line, visible_first + (visible_first % 2 == 0 and 1 or 2))
        local heading, paragraph = drawn_geometry(view, drawn_line)
        test.equal(heading.size, expected_heading.font_size)
        test.equal(paragraph.size, expected_body.font_size)
        test.ok(paragraph.y - heading.y >= heading.height,
          "the first redraw put the paragraph inside the heading")

        scale.set(old_scale)
        scale.set_code(old_code)
        view:update()
        local first, last = view:get_visible_line_range()
        for line = first, last do
          test.same(visible_geometry(view, line), test.not_nil(baseline[line]),
            "zoom out kept the old layout at visible line " .. line)
        end
      end)
      core.active_view = old_active
      for _, view in ipairs(views) do view:on_close() end
      scale.set(old_scale)
      scale.set_code(old_code)
      config.markdown_live_editor = old_live
      if not ok then error(err, 0) end
    end)
  end
end)
