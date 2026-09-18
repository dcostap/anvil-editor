local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local tokenizer = require "core.tokenizer"
local TextView = require "core.textview"

local M = {}
local previews = setmetatable({}, { __mode = "k" })
local provider_id = "core.poi-preview"

local function draw_frame(x, y, width, height)
  local bottom = y + height
  local size = math.max(1, math.ceil(style.poi_preview_shadow_size))
  local source = style.poi_preview_shadow
  local color = { source[1], source[2], source[3], 0 }
  for offset = 1, size do
    local fade = 1 - (offset - 1) / size
    color[4] = math.floor(source[4] * fade * fade + 0.5)
    renderer.draw_rect(x - offset, y - offset, width + offset * 2, 1, color)
    renderer.draw_rect(x - offset, bottom + offset - 1, width + offset * 2, 1, color)
    renderer.draw_rect(x - offset, y - offset + 1, 1, bottom - y + offset * 2 - 2, color)
    renderer.draw_rect(x + width + offset - 1, y - offset + 1, 1, bottom - y + offset * 2 - 2, color)
  end
  local border = math.max(1, SCALE)
  renderer.draw_rect(x, y, width, border, style.divider)
  renderer.draw_rect(x, bottom - border, width, border, style.divider)
  renderer.draw_rect(x, y, border, height, style.divider)
  renderer.draw_rect(x + width - border, y, border, height, style.divider)
end

local draw_overlay = TextView.draw_overlay
function TextView:draw_overlay(...)
  local result = draw_overlay(self, ...)
  local preview = previews[self]
  if not preview then return result end
  -- Draw after all text rows so adjacent line backgrounds cannot erase the shadow.
  for entry in self:iter_visible_visual_rows() do
    local row = entry.provider_row
    if row and row.preview == preview then
      local x = self:get_content_offset() + self:get_gutter_width()
      local first = entry.visual_row - row.index + 1
      local top = self:get_visual_row_y_offset(first)
      local y = entry.y - (self:get_visual_row_y_offset(entry.visual_row) - top)
      local width = math.max(0, self.size.x - self:get_gutter_width())
      local bottom = y + self:get_visual_row_y_offset(first + preview.row_count) - top
      draw_frame(x, y, width, bottom - y)
      break
    end
  end
  return result
end

function M.for_view(view)
  return previews[view]
end

function M.dismiss(view)
  local preview = previews[view]
  if not preview then return false end
  previews[view] = nil
  view:remove_visual_row_provider(provider_id)
  view:remove_visual_metric_provider(provider_id)
  view:remove_decoration_provider(provider_id)
  view:remove_selection_listener(provider_id)
  view:remove_owned_feature(provider_id)
  if preview.content then preview.content:on_close() end
  core.redraw = true
  return true
end

local function draw_row(view, row, x, y, width, height)
  if row.content then
    renderer.draw_rect(x, y, width, height, style.background2)
    row.content:draw(x + style.padding.x, y + style.padding.y,
      math.max(1, width - style.padding.x * 2), math.max(1, height - style.padding.y * 2))
  elseif row.tokens then
    renderer.draw_rect(x, y, width, height, row.background)
    local font = view:get_font()
    local _, indent_size = view.buffer:get_indent_info()
    font:set_tab_size(indent_size)
    for _, range in ipairs(row.inline_ranges or {}) do
      local left = font:get_width(row.text:sub(1, range.col1 - 1))
      local right = font:get_width(row.text:sub(1, range.col2 - 1))
      renderer.draw_rect(x + left, y, right - left, height, style.diff_modify_inline)
    end
    -- Provider rows already receive the scrolled text origin. Keep code
    -- previews aligned with the source line instead of adding another offset.
    local tx = x
    local origin = tx
    local ty = y + (height - font:get_height()) / 2
    for _, kind, text in tokenizer.each_token(row.tokens) do
      tx = renderer.draw_text(font, text, tx, ty, style.syntax[kind] or style.text,
        { tab_offset = tx - origin })
    end
  else
    renderer.draw_rect(x, y, width, height, style.background2)
    local font = row.title and style.font or view:get_font()
    core.push_clip_rect(x, y, width, height)
    renderer.draw_text(font, row.text, x + style.padding.x,
      y + (height - font:get_height()) / 2, row.title and style.dim or style.text)
    core.pop_clip_rect()
  end
end

