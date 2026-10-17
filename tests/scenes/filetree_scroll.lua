-- Wheel-scroll a File Tree over a Git repository with changed files.
-- Rows show Git colors, change counts, folder counts, and metadata hints.
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

function scene.ready(context)
  local view = context.view
  return support.git_settled(context.root, true) and support.scroll_settled(view)
    and support.file_tree_counts_ready(view)
end

function scene.action_name(_, index)
  return index <= DOWN_TICKS and "wheel-down" or "wheel-up"
end

function scene.dispatch(context, index)
  local view = context.view
  if index == 1 then support.hover(view) end
  local before = view.scroll.to.y
  support.wheel(index <= DOWN_TICKS and 1 or -1)
  assert(view.scroll.to.y ~= before, "the File Tree did not accept the wheel scroll")
end

function scene.action_ready(context)
  local view = context.view
  if not support.scroll_settled(view) then return false end
  return true, string.format("y=%d", math.floor(view.scroll.y + 0.5))
end

function scene.state(context)
  return { rows = context.rows, scroll_y = math.floor(context.view.scroll.to.y + 0.5) }
end

return scene
