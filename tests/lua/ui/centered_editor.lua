local core = require "core"
local command = require "core.command"
local config = require "core.config"
local linewrapping = require "core.linewrapping"
local style = require "core.style"
local test = require "core.test"

local centered_editor = require "plugins.centered_editor"

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
  cfg.scale_width = saved.scale_width
  cfg.min_margin = saved.min_margin
  cfg.pane_views_only = saved.pane_views_only
end

local function use_test_centered_config()
  local cfg = config.plugins.centered_editor
  cfg.enabled = true
  cfg.max_width = 200
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
end)
