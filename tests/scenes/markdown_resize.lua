-- Resize the window around a wrapped Markdown note with tables and an embedded
-- image: narrower one step per action, then wider again.
-- Each step must reflow the prose, as a live window drag does.
local core = require "core"
local support = require "scenes.support"

local scene = {}
local STEP = 10

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
  -- Start with the image and the first table in view.
  view:with_selection_state(function() view.buffer:set_selection(settings.image_line + 6, 1) end)
  view:scroll_to_line(settings.image_line - 10, false, true)
  context.window_width, context.window_height, context.window_x, context.window_y =
    system.get_window_size(core.window)
  return view
end

function scene.ready(context)
  local model = require("core.markdown.model").peek(context.view.buffer)
  return model and model.status == "ready" and image_rendered(context.view, context.settings.image_line)
    and context.view.wrapped_settings ~= nil and support.background_settled(context)
end

local function narrows(context, index)
  return index <= math.floor(context.settings.actions / 2)
end

function scene.action_name(context, index)
  return narrows(context, index) and "narrow" or "widen"
end

function scene.dispatch(context, index)
  local view = context.view
  context.before_view_width = view.size.x
  context.before_wrap_width = view.wrapped_settings.width
  context.window_width = context.window_width + (narrows(context, index) and -STEP or STEP)
  system.set_window_size(core.window, context.window_width, context.window_height,
    context.window_x, context.window_y)
end

function scene.action_ready(context)
  local view = context.view
  if view.size.x == context.before_view_width then return false end
  -- The prose wraps to the new width, not only the window frame.
  local wrap_width = view.wrapped_settings and view.wrapped_settings.width
  if not wrap_width or wrap_width == context.before_wrap_width then return false end
  return true, string.format("view=%d wrap=%d", math.floor(view.size.x), math.floor(wrap_width))
end

function scene.state(context)
  local view = context.view
  return {
    view_width = math.floor(view.size.x),
    wrap_width = view.wrapped_settings and math.floor(view.wrapped_settings.width),
    rows = require("core.linewrapping").get_total_wrapped_lines(view),
  }
end

return scene
