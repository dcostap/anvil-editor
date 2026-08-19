local core = require "core"
local command = require "core.command"
local config = require "core.config"
local markdown = require "core.markdown"
local style = require "core.style"
local test = require "core.test"

local centered_editor = require "plugins.centered_editor"
local sticky_scroll = require "plugins.sticky_scroll"
local Editor = require "core.editor"
local panes = require "core.panes"

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function remove_buffer(buffer)
  for i = #core.buffers, 1, -1 do
    if core.buffers[i] == buffer then
      table.remove(core.buffers, i)
      buffer:on_close()
      return
    end
  end
end

local function open_editor(context, text)
  local buffer = track(context, "buffers", core.open_buffer())
  if text and text ~= "" then buffer:text_input(text) end
  local view = track(context, "views", panes.place(function() return Editor(buffer) end,
    { placement = "new", focus = true }))
  view.position.x, view.position.y = 10, 20
  view.size.x, view.size.y = 1000, 240
  view.scroll.x, view.scroll.to.x = 0, 0
  view.scroll.y, view.scroll.to.y = 0, 0
  return view, buffer
end

local function save_centered_config(context)
  local cfg = config.plugins.centered_editor
  context.centered_config = {
    enabled = cfg.enabled,
    max_width = cfg.max_width,
    markdown_live_max_width = cfg.markdown_live_max_width,
    scale_width = cfg.scale_width,
    min_margin = cfg.min_margin,
    pane_views_only = cfg.pane_views_only,
  }
end

local function restore_centered_config(context)
  local saved = context.centered_config
  if not saved then return end
  local cfg = config.plugins.centered_editor
  cfg.enabled = saved.enabled
  cfg.max_width = saved.max_width
  cfg.markdown_live_max_width = saved.markdown_live_max_width
  cfg.scale_width = saved.scale_width
  cfg.min_margin = saved.min_margin
  cfg.pane_views_only = saved.pane_views_only
end

local function use_test_centered_config()
  local cfg = config.plugins.centered_editor
  cfg.enabled = true
  cfg.max_width = 200
  cfg.markdown_live_max_width = 120
  cfg.scale_width = false
  cfg.min_margin = 0
  cfg.pane_views_only = true
end

test.describe("centered editor", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    save_centered_config(context)
    use_test_centered_config()
  end)

  test.after_each(function(context)
    restore_centered_config(context)
    panes.reset_for_tests()
    for _, view in ipairs(context.views or {}) do
      view.wrapping_enabled = false
      view.wrapped_settings = nil
    end
    for _, buffer in ipairs(context.buffers or {}) do
      if buffer:is_dirty() then buffer:clean() end
      remove_buffer(buffer)
    end
  end)

  test.it("uses the real Text View right edge for unwrapped centered drawing", function(context)
    local view, buffer = open_editor(context, string.rep("x", 1000) .. "\n")
    view.wrapping_enabled = false
    view.wrapped_settings = nil

    local lane_x, lane_width = centered_editor.get_lane_rect(view)
    local editor_x, editor_width = centered_editor.get_editor_rect(view)
    local expected_width = view.position.x + view.size.x - lane_x

    test.ok(centered_editor.should_center(view), "expected test view to be centered")
    test.equal(editor_x, lane_x)
    test.equal(editor_width, expected_width)
    test.ok(editor_width > lane_width, "expected unwrapped drawing to extend past the centered lane")

    local _, col2 = view:get_visible_cols_range(1, 0)
    local gw = view:get_gutter_width()
    local char_width = view:get_font():get_width("W")
    local expected_col2 = math.min(#buffer.lines[1], math.floor((expected_width - gw) / char_width) * 2)
    local lane_col2 = math.min(#buffer.lines[1], math.floor((lane_width - gw) / char_width) * 2)

    test.equal(col2, expected_col2)
    test.ok(col2 > lane_col2, "expected visible-column estimation to include the right-side drawing area")
  end)

  test.it("uses the Markdown Live Preview width for centering", function(context)
    local standard_view = open_editor(context, "standard\n")
    local markdown_view, markdown_buffer = open_editor(context, "markdown\n")
    markdown_buffer.filename = "centered-width.md"
    markdown_buffer.abs_filename = "centered-width.md"
    test.equal(markdown.live_render.refresh_view(markdown_view), true)

    standard_view.size.x = 150
    markdown_view.size.x = 150
    test.equal(centered_editor.should_center(standard_view), false)
    test.equal(centered_editor.should_center(markdown_view), true)

    local _, standard_width = centered_editor.get_lane_rect(standard_view)
    local _, markdown_width = centered_editor.get_lane_rect(markdown_view)
    test.equal(standard_width, standard_view.size.x)
    test.ok(markdown_width > 0 and markdown_width < standard_width)

    test.equal(markdown.live_render.detach(markdown_view), true)
    test.equal(centered_editor.should_center(markdown_view), false)
    test.equal(select(2, centered_editor.get_lane_rect(markdown_view)), markdown_view.size.x)
  end)

  test.it("allows unwrapped right-side drawn text to receive buffer mouse commands", function(context)
    local view = open_editor(context, string.rep("x", 1000) .. "\n")
    local lane_x, lane_width = centered_editor.get_lane_rect(view)
    local y = view.position.y + style.padding.y + view:get_line_height() / 2
    local right_of_lane_x = lane_x + lane_width + 20
    local left_margin_x = lane_x - 1

    test.ok(right_of_lane_x < view.position.x + view.size.x, "expected a test point to the right of the lane")
    test.ok(left_margin_x > view.position.x + view:get_gutter_width(), "expected a test point in the left centered margin")

    view.wrapping_enabled = false
    view.wrapped_settings = nil
    test.ok(command.is_valid("core:set_cursor", right_of_lane_x, y), "expected unwrapped right-side text area to be interactive")
    test.equal(command.is_valid("core:set_cursor", left_margin_x, y), false)

    view.wrapping_enabled = true
    test.equal(command.is_valid("core:set_cursor", right_of_lane_x, y), false)
  end)

  test.it("limits sticky-line hover and clicks to the centered drawing lane", function(context)
    local view, buffer = open_editor(context, "# Heading\nbody\n")
    view.wrapping_enabled = true
    local lane_x, lane_width = centered_editor.get_lane_rect(view)
    local data = sticky_scroll.managed_textviews[view]
    data.enabled = true
    data.sticky_lines = { 1 }
    data.reference_line = nil
    local y = view.position.y + view:get_line_height() / 2
    local inside_x = lane_x + view:get_gutter_width() + 4
    local outside_x = lane_x + lane_width + 20

    test.ok(outside_x < view.position.x + view.size.x)
    test.equal(view:on_mouse_moved(inside_x, y, 0, 0), true)
    test.equal(data.hovered_sticky_scroll_line, 1)

    view:on_mouse_moved(outside_x, y, 0, 0)
    test.equal(data.hovered_sticky_scroll_line, nil)

    buffer:set_selection(2, 1)
    view:on_mouse_pressed("left", outside_x, y, 1)
    local line, col = buffer:get_selection()
    test.equal(line, 2)
    test.equal(col, 1)
  end)
end)
