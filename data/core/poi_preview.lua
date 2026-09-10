local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local tokenizer = require "core.tokenizer"

local M = {}
local previews = setmetatable({}, { __mode = "k" })
local provider_id = "core.poi-preview"

function M.for_view(view)
  return previews[view]
end

function M.dismiss(view)
  if not previews[view] then return false end
  previews[view] = nil
  view:remove_visual_row_provider(provider_id)
  view:remove_selection_listener(provider_id)
  core.redraw = true
  return true
end

local function draw_row(view, row, x, y, width, height)
  if row.tokens then
    renderer.draw_rect(x, y, width, height, row.background)
    local font = view:get_font()
    local _, indent_size = view.buffer:get_indent_info()
    font:set_tab_size(indent_size)
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
    renderer.draw_text(view:get_font(), row.text, x + style.padding.x, y, style.text)
  end
  if row.framed then
    local border = math.max(1, SCALE)
    renderer.draw_rect(x, y, border, height, style.divider)
    renderer.draw_rect(x + width - border, y, border, height, style.divider)
    if row.first then renderer.draw_rect(x, y, width, border, style.divider) end
    if row.last then renderer.draw_rect(x, y + height - border, width, border, style.divider) end
  end
end

function M.show(view, point, title, lines, options)
  M.dismiss(view)
  local preview = { line = point.line, title = title, lines = lines }
  previews[view] = preview
  local rows = options and options.code and {} or {
    { id = "title", text = title .. "  [Escape to close]", draw = draw_row },
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
    else
      row.text = row.text:gsub("\t", "    ")
    end
    rows[#rows + 1] = row
  end
  if options and options.code then
    for index, row in ipairs(rows) do
      row.framed = true
      row.first = index == 1
      row.last = index == #rows
    end
  end
  view:add_visual_row_provider(provider_id, {
    visual_rows = function(_, _, line, placement)
      if line == preview.line and placement == "after" then return rows end
    end,
  })
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
