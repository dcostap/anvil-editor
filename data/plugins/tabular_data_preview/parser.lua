local parser = {}

local DELIMITERS = {
  csv = ",",
  tsv = "\t",
  psv = "|",
  ssv = ";",
}

function parser.delimiter_for_path(path)
  local extension = type(path) == "string" and path:match("%.([^./\\]+)$")
  return extension and DELIMITERS[extension:lower()] or nil
end

function parser.is_supported(path)
  return parser.delimiter_for_path(path) ~= nil
end

local function append(parts, text)
  if text ~= "" then parts[#parts + 1] = text end
end

function parser.parse(lines, delimiter, options)
  assert(type(lines) == "table", "tabular parser lines must be a table")
  assert(type(delimiter) == "string" and #delimiter == 1,
    "tabular parser delimiter must be one byte")
  options = options or {}

  local should_cancel = options.should_cancel
  local yield_fn = options.yield_fn
  local yield_every = math.max(1024, tonumber(options.yield_every) or 256 * 1024)
  local next_yield = yield_every
  local processed = 0
  local delimiter_byte = delimiter:byte()

  local records = {}
  local record = {}
  local field_parts = {}
  local in_quotes = false
  local field_start = true
  local record_touched = false
  local record_line1 = 1
  local max_columns = 0
  local warning

  local function cancelled()
    return should_cancel and should_cancel() or false
  end

  local function maybe_yield(amount)
    processed = processed + amount
    if not yield_fn or processed < next_yield then return true end
    next_yield = processed + yield_every
    yield_fn(processed)
    return not cancelled()
  end

  local function finish_field()
    record[#record + 1] = table.concat(field_parts)
    field_parts = {}
    field_start = true
  end

  local function finish_record(source_line2)
    finish_field()
    if record_touched then
      max_columns = math.max(max_columns, #record)
      records[#records + 1] = {
        cells = record,
        source_line1 = record_line1,
        source_line2 = source_line2,
      }
    end
    record = {}
    record_touched = false
    record_line1 = source_line2 + 1
  end

  for line_number, source_line in ipairs(lines) do
    if cancelled() then return nil, "cancelled" end
    local source_text = tostring(source_line or "")
    local line = source_text
    if line:sub(-1) == "\n" then line = line:sub(1, -2) end
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end

    local index = 1
    local accounted = 0
    local segment_start = 1
    local length = #line
    while index <= length do
      local byte = line:byte(index)
      if in_quotes then
        if byte == 34 then
          append(field_parts, line:sub(segment_start, index - 1))
          if line:byte(index + 1) == 34 then
            append(field_parts, '"')
            record_touched = true
            index = index + 2
          else
            in_quotes = false
            index = index + 1
          end
          segment_start = index
        else
          index = index + 1
        end
      elseif byte == delimiter_byte then
        append(field_parts, line:sub(segment_start, index - 1))
        finish_field()
        record_touched = true
        index = index + 1
        segment_start = index
      elseif byte == 34 and field_start then
        append(field_parts, line:sub(segment_start, index - 1))
        in_quotes = true
        record_touched = true
        index = index + 1
        segment_start = index
      else
        record_touched = true
        field_start = false
        index = index + 1
      end

      if index - accounted >= yield_every then
        if not maybe_yield(index - accounted) then return nil, "cancelled" end
        accounted = index
      end
    end
    append(field_parts, line:sub(segment_start))
    if not maybe_yield(math.max(0, #source_text - accounted)) then
      return nil, "cancelled"
    end

    if in_quotes then
      if line_number < #lines then append(field_parts, "\n") end
    else
      finish_record(line_number)
    end
  end

  if in_quotes then
    warning = string.format("Unfinished quoted field at line %d", #lines)
    finish_record(math.max(1, #lines))
  end

  if #records == 0 then
    return {
      headers = {},
      rows = {},
      column_count = 0,
      warning = warning,
      bytes = processed,
    }
  end

  local header_record = table.remove(records, 1)
  local headers = header_record.cells
  for column = #headers + 1, max_columns do
    headers[column] = "Column " .. column
  end
  for _, row in ipairs(records) do
    for column = #row.cells + 1, max_columns do row.cells[column] = false end
  end

  return {
    headers = headers,
    rows = records,
    column_count = max_columns,
    warning = warning,
    bytes = processed,
    header_source_line1 = header_record.source_line1,
    header_source_line2 = header_record.source_line2,
  }
end

return parser