-- All content shares the card frame and lifetime. Custom content supplies
-- layout(width, max_height), draw(x, y, width, height), and on_close().
function M.show(view, point, title, lines, options)
  M.dismiss(view)
  local preview = { line = point.line, title = title, lines = lines,
    content = options and options.content,
    placement = options and options.placement or "after" }
  previews[view] = preview
  local rows = options and options.code and {} or {
    { id = "title", title = true, text = title, draw = draw_row },
  }
  local token_state
  for index, text in ipairs(lines) do
    if index > 24 then
      rows[#rows + 1] = { id = "more", text = "...", draw = draw_row }
      break
    end
    local row = { id = tostring(index), text = text:gsub("[\r\n]+$", ""), draw = draw_row }
    if options and options.code then
      row.tokens, token_state = tokenizer.tokenize(view.buffer.syntax, row.text .. "\n", token_state)
      -- Keep newline tokens out of the renderer without changing lexer state.
      for i = 2, #row.tokens, 2 do row.tokens[i] = row.tokens[i]:gsub("[\r\n]+$", "") end
      row.background = style.diff_delete_background
      local change = options.changes and options.changes[index]
      row.inline_ranges = change and change.inline_ranges
    else
      row.text = row.text:gsub("\t", "    ")
    end
    rows[#rows + 1] = row
  end
  if preview.content then
    rows[#rows + 1] = { id = "content", content = preview.content, draw = draw_row }
  end
  preview.row_count = #rows
  for index, row in ipairs(rows) do
    row.preview, row.index = preview, index
  end
  local function layout()
    if not preview.content then return 0 end
    -- Measurement and drawing must use the same centered content width.
    local width = math.max(1,
      view:get_presentation_viewport_width() - view:get_gutter_width() - style.padding.x * 2)
    local limit = math.max(view:get_line_height(), math.min(view.size.y / 2, view:get_line_height() * 12))
    local height = preview.content:layout(width, limit) + style.padding.y * 2
    rows[#rows].height = height
    return table.concat({ width, height, style.font:get_height() }, ":")
  end
  view:add_visual_row_provider(provider_id, {
    generation = layout,
    visual_rows = function(_, _, line, placement)
      if line == preview.line and placement == preview.placement then return rows end
    end,
  })
  if preview.content then
    view:add_visual_metric_provider(provider_id, {
      -- Card rows own their height, regardless of the source line's presentation.
      priority = 100,
      generation = layout,
      line_height = function(_, _, _, entry)
        local row = entry.provider_row
        if row and row.preview == preview then
          return row.height or (style.font:get_height() + style.padding.y)
        end
      end,
    })
  end
  view:add_owned_feature(provider_id, { on_release = function() M.dismiss(view) end })
  if options and options.current_changes then
    view:add_decoration_provider(provider_id, {
      line_background = function(_, _, line)
        local change = options.current_changes[line - options.current_start + 1]
        if change and change.tag ~= "equal" then return style.diff_insert_background end
      end,
      inline_ranges = function(_, _, line)
        local change = options.current_changes[line - options.current_start + 1]
        if not change or not change.inline_ranges then return nil end
        local ranges = {}
        for _, range in ipairs(change.inline_ranges) do
          ranges[#ranges + 1] = {
            col1 = range.col1, col2 = range.col2, color = style.diff_modify_inline,
          }
        end
        return ranges
      end,
    })
  end
  view:add_selection_listener(provider_id, function(_, state)
    if state.selections[1] ~= preview.line then M.dismiss(view) end
  end)
  core.log_quiet("POI preview shown: %s", title)
  core.redraw = true
  return true
end

function M.location(view, point)
  local target = point.target_buffer
  if not target and point.path then
    for _, buffer in ipairs(core.buffers) do
      if buffer.abs_filename and common.path_equals(buffer.abs_filename, point.path) then
        target = buffer
        break
      end
    end
  end
  local line = math.max(1, point.target_line or 1)
  local path = point.path or (target and (target.abs_filename or target.filename))
  local markdown = require "core.markdown.live_render"
  if markdown.is_markdown_buffer(target or { filename = path }) then
    local text
    if target then
      text = table.concat(target.lines)
    elseif path then
      local info = system.get_file_info(path)
      if info and info.type == "file" and info.size <= 1024 * 1024 then
        local file = io.open(path, "rb")
        if file then
          text = file:read("*a")
          file:close()
        end
      end
    end
    local title = common.basename(path or target:get_name())
    if not text or #text > 1024 * 1024 then
      return M.show(view, point, title, { "Preview unavailable" })
    end
    local content = require("core.markdown.preview")(path or title, text:gsub("\r\n", "\n"), line)
    return M.show(view, point, title, {}, { content = content })
  end
  local first, last = math.max(1, line - 3), line + 3
  local lines = {}
  if target then
    for index = first, math.min(last, #target.lines) do
      lines[#lines + 1] = string.format("%s %d  %s", index == line and ">" or " ", index, target.lines[index])
    end
  elseif point.path then
    local info = system.get_file_info(point.path)
    if not info or info.type ~= "file" or info.size > 1024 * 1024 then
      return M.show(view, point, point.path, { "Preview unavailable" })
    end
    local file = io.open(point.path, "rb")
    if not file then return M.show(view, point, point.path, { "Preview unavailable" }) end
    local index = 0
    for text in file:lines() do
      index = index + 1
      if index >= first then
        lines[#lines + 1] = string.format("%s %d  %s", index == line and ">" or " ", index, text)
      end
      if index >= last then break end
    end
    file:close()
  else
    return false
  end
  return M.show(view, point, point.path or target:get_name(), lines)
end

command.add(function()
  local view = core.active_view
  return previews[view] ~= nil, view
end, {
  ["core:dismiss_point_of_interest_preview"] = function(view) M.dismiss(view) end,
})
keymap.add { ["escape"] = "core:dismiss_point_of_interest_preview" }

return M
