local core = require "core"
local common = require "core.common"
local translate = require "core.buffer.translate"
local model = require "core.markdown.model"

local tables = {}
local collect_interactive_contexts
local source_indexes = setmetatable({}, { __mode = "k" })

tables.MAX_PRESENTATION_ROWS = 256
tables.MAX_PRESENTATION_COLUMNS = 64

local function line_text(buffer, line)
  return (buffer.lines[line] or ""):gsub("\n$", "")
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

local function cell_content_bounds(text, col1, col2)
  local raw = text:sub(col1, col2 - 1)
  local leading = #(raw:match("^%s*") or "")
  local trailing = #(raw:match("%s*$") or "")
  if leading + trailing >= #raw then
    local point = common.clamp(col1 + math.floor(#raw / 2), col1, col2)
    return point, point
  end
  return col1 + leading, col2 - trailing
end

local function source_row(text)
  local pipes = pipe_positions(text)
  if #pipes == 0 then return nil end
  local first = text:find("%S")
  local last = text:match("^.*()%S")
  local outer_left = first and pipes[1] == first
  local outer_right = last and pipes[#pipes] == last
  local cells = {}
  local start = outer_left and pipes[1] + 1 or 1
  local first_separator = outer_left and 2 or 1
  local last_separator = #pipes
  for index = first_separator, last_separator do
    local finish = pipes[index]
    local content_col1, content_col2 = cell_content_bounds(text, start, finish)
    cells[#cells + 1] = {
      col1 = start, col2 = finish,
      content_col1 = content_col1, content_col2 = content_col2,
    }
    start = finish + 1
  end
  if not outer_right then
    local finish = #text + 1
    local content_col1, content_col2 = cell_content_bounds(text, start, finish)
    cells[#cells + 1] = {
      col1 = start, col2 = finish,
      content_col1 = content_col1, content_col2 = content_col2,
    }
  end
  if #cells == 0 then return nil end
  local separators = {}
  if outer_left then
    separators[#separators + 1] = { col1 = 1, col2 = pipes[1] + 1 }
  else
    separators[#separators + 1] = { col1 = 1, col2 = 1 }
  end
  for index = first_separator, last_separator do
    local pipe = pipes[index]
    separators[#separators + 1] = { col1 = pipe, col2 = pipe + 1 }
  end
  if not outer_right then
    separators[#separators + 1] = { col1 = #text + 1, col2 = #text + 1 }
  elseif separators[#separators].col1 ~= pipes[#pipes] then
    separators[#separators + 1] = {
      col1 = pipes[#pipes], col2 = #text + 1,
    }
  end
  return {
    text = text, pipes = pipes, cells = cells,
    separators = separators, columns = #cells,
    canonical = outer_left and outer_right,
  }
end

local function delimiter_row(row)
  if not row then return false end
  for _, cell in ipairs(row.cells) do
    local marker = row.text:sub(cell.content_col1, cell.content_col2 - 1)
    if not marker:match("^:?-+:?$") then return false end
  end
  return true
end

local function source_index(buffer)
  local revision = buffer.text_revision or 0
  local line_count = #buffer.lines
  local cached = source_indexes[buffer]
  if cached and cached.revision == revision and cached.line_count == line_count then
    return cached
  end

  -- Parse each source line once.  Table discovery is queried from rendering,
  -- hit testing, selection handling, and metric calculation, so searching
  -- around the requested line (the old implementation) multiplies this work
  -- by the number of visual rows in the buffer.
  local rows = {}
  for line = 1, line_count do
    local row = source_row(line_text(buffer, line))
    if row then
      -- Keep the index compact. Full cell bounds are only needed by the
      -- presentation parser and by the uncommon empty-row extension path.
      rows[line] = {
        columns = row.columns,
        delimiter = delimiter_row(row),
      }
    end
  end

  local by_line = {}
  for delimiter_line = 2, line_count do
    local delimiter = rows[delimiter_line]
    local header = rows[delimiter_line - 1]
    if delimiter and delimiter.delimiter and header
    and header.columns == delimiter.columns
    then
      local line2 = delimiter_line
      for body_line = delimiter_line + 1, math.min(line_count, delimiter_line + 255) do
        local body = rows[body_line]
        if not body or body.columns ~= header.columns then break end
        line2 = body_line
      end
      local line1 = delimiter_line - 1
      local table_range = {
        line1 = line1, line2 = line2,
        delimiter_line = delimiter_line, columns = header.columns,
      }
      -- Preserve the old search order: the first matching delimiter wins for
      -- a line when malformed source produces overlapping candidates.
      for line = line1, line2 do
        if line ~= delimiter_line and by_line[line] == nil then
          by_line[line] = table_range
        end
      end
    end
  end

  cached = {
    revision = revision, line_count = line_count,
    rows = rows, by_line = by_line,
  }
  source_indexes[buffer] = cached
  return cached
end

local function source_table_bounds(buffer, line)
  local table_range = source_index(buffer).by_line[line]
  if table_range then
    return table_range.line1, table_range.line2
  end
end

local function source_row_at(buffer, line)
  return source_row(line_text(buffer, line))
end

---Parse one Markdown table source row.
---The parsed row is shared by table commands and Markdown Live Preview so
---table discovery and presentation cannot drift into separate parsers.
function tables.source_row(text)
  return source_row(tostring(text or ""))
end

local function source_line_in_fence_or_frontmatter(buffer, target)
  if line_text(buffer, 1):match("^%s*%-%-%-%s*$") then
    for line = 2, target do
      if line_text(buffer, line):match("^%s*%-%-%-%s*$") then return false end
    end
    return target > 1
  end
  local marker, count
  for line = 1, target do
    local text = line_text(buffer, line)
    if marker then
      if line == target then return true end
      local run = text:match("^%s*(" .. marker .. "+)")
      if run and #run >= count then marker, count = nil, nil end
    else
      local run = text:match("^%s*(```+)") or text:match("^%s*(~~~+)")
      if run then
        marker, count = run:sub(1, 1), #run
        if line == target then return true end
      end
    end
  end
  return marker ~= nil
end

function tables.source_bounds(view, line)
  if not (view and view.buffer and line) then return nil end
  return source_table_bounds(view.buffer, line)
end

local function source_row_is_empty(row)
  if not row then return false end
  for _, cell in ipairs(row.cells) do
    if cell.content_col1 ~= cell.content_col2 then return false end
  end
  return true
end

---Extend a real semantic table across canonical all-empty body rows that the
---Markdown parser treats as a table terminator. The extension is allowed only
---when a current semantic table owns the same header, so source lookalikes in
---fences and other raw blocks remain excluded.
function tables.extend_semantic_table(view, line, table_node)
  if not (view and view.buffer and line) then return table_node end
  local line1, source_line2 = source_table_bounds(view.buffer, line)
  if not line1 then return table_node end
  local instance = model.peek(view.buffer)
  if not (instance and instance.status == "ready"
    and instance.published_revision == view.buffer.text_revision)
  then
    return table_node
  end
  if not table_node then
    local nodes = instance:nodes_for_lines(line1, line1, { limit = 1024 })
    for _, node in ipairs(nodes or {}) do
      if node.type == "table" and node.source.line1 == line1 then
        table_node = node
        break
      end
    end
  end
  if not table_node or table_node.source.line1 ~= line1 then return table_node end
  local semantic_line2 = effective_line2(table_node)
  if source_line2 <= semantic_line2 then return table_node end
  local has_empty_body_row = false
  for row_line = semantic_line2 + 1, source_line2 do
    if source_row_is_empty(source_row_at(view.buffer, row_line)) then
      has_empty_body_row = true
      break
    end
  end
  if not has_empty_body_row then return table_node end
  local extended = {}
  for key, value in pairs(table_node) do extended[key] = value end
  extended.source = {}
  for key, value in pairs(table_node.source or {}) do extended.source[key] = value end
  extended.id = table.concat({
    tostring(table_node.id), "empty-row-extension", tostring(view.buffer.text_revision),
    tostring(source_line2),
  }, ":")
  extended.source.line2 = source_line2
  extended.source.col2 = #line_text(view.buffer, source_line2) + 1
  return extended
end

local function context_at(view, line, col, require_canonical)
  local instance = view and view.buffer and model.peek(view.buffer)
  if not (view and view.buffer) then return nil, "view is unavailable" end
  if not line then line, col = view.buffer:get_selection() end
  if not col then col = select(2, view.buffer:get_selection()) end
  local semantic_current = instance and instance.status == "ready"
    and instance.published_revision == view.buffer.text_revision
  local nodes = semantic_current
    and instance:nodes_for_lines(line, line, { limit = 1024 }) or nil
  local table_node
  for _, node in ipairs(nodes or {}) do
    if node.type == "table" then table_node = node break end
  end
  if semantic_current then
    table_node = tables.extend_semantic_table(view, line, table_node)
  end
  local line1, line2
  if table_node then
    line1, line2 = table_node.source.line1, effective_line2(table_node)
  elseif view.__markdown_live_attached and not semantic_current
    and not source_line_in_fence_or_frontmatter(view.buffer, line)
  then
    line1, line2 = source_table_bounds(view.buffer, line)
    if line1 then
      table_node = {
        id = "interactive-table:" .. line1,
        source = { line1 = line1, col1 = 1, line2 = line2, col2 = #line_text(view.buffer, line2) + 1 },
      }
    end
  end
  if not table_node then return nil, "caret is outside a semantic table" end
  if line2 <= line1 then return nil, "table range is incomplete" end
  if line2 - line1 + 1 > tables.MAX_PRESENTATION_ROWS then
    return nil, "table exceeds interactive row limit"
  end
  local rows, columns = {}, nil
  for row_line = line1, line2 do
    local row = source_row(line_text(view.buffer, row_line))
    if not row then return nil, "table row is unavailable" end
    if require_canonical and not row.canonical then
      return nil, "table row is not canonical"
    end
    if columns and row.columns ~= columns then
      core.log_quiet("Markdown table command declined inconsistent row at %s:%d", view.buffer:get_name(), row_line)
      return nil, "table columns are inconsistent"
    end
    columns = columns or row.columns
    if columns > tables.MAX_PRESENTATION_COLUMNS then
      return nil, "table exceeds interactive column limit"
    end
    row.line = row_line
    rows[#rows + 1] = row
  end
  local current = rows[line - line1 + 1]
  if not current or line == line1 + 1 then return nil, "caret row is unavailable" end
  local column = columns
  for index, cell in ipairs(current.cells) do
    if col <= cell.col2 then column = index break end
  end
  local editable_rows = { rows[1] }
  for index = 3, #rows do editable_rows[#editable_rows + 1] = rows[index] end
  local grid_row
  for index, row in ipairs(editable_rows) do
    if row.line == line then grid_row = index break end
  end
  if not grid_row then return nil, "caret row is unavailable" end
  return {
    view = view, buffer = view.buffer, node = table_node,
    line = line, col = col, line1 = line1, line2 = line2,
    delimiter_line = line1 + 1, rows = rows, editable_rows = editable_rows,
    columns = columns, column = column, grid_row = grid_row,
    cell = current.cells[column], current_row = current,
  }
end

function tables.context(view)
  local line, col = view.buffer:get_selection()
  return context_at(view, line, col, true)
end

function tables.interactive_context(view, line, col)
  return context_at(view, line, col, false)
end

function tables.has_interactive_context(view)
  if not (view and view.buffer) then return false end
  local contexts = collect_interactive_contexts(view)
  return contexts ~= nil
end

function tables.has_command_context(view)
  return tables.context(view) ~= nil
end

function tables.has_interactive_position(view, x, y)
  if not (view and type(x) == "number" and type(y) == "number") then
    return false
  end
  local line, col = view:resolve_screen_position(x, y)
  return context_at(view, line, col, false) ~= nil
end

local function selection_for_cell(row, column)
  local cell = row and row.cells[column]
  if not cell then return nil end
  return { row.line, cell.content_col2, row.line, cell.content_col1 }
end

local function same_table(a, b)
  return a and b and a.line1 == b.line1 and a.line2 == b.line2
end

collect_interactive_contexts = function(view)
  local contexts = {}
  local first
  for selection_index, line, col, anchor_line, anchor_col in
    view.buffer:get_selections(false)
  do
    local context = context_at(view, line, col, false)
    local anchor = context_at(view, anchor_line, anchor_col, false)
    if not context or not anchor
    or not same_table(context, anchor)
    or context.grid_row ~= anchor.grid_row
    or context.column ~= anchor.column
    or first and not same_table(first, context)
    then
      return nil
    end
    context.selection_index = selection_index
    first = first or context
    contexts[#contexts + 1] = context
  end
  return contexts, first
end

local function structure_refresher(context)
  for _, line in ipairs({ context.line, context.line1, context.line2 }) do
    local render = context.view:get_line_render(line)
    if render and render.on_table_structure_changed then
      return render.on_table_structure_changed
    end
  end
end

local function refresh_structure(context, refresh, line1, line2)
  if not refresh then return end
  local ok, err = pcall(refresh, context.view, line1, line2)
  if not ok then
    core.log_quiet(
      "Markdown interactive table refresh failed for %s:%d: %s",
      context.buffer:get_name(), line1, tostring(err)
    )
  end
end

local function insert_source_row(buffer, line, text)
  if line <= #buffer.lines then
    buffer:insert(line, 1, text)
    return line
  end
  local last = #buffer.lines
  local current = buffer.lines[last] or "\n"
  local row = tostring(text or ""):gsub("\n$", "")
  -- Buffer lines retain their newline terminator. Insert a newline plus the
  -- new row immediately before the final terminator instead of asking
  -- Buffer:insert for an out-of-range line, which intentionally clamps.
  buffer:insert(last, #current, "\n" .. row)
  return last + 1
end

local function append_body_row(context)
  local refresh = structure_refresher(context)
  local text = "|" .. string.rep("  |", context.columns) .. "\n"
  local inserted_line = insert_source_row(context.buffer, context.line2 + 1, text)
  local row = source_row(text:gsub("\n$", ""))
  row.line = inserted_line
  refresh_structure(context, refresh, context.line1, inserted_line)
  return row
end

function tables.navigate(view, direction)
  local contexts, first = collect_interactive_contexts(view)
  if not contexts then return false end
  local append = false
  local targets = {}
  for index, context in ipairs(contexts) do
    local row, column = context.grid_row, context.column
    if direction == "next" then
      column = column + 1
      if column > context.columns then row, column = row + 1, 1 end
      if row > #context.editable_rows then append = true end
    elseif direction == "previous" then
      column = column - 1
      if column < 1 then row, column = row - 1, context.columns end
      if row < 1 then
        local line = math.max(1, context.line1 - 1)
        local col = context.line1 > 1 and #context.buffer.lines[line] or 1
        targets[index] = { line, col, line, col }
      end
    elseif direction == "below" then
      row = row + 1
      if row > #context.editable_rows then append = true end
    else
      return false
    end
    if not targets[index] then targets[index] = { row = row, column = column } end
  end
  local appended
  if append then appended = append_body_row(first) end
  local selections = {}
  for index, target in ipairs(targets) do
    local selection
    if target.row then
      local row = first.editable_rows[target.row] or appended
      selection = selection_for_cell(row, target.column)
    else
      selection = target
    end
    if selection then
      for _, value in ipairs(selection) do selections[#selections + 1] = value end
    end
  end
  if #selections == 0 then return false end
  view.buffer:set_selection_list(selections, math.min(view.buffer.last_selection, #selections / 4), {
    merge_cursors = true,
  })
  return true
end

function tables.insert_cell_break(view)
  local contexts = collect_interactive_contexts(view)
  if not contexts then return false end
  return view:on_text_input("<br>")
end

local function cell_lexical_state(source, col1, col2)
  local ticks, slashes, col = 0, 0, col1
  while col < col2 do
    local char = source:sub(col, col)
    if char == "\\" then
      slashes = slashes + 1
      col = col + 1
    elseif char == "`" and slashes % 2 == 0 then
      local finish = col
      while finish + 1 < col2 and source:sub(finish + 1, finish + 1) == "`" do
        finish = finish + 1
      end
      local count = finish - col + 1
      if ticks == 0 then ticks = count elseif ticks == count then ticks = 0 end
      slashes = 0
      col = finish + 1
    else
      slashes = 0
      col = col + 1
    end
  end
  return { ticks = ticks, slashes = slashes }
end

function tables.normalize_cell_input(text, initial_state)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local parts = {}
  local ticks = initial_state and initial_state.ticks or 0
  local slashes = initial_state and initial_state.slashes or 0
  local col = 1
  while col <= #text do
    local char = text:sub(col, col)
    if char == "\n" then
      parts[#parts + 1] = "<br>"
      slashes = 0
      col = col + 1
    elseif char == "\\" then
      parts[#parts + 1] = char
      slashes = slashes + 1
      col = col + 1
    elseif char == "`" and slashes % 2 == 0 then
      local finish = col
      while text:sub(finish + 1, finish + 1) == "`" do finish = finish + 1 end
      local run = text:sub(col, finish)
      parts[#parts + 1] = run
      local count = #run
      if ticks == 0 then ticks = count elseif ticks == count then ticks = 0 end
      slashes = 0
      col = finish + 1
    elseif char == "|" then
      if ticks == 0 and slashes % 2 == 0 then parts[#parts + 1] = "\\" end
      parts[#parts + 1] = char
      slashes = 0
      col = col + 1
    else
      parts[#parts + 1] = char
      slashes = 0
      col = col + 1
    end
  end
  return table.concat(parts)
end

local function text_input_by_selection(view, text_for_context)
  local contexts = collect_interactive_contexts(view)
  if not contexts then return false end
  local by_index = {}
  for _, context in ipairs(contexts) do by_index[context.selection_index] = context end
  view.buffer:text_input_by_selection(function(index, line, col)
    local context = by_index[index]
    local source = line_text(view.buffer, line)
    local state = cell_lexical_state(
      source, context.cell.content_col1, math.min(col, context.cell.content_col2)
    )
    return tables.normalize_cell_input(text_for_context(context, index), state)
  end, nil, { type = "insert" })
  return true
end

function tables.text_input(view, text)
  return text_input_by_selection(view, function() return text end)
end

function tables.ime_text_editing(view, text, start, length)
  local contexts, first = collect_interactive_contexts(view)
  if not contexts then return false end
  local by_index = {}
  for _, context in ipairs(contexts) do by_index[context.selection_index] = context end
  local function state_for(context, line, col)
    return cell_lexical_state(
      line_text(view.buffer, line), context.cell.content_col1,
      math.min(col, context.cell.content_col2)
    )
  end
  local first_state = state_for(first, first.line, first.col)
  local prefix = tables.normalize_cell_input(
    tostring(text or ""):sub(1, start), first_state
  )
  local through_selection = tables.normalize_cell_input(
    tostring(text or ""):sub(1, start + length), first_state
  )
  view.buffer:ime_text_editing_by_selection(function(index, line, col)
    local context = by_index[index]
    return tables.normalize_cell_input(text, state_for(context, line, col))
  end)
  return true, #prefix, #through_selection - #prefix
end

function tables.paste(view)
  local clipboard = system.get_clipboard() or ""
  local selection_count = #view.buffer.selections / 4
  if core.cursor_clipboard
  and core.cursor_clipboard.full == clipboard
  and #core.cursor_clipboard_whole_line == selection_count
  then
    return text_input_by_selection(view, function(_, index)
      return tostring(core.cursor_clipboard[index] or ""):gsub("\r", "")
    end)
  end
  return tables.text_input(view, clipboard)
end

function tables.paste_primary(view, x, y)
  if type(x) == "number" and type(y) == "number" then
    local line, col = view:resolve_screen_position(x, y)
    view.buffer:set_selection(line, col)
    view.mouse_selecting = nil
  end
  return tables.text_input(view, system.get_primary_selection() or "")
end

function tables.has_text_clipboard()
  local text = system.get_clipboard()
  return type(text) == "string" and text ~= ""
end

function tables.has_primary_selection()
  local text = system.get_primary_selection()
  return type(text) == "string" and text ~= ""
end

local CELL_BREAK_PATTERN = "<[bB][rR]%s*/?%s*>"

local function next_cell_break(text, cell, start)
  local escaped, ticks = false, 0
  local col = cell.content_col1
  while col < cell.content_col2 do
    local char = text:sub(col, col)
    if escaped then
      escaped = false
    elseif char == "\\" then
      escaped = true
    elseif char == "`" then
      local finish = col
      while finish + 1 < cell.content_col2
      and text:sub(finish + 1, finish + 1) == "`"
      do
        finish = finish + 1
      end
      local count = finish - col + 1
      if ticks == 0 then ticks = count elseif ticks == count then ticks = 0 end
      col = finish
    elseif ticks == 0 and col >= start and char == "<" then
      local col1, col2 = text:find(CELL_BREAK_PATTERN, col)
      if col1 == col and col2 < cell.content_col2 then return col1, col2 end
    end
    col = col + 1
  end
end

local function adjacent_break(text, cell, col, direction)
  local search = cell.content_col1
  while search <= cell.content_col2 do
    local col1, col2 = next_cell_break(text, cell, search)
    if not col1 or col1 >= cell.content_col2 then return nil end
    if direction < 0 and col2 + 1 == col then return col1, col2 + 1 end
    if direction > 0 and col1 == col then return col1, col2 + 1 end
    search = col2 + 1
  end
end

function tables.move_char(view, direction, selecting)
  local contexts = collect_interactive_contexts(view)
  if not contexts then return false end
  local selections = {}
  for _, context in ipairs(contexts) do
    local offset = (context.selection_index - 1) * 4
    local caret_line, caret_col = view.buffer.selections[offset + 1], view.buffer.selections[offset + 2]
    local anchor_line, anchor_col = view.buffer.selections[offset + 3], view.buffer.selections[offset + 4]
    local text = line_text(view.buffer, context.line)
    local has_selection = caret_line ~= anchor_line or caret_col ~= anchor_col
    local break_col1, break_col2
    if not has_selection then
      break_col1, break_col2 = adjacent_break(
        text, context.cell, context.col, direction
      )
    end
    local line, col
    if has_selection and not selecting then
      line = context.line
      col = direction < 0 and math.min(caret_col, anchor_col)
        or math.max(caret_col, anchor_col)
    elseif break_col1 then
      line, col = context.line, direction < 0 and break_col1 or break_col2
    elseif direction < 0 then
      line, col = translate.previous_char(view.buffer, context.line, context.col)
    else
      line, col = translate.next_char(view.buffer, context.line, context.col)
    end
    line = context.line
    col = common.clamp(col, context.cell.content_col1, context.cell.content_col2)
    selections[#selections + 1] = line
    selections[#selections + 1] = col
    selections[#selections + 1] = selecting and anchor_line or line
    selections[#selections + 1] = selecting and anchor_col or col
  end
  view.buffer:set_selection_list(selections, view.buffer.last_selection, { merge_cursors = true })
  return true
end

function tables.delete_char(view, direction)
  local contexts = collect_interactive_contexts(view)
  if not contexts then return false end
  if view.buffer:has_any_selection() then
    return view:on_text_input("")
  end
  local edits, seen = {}, {}
  local refreshers = {}
  for _, context in ipairs(contexts) do
    local render = view:get_line_render(context.line)
    if render and render.on_table_source_changed then
      refreshers[render.on_table_source_changed] = true
    end
    local text = line_text(view.buffer, context.line)
    local col1, col2 = adjacent_break(text, context.cell, context.col, direction)
    if not col1 then
      local _, target
      if direction < 0 then
        _, target = translate.previous_char(view.buffer, context.line, context.col)
      else
        _, target = translate.next_char(view.buffer, context.line, context.col)
      end
      if direction < 0 then col1, col2 = target, context.col
      else col1, col2 = context.col, target end
      col1 = math.max(col1, context.cell.content_col1)
      col2 = math.min(col2, context.cell.content_col2)
    end
    if col2 > col1 then
      local key = context.line .. ":" .. col1 .. ":" .. col2
      if not seen[key] then
        seen[key] = true
        edits[#edits + 1] = {
          line1 = context.line, col1 = col1,
          line2 = context.line, col2 = col2, text = "",
        }
      end
    end
  end
  if #edits > 0 then
    view.buffer:apply_edits(edits, { type = "delete", reason = "markdown-table-cell" })
    for refresh in pairs(refreshers) do refresh(view) end
  end
  return true
end

function tables.move_vertical(view, direction, selecting)
  local contexts = collect_interactive_contexts(view)
  if not contexts then return false end
  if view.clear_pending_line_render_position_row_affinity then
    view:clear_pending_line_render_position_row_affinity()
  end
  local selections = {}
  for _, context in ipairs(contexts) do
    local old_offset = (context.selection_index - 1) * 4
    local old_line2 = view.buffer.selections[old_offset + 3]
    local old_col2 = view.buffer.selections[old_offset + 4]
    local line, col = view:move_within_line_render_position_rows(
      context.line, context.col, direction
    )
    if not line then
      local target_grid_row = context.grid_row + direction
      local target_row = context.editable_rows[target_grid_row]
      if target_row then
        local target_cell = target_row.cells[context.column]
        local fallback = target_cell.content_col1
        local x = view:get_col_x_offset(context.line, context.col)
        line = target_row.line
        col = view:land_on_line_render_position_row(line, fallback, direction, x)
        col = common.clamp(col, target_cell.content_col1, target_cell.content_col2)
      else
        line = direction < 0 and math.max(1, context.line1 - 1)
          or math.min(#view.buffer.lines, context.line2 + 1)
        col = direction < 0 and context.line1 > 1 and #view.buffer.lines[line] or 1
      end
    end
    selections[#selections + 1] = line
    selections[#selections + 1] = col
    selections[#selections + 1] = selecting and old_line2 or line
    selections[#selections + 1] = selecting and old_col2 or col
  end
  view.buffer:set_selection_list(selections, view.buffer.last_selection, {
    merge_cursors = true,
  })
  if view.apply_pending_line_render_position_row_affinity then
    view:apply_pending_line_render_position_row_affinity()
  end
  return true
end

function tables.select_rectangle(view, anchor_line, anchor_col, line, col)
  local anchor = context_at(view, anchor_line, anchor_col, false)
  local target = context_at(view, line, col, false)
  if not same_table(anchor, target) then return false end
  if anchor.grid_row == target.grid_row and anchor.column == target.column then
    -- A drag that remains inside one cell is ordinary character selection.
    -- Crossing a cell boundary promotes the same gesture to rectangular
    -- Table Cell Selection.
    return false
  end
  local row1, row2 = math.min(anchor.grid_row, target.grid_row),
    math.max(anchor.grid_row, target.grid_row)
  local col1, col2 = math.min(anchor.column, target.column),
    math.max(anchor.column, target.column)
  local selections, last_selection = {}, 1
  for row_index = row1, row2 do
    local row = anchor.editable_rows[row_index]
    for column = col1, col2 do
      local selection = selection_for_cell(row, column)
      if selection then
        local selection_index = #selections / 4 + 1
        for _, value in ipairs(selection) do selections[#selections + 1] = value end
        if row_index == target.grid_row and column == target.column then
          last_selection = selection_index
        end
      end
    end
  end
  if #selections == 0 then return false end
  view.buffer:set_selection_list(selections, last_selection, {
    merge_cursors = false,
  })
  return true
end

local function apply_line_replacements(context, replacements, reason)
  local refresh = structure_refresher(context)
  local edits = {}
  for line, text in pairs(replacements) do
    edits[#edits + 1] = {
      line1 = line, col1 = 1, line2 = line, col2 = #line_text(context.buffer, line) + 1,
      text = text,
    }
  end
  table.sort(edits, function(a, b) return a.line1 < b.line1 end)
  context.buffer:apply_edits(edits, { type = "markdown-table", reason = reason })
  refresh_structure(context, refresh, context.line1, context.line2)
  return true
end

function tables.insert_row(view, side)
  local context = tables.context(view)
  if not context then return false end
  local refresh = structure_refresher(context)
  local insertion_line
  if context.line <= context.delimiter_line then
    insertion_line = context.delimiter_line + 1
  elseif side == "above" then
    insertion_line = context.line
  else
    insertion_line = context.line + 1
  end
  local row = "|" .. string.rep("  |", context.columns) .. "\n"
  insertion_line = insert_source_row(context.buffer, insertion_line, row)
  context.buffer:set_selection(insertion_line, 3)
  refresh_structure(context, refresh, context.line1, context.line2 + 1)
  return true
end

function tables.delete_row(view)
  local context = tables.context(view)
  if not context or context.line <= context.delimiter_line then return false end
  local refresh = structure_refresher(context)
  local line = context.line
  context.buffer:remove(line, 1, line + 1, 1)
  context.buffer:set_selection(math.min(line, #context.buffer.lines), 1)
  refresh_structure(context, refresh, context.line1, context.line2 - 1)
  return true
end

function tables.move_row(view, direction)
  local context = tables.context(view)
  if not context or context.line <= context.delimiter_line then return false end
  local refresh = structure_refresher(context)
  local target = context.line + direction
  if target <= context.delimiter_line or target > context.line2 then return false end
  local first, second = math.min(context.line, target), math.max(context.line, target)
  local first_text, second_text = context.buffer.lines[first], context.buffer.lines[second]
  context.buffer:apply_edits({
    { line1 = first, col1 = 1, line2 = second + 1, col2 = 1, text = second_text .. first_text },
  }, { type = "markdown-table", reason = "move-row" })
  context.buffer:set_selection(target, context.col)
  refresh_structure(context, refresh, context.line1, context.line2)
  return true
end

function tables.insert_column(view, side)
  local context = tables.context(view)
  if not context then return false end
  local replacements = {}
  for _, row in ipairs(context.rows) do
    local insertion = row.pipes[context.column + (side == "left" and 0 or 1)]
    local value = row.line == context.delimiter_line and " --- |" or "  |"
    replacements[row.line] = row.text:sub(1, insertion) .. value .. row.text:sub(insertion + 1)
  end
  apply_line_replacements(context, replacements, "insert-column")
  local row = source_row(line_text(context.buffer, context.line))
  local target_column = context.column + (side == "left" and 0 or 1)
  local cell = row and row.cells[target_column]
  context.buffer:set_selection(
    context.line, cell and cell.content_col1 or context.col
  )
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
  context.buffer:set_selection(context.line, math.max(1, context.rows[context.line - context.line1 + 1].pipes[context.column]))
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
  context.buffer:set_selection(context.line, context.rows[context.line - context.line1 + 1].pipes[target] + 2)
  return true
end

return tables
