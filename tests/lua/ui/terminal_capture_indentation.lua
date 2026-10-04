local config = require "core.config"
local core = require "core"
local panes = require "core.panes"
local style = require "core.style"
local test = require "core.test"
local terminal = require "plugins.terminal"
local guides = require "plugins.indent_guides"

require "plugins.detectindent"

local function draw(view)
  renderer.begin_frame(core.window)
  local ok, err = pcall(function() view:draw() end)
  renderer.end_frame()
  if not ok then error(err, 0) end
end

local function open_capture()
  local view = terminal.TerminalTextCaptureView(nil, {
    text = " title\n\n" .. string.rep(" ", 80) .. "output\n first\n next\n",
  })
  panes.create { factory = function() return view end }
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 800, 400
  return view
end

test.describe("Terminal Text Capture indentation", function()
  test.before_each(function(context)
    context.tab_type, context.indent_size = config.tab_type, config.indent_size
    context.enabled, context.highlight_active = guides.enabled, guides.highlight_active
    config.tab_type, config.indent_size = "soft", 4
    guides.enabled = true
    panes.reset_for_tests()
  end)

  test.after_each(function(context)
    panes.reset_for_tests()
    config.tab_type, config.indent_size = context.tab_type, context.indent_size
    guides.enabled, guides.highlight_active = context.enabled, context.highlight_active
  end)

  test.it("does not treat terminal screen spacing as confirmed file indentation", function()
    local view = open_capture()
    draw(view)
    local indent_type, size, confirmed = view.buffer:get_indent_info()
    test.equal(indent_type, "soft")
    test.equal(size, config.indent_size)
    test.ok(not confirmed)
  end)

  test.it("does not draw indentation guides over terminal text or blank rows", function()
    local view = open_capture()
    draw(view)
    for _, highlight_active in ipairs({ false, true }) do
      guides.highlight_active = highlight_active
      local count = 0
      local old_rect, old_grid = renderer.draw_rect, renderer.draw_rect_grid
      renderer.draw_rect = function(x, y, width, height, color)
        if color == style.indent_guide or color == style.indent_guide_active then
          count = count + 1
        end
        return old_rect(x, y, width, height, color)
      end
      renderer.draw_rect_grid = function(x, y, step, width, height, n, color)
        if color == style.indent_guide or color == style.indent_guide_active then
          count = count + n
        end
        return old_grid(x, y, step, width, height, n, color)
      end
      renderer.begin_frame(core.window)
      local ok, err = pcall(function()
        for line = 1, #view.buffer.lines do
          local x, y = view:get_line_screen_position(line)
          view:draw_line_body(line, x, y)
        end
      end)
      renderer.end_frame()
      renderer.draw_rect, renderer.draw_rect_grid = old_rect, old_grid
      if not ok then error(err, 0) end
      test.equal(count, 0)
    end
  end)
end)
