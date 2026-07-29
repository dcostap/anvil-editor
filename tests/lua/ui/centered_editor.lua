local core = require "core"
local command = require "core.command"
local config = require "core.config"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local style = require "core.style"
local test = require "core.test"

local centered_editor = require "plugins.centered_editor"
local sticky_scroll = require "plugins.sticky_scroll"

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function remove_doc(doc)
  for i = #core.docs, 1, -1 do
    if core.docs[i] == doc then
      table.remove(core.docs, i)
      doc:on_close()
      return
    end
  end
end

local function open_editor(context, text)
  local doc = track(context, "docs", core.open_doc())
  if text and text ~= "" then doc:text_input(text) end
  local view = track(context, "views", core.root_panel:open_doc(doc))
  core.set_active_view(view)
  view.position.x, view.position.y = 10, 20
  view.size.x, view.size.y = 1000, 240
  view.scroll.x, view.scroll.to.x = 0, 0
  view.scroll.y, view.scroll.to.y = 0, 0
  return view, doc
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
    save_centered_config(context)
    use_test_centered_config()
  end)

  test.after_each(function(context)
    restore_centered_config(context)
    local root = core.root_panel.root_node
    for _, view in ipairs(context.views or {}) do
      view.wrapping_enabled = false
      view.wrapped_settings = nil
      local node = root:get_node_for_view(view)
      if node then node:remove_view(root, view) end
    end
    for _, doc in ipairs(context.docs or {}) do
      if doc:is_dirty() then doc:clean() end
      remove_doc(doc)
    end
  end)

  test.it("uses the real Document View right edge for unwrapped centered drawing", function(context)
    local view, doc = open_editor(context, string.rep("x", 1000) .. "\n")
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
    local expected_col2 = math.min(#doc.lines[1], math.floor((expected_width - gw) / char_width) * 2)
    local lane_col2 = math.min(#doc.lines[1], math.floor((lane_width - gw) / char_width) * 2)

    test.equal(col2, expected_col2)
    test.ok(col2 > lane_col2, "expected visible-column estimation to include the right-side drawing area")
  end)

  test.it("keeps wrapping constrained to the centered lane", function(context)
    local view = open_editor(context, string.rep("x", 1000) .. "\n")
    view.wrapping_enabled = true

    local lane_x, lane_width = centered_editor.get_lane_rect(view)
    local editor_x, editor_width = centered_editor.get_editor_rect(view)

    test.equal(editor_x, lane_x)
    test.equal(editor_width, lane_width)

    local scrollbar_width = view.v_scrollbar.expanded_size or style.expanded_scrollbar_size
    test.equal(linewrapping.compute_wrap_width(view), math.max(0, lane_width - view:get_gutter_width() - scrollbar_width))
  end)

  test.it("uses the Markdown Live Preview width for centering and wrapping", function(context)
    local standard_view = open_editor(context, "standard\n")
    local markdown_view, markdown_doc = open_editor(context, "markdown\n")
    markdown_doc.filename = "centered-width.md"
    markdown_doc.abs_filename = "centered-width.md"
    test.equal(markdown.live_render.refresh_view(markdown_view), true)

    standard_view.size.x = 150
    markdown_view.size.x = 150
    test.equal(centered_editor.should_center(standard_view), false)
    test.equal(centered_editor.should_center(markdown_view), true)

    local _, standard_width = centered_editor.get_lane_rect(standard_view)
    local _, markdown_width = centered_editor.get_lane_rect(markdown_view)
    test.equal(standard_width, 150)
    test.equal(markdown_width, 120)

    markdown_view.wrapping_enabled = true
    local scrollbar_width = markdown_view.v_scrollbar.expanded_size
      or style.expanded_scrollbar_size
    test.equal(
      linewrapping.compute_wrap_width(markdown_view),
      math.max(0, markdown_width - markdown_view:get_gutter_width() - scrollbar_width)
    )

    test.equal(markdown.live_render.detach(markdown_view), true)
    test.equal(centered_editor.should_center(markdown_view), false)
    test.equal(select(2, centered_editor.get_lane_rect(markdown_view)), 150)
  end)

  test.it("keeps Markdown Live Preview caches stable across centered geometry", function(context)
    local view, doc = open_editor(
      context,
      "# Heading\n\n| Name | Value |\n| --- | --- |\n| one | two |\n\nplain\n"
    )
    doc.filename = "centered-cache.md"
    doc.abs_filename = "centered-cache.md"
    test.equal(markdown.live_render.refresh_view(view), true)
    view.wrapping_enabled = true
    view:update_wrap_cache()

    view:get_visual_row_metric_cache()
    view:get_line_render(1)
    local before = view:get_render_cache_diagnostics()

    centered_editor.with_editor_geometry(view, function()
      for _ = 1, 100 do view:get_visual_row_metric_cache() end
      view:get_line_render(1)
    end)
    for _ = 1, 100 do view:get_visual_row_metric_cache() end
    view:get_line_render(1)

    local after = view:get_render_cache_diagnostics()
    test.equal(after.metric_full_rebuilds, before.metric_full_rebuilds)
    test.equal(after.metric_signature_changes, before.metric_signature_changes)
    test.equal(after.line_signature_misses, before.line_signature_misses)
    test.equal(
      after.metric_signature_computations,
      before.metric_signature_computations,
      "cache hits should reuse the validated metric signature"
    )
    test.ok(
      after.metric_signature_cache_hits - before.metric_signature_cache_hits >= 200,
      "expected repeated metric lookups to hit the signature cache"
    )

    test.equal(markdown.live_render.detach(view), true)
  end)

  test.it("allows unwrapped right-side drawn text to receive document mouse commands", function(context)
    local view = open_editor(context, string.rep("x", 1000) .. "\n")
    local lane_x, lane_width = centered_editor.get_lane_rect(view)
    local y = view.position.y + style.padding.y + view:get_line_height() / 2
    local right_of_lane_x = lane_x + lane_width + 20
    local left_margin_x = lane_x - 1

    test.ok(right_of_lane_x < view.position.x + view.size.x, "expected a test point to the right of the lane")
    test.ok(left_margin_x > view.position.x + view:get_gutter_width(), "expected a test point in the left centered margin")

    view.wrapping_enabled = false
    view.wrapped_settings = nil
    test.ok(command.is_valid("doc:set-cursor", right_of_lane_x, y), "expected unwrapped right-side text area to be interactive")
    test.equal(command.is_valid("doc:set-cursor", left_margin_x, y), false)

    view.wrapping_enabled = true
    test.equal(command.is_valid("doc:set-cursor", right_of_lane_x, y), false)
  end)

  test.it("limits sticky-line hover and clicks to the centered drawing lane", function(context)
    local view, doc = open_editor(context, "# Heading\nbody\n")
    view.wrapping_enabled = true
    local lane_x, lane_width = centered_editor.get_lane_rect(view)
    local data = sticky_scroll.managed_docviews[view]
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

    doc:set_selection(2, 1)
    view:on_mouse_pressed("left", outside_x, y, 1)
    local line, col = doc:get_selection()
    test.equal(line, 2)
    test.equal(col, 1)
  end)
end)
