-- Scroll a long source file in the editor.
-- Settings:
--   input  "wheel" scrolls with the mouse wheel. "keys" moves the caret one line from
--          the bottom row, so each move scrolls the file.
local core = require "core"
local support = require "scenes.support"

local scene = {}
local DOWN_STEPS = 40

local function keys(context)
  return context.settings.input == "keys"
end

function scene.setup(context)
  local path = context.path(context.settings.targets[1])
  local view = assert(core.open_file(path, { placement = "current", focus = true }))
  view:scroll_to_line(1, false, true)
  return view
end

function scene.ready(context)
  local view = context.view
  if not (support.git_settled(context.root, true) and support.background_settled(context)
    and support.scroll_settled(view)) then return false end
  if #view.buffer.lines < 1000 then
    error(string.format("the file has %d lines; the scene needs a long file", #view.buffer.lines))
  end
  if keys(context) and not context.caret_placed then
    context.caret_placed = support.caret_to_bottom(view)
    return false
  end
  return true
end

function scene.action_name(context, index)
  local down = index <= DOWN_STEPS
  if keys(context) then return down and "line-down" or "line-up" end
  return down and "wheel-down" or "wheel-up"
end

function scene.dispatch(context, index)
  local view = context.view
  assert(core.active_view == view, "the editor lost input focus")
  if keys(context) then
    context.left_line = support.move_caret(view, index <= DOWN_STEPS)
    return
  end
  if index == 1 then support.hover(view) end
  local before = view.scroll.to.y
  support.wheel(index <= DOWN_STEPS and 1 or -1)
  assert(view.scroll.to.y ~= before, "the editor did not accept the wheel scroll")
end

function scene.action_ready(context)
  local view = context.view
  if keys(context) and view.buffer:get_selection() == context.left_line then return false end
  if not support.scroll_settled(view) then return false end
  return true, string.format("y=%d", math.floor(view.scroll.y + 0.5))
end

function scene.state(context)
  local view = context.view
  return { lines = #view.buffer.lines, scroll_y = math.floor(view.scroll.to.y + 0.5) }
end

return scene
