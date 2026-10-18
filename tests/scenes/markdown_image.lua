-- Open a Markdown note that embeds a large image as a data URI, then go down
-- past the image and back up. The `caret` mode moves the caret one line per
-- action. The `wheel` mode scrolls one wheel tick per action.
-- Pasted screenshots arrive this way, so one line holds the whole encoded image.
local core = require "core"
local command = require "core.command"
local support = require "scenes.support"

local scene = {}

local function image_rendered(view, line)
  for _, fragment in ipairs((view:get_line_render(line) or {}).fragments or {}) do
    if fragment.widget and fragment.widget.type == "image" then return true end
  end
  return false
end

function scene.setup(context)
  local settings = context.settings
  local view = assert(core.open_file(context.path(settings.note), { placement = "current", focus = true }))
  view:set_wrapping_enabled(true)
  -- Start a few lines above the image, so the caret crosses it.
  context.start_line = math.max(1, settings.image_line - 5)
  view:with_selection_state(function() view.buffer:set_selection(context.start_line, 1) end)
  view:scroll_to_line(1, false, true)
  return view
end

function scene.ready(context)
  local model = require("core.markdown.model").peek(context.view.buffer)
  return model and model.status == "ready" and image_rendered(context.view, context.settings.image_line)
    and support.background_settled(context)
end

-- The first half of the actions moves down, the second half moves back up.
local function moves_down(context, index)
  return index <= math.floor(context.settings.actions / 2)
end

local function wheel_mode(context)
  return context.settings.mode == "wheel"
end

function scene.action_name(context, index)
  local direction = moves_down(context, index) and "down" or "up"
  return (wheel_mode(context) and "wheel-" or "caret-") .. direction
end

function scene.dispatch(context, index)
  local view = context.view
  assert(core.active_view == view, "the editor lost input focus")
  local down = moves_down(context, index)
  if wheel_mode(context) then
    if index == 1 then support.hover(view) end
    context.before_scroll = view.scroll.to.y
    support.wheel(down and 1 or -1)
    assert(view.scroll.to.y ~= context.before_scroll, "the editor did not accept the wheel scroll")
    return
  end
  context.before_line, context.before_col = view.buffer:get_selection()
  assert(command.perform(down and "core:move_to_next_line" or "core:move_to_previous_line"),
    "the editor did not move the caret")
end

function scene.action_ready(context)
  local view = context.view
  if wheel_mode(context) then
    if not support.scroll_settled(view) then return false end
    return true, string.format("y=%d", math.floor(view.scroll.y + 0.5))
  end
  -- Wrapped movement goes by visual row, so a move can stay on the same line.
  local line, col = view.buffer:get_selection()
  if line == context.before_line and col == context.before_col then return false end
  if not support.scroll_settled(view) then return false end
  return true, string.format("line=%d col=%d", line, col)
end

function scene.state(context)
  local view = context.view
  return {
    line = (view.buffer:get_selection()),
    image_bytes = #(view.buffer.lines[context.settings.image_line] or ""),
    image_rendered = image_rendered(view, context.settings.image_line),
  }
end

return scene
