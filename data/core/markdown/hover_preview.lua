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
  state.shown = true
  -- Keyboard navigation owns its inline card. Hover must not replace it.
  if preview.for_view(view) then return end
  if live.preview_link(view, state.link, { line = state.line, floating = state.anchor }) then
    state.preview = preview.for_view(view)
    core.log_quiet("Markdown hover preview shown: %s", state.link.raw_target or state.link.path or "")
  end
end

function M.install()
  if M.installed then return end
  M.installed = true
  local moved = TextView.on_mouse_moved
  function TextView:on_mouse_moved(x, y, ...)
    local result = moved(self, x, y, ...)
    local fragment = self.hovered_render_fragment
    local link = fragment and fragment.link
    if not live.is_live_mode(self) or not link or self.mouse_selecting then
      cancel(self)
      return result
    end
    local resolution = fragment.link_resolution
    if not resolution or resolution.status ~= "resolved" or resolution.kind ~= "note" then
      cancel(self)
      return result
    end
    local line, col = self:resolve_screen_position(x, y)
    local state = pending[self]
    local key = table.concat({ line, link.source_col1, link.raw_target or link.path or "" }, ":")
    if state and state.key == key then return result end
    cancel(self)
    if preview.for_view(self) then return result end
    local _, top = self:get_line_screen_position(line, col)
    state = {
      key = key, link = link, line = line,
      deadline = system.get_time() + config.markdown_link_hover_delay,
      revision = self.buffer.text_revision,
      scroll_x = self.scroll.x, scroll_y = self.scroll.y,
      width = self:get_presentation_viewport_width(), height = self.size.y,
      active_view = core.active_view,
      anchor = { x = x, top = top, bottom = top + self:get_position_visual_row_height(line, col) },
    }
    pending[self] = state
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

  for _, name in ipairs({ "on_mouse_left", "on_mouse_pressed", "on_mouse_wheel" }) do
    local original = TextView[name]
    TextView[name] = function(self, ...)
      cancel(self)
      return original(self, ...)
    end
  end
end

return M
