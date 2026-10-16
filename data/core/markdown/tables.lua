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
  local ticks = 0
  local i = 1
  while true do
    -- Only backslashes, backticks, and pipes affect the result.
    i = text:find("[\\`|]", i)
    if not i then break end
    local byte = text:byte(i)
    if byte == 92 then
      -- A backslash escapes the next byte, whatever it is.
      i = i + 2
    elseif byte == 96 then
      local finish = i
      while text:byte(finish + 1) == 96 do finish = finish + 1 end
      local count = finish - i + 1
      if ticks == 0 then ticks = count elseif ticks == count then ticks = 0 end
      i = finish + 1
    else
      if ticks == 0 then positions[#positions + 1] = i end
      i = i + 1
    end
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
  -- An edit changes few lines, so rows are reused by source text. Only lines
  -- with a pipe can be table rows.
  local rows = {}
  local previous_by_text = cached and cached.rows_by_text
  local rows_by_text = {}
  for line = 1, line_count do
    local source = buffer.lines[line] or ""
    local entry = rows_by_text[source]
    if entry == nil then
      if previous_by_text then entry = previous_by_text[source] end
      if entry == nil then
        local row = source:find("|", 1, true) and source_row(line_text(buffer, line))
        -- Keep the index compact. Full cell bounds are only needed by the
        -- presentation parser and by the uncommon empty-row extension path.
        entry = row and {
          columns = row.columns,
          delimiter = delimiter_row(row),
        } or false
      end
      rows_by_text[source] = entry
    end
    if entry then rows[line] = entry end
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
    rows = rows, by_line = by_line, rows_by_text = rows_by_text,
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

-- Like source_table_bounds, but a delimiter row also resolves to its table.
-- The line index leaves delimiter rows out so a delimiter cannot claim a
-- second table, but every row of one table must extend identically.
local function source_table_bounds_with_delimiter(buffer, line)
  local index = source_index(buffer)
  local table_range = index.by_line[line]
  if not table_range then
    local header = index.by_line[line - 1]
    if header and header.delimiter_line == line then table_range = header end
  end
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

---Record the complete source rows a cached table result was built from.
function tables.source_record(buffer, line1, line2)
  local texts = {}
  for line = line1, line2 do texts[line] = line_text(buffer, line) end
  return { line1 = line1, line2 = line2, texts = texts, revision = buffer.text_revision }
end

---Return whether a source record still describes rows line1..line2. Text
---revisions only increase, so a matching revision skips the row comparison.
function tables.source_record_current(buffer, record, line1, line2)
  if not record or record.line1 ~= line1 or record.line2 ~= line2 then return false end
  local revision = buffer.text_revision
  if record.revision == revision then return true end
  for line = line1, line2 do
    if record.texts[line] ~= line_text(buffer, line) then return false end
  end
  record.revision = revision
  return true
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
  local line1, source_line2 = source_table_bounds_with_delimiter(view.buffer, line)
  if not line1 then return table_node end
  local instance = model.peek(view.buffer)
  if not (instance and instance.status == "ready"
    and instance.published_revision == view.buffer.text_revision)
  then
    return table_node
  end
  local nodes = instance:nodes_for_lines(line1, line1, { limit = 1024 })
  local enclosing_table, has_header = nil, false
  if table_node and table_node.source.line1 ~= line1 then table_node = nil end
  for _, node in ipairs(nodes or {}) do
    if node.type == "table" then
      if node.source.line1 == line1 then
        table_node = node
        break
      end
      enclosing_table = enclosing_table or node
    elseif node.type == "table_header" and node.source.line1 == line1 then
      has_header = true
    end
  end
  if not table_node and has_header and enclosing_table then
    -- An empty row can make Tree-sitter merge the remaining rows, intervening
    -- prose, and a later table into one malformed semantic table. The header
    -- capture still confirms the canonical source table at this line.
    table_node = {}
    for key, value in pairs(enclosing_table) do table_node[key] = value end
    table_node.source = {
      line1 = line1,
      col1 = 1,
      line2 = source_line2,
      col2 = #line_text(view.buffer, source_line2) + 1,
    }
    table_node.id = table.concat({
      tostring(enclosing_table.id), "source-table", tostring(line1),
      tostring(view.buffer.text_revision), tostring(source_line2),
    }, ":")
    return table_node
  end
  if not table_node then return nil end
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

-- Table model ---------------------------------------------------------------
-- Structural commands edit a table as a grid of trimmed cell sources plus one
-- alignment per column, then write the whole table back in canonical padded
-- form: every column is as wide as its widest cell and the delimiter row
-- spells each alignment. The rewrite is one Buffer edit, so one undo step.

local MIN_COLUMN_WIDTH = 3

local function marker_alignment(marker)
  local left, right = marker:sub(1, 1) == ":", marker:sub(-1) == ":"
  if left and right then return "center" end
  if left then return "left" end
  if right then return "right" end
  return nil
end

local function display_width(text)
  local _, count = text:gsub("[^\128-\191]", "")
  return count
end

local function model_from_context(context)
  local model = { columns = context.columns, alignments = {}, rows = {} }
  local delimiter = context.rows[2]
  for column, cell in ipairs(delimiter.cells) do
    model.alignments[column] = marker_alignment(
      delimiter.text:sub(cell.content_col1, cell.content_col2 - 1)
    )
  end
  for _, row in ipairs(context.editable_rows) do
    local cells = {}
    for column, cell in ipairs(row.cells) do
      cells[column] = row.text:sub(cell.content_col1, cell.content_col2 - 1)
    end
    model.rows[#model.rows + 1] = cells
  end
  return model
end

local function pad_cell(text, width, alignment)
  local gap = width - display_width(text)
  if gap <= 0 then return text end
  if alignment == "right" then return string.rep(" ", gap) .. text end
  if alignment == "center" then
    local left = math.floor(gap / 2)
    return string.rep(" ", left) .. text .. string.rep(" ", gap - left)
  end
  return text .. string.rep(" ", gap)
end

local function delimiter_marker(width, alignment)
  if alignment == "center" then return ":" .. string.rep("-", width - 2) .. ":" end
  if alignment == "left" then return ":" .. string.rep("-", width - 1) end
  if alignment == "right" then return string.rep("-", width - 1) .. ":" end
  return string.rep("-", width)
end

---Return the canonical source lines, without newlines, for a table model.
---`model.rows[1]` is the header row; the delimiter row is generated.
function tables.serialize_model(model, indent)
  local widths = {}
  for column = 1, model.columns do
    local width = MIN_COLUMN_WIDTH
    for _, cells in ipairs(model.rows) do
      width = math.max(width, display_width(cells[column] or ""))
    end
    widths[column] = width
  end
  local function source_line(cells)
    return (indent or "") .. "| " .. table.concat(cells, " | ") .. " |"
  end
  local lines = {}
  for index, cells in ipairs(model.rows) do
    local padded = {}
    for column = 1, model.columns do
      padded[column] = pad_cell(cells[column] or "", widths[column], model.alignments[column])
    end
    lines[#lines + 1] = source_line(padded)
    if index == 1 then
      local markers = {}
      for column = 1, model.columns do
        markers[column] = delimiter_marker(widths[column], model.alignments[column])
      end
      lines[#lines + 1] = source_line(markers)
    end
  end
  return lines
end

local function grid_row_line(line1, grid_row)
  return line1 + grid_row - 1 + (grid_row > 1 and 1 or 0)
end

local function editable_rows_between(buffer, line1, line2)
  local rows = {}
  for line = line1, line2 do
    if line ~= line1 + 1 then
      local row = source_row(line_text(buffer, line))
      if not row then return nil end
      row.line = line
      rows[#rows + 1] = row
    end
  end
  return rows
end

---Write `model` over the table described by `context` and place the caret.
---`target` names a grid row and column; `offset` keeps the caret's byte
---offset inside the cell contents and `select` selects the whole cell.
local function apply_model(context, model, reason, target)
  local buffer = context.buffer
  local refresh = structure_refresher(context)
  local indent = context.rows[1].text:match("^%s*") or ""
  local lines = tables.serialize_model(model, indent)
  local old_count = context.line2 - context.line1 + 1
  local edits = {}
  if #lines == old_count then
    -- Rewrite only changed rows so unchanged rows keep their marks.
    for index, text in ipairs(lines) do
      local line = context.line1 + index - 1
      local current = line_text(buffer, line)
      if current ~= text then
        edits[#edits + 1] = {
          line1 = line, col1 = 1, line2 = line, col2 = #current + 1, text = text,
        }
      end
    end
  else
    edits[1] = {
      line1 = context.line1, col1 = 1,
      line2 = context.line2, col2 = #line_text(buffer, context.line2) + 1,
      text = table.concat(lines, "\n"),
    }
  end
  if #edits > 0 then
    buffer:apply_edits(edits, { type = "markdown-table", reason = reason })
  end
  local line2 = context.line1 + #lines - 1
  core.log_quiet(
    "Markdown table %s at %s:%d: %d rows, %d columns, %d edits",
    reason, buffer:get_name(), context.line1, #model.rows, model.columns, #edits
  )
  if target then
    local line = grid_row_line(context.line1, target.row)
    local row = source_row(line_text(buffer, line))
    local cell = row and row.cells[target.column]
    if cell then
      if target.select then
        buffer:set_selection(line, cell.content_col2, line, cell.content_col1)
      else
        buffer:set_selection(line, math.min(
          cell.content_col1 + math.max(0, target.offset or 0), cell.content_col2
        ))
      end
    end
  end
  refresh_structure(context, refresh, context.line1, line2)
  return true, line2
end

local function caret_offset(context)
  if context.col < context.cell.content_col1 then return 0 end
  return context.col - context.cell.content_col1
end

local function empty_cells(columns)
  local cells = {}
  for column = 1, columns do cells[column] = "" end
  return cells
end

local function append_body_row(context)
  local model = model_from_context(context)
  model.rows[#model.rows + 1] = empty_cells(model.columns)
  local _, line2 = apply_model(context, model, "append-row")
  return editable_rows_between(context.buffer, context.line1, line2)
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
  -- Appending rewrites the table in canonical form, which can move every
  -- cell, so destinations resolve against the rewritten rows.
  local rows = first.editable_rows
  if append then rows = append_body_row(first) or rows end
  local selections = {}
  for index, target in ipairs(targets) do
    local selection
    if target.row then
      local row = rows[math.min(target.row, #rows)]
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
      -- Whitespace typed after the cell's text stays deletable up to the caret.
      col2 = math.min(col2, math.max(context.cell.content_col2, context.col))
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

function tables.insert_row(view, side)
  local context = tables.context(view)
  if not context then return false end
  local model = model_from_context(context)
  -- The header row stays first; a row inserted "above" it lands below it.
  local index = context.grid_row + 1
  if side == "above" and context.grid_row > 1 then index = context.grid_row end
  table.insert(model.rows, index, empty_cells(model.columns))
  return apply_model(context, model, "insert-row", {
    row = index, column = context.column,
  })
end

function tables.delete_row(view)
  local context = tables.context(view)
  if not context or context.grid_row <= 1 then return false end
  local model = model_from_context(context)
  table.remove(model.rows, context.grid_row)
  return apply_model(context, model, "delete-row", {
    row = math.min(context.grid_row, #model.rows), column = context.column,
  })
end

function tables.move_row(view, direction)
  local context = tables.context(view)
  if not context or context.grid_row <= 1 then return false end
  local target = context.grid_row + direction
  local model = model_from_context(context)
  if target <= 1 or target > #model.rows then return false end
  model.rows[context.grid_row], model.rows[target] =
    model.rows[target], model.rows[context.grid_row]
  return apply_model(context, model, "move-row", {
    row = target, column = context.column, offset = caret_offset(context),
  })
end

function tables.insert_column(view, side)
  local context = tables.context(view)
  if not context then return false end
  if context.columns >= tables.MAX_PRESENTATION_COLUMNS then return false end
  local model = model_from_context(context)
  local index = context.column + (side == "left" and 0 or 1)
  for _, cells in ipairs(model.rows) do table.insert(cells, index, "") end
  -- Alignments may have holes, so shift them explicitly.
  for column = model.columns, index, -1 do
    model.alignments[column + 1] = model.alignments[column]
  end
  model.alignments[index] = nil
  model.columns = model.columns + 1
  return apply_model(context, model, "insert-column", {
    row = context.grid_row, column = index,
  })
end

function tables.delete_column(view)
  local context = tables.context(view)
  if not context or context.columns <= 1 then return false end
  local model = model_from_context(context)
  for _, cells in ipairs(model.rows) do table.remove(cells, context.column) end
  for column = context.column, model.columns do
    model.alignments[column] = model.alignments[column + 1]
  end
  model.columns = model.columns - 1
  return apply_model(context, model, "delete-column", {
    row = context.grid_row, column = math.min(context.column, model.columns),
  })
end

function tables.move_column(view, direction)
  local context = tables.context(view)
  if not context then return false end
  local a, b = context.column, context.column + direction
  if b < 1 or b > context.columns then return false end
  local model = model_from_context(context)
  for _, cells in ipairs(model.rows) do cells[a], cells[b] = cells[b], cells[a] end
  model.alignments[a], model.alignments[b] = model.alignments[b], model.alignments[a]
  return apply_model(context, model, "move-column", {
    row = context.grid_row, column = b, offset = caret_offset(context),
  })
end

-- The first cell is the primary selection. Callers list the cell nearest the
-- handle that selected the cells first, so the view stays where it is.
local function select_cells(view, cells)
  local selections = {}
  for _, cell in ipairs(cells) do
    for _, value in ipairs(selection_for_cell(cell[1], cell[2]) or {}) do
      selections[#selections + 1] = value
    end
  end
  if #selections == 0 then return false end
  view.buffer:set_selection_list(selections, 1, { merge_cursors = false })
  return true
end

---Select every cell of the table row at `line` as Table Cell Selections.
function tables.select_row(view, line)
  local context = context_at(view, line, 1, false)
  if not context then return false end
  local cells = {}
  for column = 1, context.columns do cells[#cells + 1] = { context.current_row, column } end
  return select_cells(view, cells)
end

---Select every cell of `column` in the table holding `line`.
function tables.select_column(view, line, column)
  local context = context_at(view, line, 1, false)
  if not context or column < 1 or column > context.columns then return false end
  local cells = {}
  for _, row in ipairs(context.editable_rows) do cells[#cells + 1] = { row, column } end
  return select_cells(view, cells)
end

---Move the body row at `line` to grid row `target` and select it.
function tables.move_row_to(view, line, target)
  local context = context_at(view, line, 1, true)
  if not context or context.grid_row <= 1 then return false end
  local model = model_from_context(context)
  target = common.clamp(target, 2, #model.rows)
  if target == context.grid_row then return false end
  table.insert(model.rows, target, table.remove(model.rows, context.grid_row))
  apply_model(context, model, "drag-row")
  return tables.select_row(view, grid_row_line(context.line1, target))
end

---Move `column` of the table holding `line` to `target` and select it.
function tables.move_column_to(view, line, column, target)
  local context = context_at(view, line, 1, true)
  if not context or column < 1 or column > context.columns then return false end
  target = common.clamp(target, 1, context.columns)
  if target == column then return false end
  local model = model_from_context(context)
  for _, cells in ipairs(model.rows) do
    table.insert(cells, target, table.remove(cells, column))
  end
  -- Alignments can have nil holes, which table.remove cannot shift.
  local alignments = {}
  for index = 1, model.columns do alignments[index] = model.alignments[index] or false end
  table.insert(alignments, target, table.remove(alignments, column))
  for index = 1, model.columns do model.alignments[index] = alignments[index] or nil end
  apply_model(context, model, "drag-column")
  return tables.select_column(view, context.line1, target)
end

---Columns holding a selection, or the caret's column.
local function selected_columns(view, context)
  local columns, seen = {}, {}
  for _, selection_context in ipairs(collect_interactive_contexts(view) or { context }) do
    if same_table(selection_context, context) and not seen[selection_context.column] then
      seen[selection_context.column] = true
      columns[#columns + 1] = selection_context.column
    end
  end
  return columns
end

---Set the alignment of every selected column: "left", "center", "right", or
---nil to remove explicit alignment.
function tables.set_alignment(view, alignment)
  local context = tables.context(view)
  if not context then return false end
  local model = model_from_context(context)
  for _, column in ipairs(selected_columns(view, context)) do
    model.alignments[column] = alignment
  end
  -- Re-padding moves cell text, so a Table Cell Selection group is restored
  -- by grid position rather than by source columns.
  local selected_cells = {}
  local contexts = collect_interactive_contexts(view)
  if contexts and #contexts > 1 then
    for _, selection_context in ipairs(contexts) do
      selected_cells[#selected_cells + 1] = {
        selection_context.grid_row, selection_context.column,
      }
    end
  end
  local ok, line2 = apply_model(context, model, "align-" .. tostring(alignment or "none"), {
    row = context.grid_row, column = context.column, offset = caret_offset(context),
  })
  if #selected_cells > 0 then
    local rows = editable_rows_between(context.buffer, context.line1, line2) or {}
    local selections = {}
    for _, cell in ipairs(selected_cells) do
      for _, value in ipairs(selection_for_cell(rows[cell[1]], cell[2]) or {}) do
        selections[#selections + 1] = value
      end
    end
    if #selections > 0 then
      view.buffer:set_selection_list(selections, #selections / 4, { merge_cursors = false })
    end
  end
  return ok
end

local function sort_key(text)
  local plain = text:gsub("[%*_~`]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  return tonumber((plain:gsub(",", ""))), plain:lower()
end

---Sort body rows by the caret's column. The header row stays first, empty
---cells sort last, and numbers compare numerically.
function tables.sort_rows(view, descending)
  local context = tables.context(view)
  if not context then return false end
  local model = model_from_context(context)
  local column = context.column
  local entries = {}
  for index = 2, #model.rows do
    local number, text = sort_key(model.rows[index][column] or "")
    entries[#entries + 1] = {
      cells = model.rows[index], number = number, text = text, index = index,
    }
  end
  table.sort(entries, function(a, b)
    if (a.text == "") ~= (b.text == "") then return b.text == "" end
    local order
    if a.number and b.number then
      if a.number ~= b.number then order = a.number < b.number end
    elseif a.number or b.number then
      order = a.number ~= nil
    elseif a.text ~= b.text then
      order = a.text < b.text
    end
    if order == nil then return a.index < b.index end
    if descending then return not order end
    return order
  end)
  local caret_row = context.grid_row
  for index, entry in ipairs(entries) do
    model.rows[index + 1] = entry.cells
    if entry.index == context.grid_row then caret_row = index + 1 end
  end
  return apply_model(context, model, descending and "sort-descending" or "sort-ascending", {
    row = caret_row, column = column, offset = caret_offset(context),
  })
end

---Rewrite the caret's table in canonical padded form.
function tables.format(view)
  local context = tables.context(view)
  if not context then return false end
  return apply_model(context, model_from_context(context), "format", {
    row = context.grid_row, column = context.column, offset = caret_offset(context),
  })
end

---Write a new table at the caret. A blank caret line becomes the table;
---otherwise the table starts below the caret line. Blank lines keep it apart
---from neighboring blocks. Returns the table's first line.
local function insert_model_at_caret(view, model, reason)
  local buffer = view.buffer
  local line = buffer:get_selection()
  local current = line_text(buffer, line)
  local text = table.concat(tables.serialize_model(model), "\n")
  local table_line
  local edit
  if current:match("^%s*$") then
    local before = line > 1 and line_text(buffer, line - 1) or ""
    if not before:match("^%s*$") then
      text = "\n" .. text
      table_line = line + 1
    else
      table_line = line
    end
    edit = { line1 = line, col1 = 1, line2 = line, col2 = #current + 1, text = text }
  else
    text = "\n\n" .. text
    table_line = line + 2
    edit = { line1 = line, col1 = #current + 1, line2 = line, col2 = #current + 1, text = text }
  end
  local following = line_text(buffer, line + 1)
  if line < #buffer.lines and not following:match("^%s*$") then
    edit.text = edit.text .. "\n"
  end
  buffer:apply_edits({ edit }, { type = "markdown-table", reason = reason })
  core.log_quiet(
    "Markdown table %s at %s:%d: %d columns, %d rows",
    reason, buffer:get_name(), table_line, model.columns, #model.rows
  )
  return table_line
end

local function place_caret_in_cell(buffer, line, column, at_end)
  local row = source_row(line_text(buffer, line))
  local cell = row and row.cells[column]
  if cell then
    buffer:set_selection(line, at_end and cell.content_col2 or cell.content_col1)
  end
end

---Return whether a new table can start at the caret line.
function tables.can_insert_table(view)
  if not (view and view.buffer) then return false end
  local line = view.buffer:get_selection()
  return source_table_bounds_with_delimiter(view.buffer, line) == nil
    and context_at(view, line, nil, false) == nil
    and not source_line_in_fence_or_frontmatter(view.buffer, line)
end

---Insert an empty table at the caret and place the caret in its first header
---cell.
function tables.insert_table(view, columns, body_rows)
  if not tables.can_insert_table(view) then return false end
  columns = math.max(1, math.min(columns or 2, tables.MAX_PRESENTATION_COLUMNS))
  local model = { columns = columns, alignments = {}, rows = {} }
  for _ = 1, math.max(0, body_rows or 1) + 1 do
    model.rows[#model.rows + 1] = empty_cells(columns)
  end
  local table_line = insert_model_at_caret(view, model, "insert-table")
  place_caret_in_cell(view.buffer, table_line, 1)
  return true
end

---Return the caret line's cells when Enter should turn it into a table
---header: a single caret at the end of a pipe-delimited row with at least two
---cells, outside any table, code fence, or front matter.
function tables.header_row_at_caret(view)
  if not (view and view.buffer) or #view.buffer.selections ~= 4 then return nil end
  local buffer = view.buffer
  local line, col, anchor_line, anchor_col = buffer:get_selection()
  if line ~= anchor_line or col ~= anchor_col then return nil end
  local text = line_text(buffer, line)
  local trimmed = text:gsub("%s+$", "")
  if col <= #trimmed then return nil end
  local row = source_row(trimmed)
  if not (row and row.canonical and row.columns >= 2) or delimiter_row(row) then
    return nil
  end
  if line < #buffer.lines and delimiter_row(source_row_at(buffer, line + 1)) then
    return nil
  end
  if source_table_bounds_with_delimiter(buffer, line)
  or source_line_in_fence_or_frontmatter(buffer, line)
  then
    return nil
  end
  local cells = {}
  for column, cell in ipairs(row.cells) do
    cells[column] = trimmed:sub(cell.content_col1, cell.content_col2 - 1)
  end
  return cells
end

---Turn the caret's header row into a table with one empty body row and place
---the caret in the first body cell.
function tables.create_from_header_row(view)
  local header = tables.header_row_at_caret(view)
  if not header then return false end
  local buffer = view.buffer
  local line = buffer:get_selection()
  local model = { columns = #header, alignments = {}, rows = { header, empty_cells(#header) } }
  local lines = tables.serialize_model(model, line_text(buffer, line):match("^%s*"))
  local text = table.concat(lines, "\n")
  local before = line > 1 and line_text(buffer, line - 1) or ""
  local table_line = line
  if not before:match("^%s*$") then
    -- A table cannot continue a paragraph.
    text = "\n" .. text
    table_line = line + 1
  end
  if line < #buffer.lines and not line_text(buffer, line + 1):match("^%s*$") then
    -- A following line without pipes would otherwise become a table row.
    text = text .. "\n"
  end
  buffer:apply_edits({
    { line1 = line, col1 = 1, line2 = line, col2 = #line_text(buffer, line) + 1, text = text },
  }, { type = "markdown-table", reason = "create-from-header" })
  place_caret_in_cell(buffer, table_line + 2, 1)
  core.log_quiet(
    "Markdown table created from header row at %s:%d: %d columns",
    buffer:get_name(), table_line, #header
  )
  return true
end

-- Spreadsheet paste ---------------------------------------------------------

local MAX_GRID_PASTE_BYTES = 1024 * 1024

---Parse tab-separated text as copied from a spreadsheet. Quoted fields may
---hold tabs, newlines, and doubled quotes.
local function parse_tsv(text)
  local rows, row, cell = {}, {}, {}
  local i, n = 1, #text
  local cell_start = true
  while i <= n do
    local char = text:sub(i, i)
    if cell_start and char == '"' then
      local j = i + 1
      while j <= n do
        local quoted = text:sub(j, j)
        if quoted == '"' then
          if text:sub(j + 1, j + 1) ~= '"' then j = j + 1 break end
          j = j + 1
        end
        cell[#cell + 1] = text:sub(j, j)
        j = j + 1
      end
      i, cell_start = j, false
    elseif char == "\t" then
      row[#row + 1] = table.concat(cell)
      cell, cell_start = {}, true
      i = i + 1
    elseif char == "\n" then
      row[#row + 1] = table.concat(cell)
      rows[#rows + 1] = row
      row, cell, cell_start = {}, {}, true
      i = i + 1
    else
      local next_special = text:find('[\t\n]', i) or n + 1
      cell[#cell + 1] = text:sub(i, next_special - 1)
      i, cell_start = next_special, false
    end
  end
  if #cell > 0 or #row > 0 then
    row[#row + 1] = table.concat(cell)
    rows[#rows + 1] = row
  end
  return rows
end

---Return clipboard text as a grid of Markdown cell sources when it is
---tab-separated with more than one cell, or nil.
function tables.spreadsheet_grid(text)
  text = tostring(text or "")
  if #text > MAX_GRID_PASTE_BYTES or not text:find("\t", 1, true) then return nil end
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n+$", "")
  local rows = parse_tsv(text)
  local columns = 0
  for _, cells in ipairs(rows) do columns = math.max(columns, #cells) end
  if columns > tables.MAX_PRESENTATION_COLUMNS
  or #rows > tables.MAX_PRESENTATION_ROWS
  or #rows * columns < 2
  then
    return nil
  end
  for _, cells in ipairs(rows) do
    for column = 1, columns do
      local value = (cells[column] or ""):match("^%s*(.-)%s*$")
      cells[column] = tables.normalize_cell_input(value)
    end
  end
  return { rows = rows, columns = columns }
end

local function paste_grid(view, context, grid)
  local model = model_from_context(context)
  local last_column = context.column + grid.columns - 1
  if last_column > tables.MAX_PRESENTATION_COLUMNS then return false end
  while model.columns < last_column do
    model.columns = model.columns + 1
    for _, cells in ipairs(model.rows) do cells[model.columns] = "" end
  end
  local last_row = context.grid_row + #grid.rows - 1
  while #model.rows < last_row do model.rows[#model.rows + 1] = empty_cells(model.columns) end
  for row_offset, cells in ipairs(grid.rows) do
    for column_offset, value in ipairs(cells) do
      model.rows[context.grid_row + row_offset - 1][context.column + column_offset - 1] = value
    end
  end
  local last_value = grid.rows[#grid.rows][grid.columns] or ""
  apply_model(context, model, "paste-grid", {
    row = last_row, column = last_column, offset = #last_value,
  })
  return true
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
  if selection_count == 1 then
    local grid = tables.spreadsheet_grid(clipboard)
    local context = grid and tables.context(view)
    if context and paste_grid(view, context, grid) then return true end
  end
  return tables.text_input(view, clipboard)
end

---Return whether the clipboard should paste as a new table at the caret:
---spreadsheet rows outside any table, with no selection to replace.
function tables.can_paste_table(view)
  if not (view and view.buffer) or view.buffer:has_any_selection() then return false end
  if #view.buffer.selections ~= 4 then return false end
  -- The clipboard check is cheap and usually fails; the table and fence
  -- checks scan the Buffer.
  local grid = tables.spreadsheet_grid(system.get_clipboard())
  return grid ~= nil and #grid.rows >= 2 and grid.columns >= 2
    and tables.can_insert_table(view)
end

---Paste spreadsheet rows as a new table whose first row is the header.
function tables.paste_table(view)
  if not tables.can_paste_table(view) then return false end
  local grid = tables.spreadsheet_grid(system.get_clipboard())
  local model = { columns = grid.columns, alignments = {}, rows = grid.rows }
  local table_line = insert_model_at_caret(view, model, "paste-table")
  place_caret_in_cell(
    view.buffer, grid_row_line(table_line, #grid.rows), grid.columns, true
  )
  return true
end

return tables
