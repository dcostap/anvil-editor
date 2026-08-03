local common = require "core.common"
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local style = require "core.style"
local test = require "core.test"
local LineWrapping = require "core.linewrapping"

local gitdiff = require "plugins.gitdiff_highlight"

local function numbered_lines(count)
  local lines = {}
  for i = 1, count do lines[i] = "line " .. i end
  return table.concat(lines, "\n")
end

local function make_view(context, count)
  local doc = Doc()
  doc:insert(1, 1, numbered_lines(count))
  doc:clear_undo_redo()
  local view = DocView(doc)
  context.docs[#context.docs + 1] = doc
  return view
end

test.describe("DocView gutter line numbers", function()
  test.before_each(function(context)
    context.docs = {}
    context.show_line_numbers = config.show_line_numbers
    context.gitdiff_gutter = config.plugins.gitdiff_highlight.gutter
    context.gitdiff_overview = config.plugins.gitdiff_highlight.overview
    local wrapping = config.plugins.linewrapping
    context.wrapping = {
      mode = wrapping.mode,
      width_override = wrapping.width_override,
      indent = wrapping.indent,
      wrapping_indent = wrapping.wrapping_indent,
      require_tokenization = wrapping.require_tokenization,
    }
    config.show_line_numbers = true
    config.plugins.gitdiff_highlight.gutter = true
  end)

  test.after_each(function(context)
    config.show_line_numbers = context.show_line_numbers
    config.plugins.gitdiff_highlight.gutter = context.gitdiff_gutter
    config.plugins.gitdiff_highlight.overview = context.gitdiff_overview
    local wrapping = config.plugins.linewrapping
    if context.wrapping then
      wrapping.mode = context.wrapping.mode
      wrapping.width_override = context.wrapping.width_override
      wrapping.indent = context.wrapping.indent
      wrapping.wrapping_indent = context.wrapping.wrapping_indent
      wrapping.require_tokenization = context.wrapping.require_tokenization
    end
    if context.original_draw_rect then renderer.draw_rect = context.original_draw_rect end
    if context.original_common_draw_text then common.draw_text = context.original_common_draw_text end
    for _, doc in ipairs(context.docs or {}) do doc:on_close() end
  end)

  test.it("reserves two digits so the gutter does not jump at ten lines", function(context)
    local nine = make_view(context, 9)
    local ten = make_view(context, 10)

    test.equal(nine:get_line_number_gutter_width(), ten:get_line_number_gutter_width())
    test.equal(nine:get_gutter_width(), ten:get_gutter_width())
  end)

  test.it("allows one Document View to hide line numbers without removing its gutter", function(context)
    local view = make_view(context, 3)
    view.show_line_numbers = false
    local draw_count = 0
    context.original_common_draw_text = common.draw_text
    common.draw_text = function() draw_count = draw_count + 1 end

    local gutter_width = view:get_gutter_width()
    view:draw_line_gutter(1, 0, 0, gutter_width)

    test.ok(gutter_width > 0, "expected hidden line numbers to retain gutter spacing")
    test.equal(draw_count, 0)
  end)

  test.it("keeps the git hunk marker lane stable from nine to ten lines", function(context)
    local function marker_x_for(line_count)
      local view = make_view(context, line_count)
      gitdiff._set_state_for_tests(view.doc, {
        is_in_repo = true,
        line_index = { [1] = "addition" },
        ranges = {},
      })
      local marker_x
      context.original_draw_rect = context.original_draw_rect or renderer.draw_rect
      context.original_common_draw_text = context.original_common_draw_text or common.draw_text
      renderer.draw_rect = function(x)
        marker_x = marker_x or x
      end
      common.draw_text = function() end
      view:draw_line_gutter(1, 0, 0, view:get_gutter_width())
      return marker_x
    end

    test.equal(marker_x_for(9), marker_x_for(10))
  end)

  test.it("keeps git hunk markers inside the gutter when line numbers are hidden", function(context)
    local view = make_view(context, 3)
    view.show_line_numbers = false
    gitdiff._set_state_for_tests(view.doc, {
      is_in_repo = true,
      line_index = { [1] = "modification" },
      ranges = {},
    })

    local marker
    context.original_draw_rect = renderer.draw_rect
    renderer.draw_rect = function(x, y, w, h, color)
      if color == style.git_change_modification then
        marker = { x = x, width = w }
      end
    end

    local gutter_width, gutter_padding = view:get_gutter_width()
    local content_width = gutter_padding and gutter_width - gutter_padding or gutter_width
    view:draw_line_gutter(1, 0, 0, content_width)

    test.ok(marker, "expected a modified-line hunk marker")
    test.ok(marker.x >= 0, "expected the marker to start inside the gutter")
    test.ok(marker.x + marker.width <= gutter_width,
      "expected the marker not to overlap document text")
  end)

  test.it("spans git hunk gutter markers across all Wrapped Visual Rows", function(context)
    local doc = Doc()
    doc:insert(1, 1, string.rep("x", 24))
    doc:clear_undo_redo()
    context.docs[#context.docs + 1] = doc
    local view = DocView(doc)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 320, 200
    local wrapping = config.plugins.linewrapping
    wrapping.mode = "letter"
    wrapping.width_override = view:get_font():get_width("xxxxxxxx")
    wrapping.indent = false
    wrapping.wrapping_indent = 0
    wrapping.require_tokenization = false
    view:set_wrapping_enabled(true)
    LineWrapping.update_docview_breaks(view)
    gitdiff._set_state_for_tests(doc, {
      is_in_repo = true,
      line_index = { [1] = "addition" },
      ranges = {},
    })

    local marker
    context.original_draw_rect = renderer.draw_rect
    context.original_common_draw_text = common.draw_text
    common.draw_text = function() end
    renderer.draw_rect = function(x, y, w, h, color)
      if color == style.git_change_addition then marker = { x = x, y = y, w = w, h = h } end
    end
    view:draw_line_gutter(1, 0, 0, view:get_gutter_width())

    local visual_rows = view:get_visual_row_count_for_line(1)
    test.ok(visual_rows > 1)
    test.equal(marker.h, visual_rows * view:get_line_height())
  end)

  test.it("maps git overview markers through the visual-row scroll model", function(context)
    local doc = Doc()
    doc:insert(1, 1, string.rep("x", 24) .. "\nchanged\nend")
    doc:clear_undo_redo()
    context.docs[#context.docs + 1] = doc
    local view = DocView(doc)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 320, 200
    local wrapping = config.plugins.linewrapping
    wrapping.mode = "letter"
    wrapping.width_override = view:get_font():get_width("xxxxxxxx")
    wrapping.indent = false
    wrapping.wrapping_indent = 0
    wrapping.require_tokenization = false
    view:set_wrapping_enabled(true)
    LineWrapping.update_docview_breaks(view)
    config.plugins.gitdiff_highlight.overview = true
    gitdiff._set_state_for_tests(doc, {
      is_in_repo = true,
      line_index = { [2] = "addition" },
      ranges = { { type = "addition", current_start = 2, current_end = 3 } },
    })

    local marker
    context.original_draw_rect = renderer.draw_rect
    renderer.draw_rect = function(x, y, w, h, color)
      if type(color) == "table"
      and color[1] == style.git_change_addition[1]
      and color[4] == (style.git_change_addition[4] or 255) * 0.8
      then
        marker = { x = x, y = y, w = w, h = h }
      end
    end
    view.v_scrollbar.draw = function() end
    view.h_scrollbar.draw = function() end
    view.v_scrollbar.draw_thumb = function() end
    view.v_scrollbar.get_track_rect = function() return 0, 0, 10, 100 end
    view:draw_scrollbar()

    local start_row = view:get_visual_row(2, 1)
    local expected_y = view:get_visual_row_y_offset(start_row)
      / view:get_scrollable_size() * 100
    test.ok(view:get_visual_row_count_for_line(1) > 1)
    test.equal(marker.y, expected_y)
  end)
end)
