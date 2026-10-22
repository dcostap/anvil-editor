-- Work in a long, feature-dense Markdown note in Live Preview.
-- `settings.mode` picks the workflow:
-- `open` opens the note from a short note and waits until Live Preview is ready.
-- `wheel` scrolls down from the top, `settings.ticks` wheel ticks per action.
-- `caret` moves the caret down one line per action from `settings.line`.
-- `type` types into the end of `settings.line`.
-- `newline` inserts a line break at the caret, from the end of `settings.line`.
local core = require "core"
local command = require "core.command"
local support = require "scenes.support"

local scene = {}
local TYPED_TEXT = "a b c d e f g h i j "

-- Live Preview is ready when the published parse matches the text and wrapping is complete.
local function preview_ready(view)
  local model = require("core.markdown.model").peek(view.buffer)
  return view.__markdown_live_attached and model and model.status == "ready"
    and model.published_revision == view.buffer.text_revision
    and view.wrapped_settings ~= nil and view.__async_wrap_reconstruction == nil
end

local function open(context, path)
  local view = assert(core.open_file(context.path(path), { placement = "current", focus = true }))
  view:set_wrapping_enabled(true)
  return view
end

function scene.setup(context)
  local settings = context.settings
  if settings.mode == "open" then return open(context, settings.start_note) end
  local view = open(context, settings.note)
  if settings.mode == "type" or settings.mode == "newline" then
    local draw_line_text = view.draw_line_text
    view.draw_line_text = function(self, line, ...)
      local height = draw_line_text(self, line, ...)
      if line == context.edited_line and self.buffer.text_revision ~= context.revision then
        context.drawn_revision = self.buffer.text_revision
      end
      return height
    end
  end
  local line = settings.line or 1
  view:with_selection_state(function() view.buffer:set_selection(line, math.huge) end)
  view:scroll_to_line(line, false, true)
  return view
end

function scene.ready(context)
  return preview_ready(context.view) and support.background_settled(context)
end

function scene.action_name(context)
  return context.settings.mode
end

function scene.dispatch(context, index)
  local settings = context.settings
  if settings.mode == "open" then
    context.opened_at = system.get_time()
    context.first_frame_ms = nil
    context.view = open(context, settings.note)
    return
  end
  local view = context.view
  assert(core.active_view == view, "the editor lost input focus")
  if settings.mode == "wheel" then
    if index == 1 then support.hover(view) end
    context.before_scroll = view.scroll.to.y
    support.wheel(settings.ticks or 1)
    assert(view.scroll.to.y ~= context.before_scroll, "the editor did not accept the wheel scroll")
  elseif settings.mode == "caret" then
    context.before_line, context.before_col = view.buffer:get_selection()
    assert(command.perform("core:move_to_next_line"), "the editor did not move the caret")
  elseif settings.mode == "type" then
    context.revision = view.buffer.text_revision
    local offset = (index - 1) % #TYPED_TEXT + 1
    core.on_event("textinput", TYPED_TEXT:sub(offset, offset))
  elseif settings.mode == "newline" then
    context.revision = view.buffer.text_revision
    assert(command.perform("core:newline"), "the editor did not insert a line break")
  end
  if settings.mode == "type" or settings.mode == "newline" then
    context.edited_line = view.buffer:get_selection()
    context.drawn_revision = nil
  end
end

-- The scene observes the edited line's draw, even while the parse is pending.
function scene.action_visible(context)
  local mode = context.settings.mode
  if mode ~= "type" and mode ~= "newline" then return nil end
  return context.drawn_revision == context.view.buffer.text_revision
end

function scene.action_ready(context)
  local view, mode = context.view, context.settings.mode
  if mode == "open" then
    local elapsed = (system.get_time() - context.opened_at) * 1000
    context.first_frame_ms = context.first_frame_ms or elapsed
    if not preview_ready(view) then return false end
    return true, string.format("first_frame=%.0fms ready=%.0fms", context.first_frame_ms, elapsed)
  elseif mode == "wheel" then
    if not support.scroll_settled(view) then return false end
    return true, string.format("y=%d", math.floor(view.scroll.y + 0.5))
  elseif mode == "caret" then
    -- Wrapped movement goes by visual row, so a move can stay on the same line.
    local line, col = view.buffer:get_selection()
    if line == context.before_line and col == context.before_col then return false end
    if not support.scroll_settled(view) then return false end
    return true, string.format("line=%d col=%d", line, col)
  end
  -- Completion keeps the publication latency; visible latency stops at the earlier text draw.
  if view.buffer.text_revision == context.revision or not preview_ready(view) then return false end
  return true, "typed"
end

function scene.state(context)
  local view = context.view
  return {
    lines = #view.buffer.lines,
    line = (view.buffer:get_selection()),
    scroll_y = math.floor(view.scroll.y + 0.5),
    rows = require("core.linewrapping").get_total_wrapped_lines(view),
    -- Footnotes show as inline rows when the margin has no space for cards.
    inline_footnotes = view.visual_row_providers ~= nil
      and view.visual_row_providers["markdown.footnotes"] ~= nil,
  }
end

return scene
