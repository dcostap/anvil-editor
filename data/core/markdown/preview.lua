local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local TextView = require "core.textview"
local common = require "core.common"
local style = require "core.style"
local live = require "core.markdown.live_render"
local model = require "core.markdown.model"

-- A detached snapshot uses the Editor's Markdown presentation, but owns no tab,
-- registered Buffer, input route, or caret. Relative links keep the note's path.
local Preview = Editor:extend()

function Preview:new(path, text, line)
  local buffer = Buffer(path, path, true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  buffer:clean()
  buffer.read_only = true
  TextView.new(self, buffer)
  self.target_line = common.clamp(line, 1, #buffer.lines)
  self.show_current_line_highlight = false
  self:set_wrapping_enabled(true)
  live.attach(self)
end

function Preview:get_line_render_selection_state()
  return { selections = {}, last_selection = 1 }
end

function Preview:get_gutter_width()
  return 0
end

function Preview:layout(width, max_height)
  self.size.x, self.size.y = math.max(1, width), max_height
  local instance = model.peek(self.buffer)
  self.ready = instance and instance.status == "ready"
  if not self.ready then return self:get_line_height() end
  self:update_wrap_cache()
  local first = self:get_visual_row(self.target_line, 1)
  local top = self:get_visual_row_y_offset(first)
  local bottom = self:get_visual_row_y_offset(self:get_scrollable_line_count() + 1)
  self.scroll.y = top + style.padding.y
  self.scroll.to.y = self.scroll.y
  return math.min(max_height, math.max(self:get_line_height(), bottom - top))
end

function Preview:draw(x, y, width, height)
  self.position.x, self.position.y = x, y
  self.size.x, self.size.y = width, height
  if not self.ready then
    local instance = model.peek(self.buffer)
    local message = instance and instance.status == "error"
      and "Preview unavailable" or "Loading preview…"
    renderer.draw_text(style.font, message, x, y, style.dim)
    return
  end
  core.push_clip_rect(x, y, width, height)
  local drawn = {}
  for entry in self:iter_visible_visual_rows() do
    if entry.line >= self.target_line and not drawn[entry.line] then
      drawn[entry.line] = true
      local tx, ty = self:get_line_screen_position(entry.line)
      self:draw_line_body(entry.line, tx, ty)
    end
  end
  core.pop_clip_rect()
end

function Preview:on_close()
  TextView.on_close(self)
  self.buffer:on_close()
end

return Preview
