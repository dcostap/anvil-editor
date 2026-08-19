local core = require "core"
local command = require "core.command"
local copy_feedback = require "core.copy_feedback"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local panes = require "core.panes"
local style = require "core.style"
local test = require "core.test"

local function make_view(text)
  local buffer = Buffer(nil, nil, true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 400, 200
  return view, buffer
end

test.describe("Copy Feedback Highlight", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.previous_active_view = core.active_view
    context.previous_clipboard = system.get_clipboard()
  end)

  test.after_each(function(context)
    system.set_clipboard(context.previous_clipboard or "")
    if context.view then
      panes.reset_for_tests()
      context.buffer:on_close()
    end
  end)

  test.it("briefly marks the exact Text View text copied by buffer:copy", function(context)
    local view, buffer = make_view("alpha")
    context.view, context.buffer = view, buffer
    panes.present(view, { placement = "new", focus = true })
    view:with_selection_state(function()
      buffer:set_selection(1, 2, 1, 5)
    end)

    test.ok(command.perform("core:copy"), "expected copy command to run")
    test.equal(system.get_clipboard(), "lph")

    local old_rect = renderer.draw_rect
    local old_text = renderer.draw_text
    local rects = {}
    renderer.draw_rect = function(x, y, w, h, color)
      rects[#rects + 1] = { x = x, y = y, w = w, h = h, color = color }
    end
    renderer.draw_text = function(font, text, x)
      return x + (font and font:get_width(text) or 0)
    end
    local ok, err = pcall(function() view:draw_line_body(1, 0, 0) end)
    renderer.draw_rect = old_rect
    renderer.draw_text = old_text
    if not ok then error(err, 0) end

    local feedback_rect
    for _, rect in ipairs(rects) do
      local color = rect.color
      if color and color[1] == style.copy_feedback[1]
      and color[2] == style.copy_feedback[2] and color[3] == style.copy_feedback[3]
      and color[4] and color[4] > 0 and color[4] <= style.copy_feedback[4] then
        feedback_rect = rect
        break
      end
    end
    test.not_nil(feedback_rect, "expected copied text to receive themed fading feedback")
    test.equal(feedback_rect.x, view:get_col_x_offset(1, 2))
    test.equal(feedback_rect.w, view:get_col_x_offset(1, 5) - view:get_col_x_offset(1, 2))
  end)
end)
