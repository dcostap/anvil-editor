local common = require "core.common"
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"

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
    config.show_line_numbers = true
    config.plugins.gitdiff_highlight.gutter = true
  end)

  test.after_each(function(context)
    config.show_line_numbers = context.show_line_numbers
    config.plugins.gitdiff_highlight.gutter = context.gitdiff_gutter
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
end)
