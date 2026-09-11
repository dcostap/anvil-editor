local core = require "core"
local config = require "core.config"
local TextView = require "core.textview"
local live = require "core.markdown.live_render"
local preview = require "core.poi_preview"

local M = {}
local pending = setmetatable({}, { __mode = "k" })
local owner_id = "markdown-hover-preview"

local function cancel(view)
  local state = pending[view]
  if not state then return end
  pending[view] = nil
  if state.preview and preview.for_view(view) == state.preview then preview.dismiss(view) end
  view:remove_selection_listener(owner_id)
  view:remove_owned_feature(owner_id)
end

local function update(view)
  local state = pending[view]
  if not state then return end
  if view.textview_closed or not live.is_live_mode(view)
    or view.buffer.text_revision ~= state.revision
    or view.scroll.x ~= state.scroll_x or view.scroll.y ~= state.scroll_y
    or view:get_presentation_viewport_width() ~= state.width
    or view.size.y ~= state.height or core.active_view ~= state.active_view
    or (core.window and not system.window_has_focus(core.window))
  then
    cancel(view)
    return
  end
  if state.shown or system.get_time() < state.deadline then return end
  -- Keyboard navigation owns its inline card. Hover must not replace it.
  if preview.for_view(view) then state.shown = true; return end
  local shown, reason = live.preview_link(view, state.link, {
    line = state.line, floating = state.anchor, note_only = true,
  })
  state.shown = reason ~= "pending"
  if shown then
    state.preview = preview.for_view(view)
    core.log_quiet("Markdown hover preview shown after %.3fs (delay %.3fs): %s",
      system.get_time() - state.started_at, state.delay, state.link.raw_target or state.link.path or "")
  end
end

function M.install()
  if M.installed then return end
  M.installed = true
  local moved = TextView.on_mouse_moved
  function TextView:on_mouse_moved(x, y, ...)
    local state = pending[self]
    if state and state.preview and preview.for_view(self) == state.preview
      and preview.contains_floating(self, x, y, true)
    then
      state.over_popup = preview.contains_floating(self, x, y)
      self.cursor = "arrow"
      return true
    end
    if state then state.over_popup = false end
    local result = moved(self, x, y, ...)
    local fragment = self.hovered_render_fragment
    local link = fragment and fragment.link
    if not live.is_live_mode(self) or not link or self.mouse_selecting then
      cancel(self)
      return result
    end
    local resolution = fragment.link_resolution
    if not resolution or (resolution.status ~= "pending"
      and (resolution.status ~= "resolved" or resolution.kind ~= "note")) then
      cancel(self)
      return result
    end
    local line, col = self:resolve_screen_position(x, y)
    state = pending[self]
    local key = table.concat({ line, link.source_col1, link.raw_target or link.path or "" }, ":")
    if state and state.key == key then return result end
    cancel(self)
    if preview.for_view(self) then return result end
    local _, top = self:get_line_screen_position(line, col)
    local started_at, delay = system.get_time(), config.markdown_link_hover_delay
    state = {
      key = key, link = link, line = line,
      started_at = started_at, delay = delay, deadline = started_at + delay,
      revision = self.buffer.text_revision,
      scroll_x = self.scroll.x, scroll_y = self.scroll.y,
      width = self:get_presentation_viewport_width(), height = self.size.y,
      active_view = core.active_view,
      anchor = { x = x, top = top, bottom = top + self:get_position_visual_row_height(line, col) },
    }
    pending[self] = state
    core.log_quiet("Markdown hover preview waiting: delay=%.3fs target=%s",
      delay, link.raw_target or link.path or "")
    self:add_selection_listener(owner_id, function() cancel(self) end)
    self:add_owned_feature(owner_id, { on_release = function() cancel(self) end })
    core.add_thread(function()
      coroutine.yield(math.max(0, state.deadline - system.get_time()))
      if pending[self] == state then update(self) end
    end)
    return result
  end

  local original_update = TextView.update
  function TextView:update(...)
    local result = original_update(self, ...)
    update(self)
    return result
  end

  local wheel = TextView.on_mouse_wheel
  function TextView:on_mouse_wheel(y, x, ...)
    local state = pending[self]
    if state and state.over_popup and preview.for_view(self) == state.preview then
      return preview.scroll_floating(self, y, x)
    end
    cancel(self)
    return wheel(self, y, x, ...)
  end

  local pressed = TextView.on_mouse_pressed
  function TextView:on_mouse_pressed(button, x, y, ...)
    if preview.contains_floating(self, x, y) then return true end
    cancel(self)
    return pressed(self, button, x, y, ...)
  end

  local left = TextView.on_mouse_left
  function TextView:on_mouse_left(...)
    cancel(self)
    return left(self, ...)
  end
end

return M
