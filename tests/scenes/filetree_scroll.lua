-- Scroll a File Tree over a Git repository with changed files.
-- Rows show Git colors, change counts, folder counts, and metadata hints.
-- Settings:
--   input  "wheel" scrolls with the mouse wheel. "keys" moves the caret one line from
--          the bottom row, so each move scrolls the tree.
local support = require "scenes.support"

local scene = {}
local DOWN_TICKS = 30

function scene.setup(context)
  local settings = context.settings
  local view = support.open_file_tree(context.root)
  context.rows = support.expand_file_tree(view, settings.rows or 600, settings.max_level or 3)
  view:scroll_to_line(1, false, true)
  return view
end

local function keys(context)
  return context.settings.input == "keys"
end

function scene.ready(context)
  local view = context.view
  if not (support.git_settled(context.root, true) and support.scroll_settled(view)
    and support.file_tree_counts_ready(view)) then return false end
  if keys(context) and not context.caret_placed then
    context.caret_placed = support.caret_to_bottom(view)
    return false
  end
  return true
end

function scene.action_name(context, index)
  if keys(context) then return index <= DOWN_TICKS and "line-down" or "line-up" end
  return index <= DOWN_TICKS and "wheel-down" or "wheel-up"
end

function scene.dispatch(context, index)
  local view = context.view
  if keys(context) then
    context.left_line = support.move_caret(view, index <= DOWN_TICKS)
    return
  end
  if index == 1 then support.hover(view) end
  local before = view.scroll.to.y
  support.wheel(index <= DOWN_TICKS and 1 or -1)
  assert(view.scroll.to.y ~= before, "the File Tree did not accept the wheel scroll")
end

function scene.action_ready(context)
  local view = context.view
  if keys(context) and view.buffer:get_selection() == context.left_line then return false end
  if not support.scroll_settled(view) then return false end
  return true, string.format("y=%d", math.floor(view.scroll.y + 0.5))
end

function scene.state(context)
  return { rows = context.rows, scroll_y = math.floor(context.view.scroll.to.y + 0.5) }
end

return scene
