local Buffer = require "core.buffer"
local TextView = require "core.textview"
local common = require "core.common"
local panes = require "core.panes"

local TextCaptureView = TextView:extend()

function TextCaptureView:__tostring() return "TextCaptureView" end

function TextCaptureView:new(capture)
  capture = capture or {}
  local buffer = Buffer()
  buffer.display_name = capture.display_name or "Text Capture"
  buffer:insert(1, 1, tostring(capture.text or ""))
  buffer:clear_undo_redo()
  buffer:clean()

  TextCaptureView.super.new(self, buffer)
  self.context = "workspace"
  self.text_capture = true
  self.text_capture_title = capture.title or buffer.display_name
  self.text_capture_data = capture
  if capture.font then self.font = capture.font end
  if capture.show_line_numbers ~= nil then
    self.show_line_numbers = capture.show_line_numbers == true
  end
  if capture.wrapping == false then self:set_wrapping_enabled(false) end

  local line = common.clamp(
    math.floor(tonumber(capture.cursor_line) or 1), 1, #buffer.lines
  )
  local col = common.clamp(
    math.floor(tonumber(capture.cursor_col) or 1), 1, #buffer.lines[line]
  )
  buffer:set_selection(line, col)
  buffer.read_only = true
  buffer.read_only_reason = capture.read_only_reason or "Text captures are read-only"

  local viewport_line = common.clamp(
    math.floor(tonumber(capture.viewport_line) or 1), 1, #buffer.lines
  )
  self.scroll.y = (viewport_line - 1) * self:get_line_height()
  self.scroll.to.y = self.scroll.y
end

function TextCaptureView:get_name()
  return self.text_capture_title or "Text Capture"
end

function TextCaptureView:duplicate()
  local line, col = self.buffer:get_selection()
  local capture = {}
  for key, value in pairs(self.text_capture_data or {}) do capture[key] = value end
  capture.text = table.concat(self.buffer.lines)
  capture.cursor_line = line
  capture.cursor_col = col
  capture.viewport_line = math.floor(self.scroll.y / self:get_line_height()) + 1
  local duplicate = TextCaptureView(capture)
  duplicate.scroll.x, duplicate.scroll.y = self.scroll.x, self.scroll.y
  duplicate.scroll.to.x, duplicate.scroll.to.y = self.scroll.to.x, self.scroll.to.y
  return duplicate
end

local M = {
  View = TextCaptureView,
}

function M.open(capture, opts)
  opts = opts or {}
  return panes.place(function() return TextCaptureView(capture) end, {
    pane = opts.pane,
    placement = opts.placement or "current",
    direction = opts.direction,
    focus = opts.focus ~= false,
    reason = opts.reason or "text-capture",
  })
end

return M
