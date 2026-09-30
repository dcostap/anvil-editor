local core = require "core"
local command = require "core.command"
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
  test.it("draws larger row spacing when zooming an unchanged Markdown Editor", function()
    coroutine.yield(0.05)
    local old_live, old_active = config.markdown_live_editor, core.active_view
    local old_scale, old_code = scale.get(), scale.get_code()
    local centered = config.plugins.centered_editor
    local old_pane_only = centered.pane_views_only
    local panes = require "core.panes"
    panes.reset_for_tests()
    config.markdown_live_editor, centered.pane_views_only = true, false
    local view, buffer = make_view("# Heading one\n# Heading two\nParagraph one\nParagraph two\nFollowing paragraph", true)
    view.size.x, view.size.y = 1600, 1000
    panes.place(function() return view end, { placement = "new", focus = true })
    buffer:set_selection(5, 1)
    local ok, err = pcall(function()
      core.set_active_view(view)
      settle(view)
      local function draw_positions()
        local old_text, old_rect, old_round = renderer.draw_text, renderer.draw_rect, renderer.draw_rounded_rect
        local old_push, old_pop = core.push_clip_rect, core.pop_clip_rect
        local drawn = {}
        renderer.draw_text = function(font, text, x, y)
          if text == "Heading one" or text == "Heading two"
            or text == "Paragraph one" or text == "Paragraph two"
          then
            drawn[text] = { y = y, height = font:get_height() }
          end
          return x + font:get_width(text)
        end
        renderer.draw_rect, renderer.draw_rounded_rect = function() end, function() end
        core.push_clip_rect, core.pop_clip_rect = function() end, function() end
        local success, failure = pcall(view.draw, view)
        renderer.draw_text, renderer.draw_rect, renderer.draw_rounded_rect = old_text, old_rect, old_round
        core.push_clip_rect, core.pop_clip_rect = old_push, old_pop
        if not success then error(failure, 0) end
        for _, text in ipairs { "Heading one", "Heading two", "Paragraph one", "Paragraph two" } do
          test.not_nil(drawn[text], "missing drawn text: " .. text)
        end
        return drawn
      end
      local before = draw_positions()
      for _ = 1, 12 do
        test.ok(command.perform("editor:zoom_in"))
        core.root_panel:update()
        coroutine.yield(0.01)
      end
      local after = draw_positions()
      for _, pair in ipairs { { "Heading one", "Heading two" }, { "Paragraph one", "Paragraph two" } } do
        local first, second = pair[1], pair[2]
        test.ok(after[first].height > before[first].height)
        test.ok(after[second].y - after[first].y > before[second].y - before[first].y,
          "font grew without drawn row spacing")
        test.ok(after[second].y - after[first].y >= after[first].height,
          "drawn row spacing does not fit the font")
      end
    end)
    core.active_view = old_active
    panes.reset_for_tests()
    scale.set(old_scale)
    scale.set_code(old_code)
    centered.pane_views_only, config.markdown_live_editor = old_pane_only, old_live
    if not ok then error(err, 0) end
  end)

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
