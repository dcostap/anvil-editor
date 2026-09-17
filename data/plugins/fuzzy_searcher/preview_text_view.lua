local style = require "core.style"
local Editor = require "core.editor"
local TextView = require "core.textview"

local PreviewTextView = TextView:extend()

local function initialize(view, buffer, wrapping)
  TextView.new(view, buffer)
  view.interactive = false
  view.show_current_line_highlight = false
  view.render_content_interactions_enabled = false
  view:set_wrapping_enabled(wrapping == true)
end

function PreviewTextView:new(buffer)
  initialize(self, buffer, false)
end

function PreviewTextView:set_interactive(interactive)
  local changed = self.interactive ~= (interactive == true)
  self.interactive = interactive == true
  self.show_current_line_highlight = self.interactive
  if changed then
    self:invalidate_line_render("fuzzy-preview-interaction")
    self:invalidate_visual_metrics("fuzzy-preview-interaction")
  end
end

function PreviewTextView:restore_preview_search_ranges()
  if not self.preview_search_ranges or next(self.buffer.search_selections) ~= nil then return end
  for _, range in ipairs(self.preview_search_ranges) do
    self.buffer:add_search_selection(range[1], range[2], range[3], range[4])
  end
end

function PreviewTextView:get_line_number_gutter_width()
  return self:get_font():get_width("00000")
end

function PreviewTextView:draw_line_gutter(line, x, y)
  local lh = self:get_line_height()
  if self:line_numbers_visible() then
    local color = style.line_number
    if self.interactive then
      for _, line1, _, line2 in self.buffer:get_selections(true) do
        if line >= line1 and line <= line2 then
          color = style.line_number2
          break
        end
      end
    end
    -- Preview gutters are fixed-width and left-aligned. The label stays
    -- anchored when the visible range changes from one to several digits.
    renderer.draw_text(
      self:get_font(), tostring(line), x + style.padding.x,
      y + self:get_line_text_y_offset(), color
    )
  end
  return lh
end

function PreviewTextView:get_font()
  return style.get_small_font(TextView.get_font(self))
end

local function close_detached(view)
  if view.textview_closed then return end
  local buffer = view.buffer
  TextView.on_close(view)
  if buffer and buffer.on_close then buffer:on_close() end
end

function PreviewTextView:on_close()
  close_detached(self)
end

-- This detached View uses the complete Editor presentation stack. It does not
-- retain its private Buffer in the normal Editor registry.
local MarkdownPreviewTextView = Editor:extend()

function MarkdownPreviewTextView:new(buffer)
  initialize(self, buffer, true)
  self.__fuzzy_markdown_preview = true
  require("core.markdown.live_render").refresh_view(self)
end

function MarkdownPreviewTextView:update()
  TextView.update(self)
end

MarkdownPreviewTextView.set_interactive = PreviewTextView.set_interactive
MarkdownPreviewTextView.restore_preview_search_ranges = PreviewTextView.restore_preview_search_ranges
MarkdownPreviewTextView.get_line_number_gutter_width = PreviewTextView.get_line_number_gutter_width
MarkdownPreviewTextView.draw_line_gutter = PreviewTextView.draw_line_gutter

function MarkdownPreviewTextView:get_line_render_selection_state()
  if self.interactive then return self:get_selection_state() end
  local selections = {}
  for _, range in ipairs(self.preview_search_ranges or {}) do
    selections[#selections + 1] = range[1]
    selections[#selections + 1] = range[2]
    selections[#selections + 1] = range[3]
    selections[#selections + 1] = range[4]
  end
  return { selections = selections, last_selection = 1 }
end

function MarkdownPreviewTextView:on_close()
  close_detached(self)
end

local M = {}

function M.new(buffer)
  local live = require "core.markdown.live_render"
  if live.is_markdown_buffer(buffer) then return MarkdownPreviewTextView(buffer) end
  return PreviewTextView(buffer)
end

return M
