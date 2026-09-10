local M = {}

local function content_lines(lines)
  -- Match the Diff View's empty Buffer convention.
  if #lines == 1 and lines[1] == "\n" then return {} end
  return lines
end

local function label(name, side)
  name = tostring(name):gsub("\\", "/")
  local path = side .. "/" .. name
  if path:find('[%c"]') then
    path = '"' .. path:gsub('[%c"]', function(char)
      if char == '"' then return '\\"' end
      return string.format("\\%03o", char:byte())
    end) .. '"'
  end
  return path
end

---Build a unified patch from current Buffer lines, independent of display filters.
-- A scope selects complete change blocks on one side, before adding context.
-- Its intervals are inclusive line ranges in that side's current Buffer.
function M.build(before, after, before_name, after_name, scope)
  local rows, ranges = {}, {}
  local old_line, new_line = 1, 1
  local function append(prefix, text)
    rows[#rows + 1] = { prefix = prefix, text = text, old = old_line, new = new_line }
    if prefix ~= "+" then old_line = old_line + 1 end
    if prefix ~= "-" then new_line = new_line + 1 end
  end
  for edit in diff.diff_iter(content_lines(before), content_lines(after)) do
    if edit.tag == "equal" then
      append(" ", edit.a)
    else
      if edit.a then append("-", edit.a) end
      if edit.b then append("+", edit.b) end
    end
  end
  if scope then
    local filtered = {}
    local side = scope.side == "left" and "old" or "new"
    local count = scope.side == "left" and #before or #after
    local i = 1
    while i <= #rows do
      if rows[i].prefix == " " then
        filtered[#filtered + 1] = rows[i]
        i = i + 1
      else
        local last = i
        while rows[last + 1] and rows[last + 1].prefix ~= " " do last = last + 1 end
        local first_line = math.min(count, rows[i][side])
        local next_line = rows[last][side]
        local consumes = side == "old" and rows[last].prefix ~= "+"
          or side == "new" and rows[last].prefix ~= "-"
        local last_line = math.min(count, math.max(first_line, next_line - (consumes and 0 or 1)))
        local selected = false
        for _, interval in ipairs(scope.intervals) do
          if first_line <= interval[2] and last_line >= interval[1] then selected = true; break end
        end
        for index = i, last do
          local row = rows[index]
          if selected then
            filtered[#filtered + 1] = row
          elseif row.prefix == "-" then
            -- Excluded changes leave the original text intact in the patch.
            filtered[#filtered + 1] = { prefix = " ", text = row.text }
          end
        end
        i = last + 1
      end
    end
    rows = filtered
    old_line, new_line = 1, 1
    for _, row in ipairs(rows) do
      row.old, row.new = old_line, new_line
      if row.prefix ~= "+" then old_line = old_line + 1 end
      if row.prefix ~= "-" then new_line = new_line + 1 end
    end
  end
  for i, row in ipairs(rows) do
    if row.prefix ~= " " then
      local first, last = math.max(1, i - 3), math.min(#rows, i + 3)
      local previous = ranges[#ranges]
      if previous and first <= previous.last + 1 then
        previous.last = last
      else
        ranges[#ranges + 1] = { first = first, last = last }
      end
    end
  end
  if #ranges == 0 then return nil end
  local output = { "--- " .. label(before_name, "a") .. "\n", "+++ " .. label(after_name, "b") .. "\n" }
  for _, range in ipairs(ranges) do
    local old_count, new_count = 0, 0
    for i = range.first, range.last do
      if rows[i].prefix ~= "+" then old_count = old_count + 1 end
      if rows[i].prefix ~= "-" then new_count = new_count + 1 end
    end
    local first = rows[range.first]
    output[#output + 1] = string.format("@@ -%d,%d +%d,%d @@\n",
      first.old - (old_count == 0 and 1 or 0), old_count,
      first.new - (new_count == 0 and 1 or 0), new_count)
    for i = range.first, range.last do
      local row = rows[i]
      output[#output + 1] = row.prefix .. row.text
      if row.text:sub(-1) ~= "\n" then
        output[#output + 1] = "\n\\ No newline at end of file\n"
      end
    end
  end
  return table.concat(output)
end

return M
