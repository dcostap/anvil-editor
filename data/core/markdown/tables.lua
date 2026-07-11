local core = require "core"
local model = require "core.markdown.model"

local tables = {}

local function line_text(doc, line)
  return (doc.lines[line] or ""):gsub("\n$", "")
end

local function effective_line2(node)
  local line2 = node.source.line2
  if node.source.col2 == 1 and line2 > node.source.line1 then line2 = line2 - 1 end
  return line2
end

local function pipe_positions(text)
  local positions = {}
  local escaped, ticks = false, 0
  local i = 1
  while i <= #text do
    local char = text:sub(i, i)
    if escaped then
      escaped = false
    elseif char == "\\" then
      escaped = true
    elseif char == "`" then
      local finish = i
      while text:sub(finish + 1, finish + 1) == "`" do finish = finish + 1 end
      local count = finish - i + 1
      if ticks == 0 then ticks = count elseif ticks == count then ticks = 0 end
      i = finish
    elseif char == "|" and ticks == 0 then
      positions[#positions + 1] = i
    end
    i = i + 1
  end
  return positions
end

local function canonical_row(text)
  local first = text:find("%S")
  local last = text:match("^.*()%S")
  if not first or text:sub(first, first) ~= "|" or text:sub(last, last) ~= "|" then return nil end
  local pipes = pipe_positions(text)
  if #pipes < 2 or pipes[1] ~= first or pipes[#pipes] ~= last then return nil end
  return { text = text, pipes = pipes, columns = #pipes - 1 }
end

function tables.context(view)
  local instance = view and view.doc and model.peek(view.doc)
  if not (instance and instance.status == "ready") then return nil, "semantic model unavailable" end
  local line, col = view.doc:get_selection()
  local nodes = instance:nodes_for_lines(line, line, { limit = 1024 })
  local table_node
  for _, node in ipairs(nodes or {}) do
    if node.type == "table" then table_node = node break end
  end
  if not table_node then return nil, "caret is outside a semantic table" end
  local line1, semantic_line2 = table_node.source.line1, effective_line2(table_node)
  if semantic_line2 <= line1 then return nil, "table range is incomplete" end
  local rows, columns = {}, nil
  for row_line = line1, semantic_line2 do
    local row = canonical_row(line_text(view.doc, row_line))
    if not row then
      if #rows > 0 then break end
      return nil, "table row is not canonical"
    end
    if columns and row.columns ~= columns then
      core.log_quiet("Markdown table command declined inconsistent row at %s:%d", view.doc:get_name(), row_line)
      return nil, "table columns are inconsistent"
    end
    columns = columns or row.columns
    row.line = row_line
    rows[#rows + 1] = row
  end
  local line2 = rows[#rows] and rows[#rows].line or line1
  local current = rows[line - line1 + 1]
  if not current then return nil, "caret row is unavailable" end
  local column = columns
  for i = 1, columns do
    if col <= current.pipes[i + 1] then column = i break end
  end
  return {
    view = view, doc = view.doc, node = table_node,
    line = line, col = col, line1 = line1, line2 = line2,
    delimiter_line = line1 + 1, rows = rows, columns = columns, column = column,
  }
end

local function apply_line_replacements(context, replacements, reason)
  local edits = {}
  for line, text in pairs(replacements) do
    edits[#edits + 1] = {
      line1 = line, col1 = 1, line2 = line, col2 = #line_text(context.doc, line) + 1,
      text = text,
    }
  end
  table.sort(edits, function(a, b) return a.line1 < b.line1 end)
  context.doc:apply_edits(edits, { type = "markdown-table", reason = reason })
  return true
end

function tables.insert_row(view)
  local context = tables.context(view)
  if not context then return false end
  local after = math.max(context.line, context.delimiter_line)
  local row = "|" .. string.rep("  |", context.columns) .. "\n"
  context.doc:insert(after + 1, 1, row)
  context.doc:set_selection(after + 1, 3)
  return true
end

function tables.delete_row(view)
  local context = tables.context(view)
  if not context or context.line <= context.delimiter_line then return false end
  local line = context.line
  context.doc:remove(line, 1, line + 1, 1)
  context.doc:set_selection(math.min(line, #context.doc.lines), 1)
  return true
end

function tables.move_row(view, direction)
  local context = tables.context(view)
  if not context or context.line <= context.delimiter_line then return false end
  local target = context.line + direction
  if target <= context.delimiter_line or target > context.line2 then return false end
  local first, second = math.min(context.line, target), math.max(context.line, target)
  local first_text, second_text = context.doc.lines[first], context.doc.lines[second]
  context.doc:apply_edits({
    { line1 = first, col1 = 1, line2 = second + 1, col2 = 1, text = second_text .. first_text },
  }, { type = "markdown-table", reason = "move-row" })
  context.doc:set_selection(target, context.col)
  return true
end

function tables.insert_column(view)
  local context = tables.context(view)
  if not context then return false end
  local replacements = {}
  for _, row in ipairs(context.rows) do
    local insertion = row.pipes[context.column + 1]
    local value = row.line == context.delimiter_line and " --- |" or "  |"
    replacements[row.line] = row.text:sub(1, insertion) .. value .. row.text:sub(insertion + 1)
  end
  apply_line_replacements(context, replacements, "insert-column")
  context.doc:set_selection(context.line, context.rows[context.line - context.line1 + 1].pipes[context.column + 1] + 3)
  return true
end

function tables.delete_column(view)
  local context = tables.context(view)
  if not context or context.columns <= 1 then return false end
  local replacements = {}
  for _, row in ipairs(context.rows) do
    local left, right = row.pipes[context.column], row.pipes[context.column + 1]
    replacements[row.line] = row.text:sub(1, left) .. row.text:sub(right + 1)
  end
  apply_line_replacements(context, replacements, "delete-column")
  context.doc:set_selection(context.line, math.max(1, context.rows[context.line - context.line1 + 1].pipes[context.column]))
  return true
end

function tables.move_column(view, direction)
  local context = tables.context(view)
  if not context then return false end
  local target = context.column + direction
  if target < 1 or target > context.columns then return false end
  local a, b = math.min(context.column, target), math.max(context.column, target)
  local replacements = {}
  for _, row in ipairs(context.rows) do
    local cells = {}
    for i = 1, context.columns do
      cells[i] = row.text:sub(row.pipes[i] + 1, row.pipes[i + 1] - 1)
    end
    cells[a], cells[b] = cells[b], cells[a]
    local parts = { row.text:sub(1, row.pipes[1]) }
    for i = 1, context.columns do
      parts[#parts + 1] = cells[i]
      parts[#parts + 1] = "|"
    end
    parts[#parts + 1] = row.text:sub(row.pipes[#row.pipes] + 1)
    replacements[row.line] = table.concat(parts)
  end
  apply_line_replacements(context, replacements, "move-column")
  context.doc:set_selection(context.line, context.rows[context.line - context.line1 + 1].pipes[target] + 2)
  return true
end

return tables
