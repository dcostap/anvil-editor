local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Editor = require "core.editor"
local panes = require "core.panes"
local test = require "core.test"

local function scroll_to_top(view, line, col, offset)
  local _, y = view:get_line_screen_position(line, col)
  local scroll = view.scroll.y + y - view.position.y + offset
  view.scroll.y, view.scroll.to.y = scroll, scroll
end

test.describe("Line wrapping toggle scroll position", function()
  test.before_each(function(context)
    local cfg = config.plugins.linewrapping
    context.old_config = {
      mode = cfg.mode,
      indent = cfg.indent,
      wrapping_indent = cfg.wrapping_indent,
      require_tokenization = cfg.require_tokenization,
      width_override = cfg.width_override,
    }
    cfg.mode, cfg.indent, cfg.wrapping_indent = "letter", false, 0
    cfg.require_tokenization = false
    local lines = {}
    for line = 1, 80 do lines[line] = string.rep("x", 40 + line % 3 * 8) end
    local buffer = core.open_buffer()
    context.buffer = buffer
    buffer:insert(1, 1, table.concat(lines, "\n"))
    buffer:set_selection(1, 1)
    local view = panes.place(function() return Editor(buffer) end,
      { placement = "new", focus = true })
    context.view = view
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 320, 240
    cfg.width_override = view:get_font():get_width("xxxxxxxx")
    view:set_wrapping_enabled(false)
    view:update()
    view.scroll.y, view.scroll.to.y = 0, 0
  end)

  test.after_each(function(context)
    local cfg = config.plugins.linewrapping
    for key, value in pairs(context.old_config) do cfg[key] = value end
    cfg.width_override = context.old_config.width_override
    context.buffer:clean()
    panes.reset_for_tests()
    for index = #core.buffers, 1, -1 do
      if core.buffers[index] == context.buffer then
        table.remove(core.buffers, index)
        context.buffer:on_close()
        break
      end
    end
  end)

  test.it("keeps the top visible text fixed when enabling wrapping", function(context)
    local view = context.view
    scroll_to_top(view, 45, 1, view:get_line_height() / 3)
    local _, before = view:get_line_screen_position(45, 1)

    test.ok(command.perform("editor:toggle_line_wrapping"))
    view:update()

    test.ok(view:is_wrapping_enabled())
    test.equal(select(2, view:get_line_screen_position(45, 1)), before)
    test.equal(view.scroll.to.y, view.scroll.y)
  end)

  test.it("keeps a visible continuation's Buffer line fixed when disabling wrapping", function(context)
    local view = context.view
    view:set_wrapping_enabled(true)
    view:update()
    scroll_to_top(view, 45, 17, view:get_line_height() / 3)
    local _, before = view:get_line_screen_position(45, 17)

    test.ok(command.perform("editor:toggle_line_wrapping"))
    view:update()

    test.ok(not view:is_wrapping_enabled())
    test.equal(select(2, view:get_line_screen_position(45, 17)), before)
    test.equal(view.scroll.to.y, view.scroll.y)
  end)

  test.it("clamps the restored position when unwrapped text ends above the old viewport", function(context)
    local view = context.view
    view:set_wrapping_enabled(true)
    view:update()
    scroll_to_top(view, 80, 17, 0)

    test.ok(command.perform("editor:toggle_line_wrapping"))
    local maximum = math.max(0, view:get_scrollable_size() - view.size.y)

    test.equal(view.scroll.y, maximum)
    test.equal(view.scroll.to.y, maximum)
    view:update()
    test.equal(view.scroll.y, maximum)
  end)
end)
