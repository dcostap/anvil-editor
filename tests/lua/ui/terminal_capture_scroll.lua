local config = require "core.config"
local panes = require "core.panes"
local test = require "core.test"
local terminal = require "plugins.terminal"

test.describe("Terminal Text Capture scrolling", function()
  test.before_each(function(context)
    context.context_lines = config.scroll_context_lines
    context.past_end = config.scroll_past_end
    config.scroll_context_lines = 4
    config.scroll_past_end = true
    panes.reset_for_tests()
  end)

  test.after_each(function(context)
    panes.reset_for_tests()
    config.scroll_context_lines = context.context_lines
    config.scroll_past_end = context.past_end
  end)

  test.it("keeps the opening position until upward navigation scrolls", function()
    local view = terminal.TerminalTextCaptureView(nil, {
      text = string.rep("output\n", 99) .. "last output",
      cursor_line = 100, cursor_col = 5, viewport_line = 81,
    })
    panes.create { factory = function() return view end }
    view.position.x, view.position.y = 0, 0
    view.size.x = 800
    view.size.y = 21 * view:get_line_height()
    local opening = view.scroll.y

    local function reveal(line, col)
      view.buffer:set_selection(line, col)
      view:scroll_to_make_visible(line, col, true)
    end

    reveal(100, 4)
    test.equal(view.scroll.y, opening, "horizontal movement shifted the opening viewport")
    reveal(99, 4)
    test.equal(view.scroll.y, opening, "upward movement near the bottom shifted the viewport")
    reveal(90, 4)
    test.equal(view.scroll.y, opening)
    reveal(100, 4)
    test.equal(view.scroll.y, opening, "bottom context activated before top navigation scrolled")

    reveal(82, 4)
    test.ok(view.scroll.y < opening, "top context must still scroll upward")
    reveal(100, 4)
    test.ok(view.scroll.y > opening, "bottom context must resume after upward scrolling")
  end)
end)
