local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local wrapping = require "core.linewrapping"
local worker_pool = require "core.worker_pool"
local scale = require "plugins.scale"
local test = require "core.test"

local identity = 0
local function make_view(text, wrapped)
  identity = identity + 1
  local buffer = Buffer(nil, nil, true)
  buffer:set_filename("markdown-zoom-" .. identity .. ".md", nil)
  buffer:insert(1, 1, text)
  local view = Editor(buffer)
  view.size.x, view.size.y = 800, 400
  view:set_wrapping_enabled(wrapped)
  markdown.live_render.refresh_view(view)
  return view, buffer
end

local function settle(view)
  local instance = test.not_nil(model.peek(view.buffer))
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    worker_pool.current_system():drain({ max_ms = 5, max_messages = 64 })
    system.sleep(0.001)
  end
  test.equal(instance.status, "ready", instance.reason)
  view:update()
  wrapping.complete_async_reconstruction(view)
end

local function visible_text(view, line)
  local render = test.not_nil(view:get_line_render(line))
  local text = {}
  for _, fragment in ipairs(view:iter_line_render_fragments(render)) do
    if not fragment.hidden then text[#text + 1] = fragment.text or "" end
  end
  return table.concat(text)
end

local function geometry(view)
  local function height(line)
    return view:get_visual_row_height(view:get_visual_row(line, 1, false))
  end
  return {
    body_height = height(1), heading_height = height(3),
    body_width = view:get_col_x_offset(1, #view.buffer.lines[1]),
    heading_width = view:get_col_x_offset(3, #view.buffer.lines[3]),
    code_height = height(6),
    code_width = view:get_col_x_offset(6, #view.buffer.lines[6]),
    body_rows = view:get_visual_row_count_for_line(1),
  }
end

test.describe("Markdown zoom", function()
  for _, wrapped in ipairs { false, true } do
    for _, edited_line in ipairs { 1, 3, 6 } do
      test.it("resizes pending formatted rows, wrapping=" .. tostring(wrapped)
        .. " edited line=" .. edited_line, function()
        -- Let the deferred startup zoom run before this test changes it.
        coroutine.yield(0.05)
        local old_live = config.markdown_live_editor
        local old_scale, old_code = scale.get(), scale.get_code()
        config.markdown_live_editor = true
        local views = {}
        local ok, err = pcall(function()
          local tail = string.rep("words that wrap across rows ", 10)
          local view, buffer = make_view("Plain **bold** paragraph " .. tail
            .. "\nAnother paragraph\n# Heading **bold**\nFollowing paragraph"
            .. "\n```text\n  code content\n```", wrapped)
          views[#views + 1] = view
          buffer:set_selection(4, 1)
          settle(view)
          geometry(view)
          view:get_line_render(1)
          view:get_line_render(3)
          view:get_line_render(6)
          buffer:insert(edited_line, edited_line == 1 and 2 or 4, "x")
          test.equal(model.peek(buffer).status, "pending")

          local samples = {}
          for _, factor in ipairs { 1.5, 0.8 } do
            scale.set(old_scale * factor)
            scale.set_code(old_code * factor)
            view:update()
            wrapping.complete_async_reconstruction(view)
            samples[#samples + 1] = { factor = factor, geometry = geometry(view) }
            test.equal(visible_text(view, 1),
              (edited_line == 1 and "Pxlain" or "Plain") .. " bold paragraph " .. tail)
            test.equal(visible_text(view, 3),
              (edited_line == 3 and "Hxeading" or "Heading") .. " bold")
            test.equal(visible_text(view, 6),
              edited_line == 6 and "  cxode content" or "  code content")
          end

          -- Fresh Editors give independent expected geometry at each zoom.
          for _, sample in ipairs(samples) do
            scale.set(old_scale * sample.factor)
            scale.set_code(old_code * sample.factor)
            local reference, reference_buffer = make_view(buffer:get_text(
              1, 1, #buffer.lines, #buffer.lines[#buffer.lines]
            ), wrapped)
            views[#views + 1] = reference
            reference_buffer:set_selection(4, 1)
            settle(reference)
            local expected = geometry(reference)
            test.same(sample.geometry, expected, "pending layout differs from current zoom")
            settle(view)
            test.same(geometry(view), expected, "publication kept stale layout measurements")
          end
        end)
        for _, view in ipairs(views) do view:on_close() end
        scale.set(old_scale)
        scale.set_code(old_code)
        config.markdown_live_editor = old_live
        if not ok then error(err, 0) end
      end)
    end
  end

  test.it("keeps the visible caret at the same height when zoom changes pending rows", function()
    coroutine.yield(0.05)
    local old_live, old_past_end = config.markdown_live_editor, config.scroll_past_end
    local old_active = core.active_view
    local old_scale, old_code = scale.get(), scale.get_code()
    config.markdown_live_editor, config.scroll_past_end = true, true
    local view, buffer = make_view(string.rep("# Heading\nParagraph\n", 30), false)
    local ok, err = pcall(function()
      core.set_active_view(view)
      buffer:set_selection(30, 1)
      settle(view)
      view:scroll_to_line(30, false, true)
      local before_y = view:get_caret_highlight_geometry(30, 1)
      buffer:insert(2, 2, "x")
      test.equal(model.peek(buffer).status, "pending")
      scale.set(old_scale * 1.2)
      scale.set_code(old_code * 1.2)
      local scaled_y = view:get_caret_highlight_geometry(30, 1)
      view:update()
      local after_y = view:get_caret_highlight_geometry(30, 1)
      -- Scroll coordinates use whole pixels; padding can use partial pixels.
      test.near(after_y, before_y, 1, string.format(
        "zoom moved the visible caret: before=%s scaled=%s updated=%s selection=%s",
        before_y, scaled_y, after_y, buffer:get_selection()))
    end)
    core.active_view = old_active
    view:on_close()
    scale.set(old_scale)
    scale.set_code(old_code)
    config.markdown_live_editor, config.scroll_past_end = old_live, old_past_end
    if not ok then error(err, 0) end
  end)
end)
