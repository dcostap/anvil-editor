-- Format SQL: DbVisualizer's default layout for the selected lines, or for the
-- Buffer without a selection. The change is one undo step.
local core = require "core"
local style = require "core.style"
local native = require "sql_server_native"

local M = {}

-- The line ranges of the selections, joined where they overlap.
local function selected_ranges(buffer)
  local ranges = {}
  for _, line1, col1, line2, col2 in buffer:get_selections(true) do
    if line1 ~= line2 or col1 ~= col2 then
      if col2 == 1 and line2 > line1 then line2 = line2 - 1 end
      ranges[#ranges + 1] = { line1, line2 }
    end
  end
  table.sort(ranges, function(a, b) return a[1] < b[1] end)
  local joined = {}
  for _, r in ipairs(ranges) do
    local last = joined[#joined]
    if last and r[1] <= last[2] + 1 then last[2] = math.max(last[2], r[2]) else joined[#joined + 1] = r end
  end
  return joined
end

function M.format(view)
  local buffer = view.buffer
  if buffer.read_only then
    core.status_bar:show_message("!", style.warn, buffer.read_only_reason or "This Buffer is read-only.")
    return false
  end
  local tab_type, size = buffer:get_indent_info()
  local indent = tab_type == "hard" and "\t" or string.rep(" ", size)
  local ranges = selected_ranges(buffer)
  if #ranges == 0 then ranges[1] = { 1, #buffer.lines } end
  local lines, next_line = {}, 1
  for _, r in ipairs(ranges) do
    for i = next_line, r[1] - 1 do lines[#lines + 1] = buffer.lines[i] end
    local text, err = native.format(table.concat(buffer.lines, "", r[1], r[2]), indent)
    if not text then
      core.status_bar:show_message("!", style.warn, err)
      return false
    end
    for line in text:gmatch("[^\n]*\n") do lines[#lines + 1] = line end
    local rest = text:match("[^\n]*$")
    if rest ~= "" then lines[#lines + 1] = rest .. "\n" end
    next_line = r[2] + 1
  end
  for i = next_line, #buffer.lines do lines[#lines + 1] = buffer.lines[i] end
  local tx = buffer:apply_lines(lines, "format")
  core.log_quiet("SQL format changed %d ranges with %d edits", #ranges, #tx.edits)
  return true
end

return M
