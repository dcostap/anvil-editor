local core = require "core"
local config = require "core.config"
local style = require "core.style"
local test = require "core.test"

local LineWrapping = require "plugins.linewrapping"

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
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 320, 240
  view.scroll.x, view.scroll.to.x = 0, 0
  view.scroll.y, view.scroll.to.y = 0, 0
  return view, doc
end

local function configure_wrapping_for_test(context, view)
  local cfg = config.plugins.linewrapping
  context.linewrapping_config = {
    mode = cfg.mode,
    width_override = cfg.width_override,
    indent = cfg.indent,
    wrapping_indent = cfg.wrapping_indent,
  }
  context.highlight_current_line = config.highlight_current_line

  cfg.mode = "letter"
  cfg.indent = false
  cfg.wrapping_indent = 0
  cfg.width_override = view:get_font():get_width("xxxxxxxx")
  config.highlight_current_line = true

  view.wrapping_enabled = true
  LineWrapping.update_docview_breaks(view)
end

local function restore_config(context)
  if context.linewrapping_config then
    local cfg = config.plugins.linewrapping
    cfg.mode = context.linewrapping_config.mode
    cfg.width_override = context.linewrapping_config.width_override
    cfg.indent = context.linewrapping_config.indent
    cfg.wrapping_indent = context.linewrapping_config.wrapping_indent
  end
  if context.highlight_current_line ~= nil then
    config.highlight_current_line = context.highlight_current_line
  end
end

local function collect_current_line_highlights(view, fn)
  local highlights = {}
  local old_draw_line_highlight = view.draw_line_highlight
  local old_draw_rect = renderer.draw_rect
  local old_draw_text = renderer.draw_text
  local old_set_clip_rect = renderer.set_clip_rect

  view.draw_line_highlight = function(_, x, y)
    highlights[#highlights + 1] = { x = x, y = y }
  end
  renderer.draw_rect = function() end
  renderer.draw_text = function(font, text, x)
    return x + font:get_width(text)
  end
  renderer.set_clip_rect = function() end

  local ok, err = pcall(fn)

  view.draw_line_highlight = old_draw_line_highlight
  renderer.draw_rect = old_draw_rect
  renderer.draw_text = old_draw_text
  renderer.set_clip_rect = old_set_clip_rect

  if not ok then error(err, 0) end
  return highlights
end

test.describe("line wrapping current line highlight", function()
  test.after_each(function(context)
    restore_config(context)
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

  test.it("highlights only the wrapped visual line containing the caret", function(context)
    local view, doc = open_editor(context, string.rep("x", 40) .. "\n")
    configure_wrapping_for_test(context, view)

    local first_x, first_y = view:get_line_screen_position(1)
    local _, second_visual_y = view:get_line_screen_position(1, 12)
    test.ok(second_visual_y > first_y, "expected the test caret column to be on a wrapped continuation line")

    doc:set_selection(1, 12, 1, 12)

    local highlights = collect_current_line_highlights(view, function()
      view:draw_line_body(1, first_x, first_y)
    end)

    test.equal(#highlights, 1)
    test.equal(highlights[1].y, second_visual_y)
  end)

  test.it("draws a single current-line highlight during a full wrapped Document View draw", function(context)
    local view, doc = open_editor(context, string.rep("x", 40) .. "\n")
    configure_wrapping_for_test(context, view)
    doc:set_selection(1, 12, 1, 12)

    local _, expected_y = view:get_line_screen_position(1, 12)
    local highlights = collect_current_line_highlights(view, function()
      view:draw()
    end)

    test.equal(#highlights, 1)
    test.equal(highlights[1].y, expected_y)
  end)
end)
