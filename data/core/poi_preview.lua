local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"

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
  renderer.draw_rect(x, y, width, height, style.background2)
  renderer.draw_text(view:get_font(), row.text, x + style.padding.x, y, style.text)
end

function M.show(view, point, title, lines)
  M.dismiss(view)
  local preview = { line = point.line, title = title, lines = lines }
  previews[view] = preview
  local rows = {{ id = "title", text = title .. "  [Escape to close]", draw = draw_row }}
  for index, text in ipairs(lines) do
    if index > 24 then
      rows[#rows + 1] = { id = "more", text = "...", draw = draw_row }
      break
    end
    rows[#rows + 1] = {
      id = tostring(index), text = text:gsub("[\r\n]+$", ""):gsub("\t", "    "), draw = draw_row,
    }
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
